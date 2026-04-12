"""Router for subway line arrivals and route shapes."""

from __future__ import annotations

import asyncio
import contextlib
import json
import math
import os
import tempfile
import time
from pathlib import Path as _Path

from fastapi import APIRouter, HTTPException, Path, Query, Response

from app.config import get_settings
from app.models import (
    RESP_404,
    RESP_503,
    AllSubwayLinesResponse,
    AllSubwayStationsResponse,
    BusStop,
    DirectionShape,
    ProcessedStationsResponse,
    RouteShape,
    SubwayLineOverlay,
    SubwayStation,
    TrackArrival,
    TrunkGroupPolylines,
)
from app.services.gtfs.realtime_parser import get_arrivals_for_line
from app.services.mapping.subway.corridor import (
    ROUTE_TO_TRUNK,
    apply_topological_offsets,
    get_processed_stops,
    get_trunk_crossings,
    get_trunk_polylines,
)
from app.services.mapping.subway.shapes import (
    enrich_stops_with_transfers,
    get_all_subway_stations,
    get_subway_route_shape,
    get_subway_service_type,
)
from app.utils.logger import TrackLogger
from app.utils.polyline_utils import (
    decode_polyline as _decode_polyline,
)
from app.utils.polyline_utils import (
    densify_wgs84 as _densify_wgs84,
)
from app.utils.polyline_utils import (
    encode_polyline as _encode_polyline,
)
from app.utils.polyline_utils import (
    simplify_polyline as _simplify_polyline,
)
from app.utils.transit_utils import (
    clean_route_id,
    get_all_subway_lines,
    get_subway_color,
    resolve_subway_feed_key,
)

router = APIRouter(tags=["subway"])

# NOTE: Static path endpoints MUST be declared before the wildcard /{line_id}
# endpoint, otherwise FastAPI would match literal segments as a line_id.

# ── Response-level cache for /subway/shapes/all ──
# The pipeline + dir1 clipping is extremely CPU-heavy (60-90s cold).
# Cache the fully-built response so only the first request pays the cost.
#
# Three cache layers:
#   1. Pre-serialized JSON bytes: returned directly as a Response, skipping
#      Pydantic → JSON serialization on every request (~100ms savings).
#   2. In-memory Pydantic model: for code that needs the parsed object.
#   3. Disk:      survives restarts / deploys so the 60-90s corridor
#      pipeline only needs to run ONCE.  The disk cache is loaded at
#      startup and the in-memory cache is populated from it.
_shapes_all_cache: AllSubwayLinesResponse | None = None
_shapes_all_json_bytes: bytes | None = None  # pre-serialized JSON
# Lazy — must be created inside the running event loop to avoid
# "Lock is bound to a different event loop" errors with gunicorn workers.
_shapes_all_lock: asyncio.Lock | None = None
_shapes_all_building = False  # True while pipeline is running


def _get_shapes_all_lock() -> asyncio.Lock:
    global _shapes_all_lock
    if _shapes_all_lock is None:
        _shapes_all_lock = asyncio.Lock()
    return _shapes_all_lock

# ── Disk cache versioning ──
# Bump this whenever corridor_pipeline.py changes affect polyline output.
# The persistent Render disk survives deploys, so without a version tag
# the stale cached pipeline result would be served forever.
_SHAPES_DISK_CACHE_VERSION = 5  # v5: guard against empty-build poison
_SHAPES_DISK_CACHE_PATH = (
    _Path(__file__).resolve().parent.parent
    / "data"
    / f"_cache_shapes_all_v{_SHAPES_DISK_CACHE_VERSION}.json"
)
# Clean up caches from previous versions on import
for _old in (
    _Path(__file__).resolve().parent.parent / "data" / "_cache_shapes_all.json",
    _Path(__file__).resolve().parent.parent / "data" / "_cache_shapes_all_v1.json",
    _Path(__file__).resolve().parent.parent / "data" / "_cache_shapes_all_v2.json",
    _Path(__file__).resolve().parent.parent / "data" / "_cache_shapes_all_v3.json",
    _Path(__file__).resolve().parent.parent / "data" / "_cache_shapes_all_v4.json",
):
    if _old.exists():
        _old.unlink(missing_ok=True)


