#
# bus.py
# TrackBackend
#
# Router for MTA Bus endpoints.
# Uses the dual-API architecture: OBA for static data, SIRI for real-time.
#

from __future__ import annotations

import logging
import traceback
from datetime import datetime, timezone, timedelta

import httpx
from fastapi import APIRouter, HTTPException, Query, Response

from app.config import get_settings
from app.models import BusArrival, BusRoute, BusStop, BusVehicle, RouteShape
from app.services.bus_client import (
    get_nearby_stops,
    get_realtime_arrivals,
    get_route_shape,
    get_routes,
    get_stops,
    get_vehicle_positions,
)
from app.services.schedule_service import schedule_service
from app.utils.logger import TrackLogger

logger = logging.getLogger("track")
router = APIRouter(prefix="/bus", tags=["bus"])


def _raise_bus_upstream_http_error(exc: httpx.HTTPStatusError) -> None:
    """Normalize upstream bus API errors into stable API responses."""
    status = exc.response.status_code if exc.response is not None else 502
    if status in (401, 403):
        raise HTTPException(
            status_code=503,
            detail="Bus API authentication failed or quota exceeded",
        ) from exc
    if status == 404:
        raise HTTPException(status_code=404, detail="Route not found") from exc
    raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/schedule/{route_id}")
async def get_bus_schedule(route_id: str):
    """
    Returns today's upcoming scheduled departures for a bus route,
    using the OneBusAway schedule-for-stop API.
    """
    from datetime import datetime, timezone, timedelta

    import httpx as _httpx

    settings = get_settings()
    oba_base = settings.urls.bus_oba_base
    api_key = settings.api_keys.mta_bus_key

    if not oba_base or not api_key:
        TrackLogger.warning("[SCHEDULE] OBA base URL or API key not configured", tag="BUS")
        return {"route_id": route_id, "directions": []}

    now = datetime.now(timezone(timedelta(hours=-5)))
    now_epoch = int(now.timestamp())

    # Fetch stops using the existing bus_client function (handles agency prefix resolution)
    try:
        stop_models = await get_stops(route_id)
    except Exception as e:
        logger.error(f"[SCHEDULE] Failed to get stops for {route_id}: {e}")
        return {"route_id": route_id, "directions": []}

    if not stop_models:
        return {"route_id": route_id, "directions": []}

    # Group stops by direction
    dir_stops: dict[str, list[BusStop]] = {}
    for stop in stop_models:
        d = stop.direction or "0"
        dir_stops.setdefault(d, []).append(stop)

    directions = []
    async with _httpx.AsyncClient(timeout=10) as client:
        for direction, d_stops in dir_stops.items():
            sample_stops = d_stops[:3]
            scheduled_departures = []

            for stop in sample_stops:
                if not stop.id:
                    continue
                try:
                    url = f"{oba_base}/api/where/schedule-for-stop/{stop.id}.json"
                    params = {"key": api_key, "date": now.strftime("%Y-%m-%d")}
                    resp = await client.get(url, params=params)
                    if resp.status_code != 200:
                        continue
                    data = resp.json()
                except Exception:
                    continue

                entry = data.get("data", {}).get("entry", {})
                for srs in entry.get("stopRouteSchedules", []):
                    srs_route = srs.get("routeId", "")
                    if route_id.upper() not in srs_route.upper():
                        continue
                    for dg in srs.get("stopRouteDirectionSchedules", []):
                        headsign = dg.get("tripHeadsign", "")
                        for ts in dg.get("scheduleStopTimes", []):
                            t = ts.get("departureTime", 0) or ts.get("arrivalTime", 0)
                            if t and t / 1000 > now_epoch:
                                scheduled_departures.append({
                                    "stop_name": stop.name,
                                    "stop_id": stop.id,
                                    "departure_time": t // 1000,
                                    "headsign": headsign,
                                    "trip_id": ts.get("tripId", ""),
                                })
                if scheduled_departures:
                    break

            seen = set()
            unique = []
            for dep in sorted(scheduled_departures, key=lambda x: x["departure_time"]):
                if dep["trip_id"] not in seen:
                    seen.add(dep["trip_id"])
                    unique.append(dep)

            directions.append({
                "route_id": route_id,
                "direction": direction,
                "headsign": unique[0]["headsign"] if unique else "",
                "departures": unique[:10],
            })

    return {"route_id": route_id, "directions": directions}


