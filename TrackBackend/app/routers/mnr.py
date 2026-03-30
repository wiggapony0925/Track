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
from app.services.mapping.subway_shapes import enrich_stops_with_transfers
from app.clients.rail_client import fetch_rail_arrivals, filter_fresh_arrivals
from app.utils.logger import TrackLogger
from app.utils.polyline_utils import encode_polyline as _encode_polyline

router = APIRouter(tags=["mnr"])


# NOTE: Static path endpoints MUST be declared before the wildcard endpoints.


@router.get(
    "/mnr/shapes/all",
    response_model=AllCommuterRailLinesResponse,
    summary="Get all Metro-North line shapes",
    description="Returns encoded polylines for every Metro-North line — used to draw the full MNR system map.",
)
async def mnr_shapes_all() -> AllCommuterRailLinesResponse:
    """Return polylines for ALL Metro-North lines.

    Each line includes `route_id`, `name`, `color_hex`, `polylines`,
    and `stops` (all stations on the line).
    """
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


@router.get(
    "/mnr/shape/{route_id}",
    response_model=RouteShape,
    summary="Get single Metro-North line shape",
    description="Returns the polyline geometry and ordered stops for a single Metro-North line.",
)
async def mnr_shape(route_id: str) -> RouteShape:
    """Return the polyline for a single Metro-North line.

    **Path parameter:** Numeric GTFS route ID (e.g. `1` for Hudson)
    or the prefixed form `MNR_1`.

    Response includes:
    - `polylines` — encoded polylines for the line geometry
    - `stops` — ordered station list with transfer info
    - `directions` — per-direction shapes split by GTFS `direction_id`
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
    enrich_stops_with_transfers(all_stops, current_route=f"MNR_{numeric_id}")

    # Build per-direction shapes
    directions: list[DirectionShape] = []
    for dd in line_data.get("directions", []):
        dir_encoded = [_encode_polyline(coords) for coords in dd["polylines"]]
        dir_stops = [
            BusStop(id=s.stop_id, name=s.name, lat=s.lat, lon=s.lon)
            for s in dd.get("stops", [])
        ]
        enrich_stops_with_transfers(dir_stops, current_route=f"MNR_{numeric_id}")
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
    "/mnr",
    response_model=list[TrackArrival],
    summary="Get real-time Metro-North arrivals",
    description="Returns upcoming real-time Metro-North arrivals from the GTFS-Realtime feed.",
)
async def mnr_arrivals(response: Response) -> list[TrackArrival]:
    """Return upcoming Metro-North arrivals.

    Each arrival includes `route_id`, `station_name`, `direction`,
    `destination`, `minutes_away`, `arrival_ts` (epoch), and `status`.

    Returns an empty array if the MTA feed is temporarily unavailable.
    """
    try:
        return filter_fresh_arrivals(await fetch_rail_arrivals("metro_north"))
    except Exception as exc:
        TrackLogger.warning(
            f"[MNR] /mnr: feed error ({exc}) — returning empty fallback",
            tag="MNR",
        )
        response.headers["X-Track-Degraded"] = "mnr-arrivals-fallback"
        return []
