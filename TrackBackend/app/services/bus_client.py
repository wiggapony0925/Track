#
# bus_client.py
# TrackBackend
#
# Dual-API client for MTA Bus data.
#   - OneBusAway (OBA) API: Static route/stop discovery
#   - SIRI API: Real-time vehicle locations and arrival predictions
#
# Important: Always use fully-qualified IDs (e.g. "MTA NYCT_B63").
# The MTA APIs require the full prefix for lookups.
#

from __future__ import annotations

import asyncio
import csv
from dataclasses import dataclass
import json
import math
import os
import re
import time as _time
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any, Callable
from urllib.parse import quote

import httpx

from app.cache_config import (
    BUS_ARRIVALS_FRESH_TTL, BUS_ARRIVALS_MAX_SIZE, BUS_ARRIVALS_STALE_TTL,
    BUS_NEARBY_STOPS_MAX_SIZE, BUS_NEARBY_STOPS_TTL,
    BUS_ROUTE_SHAPE_FRESH_TTL, BUS_ROUTE_SHAPE_MAX_SIZE, BUS_ROUTE_SHAPE_STALE_TTL,
    BUS_ROUTES_FRESH_TTL, BUS_ROUTES_MAX_SIZE, BUS_ROUTES_STALE_TTL,
    BUS_STOPS_FRESH_TTL, BUS_STOPS_MAX_SIZE, BUS_STOPS_STALE_TTL,
    BUS_UPSTREAM_CONCURRENCY, BUS_VEHICLES_FRESH_TTL, BUS_VEHICLES_MAX_SIZE,
    BUS_VEHICLES_STALE_TTL, OBA_AUTH_COOLDOWN, REDIS_KEY_PREFIX,
    SIRI_CIRCUIT_COOLDOWN, SIRI_FAIL_THRESHOLD,
)
from app.config import get_settings
from app.models import BusArrival, BusRoute, BusStop, BusVehicle, DirectionShape, RouteShape
from app.utils.geo_utils import haversine_m
from app.utils import cache_stats
from app.utils.logger import TrackLogger
from app.utils.polyline_utils import decode_polyline, encode_polyline

# Python 3.14 no longer creates an implicit main-thread event loop.
# Some legacy sync test paths still call asyncio.get_event_loop().run_until_complete(...).
try:
    asyncio.get_event_loop()
except RuntimeError:
    asyncio.set_event_loop(asyncio.new_event_loop())

from app.utils import redis_client as _redis

# ---------------------------------------------------------------------------
# Load Route Map (Canonical Source of Truth)
# ---------------------------------------------------------------------------
ROUTE_LOOKUP = {}
# All agency prefixes found in official route IDs (e.g. "MTA NYCT_", "MTABC_").
# Built dynamically from the JSON so new agencies are automatically supported.
BUS_AGENCY_PREFIXES: set[str] = set()
try:
    # Path relative to this file: ../data/early_2026_buses_tag.json
    base_dir = Path(__file__).parent.parent
    map_path = base_dir / "data" / "early_2026_buses_tag.json"
    if map_path.exists():
        with open(map_path, "r") as f:
            data = json.load(f)
            # Flatten the categorized structure into a single lookup dict
            # Data is { "Brooklyn": { "B1": "ID" }, ... }
            for category, routes in data.items():
                if isinstance(routes, dict):
                    for short_name, official_id in routes.items():
                        # Store exact match
                        ROUTE_LOOKUP[short_name] = official_id
                        # Store lowercase match
                        ROUTE_LOOKUP[short_name.lower()] = official_id
                        # Store no-space match (e.g. "Q 9" -> "Q9")
                        ROUTE_LOOKUP[short_name.replace(" ", "")] = official_id
                        ROUTE_LOOKUP[short_name.lower().replace(" ", "")] = official_id
                        # Collect agency prefix (everything up to and including "_")
                        if "_" in official_id:
                            prefix = official_id[: official_id.index("_") + 1]
                            BUS_AGENCY_PREFIXES.add(prefix)

    # Always include "MTA BUS_" — used by some SIRI/OBA edge cases
    # even if it doesn't appear in the JSON.
    BUS_AGENCY_PREFIXES.add("MTA BUS_")

except Exception as e:
    # Log error or silently fail to empty dict (fallback logic will take over)
    TrackLogger.warning(f"Could not load early_2026_buses_tag.json: {e}", tag="BUS")

# ---------------------------------------------------------------------------
# Agency Map for Bus Route Resolution (Fallback)
# ---------------------------------------------------------------------------
AGENCY_MAP = {
    "B": "MTA NYCT",  # Brooklyn
    "M": "MTA NYCT",  # Manhattan
    "Q": "MTABC",     # Queens (Default to MTABC, but fallback to NYCT handles exceptions)
    "Bx": "MTA NYCT", # Bronx
    "S": "MTA NYCT",  # Staten Island
    "X": "MTABC",     # Express buses are largely MTABC
}

async def _discover_and_cache_bus_id(short_name: str) -> str | None:
    """Attempt to discover a new route ID from the live MTA API and cache it.
    
    This handles cases like a brand new 'Q80' that isn't in our 2026 JSON yet.
    """
    settings = get_settings()
    api_key = settings.api_keys.mta_bus_key
    base_url = settings.urls.bus_oba_base + "/routes-for-agency"
    
    clean_name = short_name.strip().upper()
    
    # We check the most likely agencies
    agencies = ["MTABC", "MTA NYCT", "MTA BUS"]
    
    async with httpx.AsyncClient(timeout=5.0) as client:
        for agency in agencies:
            try:
                url = f"{base_url}/{agency}.json"
                params = {"key": api_key}
                resp = await client.get(url, params=params)
                
                if resp.status_code == 200:
                    data = resp.json()
                    if data.get("code") == 200:
                        routes = data.get("data", {}).get("list", [])
                        for r in routes:
                            sn = r.get("shortName", "").upper()
                            official_id = r.get("id")
                            
                            # If we find it, cache it in memory immediately
                            if sn == clean_name:
                                ROUTE_LOOKUP[short_name] = official_id
                                ROUTE_LOOKUP[short_name.lower()] = official_id
                                return official_id
            except Exception as e:
                TrackLogger.warning(f"Auto-discovery failed for {agency}: {e}", tag="BUS")
                continue
                
    return None

async def resolve_bus_id(route_id: str) -> str:
    """Resolve the correct agency prefix for a bus route ID.
    
    1. Direct Lookup: Check the canonical route map.
    2. Live Discovery: If not in map, ask the MTA API directly (Self-Healing).
    3. Heuristic Fallback: Use prefix logic if all else fails.
    """
    if "_" in route_id:
        return route_id
        
    # Standardize input for lookup
    clean_id = route_id.strip()
    
    # 1. Try Memory Cache / JSON Map
    if clean_id in ROUTE_LOOKUP:
        return ROUTE_LOOKUP[clean_id]
        
    clean_lower = clean_id.lower()
    if clean_lower in ROUTE_LOOKUP:
        return ROUTE_LOOKUP[clean_lower]

    # 2. Live Discovery (The "Self-Healing" Layer)
    # If it's a new route like 'Q80', we look it up live and update ROUTE_LOOKUP
    discovered_id = await _discover_and_cache_bus_id(clean_id)
    if discovered_id:
        TrackLogger.resolve(f"Self-healed: Discovered new route {clean_id} -> {discovered_id}")
        return discovered_id

    # 3. Fallback Heuristics (Guessing)
    base_id = clean_id
    for key, agency in AGENCY_MAP.items():
        if base_id.startswith(key):
            if agency == "MTABC" and base_id.startswith("Q"):
                m = re.match(r"^Q(\d+)(.*)$", base_id)
                if m:
                    num_str, suffix = m.groups()
                    if len(num_str) == 1:
                        return f"{agency}_Q0{num_str}{suffix}"
            return f"{agency}_{base_id}"
    
    return f"MTA NYCT_{base_id}"


async def _guess_alternative_id(canonical_id: str) -> str | None:
    """Swap agency prefix to try the other common operator.

    MTA has two bus operators: ``MTA NYCT`` and ``MTABC``.  Some routes
    (especially Queens) exist under one but not the other.  When a 404 is
    returned for the first guess, this helper builds the alternative ID.

    If the alternative also fails a live OBA lookup, returns ``None``.
    """
    if "_" not in canonical_id:
        return None

    agency, route_part = canonical_id.split("_", 1)

    if agency == "MTA NYCT":
        alt = f"MTABC_{route_part}"
    elif agency == "MTABC":
        alt = f"MTA NYCT_{route_part}"
    else:
        return None

    # Quick validation: hit the OBA API to confirm the alternative exists
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        return alt  # Can't validate, just return the guess

    encoded_id = quote(alt, safe="")
    path = eps.stops_for_route.replace("{route_id}", encoded_id)
    url = settings.urls.bus_oba_base + path
    params = {"key": settings.api_keys.mta_bus_key, "version": "2"}

    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(url, params=params)
            if resp.status_code == 200:
                # Cache the correct mapping so we don't guess again
                # Extract the short name from the route_part
                ROUTE_LOOKUP[route_part] = alt
                ROUTE_LOOKUP[route_part.lower()] = alt
                TrackLogger.resolve(f"Agency fallback: {canonical_id} -> {alt} (cached)")
                return alt
    except Exception:
        pass

    return None


