#
# lirr.py
# TrackBackend
#
# Router for Long Island Rail Road arrivals and route shapes.
#

from __future__ import annotations

import time

from fastapi import APIRouter, HTTPException

from app.models import (
    AllCommuterRailLinesResponse,
    CommuterRailLineOverlay,
    DirectionShape,
    RouteShape,
    TrackArrival,
)
from app.services.commuter_rail_shapes import get_all_lirr_lines, get_single_lirr_line
from app.services.rail_client import fetch_rail_arrivals
from app.services.station_lookup import get_stop_info
from app.utils.polyline_utils import encode_polyline as _encode_polyline

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


@router.get("/lirr/shape/{route_id}", response_model=RouteShape)
async def lirr_shape(route_id: str) -> RouteShape:
    """Return the polyline for a single LIRR branch.

    Accepts the numeric GTFS route_id (e.g. "9" for Port Washington)
    or the prefixed form "LIRR_9".
    """
    # Strip prefix if client sends "LIRR_9"
    numeric_id = route_id.removeprefix("LIRR_")

    line_data = get_single_lirr_line(numeric_id)
    if line_data is None:
        raise HTTPException(status_code=404, detail=f"LIRR branch '{route_id}' not found")

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


@router.get("/lirr", response_model=list[TrackArrival])
async def lirr_arrivals() -> list[TrackArrival]:
    """Return upcoming LIRR arrivals from the GTFS-Realtime feed."""
    try:
        arrivals = await fetch_rail_arrivals("lirr")
        # Filter out stale arrivals (already departed / in the past)
        now = int(time.time())
        fresh = [a for a in arrivals if a.arrival_ts and a.arrival_ts > now]
        # Recalculate minutes_away from the current time
        for a in fresh:
            a.minutes_away = max(0, (a.arrival_ts - now) // 60)
        return fresh
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"LIRR Feed Error: {str(exc)}") from exc
