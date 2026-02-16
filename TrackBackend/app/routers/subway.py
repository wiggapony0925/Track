#
# subway.py
# TrackBackend
#
# Router for subway line arrivals and route shapes.
#

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app.models import (
    AllSubwayLinesResponse,
    AllSubwayStationsResponse,
    BusStop,
    RouteShape,
    SubwayLineOverlay,
    SubwayStation,
    TrackArrival,
)
from app.services.data_cleaner import get_arrivals_for_line
from app.services.subway_shapes import get_all_subway_stations, get_subway_route_shape
from app.utils.logger import TrackLogger
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
    from app.services.subway_shapes import _load_route_shapes, _load_shapes

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
            shape_points = shapes_data.get(shape_id)
            if shape_points:
                raw = [(p.lat, p.lon) for p in shape_points]
                # Simplify for the system map (~11 m tolerance, invisible at overview zoom)
                polylines_raw.append(_simplify_polyline(raw, tolerance=0.0001))

        if not polylines_raw:
            continue

        # Deduplicate geometrically near-identical polylines for the same route.
        # GTFS often has multiple shape_ids that trace the same physical track
        # with minor coordinate differences.  The old endpoint-only check missed
        # shapes with different termini but 90%+ overlap in the middle.
        # New approach: sample 20 evenly-spaced points along the candidate and
        # check if ≥70% of them lie within ~55m of the existing polyline.
        deduped: list[list[tuple[float, float]]] = []
        _PROX = 0.0005  # ~55 m proximity threshold

        def _polylines_overlap(
            candidate: list[tuple[float, float]],
            existing: list[tuple[float, float]],
        ) -> bool:
            """Return True if most sample points of *candidate* are near *existing*."""
            n_samples = min(20, len(candidate))
            if n_samples < 2:
                return False
            step = max(1, len(candidate) // n_samples)
            close_count = 0
            total = 0
            for si in range(0, len(candidate), step):
                clat, clon = candidate[si]
                total += 1
                # Check a sliding window around the proportional position
                prop = si / max(len(candidate) - 1, 1)
                center = int(prop * (len(existing) - 1))
                window = max(len(existing) // 5, 10)
                lo = max(0, center - window)
                hi = min(len(existing), center + window)
                for ei in range(lo, hi):
                    if (abs(clat - existing[ei][0]) < _PROX
                            and abs(clon - existing[ei][1]) < _PROX):
                        close_count += 1
                        break
            return total > 0 and close_count / total >= 0.70

        for poly in sorted(polylines_raw, key=len, reverse=True):
            is_dup = False
            for existing in deduped:
                if _polylines_overlap(poly, existing):
                    is_dup = True
                    break
            if not is_dup:
                deduped.append(poly)

        encoded = [_encode_polyline(coords) for coords in deduped]
        color = get_subway_color(line)
        overlays.append(SubwayLineOverlay(
            route_id=line,
            color_hex=color,
            polylines=encoded,
        ))

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

    polylines_raw, stop_entries = result

    # Google-encode each polyline for transmission
    encoded_polylines: list[str] = []
    for coords in polylines_raw:
        encoded_polylines.append(_encode_polyline(coords))

    stops = [
        BusStop(
            id=entry.stop_id,
            name=entry.name,
            lat=entry.lat,
            lon=entry.lon,
        )
        for entry in stop_entries
    ]

    TrackLogger.info(
        f"Subway shape '{clean_id}': {len(encoded_polylines)} polyline(s), "
        f"{len(stops)} stops"
    )

    return RouteShape(
        route_id=clean_id,
        polylines=encoded_polylines,
        stops=stops,
    )


@router.get("/subway/{line_id}", response_model=list[TrackArrival])
async def subway_arrivals(line_id: str) -> list[TrackArrival]:
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
        import time
        now = int(time.time())
        fresh = [a for a in arrivals if a.arrival_ts and a.arrival_ts > now]
        # Recalculate minutes_away from the current time
        for a in fresh:
            a.minutes_away = max(0, (a.arrival_ts - now) // 60)
        return fresh
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


def _encode_polyline(coords: list[tuple[float, float]]) -> str:
    """Encode a list of (lat, lon) tuples into a Google-encoded polyline string."""
    encoded: list[str] = []
    prev_lat = 0
    prev_lon = 0

    for lat, lon in coords:
        lat_e5 = round(lat * 1e5)
        lon_e5 = round(lon * 1e5)
        _encode_value(lat_e5 - prev_lat, encoded)
        _encode_value(lon_e5 - prev_lon, encoded)
        prev_lat = lat_e5
        prev_lon = lon_e5

    return "".join(encoded)


def _encode_value(value: int, result: list[str]) -> None:
    """Encode a single signed value into Google polyline encoding."""
    v = ~(value << 1) if value < 0 else (value << 1)
    while v >= 0x20:
        result.append(chr(((v & 0x1F) | 0x20) + 63))
        v >>= 5
    result.append(chr(v + 63))