def _load_shapes_disk_cache() -> AllSubwayLinesResponse | None:
    """Try to load the shapes/all response from disk cache."""
    try:
        if not _SHAPES_DISK_CACHE_PATH.exists():
            return None
        raw = json.loads(_SHAPES_DISK_CACHE_PATH.read_text())
        resp = AllSubwayLinesResponse(**raw)
        if not resp.lines:
            # Disk cache was written during an incomplete cold start —
            # treat it as missing so the pipeline rebuilds correctly.
            TrackLogger.warning(
                "[SHAPES_DISK] Disk cache has 0 lines — deleting and rebuilding",
                tag="SHAPES",
            )
            _SHAPES_DISK_CACHE_PATH.unlink(missing_ok=True)
            return None
        TrackLogger.info(
            f"[SHAPES_DISK] Loaded shapes/all disk cache "
            f"({len(resp.lines)} lines, {len(resp.trunk_polylines)} trunks)",
            tag="SHAPES",
        )
        return resp
    except Exception as exc:
        TrackLogger.warning(
            f"[SHAPES_DISK] Failed to load disk cache: {exc}", tag="SHAPES"
        )
        return None


def _save_shapes_disk_cache(resp: AllSubwayLinesResponse) -> None:
    """Persist the shapes/all response to disk so it survives restarts.

    Uses atomic write (tmp file + rename) so a crash mid-write can't
    leave a corrupted JSON file that breaks the next cold start.
    """
    if not resp.lines:
        # Never persist an empty result — it would poison the disk cache
        # and cause every subsequent cold start to return 0 lines forever.
        TrackLogger.warning(
            "[SHAPES_DISK] Skipping disk cache write — 0 lines (GTFS not ready)",
            tag="SHAPES",
        )
        return
    try:
        _SHAPES_DISK_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        data = resp.model_dump(mode="json")
        payload = json.dumps(data)
        # Write to a temp file in the same directory, then atomic rename.
        # os.rename() is atomic on POSIX when src and dst are on the same
        # filesystem — guaranteed here since both are in app/data/.
        fd, tmp_path = tempfile.mkstemp(
            dir=_SHAPES_DISK_CACHE_PATH.parent,
            suffix=".tmp",
        )
        try:
            with open(fd, "w") as f:
                f.write(payload)
            os.replace(tmp_path, _SHAPES_DISK_CACHE_PATH)
        except BaseException:
            # Clean up the temp file if rename failed
            with contextlib.suppress(OSError):
                os.unlink(tmp_path)
            raise
        size_kb = _SHAPES_DISK_CACHE_PATH.stat().st_size / 1024
        TrackLogger.info(
            f"[SHAPES_DISK] Saved shapes/all disk cache ({size_kb:.0f} KB)",
            tag="SHAPES",
        )
    except Exception as exc:
        TrackLogger.warning(
            f"[SHAPES_DISK] Failed to save disk cache: {exc}", tag="SHAPES"
        )


