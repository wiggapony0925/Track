#
# subway.py
# TrackBackend
#
# Router for subway line arrivals and route shapes.
#

from __future__ import annotations

import math
import time

from fastapi import APIRouter, HTTPException, Query, Response

from app.models import (
    AllSubwayLinesResponse,
    AllSubwayStationsResponse,
    BusStop,
    DirectionShape,
    RouteShape,
    SubwayLineOverlay,
    SubwayStation,
    TrackArrival,
)
from app.services.data_cleaner import get_arrivals_for_line
from app.services.subway_shapes import get_all_subway_stations, get_subway_route_shape, get_subway_service_type
from app.services.station_lookup import get_nearby_stop_ids, get_stop_info
from app.utils.logger import TrackLogger
from app.utils.polyline_utils import decode_polyline as _decode_polyline, encode_polyline as _encode_polyline
from app.utils.transit_utils import (
    clean_route_id,
    get_all_subway_lines,
    get_subway_color,
    resolve_subway_feed_key,
)

router = APIRouter(tags=["subway"])

# NOTE: Static path endpoints MUST be declared before the wildcard /{line_id}
# endpoint, otherwise FastAPI would match literal segments as a line_id.


def _simplify_polyline(
    coords: list[tuple[float, float]], tolerance: float = 0.0001
) -> list[tuple[float, float]]:
    """Ramer-Douglas-Peucker polyline simplification.

    Removes intermediate points that lie within *tolerance* degrees of the
    line segment between their neighbours.  A tolerance of 0.0001° ≈ 11 m
    at NYC latitude — visually identical on the system-map zoom level but
    cuts the point count by 40-60 %.
    """
    if len(coords) <= 2:
        return coords

    # Find the point with the maximum distance from the line (first, last)
    first = coords[0]
    last = coords[-1]
    max_dist = 0.0
    max_idx = 0

    dx = last[1] - first[1]
    dy = last[0] - first[0]
    line_len_sq = dx * dx + dy * dy

    for i in range(1, len(coords) - 1):
        if line_len_sq == 0:
            dist = ((coords[i][0] - first[0]) ** 2 + (coords[i][1] - first[1]) ** 2) ** 0.5
        else:
            t = max(0, min(1, ((coords[i][1] - first[1]) * dx + (coords[i][0] - first[0]) * dy) / line_len_sq))
            proj_lat = first[0] + t * dy
            proj_lon = first[1] + t * dx
            dist = ((coords[i][0] - proj_lat) ** 2 + (coords[i][1] - proj_lon) ** 2) ** 0.5
        if dist > max_dist:
            max_dist = dist
            max_idx = i

    if max_dist > tolerance:
        left = _simplify_polyline(coords[: max_idx + 1], tolerance)
        right = _simplify_polyline(coords[max_idx:], tolerance)
        return left[:-1] + right
    else:
        return [first, last]


@router.get("/subway/shapes/all", response_model=AllSubwayLinesResponse)
async def subway_shapes_all() -> AllSubwayLinesResponse:
    """Return polylines for ALL subway lines — the full system map.

    This is called once on app launch to draw every subway line on the
    map with the correct MTA colors.  The response is lightweight
    (polylines + color only, no stop lists) to keep it fast.

    Optimizations for the system map overlay:
    - Express/shuttle variants (6X, 7X, FX, FS, GS) are skipped because
      they run on the exact same tracks as their parent line.
    - Only direction-0 shapes are returned because northbound and southbound
      trace the same physical tracks — halving the polyline count.
    """
    from app.services.subway_shapes import _load_route_shapes, _load_shapes, _unpack_coords

    # Routes to skip: express/shuttle duplicates of parent lines
    skip_variants = {"6X", "7X", "FX", "FS", "GS", "SR"}

    overlays: list[SubwayLineOverlay] = []
    lines = [l for l in get_all_subway_lines() if l not in skip_variants]

    route_shapes = _load_route_shapes()
    shapes_data = _load_shapes()

    for line in lines:
        direction_shapes = route_shapes.get(line)
        if not direction_shapes:
            continue

        # Use only direction 0 (or whichever exists) — N and S trace the same tracks
        primary_dir = 0 if 0 in direction_shapes else min(direction_shapes.keys())
        shape_ids = direction_shapes[primary_dir]

        polylines_raw: list[list[tuple[float, float]]] = []
        for shape_id in shape_ids:
            shape_buf = shapes_data.get(shape_id)
            if shape_buf:
                raw = _unpack_coords(shape_buf)
                # Light simplification for the system map (~5.5 m tolerance).
                # The iOS client merges + simplifies further based on its own
                # configurable tolerance, so keep server output reasonably detailed.
                polylines_raw.append(_simplify_polyline(raw, tolerance=0.00005))

        if not polylines_raw:
            continue

        # No additional dedup needed here — _load_route_shapes() already
        # performs smart unique-stop dedup that preserves real branches
        # (e.g. A train's Far Rockaway, Lefferts Blvd, Rockaway Park).
        # The old geometric 70% overlap dedup was killing branch polylines
        # because branches share a trunk with the main line.

        encoded = [_encode_polyline(coords) for coords in polylines_raw]
        color = get_subway_color(line)
        overlays.append(SubwayLineOverlay(
            route_id=line,
            color_hex=color,
            polylines=encoded,
        ))

    # Apply Shapely-based corridor offsets so co-located trunk groups
    # (e.g. blue A/C/E + green 4/5/6 on Lex Ave) render as parallel
    # stripes instead of stacking on the same pixel.
    overlays = _apply_corridor_offsets(overlays)

    total_polys = sum(len(o.polylines) for o in overlays)
    TrackLogger.info(f"Subway shapes/all: {len(overlays)} lines, {total_polys} polylines returned")
    return AllSubwayLinesResponse(lines=overlays)


