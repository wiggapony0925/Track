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
from app.services.gtfs.data_cleaner import get_arrivals_for_line
from app.services.mapping.subway_shapes import get_all_subway_stations, get_subway_route_shape, get_subway_service_type
from app.services.transit.station_lookup import get_nearby_stop_ids, get_stop_info
from app.utils.logger import TrackLogger
from app.utils.polyline_utils import decode_polyline as _decode_polyline, encode_polyline as _encode_polyline
from app.services.mapping.corridor_pipeline import apply_topological_offsets, get_processed_stops
from app.utils.transit_utils import (
    clean_route_id,
    get_all_subway_lines,
    get_subway_color,
    resolve_subway_feed_key,
)

router = APIRouter(tags=["subway"])

# NOTE: Static path endpoints MUST be declared before the wildcard /{line_id}
# endpoint, otherwise FastAPI would match literal segments as a line_id.


def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in metres between two WGS84 points."""
    R = 6_371_000.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (math.sin(dlat / 2) ** 2
         + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2))
         * math.sin(dlon / 2) ** 2)
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


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

        encoded = [_encode_polyline(coords) for coords in polylines_raw]
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

    # ── Post-pipeline: Append direction-1 branch extensions ──
    # These shapes cover stations not reachable by any direction-0 shape
    # (e.g. R train south of 36th St to Bay Ridge).  They're added AFTER
    # the pipeline to avoid disrupting the trunk-group merge.  The shapes
    # are reversed (southbound → northbound order) and appended as extra
    # encoded polylines to the relevant route's overlay.
    if dir1_extras:
        overlay_map: dict[str, SubwayLineOverlay] = {o.route_id: o for o in overlays}
        for line, sid in dir1_extras:
            shape_buf = shapes_data.get(sid)
            if not shape_buf:
                continue
            raw = list(reversed(_unpack_coords(shape_buf)))
            enc = _encode_polyline(raw)
            if line in overlay_map:
                overlay_map[line].polylines.append(enc)
                TrackLogger.info(f"[Dir1] Added reverse shape {sid} to {line} ({len(raw)} pts)")

    # ── Post-pipeline: Stop-alignment supplemental polylines ──
    # The trunk-group merge replaces per-route GTFS coordinates with a
    # merged baseline.  At locations where routes in the same trunk group
    # follow slightly different physical tracks (e.g. express / local
    # divergence, junction approaches), the merged baseline can be 30-100 m
    # from the stop even though the route's raw GTFS shape passes within 1 m.
    # Fix: for each stop >STOP_ALIGN_THRESHOLD from the output polylines,
    # extract a short segment from the raw GTFS shape and append it.
    _STOP_ALIGN_THRESHOLD = 30.0  # metres — trigger supplemental polyline
    _STOP_RAW_QUALIFY = 10.0       # metres — raw shape must be within this
    _STOP_EXTRACT_WINDOW = 25      # vertices ± around nearest point on raw shape

    from app.services.mapping.subway_shapes import get_stops_for_route
    from app.services.transit.station_lookup import get_stop_info

    overlay_map_align: dict[str, SubwayLineOverlay] = {o.route_id: o for o in overlays}
    align_count = 0

    for ov in overlays:
        route_id = ov.route_id

        # Collect this route's GTFS stop positions
        stop_ids = get_stops_for_route(route_id)
        if not stop_ids:
            continue

        stop_positions: list[tuple[str, float, float]] = []
        seen_parents: set[str] = set()
        for sid in stop_ids:
            parent = _station_id(sid)
            if parent in seen_parents:
                continue
            seen_parents.add(parent)
            info = get_stop_info(sid)
            if info is None:
                info = get_stop_info(parent)
            if info is not None:
                stop_positions.append((sid, info.lat, info.lon))

        if not stop_positions:
            continue

        # Decode current output polylines for distance checks
        decoded_polys: list[list[tuple[float, float]]] = [
            _decode_polyline(e) for e in ov.polylines
        ]

        # Pre-flatten all output vertices for fast min-distance
        flat_out: list[tuple[float, float]] = []
        for poly in decoded_polys:
            flat_out.extend(poly)

        # Collect all raw shapes for this route (both directions)
        direction_shapes_r = route_shapes.get(route_id, {})
        raw_shape_list: list[list[tuple[float, float]]] = []
        for _dir_id, sids in direction_shapes_r.items():
            for sid in sids:
                buf = shapes_data.get(sid)
                if buf:
                    raw_shape_list.append(_unpack_coords(buf))
        if not raw_shape_list:
            continue

        # Find stops that need supplemental polylines
        for sid, slat, slon in stop_positions:
            # Distance to output polylines
            best_out = float("inf")
            for olat, olon in flat_out:
                d = _haversine_m(slat, slon, olat, olon)
                if d < best_out:
                    best_out = d
                if d < 5.0:
                    break
            if best_out <= _STOP_ALIGN_THRESHOLD:
                continue

            # Check raw shapes for this stop
            best_raw = float("inf")
            best_raw_shape: list[tuple[float, float]] | None = None
            best_raw_idx = 0
            for raw_coords in raw_shape_list:
                for i, (rlat, rlon) in enumerate(raw_coords):
                    d = _haversine_m(slat, slon, rlat, rlon)
                    if d < best_raw:
                        best_raw = d
                        best_raw_shape = raw_coords
                        best_raw_idx = i
                    if d < 1.0:
                        break
                if best_raw < 1.0:
                    break

            if best_raw > _STOP_RAW_QUALIFY or best_raw_shape is None:
                # Raw GTFS also doesn't cover this stop closely.
                # If the shape is within 150 m (truncated terminus or sparse
                # vertex gap — e.g. 96th St 2nd Ave, Arthur Kill SIR),
                # synthesize a short connecting polyline from the nearest
                # raw shape vertex through the stop.
                _GTFS_GAP_MAX = 150.0
                if best_raw_shape is not None and best_raw < _GTFS_GAP_MAX:
                    n = len(best_raw_shape)
                    seg_start = max(0, best_raw_idx - 3)
                    seg_end = min(n, best_raw_idx + 4)
                    segment = list(best_raw_shape[seg_start:seg_end])
                    # Append/prepend the stop position to extend through it
                    if best_raw_idx <= 3:
                        # Stop is near the start → prepend stop
                        segment.insert(0, (slat, slon))
                    else:
                        # Stop is near the end → append stop
                        segment.append((slat, slon))
                    if len(segment) >= 2:
                        ov.polylines.append(_encode_polyline(segment))
                        align_count += 1
                continue

            # Extract a segment from the raw shape centred on the stop
            n = len(best_raw_shape)
            seg_start = max(0, best_raw_idx - _STOP_EXTRACT_WINDOW)
            seg_end = min(n, best_raw_idx + _STOP_EXTRACT_WINDOW + 1)
            segment = best_raw_shape[seg_start:seg_end]

            if len(segment) >= 2:
                ov.polylines.append(_encode_polyline(segment))
                align_count += 1

    if align_count:
        TrackLogger.info(
            f"[StopAlign] Added {align_count} supplemental polylines "
            f"for stops >30 m from trunk baseline"
        )

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


