#
# mnr.py
# TrackBackend
#
# Router for Metro-North Railroad arrivals and route shapes.
#

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app.models import (
    AllCommuterRailLinesResponse,
    CommuterRailLineOverlay,
    DirectionShape,
    RouteShape,
    TrackArrival,
)
from app.services.commuter_rail_shapes import get_all_mnr_lines, get_single_mnr_line
from app.services.rail_client import fetch_rail_arrivals

router = APIRouter(tags=["mnr"])


# NOTE: Static path endpoints MUST be declared before the wildcard endpoints.


@router.get("/mnr/shapes/all", response_model=AllCommuterRailLinesResponse)
async def mnr_shapes_all() -> AllCommuterRailLinesResponse:
    """Return polylines for ALL Metro-North branches — for the system map."""
    lines_data = get_all_mnr_lines()
    overlays: list[CommuterRailLineOverlay] = []
    for line in lines_data:
        encoded = [_encode_polyline(coords) for coords in line["polylines"]]
        overlays.append(CommuterRailLineOverlay(
            route_id=line["route_id"],
            name=line["name"],
            color_hex=line["color_hex"],
            polylines=encoded,
            mode="mnr",
        ))
    return AllCommuterRailLinesResponse(lines=overlays)


@router.get("/mnr/shape/{route_id}", response_model=RouteShape)
async def mnr_shape(route_id: str) -> RouteShape:
    """Return the polyline for a single Metro-North line.

    Accepts the numeric GTFS route_id (e.g. "1" for Hudson)
    or the prefixed form "MNR_1".
    """
    numeric_id = route_id.removeprefix("MNR_")

    line_data = get_single_mnr_line(numeric_id)
    if line_data is None:
        raise HTTPException(status_code=404, detail=f"MNR line '{route_id}' not found")

    encoded = [_encode_polyline(coords) for coords in line_data["polylines"]]

    # Build per-direction shapes
    directions: list[DirectionShape] = []
    for dd in line_data.get("directions", []):
        dir_encoded = [_encode_polyline(coords) for coords in dd["polylines"]]
        directions.append(DirectionShape(
            direction_id=dd["direction_id"],
            headsign=dd.get("headsign", ""),
            polylines=dir_encoded,
            stops=[],
        ))

    return RouteShape(
        route_id=line_data["route_id"],
        polylines=encoded,
        stops=[],
        directions=directions,
    )


@router.get("/mnr", response_model=list[TrackArrival])
async def mnr_arrivals() -> list[TrackArrival]:
    """Return upcoming Metro-North arrivals from the GTFS-Realtime feed."""
    try:
        arrivals = await fetch_rail_arrivals("metro_north")
        # Filter out stale arrivals (already departed / in the past)
        import time
        now = int(time.time())
        fresh = [a for a in arrivals if a.arrival_ts and a.arrival_ts > now]
        # Recalculate minutes_away from the current time
        for a in fresh:
            a.minutes_away = max(0, (a.arrival_ts - now) // 60)
        return fresh
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Metro-North Feed Error: {str(exc)}") from exc


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
