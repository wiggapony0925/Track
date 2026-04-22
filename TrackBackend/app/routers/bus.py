"""Router for MTA Bus endpoints.
Uses the dual-API architecture: OBA for static data, SIRI for real-time."""

from __future__ import annotations

import asyncio as _asyncio
import re as _re
import time as _time
from collections import OrderedDict as _OrderedDict
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import httpx
from fastapi import APIRouter, HTTPException, Path, Query, Response

from app.clients.bus_client import (
    get_nearby_stops,
    get_realtime_arrivals,
    get_route_shape,
    get_routes,
    get_static_route_shape,
    get_stops,
    get_vehicle_positions,
    normalize_bus_short_name,
)
from app.config import get_settings
from app.models import (
    RESP_404,
    RESP_502,
    BusArrival,
    BusRoute,
    BusScheduleDeparture,
    BusScheduleDirection,
    BusScheduleResponse,
    BusStop,
    BusTileData,
    BusTileRoute,
    BusTileStop,
    BusVehicle,
    RouteShape,
)
from app.routers.nearby import _bus_color_for_service_type, _classify_bus_service_type
from app.services.mapping.bus.routes import get_bus_open_data_shapes
from app.services.mapping.bus.stops import get_bus_route_stops, get_bus_stop_index
from app.services.transit.schedule_service import schedule_service
from app.utils.logger import TrackLogger

router = APIRouter(prefix="/bus", tags=["bus"])


async def _fallback_route_shape(route_id: str) -> RouteShape:
    # Normalise: "MTA NYCT_B63" → "B63".
    short = route_id.split("_", 1)[-1].strip() if "_" in route_id else route_id

    # Tier 1: open data (clean street geometry + live stop list per bundle).
    open_data_index = await get_bus_open_data_shapes()
    od_shape = open_data_index.get(short)
    if od_shape is not None:
        # Enrich each direction with stop locations from the stops dataset.
        enriched = []
        for direction in od_shape.directions:
            stops = await get_bus_route_stops(short, direction.direction_id)
            enriched.append(direction.model_copy(update={"stops": stops}))
        return od_shape.model_copy(update={"directions": enriched})

    # Tier 2: GTFS static shapes (raw, updated 4×/year).
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


# ── In-memory TTL cache for tile data ─────────────────────────────────
# Pre-built response is heavy (~1 MB) but changes only on schedule bundle
# updates.  Cache for 6 hours in-memory to avoid rebuilding on every call.
_tile_data_cache: BusTileData | None = None
_tile_data_cache_ts: float = 0.0
_TILE_DATA_TTL = 6 * 3_600  # 6 hours


@router.get(
    "/tile-data",
    response_model=BusTileData,
    summary="All bus shapes and stops for map tile baking",
    description=(
        "Returns every NYC bus route polyline and every revenue stop in a "
        "single compact payload. Designed for the iOS app to download once, "
        "bake into GeoJSON tile files, and render as MapLibre GL layers."
    ),
)
async def bus_tile_data(response: Response) -> BusTileData:
    """Return all bus route shapes and stops for pre-baked tile rendering.

    The payload is cached aggressively (6 h in-memory, 24 h HTTP) because
    the underlying open data datasets update only with MTA schedule bundles
    (roughly monthly).

    Cached for 24 hours — bus network topology rarely changes.
    """
    global _tile_data_cache, _tile_data_cache_ts  # noqa: PLW0603

    response.headers["Cache-Control"] = (
        "public, max-age=86400, stale-while-revalidate=604800"
    )

    now = _time.time()
    if _tile_data_cache is not None and (now - _tile_data_cache_ts) < _TILE_DATA_TTL:
        return _tile_data_cache

    t0 = _time.perf_counter()

    # Fetch shapes and stops concurrently.
    shapes_task = get_bus_open_data_shapes()
    stops_task = get_bus_stop_index()
    shapes_index, stop_index = await _asyncio.gather(shapes_task, stops_task)

    # Build compact route list — color-coded by service type.
    tile_routes: list[BusTileRoute] = []
    for route_id, shape in sorted(shapes_index.items()):
        if not shape.polylines:
            continue
        service_type = _classify_bus_service_type(
            route_id, open_data_service_type=shape.service_type
        )
        color = _bus_color_for_service_type(service_type).lstrip("#")
        tile_routes.append(
            BusTileRoute(
                route_id=route_id,
                short_name=normalize_bus_short_name(route_id),
                color=color,
                polylines=shape.polylines,
            )
        )

    # Build compact stop list (deduplicated by stop ID).
    tile_stops: list[BusTileStop] = []
    for stop_id, stop in sorted(stop_index.items()):
        tile_stops.append(
            BusTileStop(id=stop_id, name=stop.name, lat=stop.lat, lon=stop.lon)
        )

    result = BusTileData(routes=tile_routes, stops=tile_stops)
    _tile_data_cache = result
    _tile_data_cache_ts = now

    elapsed = _time.perf_counter() - t0
    TrackLogger.info(
        f"[BUS] /tile-data: built {len(tile_routes)} routes, "
        f"{len(tile_stops)} stops in {elapsed:.1f}s",
        tag="BUS",
    )
    return result


