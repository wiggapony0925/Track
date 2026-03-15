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
    TrunkGroupPolylines,
)
from app.services.gtfs.data_cleaner import get_arrivals_for_line
from app.services.mapping.subway_shapes import get_all_subway_stations, get_subway_route_shape, get_subway_service_type
from app.services.transit.station_lookup import get_nearby_stop_ids, get_stop_info
from app.utils.logger import TrackLogger
from app.utils.polyline_utils import decode_polyline as _decode_polyline, encode_polyline as _encode_polyline, densify_wgs84 as _densify_wgs84
from app.services.mapping.corridor_pipeline import apply_topological_offsets, get_processed_stops, get_trunk_polylines, ROUTE_TO_TRUNK
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
    from app.services.mapping.subway_shapes import _load_route_shapes, _load_shapes, _unpack_coords, _load_shape_stops

    # Routes to skip: express/shuttle duplicates of parent lines
    skip_variants = {"6X", "7X", "FX", "FS", "GS", "SR"}

    overlays: list[SubwayLineOverlay] = []
    lines = [l for l in get_all_subway_lines() if l not in skip_variants]

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
        overlays.append(SubwayLineOverlay(
            route_id=line,
            color_hex=color,
            polylines=encoded,
        ))

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
        METERS_PER_DEG: float = 111_000.0
        COS_NYC: float = 0.76  # cos(40.7°)

        def _trunk_coords(trunk_idx: int) -> list[list[tuple[float, float]]]:
            """Decode all existing trunk polylines for a trunk group."""
            enc_list: list[str] = trunk_poly_map.get(trunk_idx, [])
            result: list[list[tuple[float, float]]] = []
            for enc in enc_list:
                try:
                    result.append(_decode_polyline(enc))
                except Exception:
                    pass
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
                    dlon = (plon - tlon) * METERS_PER_DEG * COS_NYC
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
                        clipped = clipped[:trim_from] + [clipped[-1]]

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
                TrackLogger.info(f"[Dir1] Added reverse shape {sid} to {line} ({len(raw)} pts)")
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

    trunk_polylines = [
        TrunkGroupPolylines(**tp) for tp in trunk_polys_raw
    ]

    total_polys = sum(len(o.polylines) for o in overlays)
    total_trunk = sum(len(tp.polylines) for tp in trunk_polylines)
    TrackLogger.info(
        f"Subway shapes/all: {len(overlays)} lines, {total_polys} per-route polylines, "
        f"{len(trunk_polylines)} trunk groups, {total_trunk} trunk polylines"
    )
    return AllSubwayLinesResponse(lines=overlays, trunk_polylines=trunk_polylines)


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


@router.get("/subway/stations/processed")
async def subway_stations_processed():
    """Return stations with positions snapped onto the offset polylines.

    Must be called after ``/subway/shapes/all`` has been fetched (which
    populates the pipeline cache).  Returns ``is_transfer`` flags and
    per-route snapped lat/lon so the iOS map can draw circles on each
    line and white bars at transfer hubs.
    """
    raw = get_processed_stops()
    return {"stations": raw}


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
    # densify curves (same 1 m resolution as the system-map polylines),
    # then simplify with RDP to cut point count without visible change.
    # Densification first ensures curves follow the real track geometry;
    # simplification then trims redundant collinear points.
    merged_all = _merge_polyline_segments(polylines_raw)
    encoded_polylines: list[str] = [
        _encode_polyline(_simplify_polyline(_densify_wgs84(coords), tolerance=0.00005))
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

    # Build per-direction shapes — merge + densify + simplify each direction
    directions: list[DirectionShape] = []
    for dd in direction_data:
        merged_dir = _merge_polyline_segments(dd.polylines)
        dir_encoded = [
            _encode_polyline(_simplify_polyline(_densify_wgs84(coords), tolerance=0.00005))
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
# Chaikin's corner-cutting algorithm for polyline smoothing
# ---------------------------------------------------------------------------


def _chaikin_smooth(
    coords: list[tuple[float, float]],
    iterations: int = 3,
) -> list[tuple[float, float]]:
    """Smooth a polyline using Chaikin's corner-cutting algorithm.

    Each iteration replaces every interior edge with two new points at
    the 25% and 75% positions, progressively rounding sharp corners
    while preserving the overall path shape.

    The first and last points are always preserved to maintain
    connectivity with adjacent polyline segments.
    """
    if len(coords) <= 2:
        return coords

    pts = list(coords)
    for _ in range(iterations):
        if len(pts) <= 2:
            break
        new_pts: list[tuple[float, float]] = [pts[0]]  # preserve start
        for i in range(len(pts) - 1):
            p0 = pts[i]
            p1 = pts[i + 1]
            # Q = 3/4 * P0 + 1/4 * P1
            q = (0.75 * p0[0] + 0.25 * p1[0], 0.75 * p0[1] + 0.25 * p1[1])
            # R = 1/4 * P0 + 3/4 * P1
            r = (0.25 * p0[0] + 0.75 * p1[0], 0.25 * p0[1] + 0.75 * p1[1])
            new_pts.append(q)
            new_pts.append(r)
        new_pts.append(pts[-1])  # preserve end
        pts = new_pts

    return pts