def _build_shapes_all_sync() -> AllSubwayLinesResponse:
    """Build the full subway system map response — CPU-bound, runs in thread pool."""
    from app.services.mapping.subway.shapes import (
        _load_route_shapes,
        _load_shape_stops,
        _load_shapes,
        _unpack_coords,
    )

    # Routes to skip: express duplicates that share tracks with parent lines.
    # FS (Franklin Shuttle) and GS (42nd St Shuttle) are NOT skipped —
    # they are unique standalone routes with their own physical tracks.
    skip_variants = {"6X", "7X", "FX", "SR"}

    overlays: list[SubwayLineOverlay] = []
    lines = [line for line in get_all_subway_lines() if line not in skip_variants]

    route_shapes = _load_route_shapes()
    shapes_data = _load_shapes()
    shape_stops = _load_shape_stops()

    # Track direction-1 shapes that cover unique stations.
    # These will be appended AFTER the pipeline to avoid disrupting
    # the trunk-group merge (adding large overlapping reverse-direction
    # shapes can corrupt offsets for other routes in the same trunk).
    def _station_id(sid: str) -> str:
        """Strip platform suffix (N/S) to get the parent station ID."""
        return sid[:-1] if sid and sid[-1] in ("N", "S") else sid

    # Per-route: (line, shape_id) pairs from the opposite direction
    dir1_extras: list[tuple[str, str]] = []

    for line in lines:
        direction_shapes = route_shapes.get(line)
        if not direction_shapes:
            continue

        # Use direction 0 (northbound) as primary — for most routes,
        # northbound and southbound trace the same physical tracks.
        primary_dir = 0 if 0 in direction_shapes else min(direction_shapes.keys())
        shape_ids = direction_shapes[primary_dir]

        polylines_raw: list[list[tuple[float, float]]] = []
        for shape_id in shape_ids:
            shape_buf = shapes_data.get(shape_id)
            if shape_buf:
                raw = _unpack_coords(shape_buf)
                polylines_raw.append(raw)

        if not polylines_raw:
            continue

        # No additional dedup needed here — _load_route_shapes() already
        # performs smart unique-stop dedup that preserves real branches
        # (e.g. A train's Far Rockaway, Lefferts Blvd, Rockaway Park).
        # The old geometric 70% overlap dedup was killing branch polylines
        # because branches share a trunk with the main line.

        encoded = [_encode_polyline(_densify_wgs84(coords)) for coords in polylines_raw]
        color = get_subway_color(line)
        overlays.append(
            SubwayLineOverlay(
                route_id=line,
                color_hex=color,
                polylines=encoded,
            )
        )

        # Check direction 1 for shapes covering unique stations
        covered_stations: set[str] = set()
        for sid in shape_ids:
            covered_stations.update(_station_id(s) for s in shape_stops.get(sid, []))

        other_dir = 1 - primary_dir
        if other_dir in direction_shapes:
            for sid in direction_shapes[other_dir]:
                other_stations = {_station_id(s) for s in shape_stops.get(sid, [])}
                unique = other_stations - covered_stations
                if len(unique) >= 2:
                    dir1_extras.append((line, sid))
                    covered_stations.update(other_stations)

    # Apply topological graph pipeline so co-located trunk groups
    # (e.g. blue A/C/E + green 4/5/6 on Lex Ave) render as parallel
    # stripes with proper lane ordering and circular arc fillets.
    overlays = apply_topological_offsets(overlays)

    # ── Export trunk-level merged polylines ──
    # These are the Phase 1+3 output: one set of continuous polylines
    # per trunk colour group with corridor offsets applied.  The client
    # uses these directly for rendering, avoiding double-stacked lines
    # from per-route GTFS shapes with slightly different GPS traces.
    trunk_polys_raw = get_trunk_polylines()

    # ── Post-pipeline: Append direction-1 branch extensions ──
    # These shapes cover stations not reachable by any direction-0 shape
    # (e.g. R train south of 36th St to Bay Ridge).  They're added AFTER
    # the pipeline to avoid disrupting the trunk-group merge.
    #
    # IMPORTANT: We clip each dir-1 shape to only the portion that
    # diverges from the existing trunk geometry.  Without clipping, the
    # full reverse-direction polyline (which overlaps the trunk for most
    # of its length) would render as a second un-offset line on top of
    # the corridor-offset trunk — producing a visually doubled line.
    if dir1_extras:
        overlay_map: dict[str, SubwayLineOverlay] = {o.route_id: o for o in overlays}
        # Build a mutable lookup for trunk polylines
        trunk_poly_map: dict[int, list[str]] = {
            tp["trunk_index"]: list(tp["polylines"]) for tp in trunk_polys_raw
        }

        # Decode existing trunk polylines into coordinate lists for
        # proximity testing.  We'll check each dir-1 vertex against
        # these to find where the branch diverges from the trunk.
        from app.providers import get_provider as _get_provider

        _prov = _get_provider()
        METERS_PER_DEG: float = _prov.meters_per_deg_lat
        COS_LAT: float = _prov.cos_lat

        def _trunk_coords(trunk_idx: int) -> list[list[tuple[float, float]]]:
            """Decode all existing trunk polylines for a trunk group."""
            enc_list: list[str] = trunk_poly_map.get(trunk_idx, [])
            result: list[list[tuple[float, float]]] = []
            for enc in enc_list:
                with contextlib.suppress(Exception):
                    result.append(_decode_polyline(enc))
            return result

        def _min_dist_to_trunk(
            pt: tuple[float, float],
            trunk_lines: list[list[tuple[float, float]]],
        ) -> float:
            """Minimum approximate distance (meters) from pt to any trunk polyline vertex."""
            best: float = float("inf")
            plat, plon = pt
            for line in trunk_lines:
                for tlat, tlon in line:
                    dlat = (plat - tlat) * METERS_PER_DEG
                    dlon = (plon - tlon) * METERS_PER_DEG * COS_LAT
                    d = (dlat * dlat + dlon * dlon) ** 0.5
                    if d < best:
                        best = d
                        if d < 30:  # early exit — clearly on trunk
                            return d
            return best

        DIVERGE_DIST_M: float = 60.0

        for line, sid in dir1_extras:
            shape_buf = shapes_data.get(sid)
            if not shape_buf:
                continue
            raw = list(reversed(_unpack_coords(shape_buf)))

            # ── Clip to the unique branch portion ──
            trunk_idx = ROUTE_TO_TRUNK.get(line)
            trunk_lines = _trunk_coords(trunk_idx) if trunk_idx is not None else []

            if trunk_lines and len(raw) > 5:
                # Walk from the START of the shape (which is the terminus
                # end after reversal) to find where it first enters the
                # trunk.  We want to keep everything BEFORE that point.
                # Walk from the END (trunk side) backwards to find the
                # divergence point.
                diverge_idx: int = len(raw)
                for i in range(len(raw) - 1, -1, -1):
                    d = _min_dist_to_trunk(raw[i], trunk_lines)
                    if d > DIVERGE_DIST_M:
                        diverge_idx = i + 1
                        break
                else:
                    # Every vertex is far from trunk — keep all
                    diverge_idx = len(raw)

                # Add a few overlap vertices for visual connection.
                # Use 5 instead of 3 — ensures enough geometric overlap
                # for MapLibre's round join to seamlessly blend the
                # branch into the trunk at the junction point.
                OVERLAP_VERTS: int = 5
                clip_end = min(len(raw), diverge_idx + OVERLAP_VERTS)

                if clip_end < len(raw) - 5:
                    # Significant clipping — only keep the branch portion.
                    # Also trim any overlap vertices that run parallel to
                    # the trunk within 40m — these create a visible
                    # double-line effect since they have slightly different
                    # GPS traces.
                    clipped = raw[:clip_end]

                    # Trim parallel tail: if the last N overlap vertices
                    # are all within 40m of the trunk, remove them except
                    # the last one (which serves as the connection point).
                    PARALLEL_TRIM_M: float = 40.0
                    trim_from = clip_end
                    for i in range(clip_end - 1, max(diverge_idx, 0) - 1, -1):
                        if i <= 0:
                            break
                        d = _min_dist_to_trunk(clipped[i], trunk_lines)
                        if d > PARALLEL_TRIM_M:
                            break
                        trim_from = i

                    if trim_from < clip_end - 1:
                        # Keep everything up to the first parallel vertex,
                        # plus the very last vertex as the join point.
                        clipped = [*clipped[:trim_from], clipped[-1]]

                    TrackLogger.info(
                        f"[Dir1] Clipped {line} shape {sid}: {len(raw)} → {len(clipped)} pts "
                        f"(diverges at idx {diverge_idx})"
                    )
                    raw = clipped

            if len(raw) < 2:
                continue

            enc = _encode_polyline(_densify_wgs84(raw))
            if line in overlay_map:
                overlay_map[line].polylines.append(enc)
                TrackLogger.info(
                    f"[Dir1] Added reverse shape {sid} to {line} ({len(raw)} pts)"
                )
            # Also append to trunk polylines
            if trunk_idx is not None:
                if trunk_idx not in trunk_poly_map:
                    trunk_poly_map[trunk_idx] = []
                trunk_poly_map[trunk_idx].append(enc)
        # Update the raw trunk polys with dir-1 additions
        for tp in trunk_polys_raw:
            ti = tp["trunk_index"]
            if ti in trunk_poly_map:
                tp["polylines"] = trunk_poly_map[ti]

    trunk_polylines = [TrunkGroupPolylines(**tp) for tp in trunk_polys_raw]

    # Detect crossing points between different trunk groups
    crossings_raw = get_trunk_crossings()
    from app.models import CrossingPoint

    crossing_points = [CrossingPoint(**c) for c in crossings_raw]

    total_polys = sum(len(o.polylines) for o in overlays)
    total_trunk = sum(len(tp.polylines) for tp in trunk_polylines)
    TrackLogger.info(
        f"Subway shapes/all: {len(overlays)} lines, {total_polys} per-route polylines, "
        f"{len(trunk_polylines)} trunk groups, {total_trunk} trunk polylines, "
        f"{len(crossing_points)} crossing points"
    )
    return AllSubwayLinesResponse(
        lines=overlays, trunk_polylines=trunk_polylines, crossings=crossing_points
    )