@router.get("/routes", response_model=list[BusRoute])
async def bus_routes() -> list[BusRoute]:
    """Return all MTA bus routes."""
    try:
        return await get_routes()
    except httpx.HTTPStatusError as exc:
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/stops/{route_id:path}", response_model=list[BusStop])
async def bus_stops(route_id: str) -> list[BusStop]:
    """Return stops for a bus route (e.g. ``/bus/stops/MTA NYCT_B63``)."""
    try:
        return await get_stops(route_id)
    except httpx.HTTPStatusError as exc:
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/nearby", response_model=list[BusStop])
async def bus_nearby(
    lat: float = Query(..., description="Latitude"),
    lon: float = Query(..., description="Longitude"),
    radius: int | None = Query(None, description="Search radius in meters"),
) -> list[BusStop]:
    """Return bus stops near a GPS coordinate."""
    settings = get_settings()
    effective_radius = radius if radius is not None else settings.app_settings.search_radius_meters
    TrackLogger.location(lat, lon, "bus/nearby")
    try:
        return await get_nearby_stops(lat, lon, radius_m=effective_radius)
    except httpx.HTTPStatusError as exc:
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/live/{stop_id:path}", response_model=list[BusArrival])
async def bus_live(stop_id: str) -> list[BusArrival]:
    """Return real-time bus arrivals at a stop (e.g. ``/bus/live/MTA_308214``)."""
    try:
        live_arrivals = await get_realtime_arrivals(stop_id)
        
        # Filter out stale arrivals (older than 1 minute ago)
        now_utc = datetime.now(timezone.utc)
        live_arrivals = [
            a for a in live_arrivals
            if not a.expected_arrival or (
                a.expected_arrival.replace(tzinfo=timezone.utc) if a.expected_arrival.tzinfo is None else a.expected_arrival
            ) > now_utc - timedelta(seconds=60)
        ]

        if not live_arrivals:
            # Fallback to schedule
            scheduled = schedule_service.get_scheduled_arrivals(stop_id, limit=5)
            return [
                BusArrival(
                    route_id=s.route_id,
                    vehicle_id="",
                    stop_id=s.station,
                    status_text=f"{s.destination} ({s.status})",
                    status="Scheduled",
                    expected_arrival=datetime.fromtimestamp(s.arrival_ts) if s.arrival_ts else None,
                    distance_meters=None,
                    bearing=None
                )
                for s in scheduled
            ]
        return live_arrivals
    except httpx.HTTPStatusError as exc:
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/vehicles/{route_id:path}", response_model=list[BusVehicle])
async def bus_vehicles(route_id: str, response: Response) -> list[BusVehicle]:
    """Return live vehicle positions for a bus route.

    Example: ``/bus/vehicles/MTA NYCT_B63``

    Each vehicle includes GPS coordinates, bearing, next stop name,
    and distance status text — everything needed to plot live buses
    on a map.
    """
    response.headers["Cache-Control"] = "public, max-age=5, stale-while-revalidate=30, stale-if-error=120"
    try:
        return await get_vehicle_positions(route_id)
    except httpx.HTTPStatusError as exc:
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/route-shape/{route_id:path}", response_model=RouteShape)
async def bus_route_shape(route_id: str, response: Response) -> RouteShape:
    """Return the route shape (polylines + stops) for a bus route.

    Example: ``/bus/route-shape/MTA NYCT_B63``

    Returns Google-encoded polylines for drawing the route on a map,
    along with all stops on the route for annotation.
    """
    response.headers["Cache-Control"] = "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800"
    try:
        return await get_route_shape(route_id)
    except httpx.HTTPStatusError as exc:
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(status_code=502, detail=str(exc)) from exc
