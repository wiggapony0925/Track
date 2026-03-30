#
# lirr.py
# TrackBackend
#
# Router for Long Island Rail Road arrivals and route shapes.
#

from __future__ import annotations

from fastapi import APIRouter, HTTPException, Response

from app.models import (
    AllCommuterRailLinesResponse,
    BusStop,
    CommuterRailLineOverlay,
    CommuterRailStop,
    DirectionShape,
    RouteShape,
    TrackArrival,
)
from app.services.mapping.commuter_rail_shapes import get_all_lirr_lines, get_single_lirr_line
from app.services.mapping.subway_shapes import enrich_stops_with_transfers
from app.clients.rail_client import fetch_rail_arrivals, filter_fresh_arrivals
from app.utils.logger import TrackLogger
from app.utils.polyline_utils import encode_polyline as _encode_polyline

router = APIRouter(tags=["lirr"])


# NOTE: Static path endpoints MUST be declared before the wildcard endpoints.


@router.get(
    "/lirr/shapes/all",
    response_model=AllCommuterRailLinesResponse,
    summary="Get all LIRR branch shapes",
    description="Returns encoded polylines for every LIRR branch — used to draw the full LIRR system map.",
)
async def lirr_shapes_all() -> AllCommuterRailLinesResponse:
    """Return polylines for ALL LIRR branches.

    Each branch includes `route_id`, `name`, `color_hex`, `polylines`,
    and `stops` (all stations on the branch).
    """
    lines_data = get_all_lirr_lines()
    overlays: list[CommuterRailLineOverlay] = []
    for line in lines_data:
        encoded = [_encode_polyline(coords) for coords in line["polylines"]]
        stops = [
            CommuterRailStop(stop_id=s.stop_id, name=s.name, lat=s.lat, lon=s.lon)
            for s in line.get("stops", [])
        ]
        overlays.append(CommuterRailLineOverlay(
            route_id=line["route_id"],
            name=line["name"],
            color_hex=line["color_hex"],
            polylines=encoded,
            mode="lirr",
            stops=stops,
        ))
    return AllCommuterRailLinesResponse(lines=overlays)


@router.get(
    "/lirr/shape/{route_id}",
    response_model=RouteShape,
    summary="Get single LIRR branch shape",
    description="Returns the polyline geometry and ordered stops for a single LIRR branch.",
)
async def lirr_shape(route_id: str) -> RouteShape:
    """Return the polyline for a single LIRR branch.

    **Path parameter:** Numeric GTFS route ID (e.g. `9` for Port Washington)
    or the prefixed form `LIRR_9`.

    Response includes:
    - `polylines` — encoded polylines for the branch geometry
    - `stops` — ordered station list with transfer info
    - `directions` — per-direction shapes split by GTFS `direction_id`
    """
    # Strip prefix if client sends "LIRR_9"
    numeric_id = route_id.removeprefix("LIRR_")

    line_data = get_single_lirr_line(numeric_id)
    if line_data is None:
        raise HTTPException(status_code=404, detail=f"LIRR branch '{route_id}' not found")

    encoded = [_encode_polyline(coords) for coords in line_data["polylines"]]

    # Resolve stops from GTFS stops.txt + stop_times.txt
    all_stops = [
        BusStop(id=s.stop_id, name=s.name, lat=s.lat, lon=s.lon)
        for s in line_data.get("stops", [])
    ]
    enrich_stops_with_transfers(all_stops, current_route=f"LIRR_{numeric_id}")

    # Build per-direction shapes
    directions: list[DirectionShape] = []
    for dd in line_data.get("directions", []):
        dir_encoded = [_encode_polyline(coords) for coords in dd["polylines"]]
        dir_stops = [
            BusStop(id=s.stop_id, name=s.name, lat=s.lat, lon=s.lon)
            for s in dd.get("stops", [])
        ]
        enrich_stops_with_transfers(dir_stops, current_route=f"LIRR_{numeric_id}")
        directions.append(DirectionShape(
            direction_id=dd["direction_id"],
            headsign=dd.get("headsign", ""),
            polylines=dir_encoded,
            stops=dir_stops,
        ))

    return RouteShape(
        route_id=line_data["route_id"],
        polylines=encoded,
        stops=all_stops,
        directions=directions,
    )


@router.get(
    "/lirr",
    response_model=list[TrackArrival],
    summary="Get real-time LIRR arrivals",
    description="Returns upcoming real-time LIRR arrivals from the GTFS-Realtime feed.",
)
async def lirr_arrivals(response: Response) -> list[TrackArrival]:
    """Return upcoming LIRR arrivals.

    Each arrival includes `route_id`, `station_name`, `direction`,
    `destination`, `minutes_away`, `arrival_ts` (epoch), and `status`.

    Returns an empty array if the MTA feed is temporarily unavailable.
    """
    try:
        return filter_fresh_arrivals(await fetch_rail_arrivals("lirr"))
    except Exception as exc:
        TrackLogger.warning(
            f"[LIRR] /lirr: feed error ({exc}) — returning empty fallback",
            tag="LIRR",
        )
        response.headers["X-Track-Degraded"] = "lirr-arrivals-fallback"
        return []