@router.get("/subway/stations/all", response_model=AllSubwayStationsResponse)
async def subway_stations_all() -> AllSubwayStationsResponse:
    """Return all unique subway stations with the lines that serve them.

    This data allows the map to display "Penn Station (1 2 3 A C E)"
    markers just like Apple Maps.
    """
    raw_stations = get_all_subway_stations()
    stations = []
    for s in raw_stations:
        stations.append(SubwayStation(**s))

    return AllSubwayStationsResponse(stations=stations)


@router.get("/subway/stations/nearby", response_model=AllSubwayStationsResponse)
async def subway_stations_nearby(
    lat: float = Query(..., ge=-90, le=90, description="User latitude"),
    lon: float = Query(..., ge=-180, le=180, description="User longitude"),
    radius: int = Query(1600, description="Search radius in meters (default ~1 mile)"),
) -> AllSubwayStationsResponse:
    """Return subway stations near the user's location.

    Instead of downloading ALL 400+ stations and filtering client-side,
    this endpoint returns only stations within *radius* meters of the
    provided coordinates.  Significantly reduces payload and client work.
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
    
    nearby.sort(key=lambda s: (
        ((s.lat - lat) * meters_per_deg_lat) ** 2 +
        ((s.lon - lon) * meters_per_deg_lon) ** 2
    ))
    
    TrackLogger.info(f"Subway stations/nearby: {len(nearby)} stations within {radius}m of ({lat:.4f}, {lon:.4f})")
    return AllSubwayStationsResponse(stations=nearby)


@router.get("/subway/shape/{route_id}", response_model=RouteShape)
async def subway_shape(route_id: str) -> RouteShape:
    """Return the full route geometry and ordered stops for a subway line.

    This enables the iOS app to draw the entire line (e.g. the full C train
    from Euclid Av to 168 St) on the map, not just the 2–3 nearby stops.

    Uses GTFS static data (shapes.txt, trips.txt, stop_times.txt) to build:
    - polylines: Google-encoded polyline strings for the route geometry
    - stops: ordered list of all stations along the line
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
    # then simplify with RDP to cut point count without visible change.
    # This produces fewer, longer, cleaner polylines for the detail view.
    merged_all = _merge_polyline_segments(polylines_raw)
    encoded_polylines: list[str] = [
        _encode_polyline(_simplify_polyline(coords, tolerance=0.00005))
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

    # Build per-direction shapes — merge + simplify each direction too
    directions: list[DirectionShape] = []
    for dd in direction_data:
        merged_dir = _merge_polyline_segments(dd.polylines)
        dir_encoded = [
            _encode_polyline(_simplify_polyline(coords, tolerance=0.00005))
            for coords in merged_dir
        ]
        dir_stops = [
            BusStop(id=s.stop_id, name=s.name, lat=s.lat, lon=s.lon)
            for s in dd.stops
        ]
        directions.append(DirectionShape(
            direction_id=dd.direction_id,
            headsign=dd.headsign,
            polylines=dir_encoded,
            stops=dir_stops,
            service_type=get_subway_service_type(clean_id),
        ))

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


@router.get("/subway/{line_id}", response_model=list[TrackArrival])
async def subway_arrivals(line_id: str, response: Response) -> list[TrackArrival]:
    """Return upcoming arrivals for a subway line (e.g. ``/subway/L``)."""
    clean_id = clean_route_id(line_id)
    if resolve_subway_feed_key(clean_id) is None:
        raise HTTPException(
            status_code=404,
            detail=f"Unknown subway line: {line_id}",
        )
    try:
        arrivals = await get_arrivals_for_line(clean_id)
        # Filter out stale arrivals (already at station or in the past)
        now = int(time.time())
        fresh = [a for a in arrivals if a.arrival_ts and a.arrival_ts > now]
        # Recalculate minutes_away from the current time
        for a in fresh:
            a.minutes_away = max(0, (a.arrival_ts - now) // 60)
        return fresh
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

    METERS_PER_DEG = 111_000.0

    def _dist_m(a: tuple[float, float], b: tuple[float, float]) -> float:
        dlat = (a[0] - b[0]) * METERS_PER_DEG
        dlon = (a[1] - b[1]) * METERS_PER_DEG * 0.76  # cos(40.7°)
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

    # Second pass: merge chains with each other
    did_merge = True
    while did_merge:
        did_merge = False
        for i in range(len(chains)):
            for j in range(i + 1, len(chains)):
                if _dist_m(chains[i][-1], chains[j][0]) < gap_threshold_m:
                    chains[i].extend(chains[j][1:])
                    chains.pop(j)
                    did_merge = True
                    break
                if _dist_m(chains[j][-1], chains[i][0]) < gap_threshold_m:
                    chains[i] = chains[j] + chains[i][1:]
                    chains.pop(j)
                    did_merge = True
                    break
                if _dist_m(chains[i][-1], chains[j][-1]) < gap_threshold_m:
                    chains[i].extend(reversed(chains[j][:-1]))
                    chains.pop(j)
                    did_merge = True
                    break
                if _dist_m(chains[i][0], chains[j][0]) < gap_threshold_m:
                    chains[i] = list(reversed(chains[j][1:])) + chains[i]
                    chains.pop(j)
                    did_merge = True
                    break
            if did_merge:
                break

    return chains

# ---------------------------------------------------------------------------
# Corridor offset computation for system map (Shapely-based)
# ---------------------------------------------------------------------------

# MTA trunk groups: routes sharing the same physical trunk + color.
# Must match the iOS MapSystemViewModel.trunkGroups for consistency.
_TRUNK_GROUPS: list[list[str]] = [
    ["1", "2", "3"],               # Red — 7th Ave / Broadway
    ["4", "5", "6", "6X"],         # Green — Lexington Ave
    ["7", "7X"],                   # Purple — Flushing
    ["A", "C", "E"],              # Blue — 8th Ave
    ["B", "D", "F", "FX", "M"],   # Orange — 6th Ave
    ["G"],                          # Lime Green — Crosstown
    ["J", "Z"],                    # Brown — Nassau St
    ["L"],                          # Gray — 14th St / Canarsie
    ["N", "Q", "R", "W"],         # Yellow — Broadway BMT
    ["S"],                          # Shuttle Gray
    ["SI"],                        # Staten Island Railway
]

# Build reverse lookup: route_id → trunk group index
_ROUTE_TO_TRUNK: dict[str, int] = {}
for _gi, _group in enumerate(_TRUNK_GROUPS):
    for _rid in _group:
        _ROUTE_TO_TRUNK[_rid] = _gi


def _apply_corridor_offsets(
    overlays: list[SubwayLineOverlay],
    offset_meters: float = 15.0,
    corridor_buffer_m: float = 50.0,
) -> list[SubwayLineOverlay]:
    """Apply perpendicular offsets to subway lines that share a corridor.

    Uses Shapely's ``offset_curve`` for geometrically perfect parallel lines.
    Co-located trunk groups (e.g. blue A/C/E + green 4/5/6 on Lex Ave) are
    fanned out so each color is visible as a distinct parallel stripe.

    **Algorithm (segment-level corridor detection)**:
    1. Group overlays by MTA trunk color.
    2. For each trunk group, merge all polylines into a single MultiLineString.
    3. Identify shared corridors by buffering each trunk group's geometry and
       checking which other trunk groups intersect the buffer.
    4. For shared corridor segments, apply Shapely ``offset_curve`` to produce
       geometrically perfect parallel offsets — no grid lookups, no flickering.

    Parameters
    ----------
    overlays : list of SubwayLineOverlay with already-encoded polylines.
    offset_meters : perpendicular distance between neighbouring trunk groups.
    corridor_buffer_m : buffer distance for detecting shared corridors (~50m).
    """
    from shapely.geometry import LineString, MultiLineString
    from shapely.ops import linemerge, unary_union

    METERS_PER_DEG_LAT = 111_000.0
    METERS_PER_DEG_LON = 84_300.0  # at ~40.7°N

    # Convert meters to degrees for offset calculations
    offset_deg_lat = offset_meters / METERS_PER_DEG_LAT
    offset_deg_lon = offset_meters / METERS_PER_DEG_LON
    # Use average for Shapely (which operates in coordinate space)
    offset_deg = (offset_deg_lat + offset_deg_lon) / 2.0

    buffer_deg = corridor_buffer_m / ((METERS_PER_DEG_LAT + METERS_PER_DEG_LON) / 2.0)

    # ── Step 1: Decode polylines and group by trunk ──
    decoded_by_route: dict[str, list[list[tuple[float, float]]]] = {}
    for overlay in overlays:
        decoded_by_route[overlay.route_id] = [
            _decode_polyline(p) for p in overlay.polylines
        ]

    # Group overlays by trunk index
    trunk_overlays: dict[int, list[SubwayLineOverlay]] = {}
    for overlay in overlays:
        trunk_idx = _ROUTE_TO_TRUNK.get(overlay.route_id, -1)
        if trunk_idx >= 0:
            trunk_overlays.setdefault(trunk_idx, []).append(overlay)

    # ── Step 2: Build Shapely geometries per trunk group ──
    trunk_geometries: dict[int, MultiLineString] = {}
    for trunk_idx, trunk_ovls in trunk_overlays.items():
        lines = []
        for ovl in trunk_ovls:
            for coords in decoded_by_route[ovl.route_id]:
                if len(coords) >= 2:
                    # Shapely uses (x, y) = (lon, lat)
                    lines.append(LineString([(lon, lat) for lat, lon in coords]))
        if lines:
            trunk_geometries[trunk_idx] = MultiLineString(lines)

    # ── Step 3: Detect shared corridors between trunk groups ──
    # For each trunk group, find which OTHER trunk groups share geometry
    active_trunks = sorted(trunk_geometries.keys())
    trunk_neighbors: dict[int, set[int]] = {t: set() for t in active_trunks}

    for i, t1 in enumerate(active_trunks):
        geom1 = trunk_geometries[t1]
        buf1 = geom1.buffer(buffer_deg)
        for t2 in active_trunks[i + 1:]:
            geom2 = trunk_geometries[t2]
            if buf1.intersects(geom2):
                # Check that the intersection is substantial (not just a crossing)
                intersection = buf1.intersection(geom2)
                if intersection.length > buffer_deg * 5:
                    trunk_neighbors[t1].add(t2)
                    trunk_neighbors[t2].add(t1)

    # ── Step 4: Compute per-point offsets for each route ──
    # For routes in trunk groups that share corridors, apply Shapely offset_curve
    result: list[SubwayLineOverlay] = []

    for overlay in overlays:
        route_id = overlay.route_id
        trunk_idx = _ROUTE_TO_TRUNK.get(route_id, -1)

        # If this trunk has no corridor neighbors, pass through unchanged
        if trunk_idx < 0 or not trunk_neighbors.get(trunk_idx):
            result.append(overlay)
            continue

        # Determine this trunk's lane position among its corridor partners
        # Collect all trunks sharing corridors with this one
        corridor_trunks = sorted({trunk_idx} | trunk_neighbors[trunk_idx])
        lane_index = corridor_trunks.index(trunk_idx)
        num_lanes = len(corridor_trunks)
        center_offset = (lane_index - (num_lanes - 1) / 2.0) * offset_deg

        if abs(center_offset) < 1e-10:
            # Center lane — no offset needed
            result.append(overlay)
            continue

        offset_polys: list[list[tuple[float, float]]] = []
        for coords in decoded_by_route[route_id]:
            if len(coords) < 2:
                offset_polys.append(coords)
                continue

            try:
                # Build LineString in (lon, lat) coordinate space
                line = LineString([(lon, lat) for lat, lon in coords])

                # Use Shapely's offset_curve for geometrically perfect parallel lines
                # Positive offset = left side, negative = right side
                offset_line = line.offset_curve(center_offset)

                if offset_line.is_empty:
                    offset_polys.append(coords)
                    continue

                # Extract coordinates, handling both LineString and MultiLineString results
                if offset_line.geom_type == "MultiLineString":
                    # offset_curve can produce multiple segments at sharp corners;
                    # merge them back into one continuous line
                    merged = linemerge(offset_line)
                    if merged.geom_type == "LineString":
                        offset_coords = [(lat, lon) for lon, lat in merged.coords]
                    else:
                        # If merge fails, use the longest segment
                        longest = max(merged.geoms, key=lambda g: g.length)
                        offset_coords = [(lat, lon) for lon, lat in longest.coords]
                elif offset_line.geom_type == "LineString":
                    offset_coords = [(lat, lon) for lon, lat in offset_line.coords]
                else:
                    offset_polys.append(coords)
                    continue

                offset_polys.append(offset_coords)

            except Exception:
                # Fallback: if Shapely fails on degenerate geometry, keep original
                offset_polys.append(coords)

        # Re-encode the offset polylines
        encoded = [_encode_polyline(p) for p in offset_polys]
        result.append(SubwayLineOverlay(
            route_id=overlay.route_id,
            color_hex=overlay.color_hex,
            polylines=encoded,
        ))

    return result
