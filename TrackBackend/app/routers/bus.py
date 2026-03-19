#
# bus.py
# TrackBackend
#
# Router for MTA Bus endpoints.
# Uses the dual-API architecture: OBA for static data, SIRI for real-time.
#

from __future__ import annotations

import traceback
from datetime import datetime, timezone, timedelta

import httpx
from fastapi import APIRouter, HTTPException, Query, Response

from app.config import get_settings
from app.models import BusArrival, BusRoute, BusStop, BusVehicle, RouteShape, BusScheduleResponse, BusScheduleDirection, BusScheduleDeparture
from app.clients.bus_client import (
    get_nearby_stops,
    get_realtime_arrivals,
    get_route_shape,
    get_routes,
    get_static_route_shape,
    get_stops,
    get_vehicle_positions,
)
from app.services.transit.schedule_service import schedule_service
from app.utils.logger import TrackLogger

router = APIRouter(prefix="/bus", tags=["bus"])


def _fallback_route_shape(route_id: str) -> RouteShape:
    static_shape = get_static_route_shape(route_id)
    if static_shape is not None:
        return static_shape
    return RouteShape(
        route_id=route_id,
        polylines=[],
        stops=[],
        directions=[],
        service_type=None,
    )


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


# ── In-memory TTL cache for bus schedules ──────────────────────────────
# This is the most expensive endpoint (up to 6 serial OBA calls per miss)
# and the only bus endpoint that had NO caching.  A 2-minute fresh window
# with 10-minute stale-while-revalidate covers both rapid re-opens and
# background refresh, preventing upstream pile-up on a single-worker server.
import time as _time, re as _re

_schedule_cache: dict[str, tuple[float, BusScheduleResponse]] = {}
_SCHEDULE_FRESH_TTL = 120       # 2 min
_SCHEDULE_STALE_TTL = 600       # 10 min
_SCHEDULE_MAX_SIZE  = 100
_schedule_inflight: dict[str, "asyncio.Task[BusScheduleResponse]"] = {}

import asyncio as _asyncio


def _normalize_route_token(raw: str) -> str:
    """Strip agency prefix, upper-case, and remove leading zeros."""
    token = (raw.split("_", 1)[-1] if "_" in raw else raw).upper()
    return _re.sub(r"(?<=\D)0+(?=\d)", "", token) or token


async def _fetch_bus_schedule_uncached(route_id: str) -> BusScheduleResponse:
    """Actual OBA schedule fetch — extracted so the handler can wrap it with caching."""
    settings = get_settings()
    oba_base = settings.urls.bus_oba_base
    api_key = settings.api_keys.mta_bus_key or "test"

    if not oba_base:
        TrackLogger.warning("[SCHEDULE] OBA base URL not configured", tag="BUS")
        return BusScheduleResponse(route_id=route_id, directions=[])

    now = datetime.now(timezone(timedelta(hours=-5)))
    now_epoch = int(now.timestamp())

    try:
        stop_models = await get_stops(route_id)
    except Exception as e:
        TrackLogger.error(f"[SCHEDULE] Failed to get stops for {route_id}: {e}", tag="BUS", exc_info=True)
        return BusScheduleResponse(route_id=route_id, directions=[])

    if not stop_models:
        return BusScheduleResponse(route_id=route_id, directions=[])

    max_sample = 6
    if len(stop_models) <= max_sample:
        sample_stops = stop_models
    else:
        step = len(stop_models) / max_sample
        sample_stops = [stop_models[int(i * step)] for i in range(max_sample)]

    TrackLogger.info(
        f"[SCHEDULE] {route_id}: {len(stop_models)} total stops, "
        f"sampling {len(sample_stops)} stops",
        tag="BUS",
    )

    req_token = _normalize_route_token(route_id)
    all_departures: list[BusScheduleDeparture] = []

    # Re-use a single httpx client for all stops (connection pooling)
    async with httpx.AsyncClient(timeout=10) as client:
        for stop in sample_stops:
            if not stop.id:
                continue
            try:
                url = f"{oba_base}/schedule-for-stop/{stop.id}.json"
                params = {"key": api_key, "date": now.strftime("%Y-%m-%d")}
                resp = await client.get(url, params=params)
                if resp.status_code != 200:
                    TrackLogger.warning(
                        f"[SCHEDULE] {route_id} stop={stop.id}: HTTP {resp.status_code}",
                        tag="BUS",
                    )
                    continue
                data = resp.json()
            except Exception as exc:
                TrackLogger.warning(
                    f"[SCHEDULE] {route_id} stop={stop.id}: {exc}",
                    tag="BUS",
                )
                continue

            entry = data.get("data", {}).get("entry", {})
            for srs in entry.get("stopRouteSchedules", []):
                srs_route = srs.get("routeId", "")
                srs_token = _normalize_route_token(srs_route)
                if srs_token != req_token:
                    continue
                for dg in srs.get("stopRouteDirectionSchedules", []):
                    headsign = dg.get("tripHeadsign", "")
                    for ts in dg.get("scheduleStopTimes", []):
                        t = ts.get("departureTime", 0) or ts.get("arrivalTime", 0)
                        if t and t / 1000 > now_epoch:
                            all_departures.append(BusScheduleDeparture(
                                stop_name=stop.name,
                                stop_id=stop.id,
                                departure_time=t // 1000,
                                headsign=headsign,
                                trip_id=ts.get("tripId", ""),
                            ))

            found_headsigns = set(d.headsign for d in all_departures)
            if len(found_headsigns) >= 2 and len(all_departures) >= 10:
                break

    hs_groups: dict[str, list[BusScheduleDeparture]] = {}
    for dep in all_departures:
        hs_groups.setdefault(dep.headsign, []).append(dep)

    directions: list[BusScheduleDirection] = []
    for headsign, deps in hs_groups.items():
        seen: set[str] = set()
        unique: list[BusScheduleDeparture] = []
        for dep in sorted(deps, key=lambda x: x.departure_time):
            if dep.trip_id not in seen:
                seen.add(dep.trip_id)
                unique.append(dep)

        TrackLogger.info(
            f"[SCHEDULE] {route_id} hs='{headsign[:50]}': "
            f"{len(deps)} raw deps → {len(unique)} unique",
            tag="BUS",
        )

        directions.append(BusScheduleDirection(
            route_id=route_id,
            direction=headsign,
            headsign=headsign,
            departures=unique[:30],
        ))

    return BusScheduleResponse(route_id=route_id, directions=directions)