def set_shapes_all_cache(resp: AllSubwayLinesResponse) -> None:
    """Set the in-memory shapes cache (called by warmup to avoid a second
    CPU-heavy computation when the first client request arrives)."""
    if not resp.lines:
        # Refuse to cache an empty result — this happens when the pipeline
        # runs before GTFS data finishes loading.  Keeping _shapes_all_json_bytes
        # as None forces every subsequent request to rebuild until data is ready.
        TrackLogger.warning(
            "[SHAPES] set_shapes_all_cache called with 0 lines — skipping",
            tag="SHAPES",
        )
        return
    global _shapes_all_cache, _shapes_all_json_bytes
    _shapes_all_cache = resp
    # Pre-serialize to JSON bytes so the endpoint skips Pydantic serialization.
    _shapes_all_json_bytes = json.dumps(resp.model_dump(mode="json")).encode("utf-8")


@router.get(
    "/subway/shapes/all",
    response_model=AllSubwayLinesResponse,
    summary="Get all subway line shapes",
    description=(
        "Returns encoded polylines for every subway line — used to draw the full NYC subway system map. "
        "Includes pre-merged trunk geometry with lane offsets for rendering parallel multi-track corridors "
        "(e.g. A/C/E on 8th Ave). The payload is 3–5\u202fMB uncompressed; GZip is enabled."
    ),
    responses={**RESP_503},
)
async def subway_shapes_all() -> Response:
    """Return polylines for ALL subway lines — the full system map.

    Response includes per-line overlays and pre-merged trunk geometry
    (colour-grouped polylines with lane offsets for multi-track rendering).

    The payload is 3–5 MB uncompressed; GZip shrinks it ~5×.
    Cached with `max-age=3600` — geometry only changes on deploy.

    Returns `503` with `Retry-After: 15` if the corridor pipeline is still
    computing (first boot only, ~60–90 s).
    """
    global _shapes_all_cache, _shapes_all_json_bytes, _shapes_all_building

    # Fast path: pre-serialized bytes ready
    if _shapes_all_json_bytes is not None:
        return Response(
            content=_shapes_all_json_bytes,
            media_type="application/json",
        )

    # Pipeline currently building — tell client to retry shortly
    if _shapes_all_building:
        return Response(
            content=b'{"detail":"Subway shapes computing, retry shortly"}',
            status_code=503,
            media_type="application/json",
            headers={"Retry-After": "15"},
        )

    async with _get_shapes_all_lock():
        # Double-check after acquiring lock
        if _shapes_all_json_bytes is not None:
            return Response(
                content=_shapes_all_json_bytes,
                media_type="application/json",
            )

        # Try disk cache before burning 60-90s of CPU
        disk_result = _load_shapes_disk_cache()
        if disk_result is not None:
            set_shapes_all_cache(disk_result)
            return Response(
                content=_shapes_all_json_bytes,
                media_type="application/json",
            )

        _shapes_all_building = True
        try:
            loop = asyncio.get_running_loop()
            result = await loop.run_in_executor(None, _build_shapes_all_sync)
            set_shapes_all_cache(result)
            _save_shapes_disk_cache(result)
        finally:
            _shapes_all_building = False

        # If the pipeline returned 0 lines (GTFS not yet loaded), return the
        # empty result but explicitly tell all caches not to store it — the
        # client must retry and hit the network rather than caching the miss.
        if _shapes_all_json_bytes is None:
            empty_bytes = json.dumps(result.model_dump(mode="json")).encode("utf-8")
            return Response(
                content=empty_bytes,
                media_type="application/json",
                headers={"Cache-Control": "no-store"},
            )

        return Response(
            content=_shapes_all_json_bytes,
            media_type="application/json",
        )


