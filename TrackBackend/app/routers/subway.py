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

    # Apply corridor offsets so co-located lines (e.g. 4/5/6 on Lex Ave)
    # fan out visually instead of stacking on top of each other.
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
    gap_threshold_m: float = 50.0,
) -> list[list[tuple[float, float]]]:
    """Merge adjacent polyline segments into continuous lines.

    GTFS shapes often produce multiple fragments per route+direction that
    are really one continuous line broken at arbitrary points.  This joins
    segments whose start/end points are within *gap_threshold_m* meters,
    dramatically reducing the overlay count that MapKit must render.

    **Branch-aware**: if multiple segments share the same endpoint (a fork /
    junction like the A train at Rockaway Blvd), those endpoints are marked
    as junctions and are never merged — preserving the visual branch split.

    Returns a new list of coordinate arrays (often shorter than input).
    """
    if len(segments) <= 1:
        return segments

    METERS_PER_DEG = 111_000.0

    def _dist_m(a: tuple[float, float], b: tuple[float, float]) -> float:
        dlat = (a[0] - b[0]) * METERS_PER_DEG
        dlon = (a[1] - b[1]) * METERS_PER_DEG * 0.76  # cos(40.7°)
        return (dlat * dlat + dlon * dlon) ** 0.5

    # --- Detect junction points (endpoints shared by 2+ segments) ---
    # Collect all start/end points and count how many segments touch each.
    endpoint_counts: dict[tuple[int, int], int] = {}
    seg_endpoints: list[tuple[tuple[float, float], tuple[float, float]]] = []
    for seg in segments:
        if not seg:
            continue
        start, end = seg[0], seg[-1]
        seg_endpoints.append((start, end))
        # Round to ~5 m grid to group nearby endpoints as the same junction
        for pt in (start, end):
            key = (round(pt[0] * 20000), round(pt[1] * 20000))  # ~5.5 m cells
            endpoint_counts[key] = endpoint_counts.get(key, 0) + 1

    # An endpoint is a junction if 2+ segments touch it
    def _is_junction(pt: tuple[float, float]) -> bool:
        key = (round(pt[0] * 20000), round(pt[1] * 20000))
        return endpoint_counts.get(key, 0) >= 2

    # --- Merge non-junction segments ---
    chains: list[list[tuple[float, float]]] = [list(segments[0])]

    for seg in segments[1:]:
        if not seg:
            continue
        merged = False
        for chain in chains:
            # Try appending seg to end of chain — but NOT if the join point is a junction
            if not _is_junction(chain[-1]) and not _is_junction(seg[0]) and _dist_m(chain[-1], seg[0]) < gap_threshold_m:
                chain.extend(seg[1:])
                merged = True
                break
            # Try prepending seg to start of chain
            if not _is_junction(chain[0]) and not _is_junction(seg[-1]) and _dist_m(chain[0], seg[-1]) < gap_threshold_m:
                chain[:0] = seg[:-1]
                merged = True
                break
            # Try appending reversed seg
            if not _is_junction(chain[-1]) and not _is_junction(seg[-1]) and _dist_m(chain[-1], seg[-1]) < gap_threshold_m:
                chain.extend(reversed(seg[:-1]))
                merged = True
                break
            # Try prepending reversed seg
            if not _is_junction(chain[0]) and not _is_junction(seg[0]) and _dist_m(chain[0], seg[0]) < gap_threshold_m:
                chain[:0] = list(reversed(seg[1:]))
                merged = True
                break
        if not merged:
            chains.append(list(seg))

    return chains


# ---------------------------------------------------------------------------
# Corridor offset computation for system map
# ---------------------------------------------------------------------------


def _apply_corridor_offsets(
    overlays: list[SubwayLineOverlay],
    offset_meters: float = 22.0,
    grid_size: float = 0.0003,
) -> list[SubwayLineOverlay]:
    """Apply perpendicular offsets to subway lines that share a corridor.

    Co-located lines (e.g. 4/5/6 on Lexington Ave) are fanned out so each
    line is visible instead of stacking on the same pixel.  This is the
    server-side equivalent of the old ``computeSubwayOffsets()`` in
    HomeViewModel.swift.

    Parameters
    ----------
    overlays : list of SubwayLineOverlay with already-encoded polylines.
    offset_meters : perpendicular distance between neighbouring lines.
    grid_size : snapping grid in degrees (~33 m at NYC latitude).
    """
    METERS_PER_DEG_LAT = 111_000.0
    METERS_PER_DEG_LON = 84_300.0  # at ~40.7°N

    # 1. Decode all polylines and build the grid → route-IDs lookup
    decoded: dict[str, list[list[tuple[float, float]]]] = {}
    grid_to_routes: dict[int, set[str]] = {}

    for overlay in overlays:
        polys = [_decode_polyline(p) for p in overlay.polylines]
        decoded[overlay.route_id] = polys
        for coords in polys:
            step = max(1, min(3, len(coords) // 10))
            for i in range(0, len(coords), step):
                lat, lon = coords[i]
                gx = round(lat / grid_size)
                gy = round(lon / grid_size)
                key = (int(gx) << 32) | (int(gy) & 0xFFFFFFFF)
                if key not in grid_to_routes:
                    grid_to_routes[key] = set()
                grid_to_routes[key].add(overlay.route_id)

    # 2. For cells with multiple routes, compute a stable sort order
    cell_ordering: dict[int, list[str]] = {}
    for key, routes in grid_to_routes.items():
        if len(routes) > 1:
            cell_ordering[key] = sorted(routes)

    if not cell_ordering:
        # No shared corridors — return as-is
        return overlays

    # 3. Offset each coordinate perpendicular to the track direction
    result: list[SubwayLineOverlay] = []
    for overlay in overlays:
        route_id = overlay.route_id
        all_polys = decoded[route_id]
        offset_polys: list[list[tuple[float, float]]] = []

        for coords in all_polys:
            if len(coords) < 2:
                offset_polys.append(coords)
                continue

            offset_coords: list[tuple[float, float]] = []
            for i, (clat, clon) in enumerate(coords):
                gx = round(clat / grid_size)
                gy = round(clon / grid_size)
                key = (int(gx) << 32) | (int(gy) & 0xFFFFFFFF)

                ordering = cell_ordering.get(key)
                if ordering is None or route_id not in ordering:
                    offset_coords.append((clat, clon))
                    continue

                slot = ordering.index(route_id)
                total = len(ordering)
                center_offset = slot - (total - 1) / 2.0

                # Direction of travel from neighbors
                prev = coords[i - 1] if i > 0 else coords[i]
                nxt = coords[i + 1] if i < len(coords) - 1 else coords[i]
                dx = nxt[1] - prev[1]
                dy = nxt[0] - prev[0]
                length = math.sqrt(dx * dx + dy * dy)

                if length < 1e-10:
                    offset_coords.append((clat, clon))
                    continue

                # Perpendicular (90° CW): (dx, -dy) normalized → (perpLat, perpLon)
                perp_lat = dx / length
                perp_lon = -dy / length

                off_lat = center_offset * offset_meters / METERS_PER_DEG_LAT * perp_lat
                off_lon = center_offset * offset_meters / METERS_PER_DEG_LON * perp_lon
                offset_coords.append((clat + off_lat, clon + off_lon))

            offset_polys.append(offset_coords)

        # Re-encode the offset polylines
        encoded = [_encode_polyline(p) for p in offset_polys]
        result.append(SubwayLineOverlay(
            route_id=overlay.route_id,
            color_hex=overlay.color_hex,
            polylines=encoded,
        ))

    return result