@router.get("/schedule/{route_id}", response_model=BusScheduleResponse)
async def get_bus_schedule(route_id: str, response: Response) -> BusScheduleResponse:
    """
    Returns today's upcoming scheduled departures for a bus route,
    using the OneBusAway schedule-for-stop API.

    Departures are grouped by **headsign** (the trip's terminal destination)
    which aligns with the logical route directions the iOS app expects
    (e.g. "RUSH JFK AIRPORT via LEFFERTS BL" vs "RUSH KEW GARDENS via LEFFERTS BL").
    """
    response.headers["Cache-Control"] = "public, max-age=60, stale-while-revalidate=600, stale-if-error=3600"

    key = _normalize_route_token(route_id)
    now = _time.monotonic()

    # ── L1: In-memory TTL cache ─────────────────────────────────────────
    cached = _schedule_cache.get(key)
    if cached:
        ts, result = cached
        age = now - ts
        if age < _SCHEDULE_FRESH_TTL:
            TrackLogger.info(f"[SCHEDULE] CACHE HIT {route_id} (age={age:.0f}s)", tag="BUS")
            return result
        if age < _SCHEDULE_STALE_TTL:
            TrackLogger.info(f"[SCHEDULE] CACHE STALE-HIT {route_id} (age={age:.0f}s), bg refresh", tag="BUS")
            # Return stale, refresh in background
            if key not in _schedule_inflight:
                async def _bg_refresh(k: str, rid: str) -> None:
                    try:
                        fresh = await _fetch_bus_schedule_uncached(rid)
                        _schedule_cache[k] = (_time.monotonic(), fresh)
                    except Exception as exc:
                        TrackLogger.warning(f"[SCHEDULE] bg refresh {rid}: {exc}", tag="BUS")
                    finally:
                        _schedule_inflight.pop(k, None)
                _schedule_inflight[key] = _asyncio.create_task(_bg_refresh(key, route_id))
            return result

    # ── Deduplicate inflight requests ──────────────────────────────────
    if key in _schedule_inflight:
        TrackLogger.info(f"[SCHEDULE] COALESCE {route_id}", tag="BUS")
        try:
            return await _schedule_inflight[key]
        except Exception:
            pass  # fall through to fresh fetch

    # ── Fresh fetch ────────────────────────────────────────────────────
    async def _do_fetch() -> BusScheduleResponse:
        try:
            result = await _fetch_bus_schedule_uncached(route_id)
            _schedule_cache[key] = (_time.monotonic(), result)
            # Evict oldest when oversized
            if len(_schedule_cache) > _SCHEDULE_MAX_SIZE:
                oldest_key = min(_schedule_cache, key=lambda k: _schedule_cache[k][0])
                _schedule_cache.pop(oldest_key, None)
            return result
        finally:
            _schedule_inflight.pop(key, None)

    task = _asyncio.create_task(_do_fetch())
    _schedule_inflight[key] = task
    return await task


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
async def bus_stops(route_id: str, response: Response) -> list[BusStop]:
    """Return stops for a bus route (e.g. ``/bus/stops/MTA NYCT_B63``)."""
    try:
        return await get_stops(route_id)
    except httpx.HTTPStatusError as exc:
        status = exc.response.status_code if exc.response is not None else 502
        if status in (401, 403, 404, 429, 500, 502, 503, 504):
            TrackLogger.warning(
                f"[BUS] /stops/{route_id}: upstream HTTP {status} — returning empty fallback",
                tag="BUS",
            )
            response.headers["X-Track-Degraded"] = "stops-fallback"
            return []
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        TrackLogger.warning(
            f"[BUS] /stops/{route_id}: upstream error ({exc}) — returning empty fallback",
            tag="BUS",
        )
        response.headers["X-Track-Degraded"] = "stops-fallback"
        return []