@router.get(
    "/subway/stations/all",
    response_model=AllSubwayStationsResponse,
    summary="Get all subway stations",
    description=(
        "Returns all 470+ unique subway stations with the route IDs that serve each — "
        "for rendering map markers with multi-line badges."
    ),
    responses={**RESP_503},
)
async def subway_stations_all() -> AllSubwayStationsResponse:
    """Return all unique subway stations with the lines that serve them.

    Each station includes `id`, `name`, `lat`, `lon`, and a `routes` array
    (e.g. `["1", "2", "3", "A", "C", "E"]` for Penn Station).
    """
    raw_stations = get_all_subway_stations()
    stations = []
    for s in raw_stations:
        stations.append(SubwayStation(**s))

    return AllSubwayStationsResponse(stations=stations)


@router.get(
    "/subway/stations/processed",
    response_model=ProcessedStationsResponse,
    summary="Get processed station positions",
    description=(
        "Returns stations snapped onto offset polylines with transfer flags for precise map rendering. "
        "Each station includes per-route snapped coordinates and an `is_transfer` flag for stations "
        "that span multiple trunk groups (e.g. Times Sq–42 St)."
    ),
    responses={**RESP_503},
)
async def subway_stations_processed() -> ProcessedStationsResponse:
    """Return stations with positions snapped onto the offset polylines.

    Each station includes:
    - `is_transfer` — `true` when the station spans ≥ 2 trunk groups
    - `positions` — per-route snapped `(lat, lon)` for circle placement on each line

    Must be called after `/subway/shapes/all` has populated the pipeline cache.
    """
    raw = get_processed_stops()
    return ProcessedStationsResponse(stations=raw)