def _get_timeout() -> httpx.Timeout:
    """Build an httpx Timeout from settings."""
    settings = get_settings()
    return httpx.Timeout(
        settings.app_settings.http_timeout_seconds,
        connect=settings.app_settings.http_connect_timeout_seconds,
    )


# ---------------------------------------------------------------------------
# Polyline merging — join adjacent small segments into continuous polylines
# ---------------------------------------------------------------------------


def _merge_polyline_segments(encoded_segments: list[str], gap_threshold_m: float = 50.0) -> list[str]:
    """Merge adjacent encoded polyline segments into fewer continuous polylines.

    Segments whose endpoints are within *gap_threshold_m* meters are joined.
    Returns a new list of encoded polyline strings (typically much shorter).
    """
    if len(encoded_segments) <= 1:
        return encoded_segments

    decoded: list[list[tuple[float, float]]] = []
    for seg in encoded_segments:
        pts = decode_polyline(seg)
        if pts:
            decoded.append(pts)

    if not decoded:
        return encoded_segments

    # Greedily merge: append each segment to the current chain if its start
    # is close to the current chain's end; otherwise start a new chain.
    chains: list[list[tuple[float, float]]] = [decoded[0]]
    for seg in decoded[1:]:
        last_pt = chains[-1][-1]
        first_pt = seg[0]
        dist = haversine_m(last_pt[0], last_pt[1], first_pt[0], first_pt[1])
        if dist <= gap_threshold_m:
            chains[-1].extend(seg[1:] if dist < 5.0 else seg)
        else:
            chains.append(seg)

    return [encode_polyline(chain) for chain in chains]


# ---------------------------------------------------------------------------
# SIRI circuit breaker – after *consecutive* 401/403 responses the API key is
# likely invalid.  Rather than flood the MTA server with requests that will
# all fail, we flip a flag and immediately raise on subsequent calls.
#
# Changed from original: require SIRI_FAIL_THRESHOLD consecutive auth
# failures before opening the circuit, so a single transient 403 (rate-limit)
# doesn't block all bus routes for 5 minutes.
# ---------------------------------------------------------------------------

_siri_consecutive_auth_failures: int = 0
_siri_circuit_open: bool = False
_siri_circuit_opened_at: float = 0.0

_oba_auth_blocked_until: float = 0.0

# Upstream concurrency guard — values sourced from cache_config.py
_upstream_semaphore = asyncio.Semaphore(BUS_UPSTREAM_CONCURRENCY)


@dataclass
class _TTLCacheEntry:
    ts: float
    value: Any


def _cache_get(
    cache: dict[str, _TTLCacheEntry],
    key: str,
    *,
    fresh_ttl: float,
    stale_ttl: float,
) -> tuple[Any | None, str | None]:
    entry = cache.get(key)
    if entry is None:
        return None, None
    age = _time.monotonic() - entry.ts
    if age <= fresh_ttl:
        return entry.value, "fresh"
    if age <= stale_ttl:
        return entry.value, "stale"
    cache.pop(key, None)
    return None, None


def _cache_set(
    cache: dict[str, _TTLCacheEntry],
    key: str,
    value: Any,
    *,
    max_size: int = 0,
    stale_ttl: float = 0,
) -> None:
    """Insert into cache with optional bounded eviction.

    When *max_size* > 0 and the cache exceeds that limit, expired entries
    are evicted first (using *stale_ttl*).  If still over, the oldest 25%
    are dropped.
    """
    cache[key] = _TTLCacheEntry(ts=_time.monotonic(), value=value)
    if max_size > 0 and len(cache) > max_size:
        _evict_cache(cache, max_size, stale_ttl)


