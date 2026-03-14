#
# mnr.py
# TrackBackend
#
# Router for Metro-North Railroad arrivals and route shapes.
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
from app.services.mapping.commuter_rail_shapes import get_all_mnr_lines, get_single_mnr_line
from app.clients.rail_client import fetch_rail_arrivals, filter_fresh_arrivals
from app.utils.logger import TrackLogger
from app.utils.polyline_utils import encode_polyline as _encode_polyline

router = APIRouter(tags=["mnr"])


# NOTE: Static path endpoints MUST be declared before the wildcard endpoints.


@router.get("/mnr/shapes/all", response_model=AllCommuterRailLinesResponse)
async def mnr_shapes_all() -> AllCommuterRailLinesResponse:
    """Return polylines for ALL Metro-North branches — for the system map."""
    lines_data = get_all_mnr_lines()
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
            mode="mnr",
            stops=stops,
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

    # Resolve stops from GTFS stops.txt + stop_times.txt
    all_stops = [
        BusStop(id=s.stop_id, name=s.name, lat=s.lat, lon=s.lon)
        for s in line_data.get("stops", [])
    ]

    # Build per-direction shapes
    directions: list[DirectionShape] = []
    for dd in line_data.get("directions", []):
        dir_encoded = [_encode_polyline(coords) for coords in dd["polylines"]]
        dir_stops = [
            BusStop(id=s.stop_id, name=s.name, lat=s.lat, lon=s.lon)
            for s in dd.get("stops", [])
        ]
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


@router.get("/mnr", response_model=list[TrackArrival])
async def mnr_arrivals(response: Response) -> list[TrackArrival]:
    """Return upcoming Metro-North arrivals from the GTFS-Realtime feed."""
    try:
        return filter_fresh_arrivals(await fetch_rail_arrivals("metro_north"))
    except Exception as exc:
        TrackLogger.warning(
            f"[MNR] /mnr: feed error ({exc}) — returning empty fallback",
            tag="MNR",
        )
        response.headers["X-Track-Degraded"] = "mnr-arrivals-fallback"
        return []