@router.get(
    "/subway/stations/nearby",
    response_model=AllSubwayStationsResponse,
    summary="Get nearby subway stations",
    description=(
        "Returns subway stations within a given radius of a GPS coordinate, sorted by distance. "
        "Lighter than downloading all 470+ stations when only nearby ones are needed."
    ),
    responses={**RESP_503},
)
async def subway_stations_nearby(
    lat: float = Query(
        ...,
        ge=-90,
        le=90,
        description="Latitude of the user's location.",
        examples=[40.7580],
    ),
    lon: float = Query(
        ...,
        ge=-180,
        le=180,
        description="Longitude of the user's location.",
        examples=[-73.9855],
    ),
    radius: int = Query(
        1600,
        ge=100,
        le=10000,
        description="Maximum search radius from the request location (in meters). Defaults to 1600\u202fm.",
        examples=[1600],
    ),
) -> AllSubwayStationsResponse:
    """Return subway stations near the user's location.

    Filters the full station list server-side and returns only stations within
    `radius` meters, sorted by proximity. Much lighter than downloading all 470+ stations.
    """
    raw_stations = get_all_subway_stations()

    # Filter by distance on the server
    nearby: list[SubwayStation] = []
    lat_rad = math.radians(lat)
    meters_per_deg_lat = 111_000.0
    meters_per_deg_lon = 111_000.0 * math.cos(lat_rad)

    for s in raw_stations:
        dlat = (s["lat"] - lat) * meters_per_deg_lat
        dlon = (s["lon"] - lon) * meters_per_deg_lon
        dist = math.sqrt(dlat * dlat + dlon * dlon)
        if dist <= radius:
            nearby.append(SubwayStation(**s))

    nearby.sort(
        key=lambda s: (
            ((s.lat - lat) * meters_per_deg_lat) ** 2
            + ((s.lon - lon) * meters_per_deg_lon) ** 2
        )
    )

    TrackLogger.info(
        f"Subway stations/nearby: {len(nearby)} stations within {radius}m of ({lat:.4f}, {lon:.4f})"
    )
    return AllSubwayStationsResponse(stations=nearby)


@router.get(
    "/subway/shape/{route_id}",
    response_model=RouteShape,
    summary="Get single subway line shape",
    description=(
        "Returns the full geometry, ordered stops, and per-direction shapes for a single subway line. "
        "Includes `service_type` (`express`, `local`, or `mixed`) and stop-level transfer annotations."
    ),
    responses={**RESP_404},
)
async def subway_shape(
    route_id: str = Path(
        ...,
        description="Subway route ID (case-insensitive).",
        examples=["A", "7", "L", "GS"],
    ),
) -> RouteShape:
    """Return the full route geometry and ordered stops for a subway line.

    **Path parameter:** Any valid subway route ID — `A`, `7`, `L`, `GS`, etc.

    Response includes:
    - `polylines` — Google-encoded polyline strings for the route geometry
    - `stops` — ordered list of all stations along the line (with transfer info)
    - `directions` — per-direction shapes split by GTFS `direction_id` (0 / 1)
    - `service_type` — `"express"`, `"local"`, or `"mixed"`
    """
    clean_id = clean_route_id(route_id)
    result = get_subway_route_shape(clean_id)
    if result is None:
        raise HTTPException(
            status_code=404,
            detail=f"No shape data for subway line: {route_id}",
        )

    polylines_raw, stop_entries, direction_data = result

    # Merge adjacent polyline segments whose endpoints are within 50 m,
    # densify curves (same 1 m resolution as the system-map polylines),
    # then simplify with RDP to cut point count without visible change.
    # Densification first ensures curves follow the real track geometry;
    # simplification then trims redundant collinear points.
    merged_all = _merge_polyline_segments(polylines_raw)
    encoded_polylines: list[str] = [
        _encode_polyline(_simplify_polyline(_densify_wgs84(coords), tolerance=0.00002))
        for coords in merged_all
    ]

    stops = [
        BusStop(
            id=entry.stop_id,
            name=entry.name,
            lat=entry.lat,
            lon=entry.lon,
        )
        for entry in stop_entries
    ]

    # Enrich stops with transfer route_ids from station data
    enrich_stops_with_transfers(stops, current_route=clean_id)

    # Build per-direction shapes — merge + densify + simplify each direction
    directions: list[DirectionShape] = []
    for dd in direction_data:
        merged_dir = _merge_polyline_segments(dd.polylines)
        dir_encoded = [
            _encode_polyline(
                _simplify_polyline(_densify_wgs84(coords), tolerance=0.00002)
            )
            for coords in merged_dir
        ]
        dir_stops = [
            BusStop(id=s.stop_id, name=s.name, lat=s.lat, lon=s.lon) for s in dd.stops
        ]
        enrich_stops_with_transfers(dir_stops, current_route=clean_id)
        directions.append(
            DirectionShape(
                direction_id=dd.direction_id,
                headsign=dd.headsign,
                polylines=dir_encoded,
                stops=dir_stops,
                service_type=get_subway_service_type(clean_id),
                local_only_stop_ids=dd.local_only_stop_ids,
            )
        )

    TrackLogger.info(
        f"Subway shape '{clean_id}': {len(encoded_polylines)} polyline(s), "
        f"{len(stops)} stops, {len(directions)} directions"
    )

    return RouteShape(
        route_id=clean_id,
        polylines=encoded_polylines,
        stops=stops,
        directions=directions,
        service_type=get_subway_service_type(clean_id),
    )


