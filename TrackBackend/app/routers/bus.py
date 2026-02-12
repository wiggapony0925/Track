#
# bus.py
# TrackBackend
#
# Router for MTA Bus endpoints.
# Uses the dual-API architecture: OBA for static data, SIRI for real-time.
#

from __future__ import annotations

import httpx
from fastapi import APIRouter, HTTPException, Query

from app.models import BusArrival, BusRoute, BusStop, BusVehicle, RouteShape
from app.services.bus_client import (
    get_nearby_stops,
    get_realtime_arrivals,
    get_route_shape,
    get_routes,
    get_stops,
    get_vehicle_positions,
)
from app.utils.logger import TrackLogger

router = APIRouter(prefix="/bus", tags=["bus"])


@router.get("/routes", response_model=list[BusRoute])
async def bus_routes() -> list[BusRoute]:
    """Return all MTA bus routes."""
    try:
        return await get_routes()
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code in (401, 403):
            raise HTTPException(
                status_code=503,
                detail="Bus API authentication failed or quota exceeded",
            ) from exc
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/stops/{route_id:path}", response_model=list[BusStop])
async def bus_stops(route_id: str) -> list[BusStop]:
    """Return stops for a bus route (e.g. ``/bus/stops/MTA NYCT_B63``)."""
    try:
        return await get_stops(route_id)
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code in (401, 403):
            raise HTTPException(
                status_code=503,
                detail="Bus API authentication failed or quota exceeded",
            ) from exc
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/nearby", response_model=list[BusStop])
async def bus_nearby(
    lat: float = Query(..., description="Latitude"),
    lon: float = Query(..., description="Longitude"),
    radius: int = Query(800, description="Search radius in meters"),
) -> list[BusStop]:
    """Return bus stops near a GPS coordinate."""
    TrackLogger.location(lat, lon, "bus/nearby")
    try:
        return await get_nearby_stops(lat, lon, radius_m=radius)
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code in (401, 403):
            raise HTTPException(
                status_code=503,
                detail="Bus API authentication failed or quota exceeded",
            ) from exc
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/live/{stop_id:path}", response_model=list[BusArrival])
async def bus_live(stop_id: str) -> list[BusArrival]:
    """Return real-time bus arrivals at a stop (e.g. ``/bus/live/MTA_308214``)."""
    try:
        return await get_realtime_arrivals(stop_id)
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code in (401, 403):
            raise HTTPException(
                status_code=503,
                detail="Bus API authentication failed or quota exceeded",
            ) from exc
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/vehicles/{route_id:path}", response_model=list[BusVehicle])
async def bus_vehicles(route_id: str) -> list[BusVehicle]:
    """Return live vehicle positions for a bus route.

    Example: ``/bus/vehicles/MTA NYCT_B63``

    Each vehicle includes GPS coordinates, bearing, next stop name,
    and distance status text — everything needed to plot live buses
    on a map.
    """
    try:
        return await get_vehicle_positions(route_id)
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code in (401, 403):
            raise HTTPException(
                status_code=503,
                detail="Bus API authentication failed or quota exceeded",
            ) from exc
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/route-shape/{route_id:path}", response_model=RouteShape)
async def bus_route_shape(route_id: str) -> RouteShape:
    """Return the route shape (polylines + stops) for a bus route.

    Example: ``/bus/route-shape/MTA NYCT_B63``

    Returns Google-encoded polylines for drawing the route on a map,
    along with all stops on the route for annotation.
    """
    try:
        return await get_route_shape(route_id)
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code in (401, 403):
            raise HTTPException(
                status_code=503,
                detail="Bus API authentication failed or quota exceeded",
            ) from exc
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