def _evict_cache(
    cache: dict[str, _TTLCacheEntry], max_size: int, stale_ttl: float
) -> None:
    """Remove expired entries; if still over *max_size*, drop oldest 25%."""
    now = _time.monotonic()
    if stale_ttl > 0:
        expired = [k for k, e in cache.items() if now - e.ts > stale_ttl]
        for k in expired:
            del cache[k]
    if len(cache) > max_size:
        by_age = sorted(cache, key=lambda k: cache[k].ts)
        for k in by_age[: max(1, len(by_age) // 4)]:
            del cache[k]


# Route-shape cache: mostly-static data, long-lived (TTLs from cache_config)
_route_shape_cache: dict[str, _TTLCacheEntry] = {}
_route_shape_inflight: dict[str, asyncio.Task[RouteShape]] = {}

_BUS_STATIC_GTFS_ROOT = Path(__file__).resolve().parent.parent / "data" / "bus"
_static_route_shape_index: dict[str, RouteShape] | None = None


def _route_short_name(route_id: str) -> str:
    rid = (route_id or "").strip()
    if "_" in rid:
        rid = rid.split("_", 1)[1]
    return rid.strip()


def _load_static_bus_route_shape_index() -> dict[str, RouteShape]:
    global _static_route_shape_index
    if _static_route_shape_index is not None:
        return _static_route_shape_index

    index: dict[str, RouteShape] = {}
    if not _BUS_STATIC_GTFS_ROOT.exists():
        _static_route_shape_index = index
        return index

    for borough_dir in _BUS_STATIC_GTFS_ROOT.iterdir():
        if not borough_dir.is_dir():
            continue

        routes_path = borough_dir / "routes.txt"
        trips_path = borough_dir / "trips.txt"
        shapes_path = borough_dir / "shapes.txt"
        stops_path = borough_dir / "stops.txt"
        stop_times_path = borough_dir / "stop_times.txt"
        if not (routes_path.exists() and trips_path.exists() and shapes_path.exists() and stops_path.exists() and stop_times_path.exists()):
            continue

        route_id_to_short: dict[str, str] = {}
        with open(routes_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                route_id = (row.get("route_id") or "").strip()
                route_short = (row.get("route_short_name") or route_id).strip()
                if route_id and route_short:
                    route_id_to_short[route_id] = route_short

        trip_to_meta: dict[str, tuple[str, int, str]] = {}
        route_shape_ids_by_dir: dict[str, dict[int, set[str]]] = defaultdict(lambda: defaultdict(set))
        with open(trips_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                trip_id = (row.get("trip_id") or "").strip()
                route_id = (row.get("route_id") or "").strip()
                shape_id = (row.get("shape_id") or "").strip()
                dir_raw = (row.get("direction_id") or "0").strip()
                if not trip_id or not route_id:
                    continue
                short = route_id_to_short.get(route_id, route_id)
                try:
                    direction_id = int(dir_raw)
                except ValueError:
                    direction_id = 0
                trip_to_meta[trip_id] = (short, direction_id, shape_id)
                if shape_id:
                    route_shape_ids_by_dir[short][direction_id].add(shape_id)

        needed_shape_ids: set[str] = {
            sid
            for by_dir in route_shape_ids_by_dir.values()
            for shape_ids in by_dir.values()
            for sid in shape_ids
        }

        shape_points: dict[str, list[tuple[int, float, float]]] = defaultdict(list)
        with open(shapes_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                shape_id = (row.get("shape_id") or "").strip()
                if not shape_id or shape_id not in needed_shape_ids:
                    continue
                try:
                    seq = int(row.get("shape_pt_sequence") or 0)
                    lat = float(row.get("shape_pt_lat") or 0.0)
                    lon = float(row.get("shape_pt_lon") or 0.0)
                except (ValueError, TypeError):
                    continue
                shape_points[shape_id].append((seq, lat, lon))

        stop_meta: dict[str, tuple[str, float, float]] = {}
        with open(stops_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                stop_id = (row.get("stop_id") or "").strip()
                if not stop_id:
                    continue
                try:
                    lat = float(row.get("stop_lat") or 0.0)
                    lon = float(row.get("stop_lon") or 0.0)
                except (ValueError, TypeError):
                    continue
                name = (row.get("stop_name") or stop_id).strip()
                stop_meta[stop_id] = (name, lat, lon)

        route_stop_ids: dict[str, set[str]] = defaultdict(set)
        with open(stop_times_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                trip_id = (row.get("trip_id") or "").strip()
                stop_id = (row.get("stop_id") or "").strip()
                if not trip_id or not stop_id:
                    continue
                meta = trip_to_meta.get(trip_id)
                if not meta:
                    continue
                short, _dir_id, _shape_id = meta
                route_stop_ids[short].add(stop_id)

        for short, by_dir in route_shape_ids_by_dir.items():
            directions: list[DirectionShape] = []
            route_polylines: list[str] = []

            for direction_id in sorted(by_dir.keys()):
                dir_polylines: list[str] = []
                for shape_id in sorted(by_dir[direction_id]):
                    pts = shape_points.get(shape_id)
                    if not pts:
                        continue
                    ordered = sorted(pts, key=lambda x: x[0])
                    coords = [(lat, lon) for _, lat, lon in ordered]
                    if len(coords) < 2:
                        continue
                    encoded = encode_polyline(coords)
                    if encoded:
                        dir_polylines.append(encoded)

                if not dir_polylines:
                    continue

                dir_polylines = _merge_polyline_segments(dir_polylines)
                route_polylines.extend(dir_polylines)
                directions.append(
                    DirectionShape(
                        direction_id=direction_id,
                        headsign=f"Direction {direction_id}",
                        polylines=dir_polylines,
                        stops=[],
                    )
                )

            if not route_polylines:
                continue

            stops: list[BusStop] = []
            for stop_id in sorted(route_stop_ids.get(short, set())):
                meta = stop_meta.get(stop_id)
                if not meta:
                    continue
                name, lat, lon = meta
                stops.append(
                    BusStop(
                        id=stop_id,
                        name=name,
                        lat=lat,
                        lon=lon,
                        direction=None,
                    )
                )

            route_polylines = _merge_polyline_segments(route_polylines)
            fresh = RouteShape(
                route_id=short,
                polylines=route_polylines,
                stops=stops,
                directions=directions,
                service_type=None,
            )

            existing = index.get(short)
            if existing is None:
                index[short] = fresh
            else:
                merged_polylines = _merge_polyline_segments(existing.polylines + fresh.polylines)
                seen_stop_ids = {s.id for s in existing.stops}
                merged_stops = list(existing.stops)
                for stop in fresh.stops:
                    if stop.id not in seen_stop_ids:
                        merged_stops.append(stop)
                        seen_stop_ids.add(stop.id)
                merged_dirs = existing.directions + fresh.directions
                index[short] = RouteShape(
                    route_id=short,
                    polylines=merged_polylines,
                    stops=merged_stops,
                    directions=merged_dirs,
                    service_type=None,
                )

    TrackLogger.bus(f"Static bus route-shape index loaded: {len(index)} routes")
    _static_route_shape_index = index
    return index


def get_static_route_shape(route_id: str) -> RouteShape | None:
    """Best-effort static GTFS route shape fallback for degraded bus APIs."""
    short = _route_short_name(route_id)
    if not short:
        return None
    index = _load_static_bus_route_shape_index()
    shape = index.get(short)
    if shape is None:
        return None
    return RouteShape(
        route_id=short,
        polylines=list(shape.polylines),
        stops=list(shape.stops),
        directions=list(shape.directions),
        service_type=shape.service_type,
    )

# Arrivals cache: live SIRI stop-monitoring data (TTLs from cache_config)
_arrivals_cache: dict[str, _TTLCacheEntry] = {}
_arrivals_inflight: dict[str, asyncio.Task[list[BusArrival]]] = {}

# Vehicle cache: live GPS dots on map (TTLs from cache_config)
_vehicle_cache: dict[str, _TTLCacheEntry] = {}
_vehicle_inflight: dict[str, asyncio.Task[list[BusVehicle]]] = {}

# Stops cache: semi-static (TTLs from cache_config)
_stops_cache: dict[str, _TTLCacheEntry] = {}
_stops_inflight: dict[str, asyncio.Task[list[BusStop]]] = {}

# Routes cache: nearly static (TTLs from cache_config)
_routes_cache: dict[str, _TTLCacheEntry] = {}
_routes_inflight: dict[str, asyncio.Task[list[BusRoute]]] = {}

def clear_bus_cache() -> int:
    """Clear all bus in-memory caches. Returns total entries cleared."""
    count = (
        len(_arrivals_cache) + len(_vehicle_cache)
        + len(_stops_cache) + len(_routes_cache)
        + len(_route_shape_cache) + len(_nearby_stops_cache)
    )
    _arrivals_cache.clear()
    _arrivals_inflight.clear()
    _vehicle_cache.clear()
    _vehicle_inflight.clear()
    _stops_cache.clear()
    _stops_inflight.clear()
    _routes_cache.clear()
    _routes_inflight.clear()
    _route_shape_cache.clear()
    _route_shape_inflight.clear()
    _nearby_stops_cache.clear()
    return count


# ---------------------------------------------------------------------------
# Redis shared cache — thin wrappers that delegate to utils/redis_client.py.
# init/close are now handled by main.py via redis_client.init_redis().
# ---------------------------------------------------------------------------

async def init_shared_cache() -> None:
    """Initialise the shared Redis connection (delegates to utils.redis_client)."""
    await _redis.init_redis()


async def close_shared_cache() -> None:
    """Close the shared Redis connection (delegates to utils.redis_client)."""
    await _redis.close_redis()


async def _shared_cache_get(
    kind: str,
    identifier: str,
    *,
    fresh_ttl: float,
    stale_ttl: float,
    parser: Callable[[Any], Any],
) -> tuple[Any | None, str | None]:
    return await _redis.cache_get(
        REDIS_KEY_PREFIX, kind, identifier,
        fresh_ttl=fresh_ttl, stale_ttl=stale_ttl, parser=parser,
    )


async def _shared_cache_set(
    kind: str,
    identifier: str,
    *,
    stale_ttl: float,
    data: Any,
) -> None:
    await _redis.cache_set(
        REDIS_KEY_PREFIX, kind, identifier,
        stale_ttl=stale_ttl, data=data,
    )


def _normalize_mta_bus_url(url: str) -> str:
    """Force HTTPS for MTA Bus Time endpoints.

    MTA increasingly rejects plaintext HTTP requests with 403. Normalizing
    here keeps settings/backward-compat values working while preventing
    auth/rate-limit retry storms caused by doomed HTTP calls.
    """
    if url.startswith("http://bustime.mta.info"):
        return "https://" + url[len("http://"):]
    return url


def _is_oba_url(url: str) -> bool:
    return "bustime.mta.info/api/where" in url


def _siri_circuit_is_open() -> bool:
    """Return True when calls should be short-circuited."""
    global _siri_circuit_open, _siri_circuit_opened_at
    if not _siri_circuit_open:
        return False
    # Auto-reset after cooldown so the app can self-heal
    if _time.time() - _siri_circuit_opened_at > SIRI_CIRCUIT_COOLDOWN:
        _siri_circuit_open = False
        _siri_consecutive_auth_failures = 0
        TrackLogger.circuit("SIRI circuit breaker CLOSED (cooldown expired)")
        return False
    return True


def _record_siri_auth_failure() -> None:
    """Record a SIRI 401/403 failure; trip the breaker after threshold."""
    global _siri_consecutive_auth_failures, _siri_circuit_open, _siri_circuit_opened_at
    _siri_consecutive_auth_failures += 1
    if _siri_consecutive_auth_failures >= SIRI_FAIL_THRESHOLD and not _siri_circuit_open:
        _siri_circuit_open = True
        _siri_circuit_opened_at = _time.time()
        TrackLogger.circuit(
            f"SIRI circuit breaker OPENED ({_siri_consecutive_auth_failures} consecutive 401/403)"
        )


def _record_oba_auth_failure(url: str) -> None:
    """Open a short cooldown window for OBA after 401/403 responses."""
    global _oba_auth_blocked_until
    if not _is_oba_url(url):
        return
    now = _time.time()
    was_open = _oba_auth_blocked_until > now
    _oba_auth_blocked_until = now + OBA_AUTH_COOLDOWN
    if not was_open:
        TrackLogger.circuit(
            f"OBA auth cooldown OPENED ({OBA_AUTH_COOLDOWN}s after 401/403)"
        )


def _oba_auth_cooldown_open(url: str) -> bool:
    if not _is_oba_url(url):
        return False
    return _time.time() < _oba_auth_blocked_until


def _reset_siri_auth_failures() -> None:
    """Reset the consecutive failure counter on a successful SIRI call."""
    global _siri_consecutive_auth_failures
    _siri_consecutive_auth_failures = 0


def _trip_siri_circuit() -> None:
    """Testing helper: force-open the SIRI circuit breaker immediately."""
    global _siri_circuit_open, _siri_circuit_opened_at, _siri_consecutive_auth_failures
    _siri_circuit_open = True
    _siri_circuit_opened_at = _time.time()
    _siri_consecutive_auth_failures = SIRI_FAIL_THRESHOLD


async def _fetch_bus_json(
    url: str,
    params: dict[str, str],
    *,
    is_siri: bool = False,
) -> Any:
    """Fetch JSON from an MTA Bus Time endpoint.

    Raises :class:`httpx.HTTPStatusError` on 4xx/5xx responses so callers
    can translate 401/403 into a clean 503 for the iOS client.

    The **circuit breaker** only applies to SIRI (real-time) requests
    (``is_siri=True``).  OBA (static/discovery) calls use a different
    API and should never be blocked by a SIRI auth failure.

    **Retries** once on 5xx server errors with a short backoff, since the
    MTA SIRI endpoint occasionally returns transient 500s for specific stops.
    """
    url = _normalize_mta_bus_url(url)

    if not is_siri and _oba_auth_cooldown_open(url):
        raise httpx.HTTPStatusError(
            "OBA auth cooldown open – skipping request",
            request=httpx.Request("GET", url),
            response=httpx.Response(403),
        )

    if is_siri and _siri_circuit_is_open():
        raise httpx.HTTPStatusError(
            "SIRI circuit breaker open – skipping request",
            request=httpx.Request("GET", url),
            response=httpx.Response(403),
        )

    _MAX_RETRIES = 2  # 1 initial + 1 retry
    last_exc: Exception | None = None

    async with httpx.AsyncClient(timeout=_get_timeout()) as client:
        for attempt in range(_MAX_RETRIES):
            try:
                async with _upstream_semaphore:
                    response = await client.get(url, params=params)
                if response.status_code in (401, 403):
                    if is_siri:
                        _record_siri_auth_failure()
                    else:
                        _record_oba_auth_failure(url)
                    response.raise_for_status()
                if response.status_code >= 500 and attempt < _MAX_RETRIES - 1:
                    # Transient server error — wait briefly and retry
                    await asyncio.sleep(0.3)
                    continue
                response.raise_for_status()
                # Successful response — reset consecutive failure counter
                if is_siri:
                    _reset_siri_auth_failures()
                data = response.json()
                if data is None:
                    return {}
                return data
            except httpx.HTTPStatusError:
                raise
            except Exception as exc:
                last_exc = exc
                if attempt < _MAX_RETRIES - 1:
                    await asyncio.sleep(0.3)
                    continue
                raise

    # Should never reach here, but satisfy the type checker
    if last_exc:
        raise last_exc
    return {}


# ---------------------------------------------------------------------------
# OBA (Static / Discovery) helpers
# ---------------------------------------------------------------------------


async def get_routes() -> list[BusRoute]:
    """Fetch all bus routes from the OBA ``routes-for-agency`` endpoint.

    Queries every agency listed in ``settings.json`` (MTA NYCT *and* MTABC)
    and merges the results, de-duplicating by route id.

    Results are cached for 1 hour (fresh) / 24h (stale) — route lists
    barely ever change, so there's no reason to hit OBA every call.
    """
    cache_key = "all_agencies"

    cached, cache_state = _cache_get(
        _routes_cache,
        cache_key,
        fresh_ttl=BUS_ROUTES_FRESH_TTL,
        stale_ttl=BUS_ROUTES_STALE_TTL,
    )
    if cache_state == "fresh":
        return cached

    if cache_state == "stale":
        # Serve stale immediately, refresh in background
        if cache_key not in _routes_inflight:
            async def _refresh_routes() -> None:
                task = _routes_inflight.get(cache_key)
                try:
                    fresh = await _fetch_routes_uncached()
                    _cache_set(
                        _routes_cache, cache_key, fresh,
                        max_size=BUS_ROUTES_MAX_SIZE,
                        stale_ttl=BUS_ROUTES_STALE_TTL,
                    )
                except Exception as exc:
                    TrackLogger.warning(
                        f"[BUS_ROUTES] Background refresh failed: {exc}",
                        tag="BUS",
                    )
                finally:
                    if task is not None and _routes_inflight.get(cache_key) is task:
                        _routes_inflight.pop(cache_key, None)

            refresh_task = asyncio.create_task(_refresh_routes())
            _routes_inflight[cache_key] = refresh_task
        return cached

    # No cache — check inflight dedup
    inflight = _routes_inflight.get(cache_key)
    if inflight is not None:
        try:
            return await inflight
        except Exception:
            if cached is not None:
                return cached
            raise

    # Fresh upstream fetch
    task = asyncio.create_task(_fetch_routes_uncached())
    _routes_inflight[cache_key] = task
    try:
        fresh = await task
        _cache_set(
            _routes_cache, cache_key, fresh,
            max_size=BUS_ROUTES_MAX_SIZE,
            stale_ttl=BUS_ROUTES_STALE_TTL,
        )
        return fresh
    except Exception:
        if cached is not None:
            return cached
        raise
    finally:
        if _routes_inflight.get(cache_key) is task:
            _routes_inflight.pop(cache_key, None)


async def _fetch_routes_uncached() -> list[BusRoute]:
    """Uncached OBA routes-for-agency fetch."""
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        return []

    # Normalise to a list so the old single-string format still works
    agency_paths: list[str] = (
        eps.routes_for_agency
        if isinstance(eps.routes_for_agency, list)
        else [eps.routes_for_agency]
    )

    params = {"key": settings.api_keys.mta_bus_key}
    seen_ids: set[str] = set()
    results: list[BusRoute] = []

    for path in agency_paths:
        url = settings.urls.bus_oba_base + path
        try:
            data = await _fetch_bus_json(url, params)
        except Exception as exc:
            TrackLogger.warning(f"Failed to fetch routes from {path}: {exc}", tag="BUS")
            continue

        routes_data: list[dict[str, Any]] = (
            data.get("data", {}).get("list", [])
            if isinstance(data, dict)
            else []
        )

        for r in routes_data:
            rid = r.get("id", "")
            if rid in seen_ids:
                continue
            seen_ids.add(rid)
            results.append(
                BusRoute(
                    id=rid,
                    short_name=r.get("shortName", ""),
                    long_name=r.get("longName", ""),
                    color=r.get("color", "0039A6"),
                    description=r.get("description", ""),
                )
            )

    TrackLogger.bus(f"Fetched {len(results)} bus routes from {len(agency_paths)} agencies")
    return results


async def get_stops(route_id: str) -> list[BusStop]:
    """Fetch stops for a specific route from OBA ``stops-for-route``.

    Includes retry logic for transient MTA API failures and an
    agency-prefix fallback on 404.
    """
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        return []

    if "_" not in route_id:
        canonical_id = await resolve_bus_id(route_id)
    else:
        canonical_id = route_id

    def _parse_stops(payload: Any) -> list[BusStop]:
        if not isinstance(payload, list):
            return []
        return [BusStop.model_validate(item) for item in payload]

    cache_key = canonical_id
    cached, cache_state = _cache_get(
        _stops_cache,
        cache_key,
        fresh_ttl=BUS_STOPS_FRESH_TTL,
        stale_ttl=BUS_STOPS_STALE_TTL,
    )
    if cache_state == "fresh":
        return cached

    if cache_state is None:
        shared, shared_state = await _shared_cache_get(
            "stops",
            cache_key,
            fresh_ttl=BUS_STOPS_FRESH_TTL,
            stale_ttl=BUS_STOPS_STALE_TTL,
            parser=_parse_stops,
        )
        if shared_state in ("fresh", "stale") and shared is not None:
            _cache_set(_stops_cache, cache_key, shared, max_size=BUS_STOPS_MAX_SIZE, stale_ttl=BUS_STOPS_STALE_TTL)
            cached = shared
            cache_state = shared_state

    if cache_state == "stale":
        if cache_key not in _stops_inflight:
            async def _refresh_stops() -> None:
                task = _stops_inflight.get(cache_key)
                try:
                    fresh = await _fetch_stops_uncached(canonical_id)
                    _cache_set(_stops_cache, cache_key, fresh, max_size=BUS_STOPS_MAX_SIZE, stale_ttl=BUS_STOPS_STALE_TTL)
                    await _shared_cache_set(
                        "stops",
                        cache_key,
                        stale_ttl=BUS_STOPS_STALE_TTL,
                        data=[item.model_dump(mode="json") for item in fresh],
                    )
                except Exception as exc:
                    TrackLogger.warning(f"[BUS_STOPS] Background refresh failed for {cache_key}: {exc}", tag="BUS")
                finally:
                    if task is not None and _stops_inflight.get(cache_key) is task:
                        _stops_inflight.pop(cache_key, None)

            refresh_task = asyncio.create_task(_refresh_stops())
            _stops_inflight[cache_key] = refresh_task
        return cached

    inflight = _stops_inflight.get(cache_key)
    if inflight is not None:
        try:
            return await inflight
        except Exception:
            if cached is not None:
                return cached
            raise

    task = asyncio.create_task(_fetch_stops_uncached(canonical_id))
    _stops_inflight[cache_key] = task
    try:
        fresh = await task
        _cache_set(_stops_cache, cache_key, fresh, max_size=BUS_STOPS_MAX_SIZE, stale_ttl=BUS_STOPS_STALE_TTL)
        await _shared_cache_set(
            "stops",
            cache_key,
            stale_ttl=BUS_STOPS_STALE_TTL,
            data=[item.model_dump(mode="json") for item in fresh],
        )
        return fresh
    except Exception:
        if cached is not None:
            return cached
        raise
    finally:
        if _stops_inflight.get(cache_key) is task:
            _stops_inflight.pop(cache_key, None)


async def _fetch_stops_uncached(canonical_id: str) -> list[BusStop]:
    """Uncached stops fetch with retry/fallback behavior."""
    settings = get_settings()

    max_retries = settings.app_settings.http_max_retries
    retry_delay = settings.app_settings.http_retry_delay_seconds
    last_error: Exception | None = None

    for attempt in range(max_retries + 1):
        try:
            return await _get_stops_impl(canonical_id)
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                fallback_id = await _guess_alternative_id(canonical_id)
                if fallback_id:
                    try:
                        return await _get_stops_impl(fallback_id)
                    except Exception:
                        pass
                raise e
            if e.response.status_code in (401, 403):
                raise e
            last_error = e
            if attempt < max_retries:
                TrackLogger.retry(f"[BUS_STOPS] Retry {attempt + 1}/{max_retries} for {canonical_id} (HTTP {e.response.status_code})")
                await asyncio.sleep(retry_delay)
        except httpx.TimeoutException as e:
            last_error = e
            if attempt < max_retries:
                TrackLogger.retry(f"[BUS_STOPS] Retry {attempt + 1}/{max_retries} for {canonical_id} (timeout)")
                await asyncio.sleep(retry_delay)

    if last_error:
        raise last_error
    return []


async def _get_stops_impl(route_id: str) -> list[BusStop]:
    """Internal implementation of get_stops."""
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        return []

    # URL-encode the route_id for the path
    encoded_id = quote(route_id, safe="")
    path = eps.stops_for_route.replace("{route_id}", encoded_id)
    url = settings.urls.bus_oba_base + path
    params = {
        "key": settings.api_keys.mta_bus_key,
        "includePolylines": "false",
        "version": "2",
    }

    data = await _fetch_bus_json(url, params)

    # Stops are in data.references.stops
    stops_data: list[dict[str, Any]] = (
        data.get("data", {}).get("references", {}).get("stops", [])
        if isinstance(data, dict)
        else []
    )

    results: list[BusStop] = []
    for s in stops_data:
        results.append(
            BusStop(
                id=s.get("id", ""),
                name=s.get("name", ""),
                lat=s.get("lat", 0.0),
                lon=s.get("lon", 0.0),
                direction=s.get("direction"),
            )
        )
    return results


# Simple TTL cache for nearby stops to avoid hammering the MTA API
# Key: rounded (lat, lon, radius) tuple → (timestamp, result)
# TTLs from cache_config.py

_nearby_stops_cache: dict[tuple[float, float, int], tuple[float, list[BusStop]]] = {}


async def get_nearby_stops(
    lat: float, lon: float, radius_m: int | None = None,
) -> list[BusStop]:
    """Fetch bus stops near a GPS coordinate using OBA ``stops-for-location``.

    *radius_m* is the search radius in meters.  It is converted to a
    degree-based bounding box (``latSpan`` / ``lonSpan``) for the OBA
    API.  One degree of latitude ≈ 111 km; one degree of longitude ≈
    85 km at NYC's latitude.

    Includes retry logic and a 60-second TTL cache to avoid rate limiting.
    """
    settings = get_settings()
    effective_radius = radius_m if radius_m is not None else settings.app_settings.search_radius_meters

    # Round coords to ~111m grid to improve cache hits from small GPS drift
    cache_key = (round(lat, 3), round(lon, 3), effective_radius)
    cached = _nearby_stops_cache.get(cache_key)
    if cached is not None:
        ts, result = cached
        if _time.monotonic() - ts < BUS_NEARBY_STOPS_TTL:
            return result

    eps = settings.urls.bus_endpoints
    if eps is None:
        return []

    # Convert meters → degrees.
    _METERS_PER_DEG_LAT = 111_000
    _METERS_PER_DEG_LON_NYC = 85_000

    lat_span = max(0.005, effective_radius / _METERS_PER_DEG_LAT)
    lon_span = max(0.005, effective_radius / _METERS_PER_DEG_LON_NYC)

    url = settings.urls.bus_oba_base + eps.stops_near_location
    params = {
        "key": settings.api_keys.mta_bus_key,
        "lat": str(lat),
        "lon": str(lon),
        "latSpan": f"{lat_span:.6f}",
        "lonSpan": f"{lon_span:.6f}",
    }

    # Retry logic driven by settings
    max_retries = settings.app_settings.http_max_retries
    retry_delay = settings.app_settings.http_retry_delay_seconds
    last_error: Exception | None = None
    for attempt in range(max_retries + 1):
        try:
            data = await _fetch_bus_json(url, params)
            stops_data: list[dict[str, Any]] = (
                data.get("data", {}).get("stops", [])
                if isinstance(data, dict)
                else []
            )

            results: list[BusStop] = []
            for s in stops_data:
                results.append(
                    BusStop(
                        id=s.get("id", ""),
                        name=s.get("name", ""),
                        lat=s.get("lat", 0.0),
                        lon=s.get("lon", 0.0),
                        direction=s.get("direction"),
                        route_ids=s.get("routeIds", []),
                    )
                )
            # Cache successful result (with bounded eviction)
            _nearby_stops_cache[cache_key] = (_time.monotonic(), results)
            if len(_nearby_stops_cache) > BUS_NEARBY_STOPS_MAX_SIZE:
                # Evict oldest entries
                by_age = sorted(_nearby_stops_cache, key=lambda k: _nearby_stops_cache[k][0])
                for k in by_age[: max(1, len(by_age) // 4)]:
                    _nearby_stops_cache.pop(k, None)
            return results
        except (httpx.HTTPStatusError, httpx.TimeoutException) as exc:
            last_error = exc
            if isinstance(exc, httpx.HTTPStatusError) and exc.response.status_code in (401, 403):
                # Auth/quota failures are not transient — return immediately.
                raise exc
            if attempt < max_retries:
                await asyncio.sleep(retry_delay)  # Brief pause before retry

    # All retries exhausted — raise so caller can handle
    if last_error:
        raise last_error
    return []


# ---------------------------------------------------------------------------
# SIRI (Real-time) helpers
# ---------------------------------------------------------------------------


async def get_realtime_arrivals(stop_id: str) -> list[BusArrival]:
    """Fetch real-time bus arrivals for *stop_id* via SIRI ``stop-monitoring``.

    Navigates ``Siri.ServiceDelivery.StopMonitoringDelivery[0]
    .MonitoredStopVisit`` and maps each visit to a :class:`BusArrival`.

    If both ``ExpectedArrivalTime`` and ``PresentableDistance`` are missing
    the entry is filtered out.

    Results are cached for 15s (fresh) / 30s (stale) so concurrent and
    near-concurrent requests for the same stop reuse a single upstream
    call instead of each firing their own SIRI request.
    """
    cache_key = stop_id

    # --- Cache hierarchy: local → stale-serve-while-refresh → inflight dedup → upstream ---
    cached, cache_state = _cache_get(
        _arrivals_cache,
        cache_key,
        fresh_ttl=BUS_ARRIVALS_FRESH_TTL,
        stale_ttl=BUS_ARRIVALS_STALE_TTL,
    )
    if cache_state == "fresh":
        return cached

    if cache_state == "stale":
        # Serve stale data immediately; kick off a background refresh
        if cache_key not in _arrivals_inflight:
            async def _refresh_arrivals() -> None:
                task = _arrivals_inflight.get(cache_key)
                try:
                    fresh = await _fetch_realtime_arrivals_uncached(stop_id)
                    _cache_set(
                        _arrivals_cache, cache_key, fresh,
                        max_size=BUS_ARRIVALS_MAX_SIZE,
                        stale_ttl=BUS_ARRIVALS_STALE_TTL,
                    )
                except Exception as exc:
                    TrackLogger.warning(
                        f"[BUS_ARRIVALS] Background refresh failed for {cache_key}: {exc}",
                        tag="BUS",
                    )
                finally:
                    if task is not None and _arrivals_inflight.get(cache_key) is task:
                        _arrivals_inflight.pop(cache_key, None)

            refresh_task = asyncio.create_task(_refresh_arrivals())
            _arrivals_inflight[cache_key] = refresh_task
        return cached

    # No cache hit — check for inflight dedup
    inflight = _arrivals_inflight.get(cache_key)
    if inflight is not None:
        try:
            return await inflight
        except Exception:
            if cached is not None:
                return cached
            raise

    # Fresh upstream fetch
    task = asyncio.create_task(_fetch_realtime_arrivals_uncached(stop_id))
    _arrivals_inflight[cache_key] = task
    try:
        fresh = await task
        _cache_set(
            _arrivals_cache, cache_key, fresh,
            max_size=BUS_ARRIVALS_MAX_SIZE,
            stale_ttl=BUS_ARRIVALS_STALE_TTL,
        )
        return fresh
    except Exception:
        if cached is not None:
            return cached
        raise
    finally:
        if _arrivals_inflight.get(cache_key) is task:
            _arrivals_inflight.pop(cache_key, None)


async def _fetch_realtime_arrivals_uncached(stop_id: str) -> list[BusArrival]:
    """Uncached SIRI stop-monitoring fetch — the actual upstream call."""
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        return []

    url = settings.urls.bus_siri_base + eps.stop_monitoring
    params = {
        "key": settings.api_keys.mta_bus_key,
        "version": "2",
        "MonitoringRef": stop_id,
        # Use default ("normal") detail level — "minimum" omits DirectionRef
        # and LineRef which are needed for proper direction grouping.
    }

    data = await _fetch_bus_json(url, params, is_siri=True)

    # Navigate the SIRI envelope
    deliveries: list[dict[str, Any]] = (
        data.get("Siri", {})
        .get("ServiceDelivery", {})
        .get("StopMonitoringDelivery", [])
        if isinstance(data, dict)
        else []
    )
    if not deliveries:
        return []

    visits: list[dict[str, Any]] = deliveries[0].get("MonitoredStopVisit", [])

    arrivals: list[BusArrival] = []
    for visit in visits:
        journey = visit.get("MonitoredVehicleJourney", {})
        monitored_call = journey.get("MonitoredCall", {})

        # Extract status_text from PresentableDistance
        extensions = monitored_call.get("Extensions", {})
        distances = extensions.get("Distances", {})
        status_text: str = distances.get("PresentableDistance", "")

        # Extract expected arrival time
        expected_str: str | None = monitored_call.get("ExpectedArrivalTime")
        expected_arrival: datetime | None = None
        if expected_str:
            try:
                expected_arrival = datetime.fromisoformat(expected_str)
            except (ValueError, TypeError):
                expected_arrival = None

        # Filter out entries with no useful data
        if not status_text and expected_arrival is None:
            continue

        # Distance in meters from the stop
        distance_meters: float | None = None
        raw_dist = distances.get("DistanceFromCall")
        if raw_dist is not None:
            try:
                distance_meters = float(raw_dist)
            except (ValueError, TypeError):
                pass

        # Vehicle bearing
        bearing: float | None = None
        raw_bearing = journey.get("Bearing")
        if raw_bearing is not None:
            try:
                bearing = float(raw_bearing)
            except (ValueError, TypeError):
                pass

        # Route identifier - prefer PublishedLineName for a clean route name
        # (e.g. "Q43"), fallback to LineRef which has agency prefix (e.g. "MTA NYCT_Q43").
        # Using PublishedLineName avoids duplicate route cards when the same
        # route appears with different agency prefixes (MTA NYCT_ vs MTABC_).
        names = journey.get("PublishedLineName")
        if isinstance(names, list) and names:
            raw_route = names[0]
        elif isinstance(names, str) and names:
            raw_route = names
        else:
            raw_route = journey.get("LineRef", "")

        # Direction from SIRI — DirectionRef (0 or 1) and DestinationName
        direction_ref: int | None = None
        raw_dir = journey.get("DirectionRef")
        if raw_dir is not None:
            try:
                direction_ref = int(raw_dir)
            except (ValueError, TypeError):
                pass

        # DestinationName can be a string or a list
        raw_dest = journey.get("DestinationName")
        destination_name: str | None = None
        if isinstance(raw_dest, list):
            destination_name = raw_dest[0] if raw_dest else None
        elif isinstance(raw_dest, str):
            destination_name = raw_dest or None

        arrivals.append(
            BusArrival(
                route_id=raw_route or "",
                vehicle_id=journey.get("VehicleRef", ""),
                stop_id=stop_id,
                status_text=status_text or "En Route",
                expected_arrival=expected_arrival,
                distance_meters=distance_meters,
                bearing=bearing,
                direction_ref=direction_ref,
                destination_name=destination_name,
            )
        )

    return arrivals


# ---------------------------------------------------------------------------
# SIRI (Vehicle Monitoring) helpers
# ---------------------------------------------------------------------------


async def get_vehicle_positions(route_id: str) -> list[BusVehicle]:
    """Fetch live vehicle positions for a bus route via SIRI ``vehicle-monitoring``.

    Includes retry logic for transient MTA API failures and an
    agency-prefix fallback on 404.
    """
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        return []

    # If the ID has no prefix, try to resolve it first
    if "_" not in route_id:
        canonical_id = await resolve_bus_id(route_id)
    else:
        canonical_id = route_id

    def _parse_vehicles(payload: Any) -> list[BusVehicle]:
        if not isinstance(payload, list):
            return []
        return [BusVehicle.model_validate(item) for item in payload]

    cache_key = canonical_id
    cached, cache_state = _cache_get(
        _vehicle_cache,
        cache_key,
        fresh_ttl=BUS_VEHICLES_FRESH_TTL,
        stale_ttl=BUS_VEHICLES_STALE_TTL,
    )
    if cache_state == "fresh":
        return cached

    if cache_state is None:
        shared, shared_state = await _shared_cache_get(
            "vehicles",
            cache_key,
            fresh_ttl=BUS_VEHICLES_FRESH_TTL,
            stale_ttl=BUS_VEHICLES_STALE_TTL,
            parser=_parse_vehicles,
        )
        if shared_state in ("fresh", "stale") and shared is not None:
            _cache_set(_vehicle_cache, cache_key, shared, max_size=BUS_VEHICLES_MAX_SIZE, stale_ttl=BUS_VEHICLES_STALE_TTL)
            cached = shared
            cache_state = shared_state

    if cache_state == "stale":
        if cache_key not in _vehicle_inflight:
            async def _refresh_vehicles() -> None:
                task = _vehicle_inflight.get(cache_key)
                try:
                    fresh = await _fetch_vehicle_positions_uncached(canonical_id)
                    _cache_set(_vehicle_cache, cache_key, fresh, max_size=BUS_VEHICLES_MAX_SIZE, stale_ttl=BUS_VEHICLES_STALE_TTL)
                    await _shared_cache_set(
                        "vehicles",
                        cache_key,
                        stale_ttl=BUS_VEHICLES_STALE_TTL,
                        data=[item.model_dump(mode="json") for item in fresh],
                    )
                except Exception as exc:
                    TrackLogger.warning(f"[BUS_VEHICLES] Background refresh failed for {cache_key}: {exc}", tag="BUS")
                finally:
                    if task is not None and _vehicle_inflight.get(cache_key) is task:
                        _vehicle_inflight.pop(cache_key, None)

            refresh_task = asyncio.create_task(_refresh_vehicles())
            _vehicle_inflight[cache_key] = refresh_task
        return cached

    inflight = _vehicle_inflight.get(cache_key)
    if inflight is not None:
        try:
            return await inflight
        except Exception:
            if cached is not None:
                return cached
            raise

    task = asyncio.create_task(_fetch_vehicle_positions_uncached(canonical_id))
    _vehicle_inflight[cache_key] = task
    try:
        fresh = await task
        _cache_set(_vehicle_cache, cache_key, fresh, max_size=BUS_VEHICLES_MAX_SIZE, stale_ttl=BUS_VEHICLES_STALE_TTL)
        await _shared_cache_set(
            "vehicles",
            cache_key,
            stale_ttl=BUS_VEHICLES_STALE_TTL,
            data=[item.model_dump(mode="json") for item in fresh],
        )
        return fresh
    except Exception:
        if cached is not None:
            return cached
        raise
    finally:
        if _vehicle_inflight.get(cache_key) is task:
            _vehicle_inflight.pop(cache_key, None)


async def _fetch_vehicle_positions_uncached(canonical_id: str) -> list[BusVehicle]:
    """Uncached vehicle fetch with retry/fallback behavior."""
    settings = get_settings()

    max_retries = settings.app_settings.http_max_retries
    retry_delay = settings.app_settings.http_retry_delay_seconds
    last_error: Exception | None = None

    for attempt in range(max_retries + 1):
        try:
            return await _get_vehicles_impl(canonical_id)
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                fallback_id = await _guess_alternative_id(canonical_id)
                if fallback_id:
                    try:
                        return await _get_vehicles_impl(fallback_id)
                    except Exception:
                        pass
                raise e
            if e.response.status_code in (401, 403) and _siri_circuit_is_open():
                raise e
            last_error = e
            if attempt < max_retries:
                TrackLogger.retry(f"[BUS_VEHICLES] Retry {attempt + 1}/{max_retries} for {canonical_id} (HTTP {e.response.status_code})")
                await asyncio.sleep(retry_delay)
        except httpx.TimeoutException as e:
            last_error = e
            if attempt < max_retries:
                TrackLogger.retry(f"[BUS_VEHICLES] Retry {attempt + 1}/{max_retries} for {canonical_id} (timeout)")
                await asyncio.sleep(retry_delay)

    if last_error:
        raise last_error
    return []


async def _get_vehicles_impl(route_id: str) -> list[BusVehicle]:
    """Internal implementation of get_vehicle_positions."""
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        return []

    url = settings.urls.bus_siri_base + eps.vehicle_monitoring
    params = {
        "key": settings.api_keys.mta_bus_key,
        "version": "2",
        "LineRef": route_id,
        "VehicleMonitoringDetailLevel": "calls",
    }

    data = await _fetch_bus_json(url, params, is_siri=True)

    deliveries: list[dict[str, Any]] = (
        data.get("Siri", {})
        .get("ServiceDelivery", {})
        .get("VehicleMonitoringDelivery", [])
        if isinstance(data, dict)
        else []
    )
    if not deliveries:
        return []

    activities: list[dict[str, Any]] = deliveries[0].get("VehicleActivity", [])

    vehicles: list[BusVehicle] = []
    for activity in activities:
        journey = activity.get("MonitoredVehicleJourney", {})
        location = journey.get("VehicleLocation", {})

        lat = location.get("Latitude")
        lon = location.get("Longitude")
        if lat is None or lon is None:
            continue

        try:
            lat_f = float(lat)
            lon_f = float(lon)
        except (ValueError, TypeError):
            continue

        bearing: float | None = None
        raw_bearing = journey.get("Bearing")
        if raw_bearing is not None:
            try:
                bearing = float(raw_bearing)
            except (ValueError, TypeError):
                pass

        # Next stop name
        monitored_call = journey.get("MonitoredCall", {})
        next_stop = monitored_call.get("StopPointName")
        if isinstance(next_stop, list) and next_stop:
            next_stop = next_stop[0]

        # Status text from extensions
        extensions = monitored_call.get("Extensions", {})
        distances = extensions.get("Distances", {})
        status_text = distances.get("PresentableDistance")

        # Expected arrival time at next stop (same field used in stop-monitoring)
        expected_arrival: datetime | None = None
        expected_str = monitored_call.get("ExpectedArrivalTime")
        if expected_str:
            try:
                expected_arrival = datetime.fromisoformat(expected_str)
            except (ValueError, TypeError):
                expected_arrival = None

        # Direction reference (0 or 1) from SIRI
        direction_ref: int | None = None
        raw_dir = journey.get("DirectionRef")
        if raw_dir is not None:
            try:
                direction_ref = int(raw_dir)
            except (ValueError, TypeError):
                pass

        # Parse OnwardCalls (future stops) to populate the arrivals list client-side
        onward_calls: list[BusArrival] = []
        onward_data = journey.get("OnwardCalls", {}).get("OnwardCall", [])
        # If it's a single dict, wrap it in a list (SIRI XML-to-JSON quirk)
        if isinstance(onward_data, dict):
            onward_data = [onward_data]

        for call in onward_data:
            stop_ref = call.get("StopPointRef")
            if not stop_ref:
                continue

            # Extensions/Distances
            call_ext = call.get("Extensions", {})
            call_dist = call_ext.get("Distances", {})
            present_dist = call_dist.get("PresentableDistance", "")
            
            # Distance in meters
            dist_m: float | None = None
            raw_dm = call_dist.get("DistanceFromCall")
            if raw_dm is not None:
                try:
                    dist_m = float(raw_dm)
                except (ValueError, TypeError):
                    pass

            # Expected Arrival
            call_expected: datetime | None = None
            call_exp_str = call.get("ExpectedArrivalTime")
            if call_exp_str:
                try:
                    call_expected = datetime.fromisoformat(call_exp_str)
                except (ValueError, TypeError):
                    pass
            
            # Skip if no useful info
            if not present_dist and not call_expected:
                continue

            # StopPointName can be a string or a list (e.g. [{'@lang': 'en', '#text': '5 Av'}])
            stop_name_raw = call.get("StopPointName", "")
            stop_name = ""
            if isinstance(stop_name_raw, list) and len(stop_name_raw) > 0:
                # Sometimes it's just a list of strings ["5 Av"]
                if isinstance(stop_name_raw[0], str):
                    stop_name = stop_name_raw[0]
                # Sometimes it's a dict inside a list
                elif isinstance(stop_name_raw[0], dict):
                    stop_name = stop_name_raw[0].get("#text", "") or stop_name_raw[0].get("value", "")
            elif isinstance(stop_name_raw, str):
                stop_name = stop_name_raw

            onward_calls.append(BusArrival(
                route_id=journey.get("LineRef", route_id),
                vehicle_id=journey.get("VehicleRef", ""),
                stop_id=stop_ref,
                stop_name=stop_name,
                status_text=present_dist or "Scheduled",
                status="Live",
                expected_arrival=call_expected,
                distance_meters=dist_m,
                bearing=bearing, # Inherit bearing from vehicle
                direction_ref=direction_ref, # Inherit direction
                destination_name=None # Will be filled by frontend via route/stop lookup if needed
            ))

        vehicles.append(
            BusVehicle(
                vehicle_id=journey.get("VehicleRef", ""),
                route_id=journey.get("LineRef", route_id),
                lat=lat_f,
                lon=lon_f,
                bearing=bearing,
                next_stop=next_stop,
                status_text=status_text,
                direction_ref=direction_ref,
                expected_arrival=expected_arrival,
                onward_calls=onward_calls,
            )
        )

    return vehicles


async def get_route_shape(route_id: str) -> RouteShape:
    """Fetch the route shape (polylines + stops) from OBA ``stops-for-route``.

    Returns encoded polylines for drawing the route on a map, along with
    all stops on the route.  Includes retry logic for transient MTA API
    failures (403 / 503 / timeouts) and an agency-prefix fallback on 404.
    """
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        TrackLogger.warning("No bus endpoints configured", tag="BUS")
        return RouteShape(route_id=route_id, polylines=[], stops=[])

    # 1. Resolve to a canonical ID (e.g. "Q112" -> "MTABC_Q112")
    if "_" not in route_id:
        canonical_id = await resolve_bus_id(route_id)
    else:
        canonical_id = route_id

    def _parse_shape(payload: Any) -> RouteShape:
        if not isinstance(payload, dict):
            return RouteShape(route_id=canonical_id, polylines=[], stops=[])
        return RouteShape.model_validate(payload)

    cache_key = canonical_id
    cached, cache_state = _cache_get(
        _route_shape_cache,
        cache_key,
        fresh_ttl=BUS_ROUTE_SHAPE_FRESH_TTL,
        stale_ttl=BUS_ROUTE_SHAPE_STALE_TTL,
    )
    if cache_state == "fresh":
        return cached

    if cache_state is None:
        shared, shared_state = await _shared_cache_get(
            "route_shape",
            cache_key,
            fresh_ttl=BUS_ROUTE_SHAPE_FRESH_TTL,
            stale_ttl=BUS_ROUTE_SHAPE_STALE_TTL,
            parser=_parse_shape,
        )
        if shared_state in ("fresh", "stale") and shared is not None:
            _cache_set(_route_shape_cache, cache_key, shared, max_size=BUS_ROUTE_SHAPE_MAX_SIZE, stale_ttl=BUS_ROUTE_SHAPE_STALE_TTL)
            cached = shared
            cache_state = shared_state

    if cache_state == "stale":
        if cache_key not in _route_shape_inflight:
            async def _refresh_shape() -> None:
                task = _route_shape_inflight.get(cache_key)
                try:
                    fresh = await _fetch_route_shape_uncached(canonical_id)
                    _cache_set(_route_shape_cache, cache_key, fresh, max_size=BUS_ROUTE_SHAPE_MAX_SIZE, stale_ttl=BUS_ROUTE_SHAPE_STALE_TTL)
                    await _shared_cache_set(
                        "route_shape",
                        cache_key,
                        stale_ttl=BUS_ROUTE_SHAPE_STALE_TTL,
                        data=fresh.model_dump(mode="json"),
                    )
                except Exception as exc:
                    TrackLogger.warning(f"[BUS_SHAPE] Background refresh failed for {cache_key}: {exc}", tag="BUS")
                finally:
                    if task is not None and _route_shape_inflight.get(cache_key) is task:
                        _route_shape_inflight.pop(cache_key, None)

            refresh_task = asyncio.create_task(_refresh_shape())
            _route_shape_inflight[cache_key] = refresh_task
        return cached

    inflight = _route_shape_inflight.get(cache_key)
    if inflight is not None:
        try:
            return await inflight
        except Exception:
            if cached is not None:
                return cached
            raise

    task = asyncio.create_task(_fetch_route_shape_uncached(canonical_id))
    _route_shape_inflight[cache_key] = task
    try:
        fresh = await task
        _cache_set(_route_shape_cache, cache_key, fresh, max_size=BUS_ROUTE_SHAPE_MAX_SIZE, stale_ttl=BUS_ROUTE_SHAPE_STALE_TTL)
        await _shared_cache_set(
            "route_shape",
            cache_key,
            stale_ttl=BUS_ROUTE_SHAPE_STALE_TTL,
            data=fresh.model_dump(mode="json"),
        )
        return fresh
    except Exception:
        if cached is not None:
            return cached
        raise
    finally:
        if _route_shape_inflight.get(cache_key) is task:
            _route_shape_inflight.pop(cache_key, None)


async def _fetch_route_shape_uncached(canonical_id: str) -> RouteShape:
    """Uncached route-shape fetch with retry/fallback behavior."""
    settings = get_settings()

    max_retries = settings.app_settings.http_max_retries
    retry_delay = settings.app_settings.http_retry_delay_seconds
    last_error: Exception | None = None

    for attempt in range(max_retries + 1):
        try:
            return await _get_route_shape_impl(canonical_id)
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                fallback_id = await _guess_alternative_id(canonical_id)
                if fallback_id:
                    try:
                        return await _get_route_shape_impl(fallback_id)
                    except Exception:
                        pass
                raise e
            if e.response.status_code in (401, 403):
                raise e
            last_error = e
            if attempt < max_retries:
                TrackLogger.retry(f"[BUS_SHAPE] Retry {attempt + 1}/{max_retries} for {canonical_id} (HTTP {e.response.status_code})")
                await asyncio.sleep(retry_delay)
        except httpx.TimeoutException as e:
            last_error = e
            if attempt < max_retries:
                TrackLogger.retry(f"[BUS_SHAPE] Retry {attempt + 1}/{max_retries} for {canonical_id} (timeout)")
                await asyncio.sleep(retry_delay)

    if last_error:
        raise last_error
    return RouteShape(route_id=canonical_id, polylines=[], stops=[])


async def _get_route_shape_impl(route_id: str) -> RouteShape:
    """Internal implementation of get_route_shape."""
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        TrackLogger.warning("No bus endpoints configured", tag="BUS")
        return RouteShape(route_id=route_id, polylines=[], stops=[])

    # URL-encode the route_id for the path (e.g. "MTA NYCT_B63" → "MTA%20NYCT_B63")
    encoded_id = quote(route_id, safe="")
    path = eps.stops_for_route.replace("{route_id}", encoded_id)
    url = settings.urls.bus_oba_base + path
    params = {
        "key": settings.api_keys.mta_bus_key,
        "includePolylines": "true",
        "version": "2",
    }

    TrackLogger.debug(f"Fetching shape for {route_id} from {url}", tag="BUS")
    data = await _fetch_bus_json(url, params)

    # Extract polylines and build an id→encoded lookup so we can assign
    # per-direction polylines later using OBA's polylineIds references.
    polylines: list[str] = []
    polyline_by_id: dict[str, str] = {}
    entry = data.get("data", {}).get("entry", {}) if isinstance(data, dict) else {}
    raw_polylines = entry.get("polylines", [])
    TrackLogger.debug(f"Got {len(raw_polylines)} raw polylines from API", tag="BUS")
    
    for poly in raw_polylines:
        encoded = poly.get("points", "")
        if encoded:
            polylines.append(encoded)
            poly_id = poly.get("id", "")
            if poly_id:
                polyline_by_id[poly_id] = encoded

    # Extract stops from references
    stops_data: list[dict[str, Any]] = (
        data.get("data", {}).get("references", {}).get("stops", [])
        if isinstance(data, dict)
        else []
    )

    stops: list[BusStop] = []
    for s in stops_data:
        stops.append(
            BusStop(
                id=s.get("id", ""),
                name=s.get("name", ""),
                lat=s.get("lat", 0.0),
                lon=s.get("lon", 0.0),
                direction=s.get("direction"),
            )
        )

    # Build per-direction shapes from OBA stopGroupings.
    # OBA includes per-direction polylineIds that reference specific polyline
    # segments, allowing us to show only the relevant geometry when the user
    # selects a direction.  When polylineIds are available, each direction
    # gets only its own polylines.  Falls back to ALL entry polylines only
    # when the reference data is missing.
    directions: list[DirectionShape] = []
    stop_groupings = entry.get("stopGroupings", [])
    try:
        for grouping in stop_groupings:
            if grouping.get("type") != "direction":
                continue
            for sg in grouping.get("stopGroups", []):
                sg_id = sg.get("id", "0")
                try:
                    dir_id = int(sg_id)
                except ValueError:
                    dir_id = 0
                headsign = sg.get("name", {}).get("name", "") if isinstance(sg.get("name"), dict) else str(sg.get("name", ""))

                # Extract stop IDs for this direction
                dir_stop_ids: set[str] = set()
                for ref in sg.get("stopIds", []):
                    if isinstance(ref, dict):
                        dir_stop_ids.add(ref.get("id", ""))
                    elif isinstance(ref, str):
                        dir_stop_ids.add(ref)

                dir_stops = [s for s in stops if s.id in dir_stop_ids]

                # Use OBA's polylineIds to assign direction-specific polylines.
                # polylineIds references the "id" field of entry.polylines[].
                dir_polyline_ids = sg.get("polylineIds", [])
                if dir_polyline_ids and polyline_by_id:
                    dir_polylines = [
                        polyline_by_id[pid]
                        for pid in dir_polyline_ids
                        if pid in polyline_by_id
                    ]
                    # Fall back to all polylines if lookup yielded nothing
                    if not dir_polylines:
                        dir_polylines = list(polylines)
                else:
                    # No polylineIds available — fall back to all entry polylines
                    dir_polylines = list(polylines)

                directions.append(DirectionShape(
                    direction_id=dir_id,
                    headsign=headsign,
                    polylines=dir_polylines,
                    stops=dir_stops,
                ))
    except Exception as exc:
        TrackLogger.warning(f"Failed to parse stopGroupings for {route_id}: {exc}", tag="BUS")
        # Continue without direction data — polylines + stops are still valid

    # Fallback: if no stopGroupings, split polylines in half as a heuristic
    if not directions and len(polylines) >= 2:
        mid = len(polylines) // 2
        directions.append(DirectionShape(
            direction_id=0, headsign="", polylines=polylines[:mid], stops=[],
        ))
        directions.append(DirectionShape(
            direction_id=1, headsign="", polylines=polylines[mid:], stops=[],
        ))

    # Merge adjacent polyline segments to eliminate gaps between short segments.
    # OBA returns many tiny fragments; merging produces continuous lines.
    merged_polylines = _merge_polyline_segments(polylines)
    for d in directions:
        d.polylines = _merge_polyline_segments(d.polylines)

    TrackLogger.bus(f"Shape for {route_id}: {len(merged_polylines)} merged polylines (from {len(polylines)} raw), "
          f"{len(stops)} stops, {len(directions)} directions"
          + (f" ({', '.join(f'dir{d.direction_id}:{len(d.polylines)}pl' for d in directions)})" if directions else ""))
    return RouteShape(route_id=route_id, polylines=merged_polylines, stops=stops, directions=directions)