# ── In-memory TTL cache for bus schedules ──────────────────────────────
# This is the most expensive endpoint (up to 6 serial OBA calls per miss)
# and the only bus endpoint that had NO caching.  A 2-minute fresh window
# with 10-minute stale-while-revalidate covers both rapid re-opens and
# background refresh, preventing upstream pile-up on a single-worker server.

# OrderedDict gives O(1) LRU eviction: move_to_end() on access,
# popitem(last=False) to evict the oldest entry.
_schedule_cache: _OrderedDict[str, tuple[float, BusScheduleResponse]] = _OrderedDict()
_SCHEDULE_FRESH_TTL = 120  # 2 min
_SCHEDULE_STALE_TTL = 600  # 10 min
_SCHEDULE_MAX_SIZE = 100
_OBA_REQUEST_TIMEOUT = 10
_MAX_SCHEDULE_SAMPLE_STOPS = 6
_schedule_inflight: dict[str, _asyncio.Task[BusScheduleResponse]] = {}


def _normalize_route_token(raw: str) -> str:
    """Strip agency prefix, upper-case, remove leading zeros, normalise SBS.

    MTA uses two SBS forms interchangeably:
      - Display / client side: ``M34-SBS``
      - OBA / SIRI route IDs:  ``M34+SBS`` (or just ``M34+``)
    Normalize ``+`` → ``-`` so both forms produce the same cache / match key.
    Also treat a bare trailing ``+`` as ``-SBS`` (e.g. ``M34+`` → ``M34-SBS``).
    """
    token = (raw.split("_", 1)[-1] if "_" in raw else raw).upper()
    token = _re.sub(r"(?<=\D)0+(?=\d)", "", token) or token
    # Unify SBS variants: M34+SBS → M34-SBS, M34+ → M34-SBS
    token = _re.sub(r"\+SBS$", "-SBS", token)
    return _re.sub(r"\+$", "-SBS", token)


# Regex to extract a bus route token embedded between underscores in a trip ID.
# MTA trip IDs follow: "AGENCY_DEPOT_SERVICE_ROUTE_BLOCK[_TIMESTAMP]"
# e.g. "MTA NYCT_MV_A6-Weekday-SDon-036000_M11_601"
# The route segment is letters followed by digits (optionally +/-SBS).
_TRIP_ROUTE_RE = _re.compile(r"_([A-Za-z]+\d+(?:[+-]SBS)?)_")


def _trip_route_token(trip_id: str) -> str | None:
    """Extract a normalised route token from an MTA trip ID, if recognisable.

    Returns ``None`` when the format is unrecognised so the caller can
    conservatively keep the trip rather than wrongly filtering it out.
    """
    m = _TRIP_ROUTE_RE.search(trip_id)
    if m is None:
        return None
    return _normalize_route_token(m.group(1))


