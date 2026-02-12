#
# subway.py
# TrackBackend
#
# Router for subway line arrivals and route shapes.
#

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app.config import LINE_TO_URL_KEY
from app.models import BusStop, RouteShape, TrackArrival
from app.services.data_cleaner import get_arrivals_for_line
from app.services.subway_shapes import get_subway_route_shape
from app.utils.logger import TrackLogger

router = APIRouter(tags=["subway"])


# NOTE: shape endpoint MUST be declared before the wildcard /{line_id}
# endpoint, otherwise FastAPI would match "shape" as a line_id.

@router.get("/subway/shape/{route_id}", response_model=RouteShape)
async def subway_shape(route_id: str) -> RouteShape:
    """Return the full route geometry and ordered stops for a subway line.

    This enables the iOS app to draw the entire line (e.g. the full C train
    from Euclid Av to 168 St) on the map, not just the 2–3 nearby stops.

    Uses GTFS static data (shapes.txt, trips.txt, stop_times.txt) to build:
    - polylines: Google-encoded polyline strings for the route geometry
    - stops: ordered list of all stations along the line
    """
    upper = route_id.upper()
    result = get_subway_route_shape(upper)
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
        f"Subway shape '{upper}': {len(encoded_polylines)} polyline(s), "
        f"{len(stops)} stops"
    )

    return RouteShape(
        route_id=upper,
        polylines=encoded_polylines,
        stops=stops,
    )


@router.get("/subway/{line_id}", response_model=list[TrackArrival])
async def subway_arrivals(line_id: str) -> list[TrackArrival]:
    """Return upcoming arrivals for a subway line (e.g. ``/subway/L``)."""
    upper = line_id.upper()
    if upper not in LINE_TO_URL_KEY:
        raise HTTPException(
            status_code=404,
            detail=f"Unknown subway line: {line_id}",
        )
    try:
        return await get_arrivals_for_line(upper)
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


