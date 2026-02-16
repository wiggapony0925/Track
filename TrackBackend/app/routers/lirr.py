#
# lirr.py
# TrackBackend
#
# Router for Long Island Rail Road arrivals and route shapes.
#

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app.models import (
    AllCommuterRailLinesResponse,
    CommuterRailLineOverlay,
    TrackArrival,
)
from app.services.commuter_rail_shapes import get_all_lirr_lines
from app.services.rail_client import fetch_rail_arrivals

router = APIRouter(tags=["lirr"])


# NOTE: Static path endpoints MUST be declared before the wildcard endpoints.


@router.get("/lirr/shapes/all", response_model=AllCommuterRailLinesResponse)
async def lirr_shapes_all() -> AllCommuterRailLinesResponse:
    """Return polylines for ALL LIRR branches — for the system map."""
    lines_data = get_all_lirr_lines()
    overlays: list[CommuterRailLineOverlay] = []
    for line in lines_data:
        encoded = [_encode_polyline(coords) for coords in line["polylines"]]
        overlays.append(CommuterRailLineOverlay(
            route_id=line["route_id"],
            name=line["name"],
            color_hex=line["color_hex"],
            polylines=encoded,
            mode="lirr",
        ))
    return AllCommuterRailLinesResponse(lines=overlays)


@router.get("/lirr", response_model=list[TrackArrival])
async def lirr_arrivals() -> list[TrackArrival]:
    """Return upcoming LIRR arrivals from the GTFS-Realtime feed."""
    try:
        arrivals = await fetch_rail_arrivals("lirr")
        # Filter out stale arrivals (already departed / in the past)
        import time
        now = int(time.time())
        fresh = [a for a in arrivals if a.arrival_ts and a.arrival_ts > now]
        # Recalculate minutes_away from the current time
        for a in fresh:
            a.minutes_away = max(0, (a.arrival_ts - now) // 60)
        return fresh
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"LIRR Feed Error: {str(exc)}") from exc


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