async def _fetch_bus_schedule_uncached(route_id: str) -> BusScheduleResponse:
    """Actual OBA schedule fetch — extracted so the handler can wrap it with caching.

    Walks ``max_bus_schedule_days_ahead`` consecutive service days so the
    chip strip and Departures board can show Transit-style multi-day
    depth, matching the subway / LIRR / MNR backfill paths.
    """
    settings = get_settings()
    oba_base = settings.urls.bus_oba_base
    api_key = settings.api_keys.mta_bus_key or "test"
    days_ahead = max(1, settings.app_settings.max_bus_schedule_days_ahead)

    if not oba_base:
        TrackLogger.warning("[SCHEDULE] OBA base URL not configured", tag="BUS")
        return BusScheduleResponse(route_id=route_id, directions=[])

    now = datetime.now(ZoneInfo("America/New_York"))
    now_epoch = int(now.timestamp())

    try:
        stop_models = await get_stops(route_id)
    except Exception as e:
        TrackLogger.error(
            f"[SCHEDULE] Failed to get stops for {route_id}: {e}",
            tag="BUS",
            exc_info=True,
        )
        return BusScheduleResponse(route_id=route_id, directions=[])

    if not stop_models:
        return BusScheduleResponse(route_id=route_id, directions=[])

    # Always include the first and last stops (terminals) — these have
    # the most reliable schedule data because every trip passes through
    # them.  Fill the remaining slots with evenly-spaced interior stops.
    max_sample = _MAX_SCHEDULE_SAMPLE_STOPS
    if len(stop_models) <= max_sample:
        sample_stops = stop_models
    else:
        interior_count = max_sample - 2  # reserve 2 slots for terminals
        interior = stop_models[1:-1]
        step = len(interior) / interior_count
        sampled_interior = [interior[int(i * step)] for i in range(interior_count)]
        sample_stops = [stop_models[0], *sampled_interior, stop_models[-1]]

    TrackLogger.info(
        f"[SCHEDULE] {route_id}: {len(stop_models)} total stops, "
        f"sampling {len(sample_stops)} stops × {days_ahead} day(s)",
        tag="BUS",
    )

    req_token = _normalize_route_token(route_id)
    all_departures: list[BusScheduleDeparture] = []
    interline_skipped = 0

    # Re-use a single httpx client for all stops & days (connection pooling)
    async with httpx.AsyncClient(timeout=_OBA_REQUEST_TIMEOUT) as client:
        for day_offset in range(days_ahead):
            day = now + timedelta(days=day_offset)
            date_str = day.strftime("%Y-%m-%d")
            for stop in sample_stops:
                if not stop.id:
                    continue
                try:
                    url = f"{oba_base}/schedule-for-stop/{stop.id}.json"
                    params = {"key": api_key, "date": date_str}
                    resp = await client.get(url, params=params)
                    if resp.status_code != 200:
                        TrackLogger.warning(
                            f"[SCHEDULE] {route_id} stop={stop.id} day={date_str}: "
                            f"HTTP {resp.status_code}",
                            tag="BUS",
                        )
                        continue
                    data = resp.json()
                except Exception as exc:
                    TrackLogger.warning(
                        f"[SCHEDULE] {route_id} stop={stop.id} day={date_str}: {exc}",
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
                            if not (t and t / 1000 > now_epoch):
                                continue

                            trip_id = ts.get("tripId", "")

                            # ── Interline guard ────────────────────────
                            # OBA nests interlined trips inside the
                            # parent route's SRS block (e.g. M104 trips
                            # appear under M11).  The trip ID embeds the
                            # *actual* route — reject mismatches.
                            trip_token = _trip_route_token(trip_id)
                            if trip_token is not None and trip_token != req_token:
                                interline_skipped += 1
                                continue

                            all_departures.append(
                                BusScheduleDeparture(
                                    stop_name=stop.name,
                                    stop_id=stop.id,
                                    departure_time=t // 1000,
                                    headsign=headsign,
                                    trip_id=trip_id,
                                )
                            )

                # Per-day early break only when we have a healthy sample
                # AND we're still on the first day — otherwise we'd skip
                # the multi-day fan-out entirely.
                if day_offset == 0:
                    found_headsigns = {d.headsign for d in all_departures}
                    if len(found_headsigns) >= 2 and len(all_departures) >= 30:
                        break

    if interline_skipped:
        TrackLogger.info(
            f"[SCHEDULE] {route_id}: filtered {interline_skipped} interlined "
            f"trips from other routes",
            tag="BUS",
        )

    hs_groups: dict[str, list[BusScheduleDeparture]] = {}
    for dep in all_departures:
        hs_groups.setdefault(dep.headsign, []).append(dep)

    # Per-direction cap — generous enough to support browsing days ahead
    # like Transit does, without flooding the wire for casual chip use.
    per_direction_cap = settings.app_settings.max_schedule_per_line // 2 or 200

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

        directions.append(
            BusScheduleDirection(
                route_id=route_id,
                direction=headsign,
                headsign=headsign,
                departures=unique[:per_direction_cap],
            )
        )

    return BusScheduleResponse(route_id=route_id, directions=directions)


@router.get(
    "/schedule/{route_id}",
    response_model=BusScheduleResponse,
    summary="Get bus schedule",
    description=(
        "Returns today's upcoming scheduled departures for a bus route, grouped by direction and headsign. "
        "Useful as a fallback when real-time SIRI data is unavailable."
    ),
    responses={**RESP_404, **RESP_502},
)
async def get_bus_schedule(
    route_id: str = Path(
        ...,
        description="MTA bus route ID — short name or fully-qualified OBA ID.",
        examples=["B63", "M34-SBS", "MTA NYCT_B63"],
    ),
    response: Response = None,
) -> BusScheduleResponse:
    """Return today's upcoming scheduled departures for a bus route.

    **Path parameter:** MTA bus route ID — e.g. `B63`, `M34-SBS`, `MTA NYCT_B63`.

    Departures are grouped by **headsign** (the trip's terminal destination),
    which aligns with the logical route directions.

    Cached for 60 s with stale-while-revalidate.
    """
    response.headers["Cache-Control"] = (
        "public, max-age=60, stale-while-revalidate=600, stale-if-error=3600"
    )

    key = _normalize_route_token(route_id)
    now = _time.monotonic()

    # ── L1: In-memory TTL cache ─────────────────────────────────────────
    cached = _schedule_cache.get(key)
    if cached:
        ts, result = cached
        age = now - ts
        if age < _SCHEDULE_FRESH_TTL:
            _schedule_cache.move_to_end(key)  # mark as recently used
            TrackLogger.info(
                f"[SCHEDULE] CACHE HIT {route_id} (age={age:.0f}s)", tag="BUS"
            )
            return result
        if age < _SCHEDULE_STALE_TTL:
            TrackLogger.info(
                f"[SCHEDULE] CACHE STALE-HIT {route_id} (age={age:.0f}s), bg refresh",
                tag="BUS",
            )
            # Return stale, refresh in background
            if key not in _schedule_inflight:

                async def _bg_refresh(k: str, rid: str) -> None:
                    try:
                        fresh = await _fetch_bus_schedule_uncached(rid)
                        _schedule_cache[k] = (_time.monotonic(), fresh)
                    except Exception as exc:
                        TrackLogger.warning(
                            f"[SCHEDULE] bg refresh {rid}: {exc}", tag="BUS"
                        )
                    finally:
                        _schedule_inflight.pop(k, None)

                _schedule_inflight[key] = _asyncio.create_task(
                    _bg_refresh(key, route_id)
                )
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
            _schedule_cache.move_to_end(key)  # freshest at the end
            # Evict oldest (front of OrderedDict) — O(1)
            while len(_schedule_cache) > _SCHEDULE_MAX_SIZE:
                _schedule_cache.popitem(last=False)
            return result
        finally:
            _schedule_inflight.pop(key, None)

    task = _asyncio.create_task(_do_fetch())
    _schedule_inflight[key] = task
    return await task


@router.get(
    "/routes",
    response_model=list[BusRoute],
    summary="List all bus routes",
    description=(
        "Returns every MTA bus route with short name, long name, brand colour, and description. "
        "Covers all 300+ NYC bus routes across all five boroughs."
    ),
    responses={**RESP_502},
)
async def bus_routes() -> list[BusRoute]:
    """Return all MTA bus routes.

    Each route includes `id`, `short_name` (e.g. `B63`), `long_name`,
    `color` (hex), and `description`.
    """
    try:
        return await get_routes()
    except httpx.HTTPStatusError as exc:
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get(
    "/stops/{route_id:path}",
    response_model=list[BusStop],
    summary="Get stops for a bus route",
    description=(
        "Returns all stops along a specific bus route, including coordinates, direction, "
        "and all other routes that serve each stop. Returns an empty array on upstream failure."
    ),
    responses={**RESP_502},
)
async def bus_stops(
    route_id: str = Path(
        ...,
        description="Fully-qualified OBA route ID.",
        examples=["MTA NYCT_B63", "MTA NYCT_M34-SBS"],
    ),
    response: Response = None,
) -> list[BusStop]:
    """Return stops for a bus route.

    **Path parameter:** MTA bus route ID — e.g. `MTA NYCT_B63`.

    Each stop includes `id`, `name`, `lat`, `lon`, `direction`, and
    `route_ids` (all routes that serve this stop).

    Returns an empty array if the upstream API is unavailable.
    """
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


@router.get(
    "/nearby",
    response_model=list[BusStop],
    summary="Get nearby bus stops",
    description=(
        "Returns bus stops within a given radius of a GPS coordinate. "
        "Each stop includes coordinates, direction, and all route IDs served."
    ),
    responses={**RESP_502},
)
async def bus_nearby(
    response: Response,
    lat: float = Query(
        ...,
        ge=-90,
        le=90,
        description="Latitude of the user's location.",
        examples=[40.7580],
    ),
    lon: float = Query(
        ...,
        ge=-180,
        le=180,
        description="Longitude of the user's location.",
        examples=[-73.9855],
    ),
    radius: int | None = Query(
        None,
        ge=100,
        le=10000,
        description="Maximum search radius from the request location (in meters). Defaults to the server-configured value (~800\u202fm).",
        examples=[800],
    ),
) -> list[BusStop]:
    """Return bus stops near a GPS coordinate.

    Returns an empty array if the upstream API is unavailable.
    """
    settings = get_settings()
    effective_radius = (
        radius if radius is not None else settings.app_settings.search_radius_meters
    )
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


@router.get(
    "/live/{stop_id:path}",
    response_model=list[BusArrival],
    summary="Get real-time bus arrivals",
    description=(
        "Returns real-time bus arrivals at a specific stop from the MTA SIRI feed. "
        "Includes vehicle distance, bearing, and `is_realtime` flag (false when position is "
        "estimated from schedule). Falls back to scheduled departures if no live data is available."
    ),
    responses={**RESP_502},
)
async def bus_live(
    stop_id: str = Path(
        ...,
        description="MTA stop ID (OBA format).",
        examples=["MTA_308214", "MTA_400062"],
    ),
    response: Response = None,
) -> list[BusArrival]:
    """Return real-time bus arrivals at a stop.

    **Path parameter:** MTA stop ID — e.g. `MTA_308214`.

    Each arrival includes `route_id`, `vehicle_id`, `stop_name`, `status_text`,
    `expected_arrival`, `distance_meters`, `bearing`, and `is_realtime`.

    When `is_realtime` is `false`, the position is interpolated from the
    static schedule (the vehicle is not actively transmitting GPS).

    Falls back to scheduled departures if no live data is available.
    """

    def _schedule_fallback() -> list[BusArrival]:
        scheduled = schedule_service.get_scheduled_arrivals(stop_id, limit=5)
        return [
            BusArrival(
                route_id=s.route_id,
                vehicle_id="",
                stop_id=s.station,
                status_text=f"{s.destination} ({s.status})",
                status="Scheduled",
                expected_arrival=(
                    datetime.fromtimestamp(s.arrival_ts) if s.arrival_ts else None
                ),
                distance_meters=None,
                bearing=None,
            )
            for s in scheduled
        ]

    try:
        live_arrivals = await get_realtime_arrivals(stop_id)

        # Filter out stale arrivals (older than 1 minute ago)
        now_utc = datetime.now(UTC)
        live_arrivals = [
            a
            for a in live_arrivals
            if not a.expected_arrival
            or (
                a.expected_arrival.replace(tzinfo=UTC)
                if a.expected_arrival.tzinfo is None
                else a.expected_arrival
            )
            > now_utc - timedelta(seconds=60)
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


@router.get(
    "/vehicles/{route_id:path}",
    response_model=list[BusVehicle],
    summary="Get live bus positions",
    description=(
        "Returns live GPS positions for all vehicles currently running on a bus route. "
        "Each vehicle includes bearing, next stop, onward predictions, and an `is_realtime` flag. "
        "Cached for 5\u202fs with stale-while-revalidate."
    ),
    responses={**RESP_502},
)
async def bus_vehicles(
    route_id: str = Path(
        ...,
        description="Fully-qualified OBA route ID.",
        examples=["MTA NYCT_B63", "MTA NYCT_M34-SBS"],
    ),
    response: Response = None,
) -> list[BusVehicle]:
    """Return live vehicle positions for a bus route.

    **Path parameter:** MTA bus route ID — e.g. `MTA NYCT_B63`.

    Each vehicle includes `lat`, `lon`, `bearing`, `next_stop`, `status_text`,
    `direction_ref`, and `is_realtime`. When `is_realtime` is `false`, the
    position is interpolated from the static schedule.

    Cached for 5 s with stale-while-revalidate.
    """
    response.headers["Cache-Control"] = (
        "public, max-age=5, stale-while-revalidate=30, stale-if-error=120"
    )
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


@router.get(
    "/route-shape/{route_id:path}",
    response_model=RouteShape,
    summary="Get bus route shape",
    description=(
        "Returns encoded polylines and stops for drawing a bus route on a map. "
        "Includes per-direction shapes split by GTFS `direction_id` and a `service_type` "
        "indicator (`express`, `local`, or `mixed`)."
    ),
    responses={**RESP_404, **RESP_502},
)
async def bus_route_shape(
    route_id: str = Path(
        ...,
        description="Fully-qualified OBA route ID.",
        examples=["MTA NYCT_B63", "MTA NYCT_M34-SBS"],
    ),
    response: Response = None,
) -> RouteShape:
    """Return the route shape (polylines + stops) for a bus route.

    **Path parameter:** MTA bus route ID — e.g. `MTA NYCT_B63`.

    Response includes:
    - `polylines` — Google-encoded polylines for the combined route geometry
    - `stops` — all stops along the route
    - `directions` — per-direction shapes split by GTFS `direction_id`

    Cached for 1 hour with stale-while-revalidate.
    """
    response.headers["Cache-Control"] = (
        "public, max-age=3600, stale-while-revalidate=86400, stale-if-error=604800"
    )
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
            return await _fallback_route_shape(route_id)
        _raise_bus_upstream_http_error(exc)
    except Exception as exc:
        TrackLogger.warning(
            f"[BUS] /route-shape/{route_id}: upstream error ({exc}) — returning empty shape fallback",
            tag="BUS",
            exc_info=True,
        )
        response.headers["X-Track-Degraded"] = "shape-fallback"
        return await _fallback_route_shape(route_id)