@router.get("/nearby", response_model=list[BusStop])
async def bus_nearby(
    response: Response,
    lat: float = Query(..., ge=-90, le=90, description="Latitude"),
    lon: float = Query(..., ge=-180, le=180, description="Longitude"),
    radius: int | None = Query(None, description="Search radius in meters"),
) -> list[BusStop]:
    """Return bus stops near a GPS coordinate."""
    settings = get_settings()
    effective_radius = radius if radius is not None else settings.app_settings.search_radius_meters
    TrackLogger.location(lat, lon, "bus/nearby")
    try:
        return await get_nearby_stops(lat, lon, radius_m=effective_radius)
    except httpx.HTTPStatusError as exc:
        status = exc.response.status_code if exc.response is not None else 502
        if status in (401, 403, 404, 429, 500, 502, 503, 504):
            TrackLogger.warning(
                f"[BUS] /nearby: upstream HTTP {status} — returning empty fallback",
                tag="BUS",
            )
            response.headers["X-Track-Degraded"] = "nearby-fallback"
            return []
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        TrackLogger.warning(
            f"[BUS] /nearby: upstream error ({exc}) — returning empty fallback",
            tag="BUS",
        )
        response.headers["X-Track-Degraded"] = "nearby-fallback"
        return []


@router.get("/live/{stop_id:path}", response_model=list[BusArrival])
async def bus_live(stop_id: str, response: Response) -> list[BusArrival]:
    """Return real-time bus arrivals at a stop (e.g. ``/bus/live/MTA_308214``)."""
    def _schedule_fallback() -> list[BusArrival]:
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
                bearing=None,
            )
            for s in scheduled
        ]

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
            return _schedule_fallback()
        return live_arrivals
    except httpx.HTTPStatusError as exc:
        status = exc.response.status_code if exc.response is not None else 502
        if status in (401, 403, 404, 429, 500, 502, 503, 504):
            TrackLogger.warning(
                f"[BUS] /live/{stop_id}: upstream HTTP {status} — returning schedule fallback",
                tag="BUS",
            )
            response.headers["X-Track-Degraded"] = "live-fallback"
            return _schedule_fallback()
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        TrackLogger.warning(
            f"[BUS] /live/{stop_id}: upstream error ({exc}) — returning schedule fallback",
            tag="BUS",
        )
        response.headers["X-Track-Degraded"] = "live-fallback"
        return _schedule_fallback()


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
        status = exc.response.status_code if exc.response is not None else 502
        if status in (401, 403, 404, 429, 500, 502, 503, 504):
            TrackLogger.warning(
                f"[BUS] /vehicles/{route_id}: upstream HTTP {status} — returning empty fallback",
                tag="BUS",
            )
            response.headers["X-Track-Degraded"] = "vehicles-fallback"
            return []
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        TrackLogger.warning(
            f"[BUS] /vehicles/{route_id}: upstream error ({exc}) — returning empty fallback",
            tag="BUS",
        )
        response.headers["X-Track-Degraded"] = "vehicles-fallback"
        return []


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
        status = exc.response.status_code if exc.response is not None else 502
        if status in (401, 403, 404, 429, 500, 502, 503, 504):
            TrackLogger.warning(
                f"[BUS] /route-shape/{route_id}: upstream HTTP {status} — returning empty shape fallback",
                tag="BUS",
            )
            response.headers["X-Track-Degraded"] = "shape-fallback"
            return _fallback_route_shape(route_id)
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        traceback.print_exc()
        TrackLogger.warning(
            f"[BUS] /route-shape/{route_id}: upstream error ({exc}) — returning empty shape fallback",
            tag="BUS",
        )
        response.headers["X-Track-Degraded"] = "shape-fallback"
        return _fallback_route_shape(route_id)