@router.get(
    "/subway/{line_id}",
    response_model=list[TrackArrival],
    summary="Get real-time subway arrivals",
    description=(
        "Returns upcoming real-time arrivals for a specific subway line from GTFS-RT feeds. "
        "Arrivals are sorted soonest-first and capped at the per-line maximum. "
        "Returns an empty array (not an error) if the MTA feed is temporarily unavailable."
    ),
    responses={**RESP_404},
)
async def subway_arrivals(
    line_id: str = Path(
        ...,
        description="Subway line ID (case-insensitive).",
        examples=["A", "7", "L", "GS"],
    ),
    response: Response = None,
) -> list[TrackArrival]:
    """Return upcoming arrivals for a subway line.

    **Path parameter:** Any valid subway line ID — `A`, `7`, `L`, `GS`, etc.

    Each arrival includes `station_name`, `direction`, `destination`,
    `minutes_away`, `arrival_ts` (epoch), and `status`.

    Results are filtered to future arrivals within the configured time horizon,
    sorted soonest-first, and capped at the per-line maximum.

    Returns an empty array (not an error) if the MTA feed is temporarily unavailable.
    """
    clean_id = clean_route_id(line_id)
    if resolve_subway_feed_key(clean_id) is None:
        raise HTTPException(
            status_code=404,
            detail=f"Unknown subway line: {line_id}",
        )
    try:
        settings = get_settings()
        max_minutes = settings.app_settings.max_arrival_minutes
        max_results = settings.app_settings.max_arrivals_per_line

        arrivals = await get_arrivals_for_line(clean_id)
        now = int(time.time())
        # Filter to: (1) this route only, (2) future, (3) within time horizon
        fresh = [
            a
            for a in arrivals
            if a.route_id == clean_id
            and a.arrival_ts
            and a.arrival_ts > now
            and (a.arrival_ts - now) <= max_minutes * 60
        ]
        # Recalculate minutes_away from the current time
        for a in fresh:
            a.minutes_away = max(0, (a.arrival_ts - now) // 60)
        # Sort by soonest first, then cap total count
        fresh.sort(key=lambda a: a.arrival_ts)

        # ── Schedule backfill ─────────────────────────────────────
        # Extend beyond the GTFS-RT horizon with static GTFS schedule
        # so the client can display "Scheduled" chips hours ahead.
        try:
            from app.services.transit.schedule_service import schedule_service

            sched = await schedule_service.get_line_schedule_async(
                clean_id, limit=max_results
            )
            # Deduplicate: skip scheduled entries whose trip_id already
            # appears in the live RT set.
            rt_trip_ids = {a.trip_id for a in fresh if a.trip_id}
            rt_keys = {
                (a.station, a.arrival_ts) for a in fresh if a.arrival_ts
            }
            for s in sched:
                if s.trip_id and s.trip_id in rt_trip_ids:
                    continue
                if (s.station, s.arrival_ts) in rt_keys:
                    continue
                fresh.append(s)
            fresh.sort(key=lambda a: a.arrival_ts or 0)
        except Exception as sched_exc:
            TrackLogger.warning(
                f"[SUBWAY] /{line_id}: schedule backfill failed ({sched_exc})",
                tag="SUBWAY",
            )

        return fresh[:max_results]
    except Exception as exc:
        TrackLogger.warning(
            f"[SUBWAY] /{line_id}: feed error ({exc}) — returning empty fallback",
            tag="SUBWAY",
        )
        response.headers["X-Track-Degraded"] = "subway-arrivals-fallback"
        return []


# ---------------------------------------------------------------------------
# Polyline segment merging
# ---------------------------------------------------------------------------


def _merge_polyline_segments(
    segments: list[list[tuple[float, float]]],
    gap_threshold_m: float = 200.0,
) -> list[list[tuple[float, float]]]:
    """Merge adjacent polyline segments into continuous lines.

    GTFS shapes often produce multiple fragments per route+direction that
    are really one continuous line broken at arbitrary points.  This joins
    segments whose start/end points are within *gap_threshold_m* meters,
    dramatically reducing the overlay count that MapKit must render.

    Uses a simple greedy merge (no junction guard) because the iOS client
    applies its own branch-aware ``unifyTrainPolylines()`` that handles
    overlapping trunks intelligently. Merging aggressively here gives the
    client fewer, longer polylines to work with.

    Returns a new list of coordinate arrays (often shorter than input).
    """
    if len(segments) <= 1:
        return segments

    from app.providers import get_provider as _get_provider

    _prov = _get_provider()
    METERS_PER_DEG = _prov.meters_per_deg_lat

    def _dist_m(a: tuple[float, float], b: tuple[float, float]) -> float:
        dlat = (a[0] - b[0]) * METERS_PER_DEG
        dlon = (a[1] - b[1]) * METERS_PER_DEG * _prov.cos_lat
        return (dlat * dlat + dlon * dlon) ** 0.5

    chains: list[list[tuple[float, float]]] = [list(segments[0])]

    for seg in segments[1:]:
        if not seg:
            continue
        merged = False
        for chain in chains:
            if _dist_m(chain[-1], seg[0]) < gap_threshold_m:
                chain.extend(seg[1:])
                merged = True
                break
            if _dist_m(chain[0], seg[-1]) < gap_threshold_m:
                chain[:0] = seg[:-1]
                merged = True
                break
            if _dist_m(chain[-1], seg[-1]) < gap_threshold_m:
                chain.extend(reversed(seg[:-1]))
                merged = True
                break
            if _dist_m(chain[0], seg[0]) < gap_threshold_m:
                chain[:0] = list(reversed(seg[1:]))
                merged = True
                break
        if not merged:
            chains.append(list(seg))

    # Second pass: merge chains using a spatial hash so lookups are O(1)
    # instead of scanning every chain pair.  Keys are coordinate tuples
    # rounded to ~11 m precision (5 decimal places ≈ 1.1 m, but we use 4
    # to create a coarser grid that captures the 200 m gap threshold with
    # neighboring-cell checks).
    _GRID_DECIMALS = 3  # ~111 m cells — comfortably covers 200 m threshold

    def _grid_key(pt: tuple[float, float]) -> tuple[int, int]:
        return (round(pt[0], _GRID_DECIMALS), round(pt[1], _GRID_DECIMALS))

    def _neighbor_keys(pt: tuple[float, float]) -> list[tuple[int, int]]:
        """Return the grid cell + 8 neighbors to handle points near cell edges."""
        base_lat = round(pt[0], _GRID_DECIMALS)
        base_lon = round(pt[1], _GRID_DECIMALS)
        step = 10 ** (-_GRID_DECIMALS)
        keys = []
        for dlat in (-step, 0, step):
            for dlon in (-step, 0, step):
                keys.append(
                    (
                        round(base_lat + dlat, _GRID_DECIMALS),
                        round(base_lon + dlon, _GRID_DECIMALS),
                    )
                )
        return keys

    did_merge = True
    while did_merge:
        did_merge = False
        # Build spatial index: grid_cell → set of chain indices with an
        # endpoint in that cell.  Only endpoints matter for merging.
        from collections import defaultdict as _defaultdict

        endpoint_index: dict[tuple, set[int]] = _defaultdict(set)
        for idx, chain in enumerate(chains):
            for key in _neighbor_keys(chain[0]):
                endpoint_index[key].add(idx)
            for key in _neighbor_keys(chain[-1]):
                endpoint_index[key].add(idx)

        merged_away: set[int] = set()
        for i in range(len(chains)):
            if i in merged_away:
                continue
            # Collect candidate chain indices near our endpoints
            candidates: set[int] = set()
            for key in _neighbor_keys(chains[i][0]):
                candidates.update(endpoint_index.get(key, set()))
            for key in _neighbor_keys(chains[i][-1]):
                candidates.update(endpoint_index.get(key, set()))
            candidates.discard(i)
            candidates -= merged_away

            for j in sorted(candidates):
                if _dist_m(chains[i][-1], chains[j][0]) < gap_threshold_m:
                    chains[i] = chains[i] + chains[j][1:]
                    merged_away.add(j)
                    did_merge = True
                    break
                if _dist_m(chains[j][-1], chains[i][0]) < gap_threshold_m:
                    chains[i] = chains[j] + chains[i][1:]
                    merged_away.add(j)
                    did_merge = True
                    break
                if _dist_m(chains[i][-1], chains[j][-1]) < gap_threshold_m:
                    chains[i] = chains[i] + list(reversed(chains[j][:-1]))
                    merged_away.add(j)
                    did_merge = True
                    break
                if _dist_m(chains[i][0], chains[j][0]) < gap_threshold_m:
                    chains[i] = list(reversed(chains[j][1:])) + chains[i]
                    merged_away.add(j)
                    did_merge = True
                    break

        if merged_away:
            chains = [c for idx, c in enumerate(chains) if idx not in merged_away]

    return chains
