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
import json
import math
import os
import re
import time as _time
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote

import httpx

from app.config import get_settings
from app.models import BusArrival, BusRoute, BusStop, BusVehicle, DirectionShape, RouteShape
from app.utils.geo_utils import haversine_m
from app.utils.logger import TrackLogger
from app.utils.polyline_utils import decode_polyline, encode_polyline

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
# Changed from original: require _SIRI_FAIL_THRESHOLD consecutive auth
# failures before opening the circuit, so a single transient 403 (rate-limit)
# doesn't block all bus routes for 5 minutes.
# ---------------------------------------------------------------------------

_siri_consecutive_auth_failures: int = 0
_SIRI_FAIL_THRESHOLD: int = 3   # open after 3 consecutive 401/403
_siri_circuit_open: bool = False
_siri_circuit_opened_at: float = 0.0
_SIRI_CIRCUIT_COOLDOWN = 300  # retry after 5 minutes


def _siri_circuit_is_open() -> bool:
    """Return True when calls should be short-circuited."""
    global _siri_circuit_open, _siri_circuit_opened_at
    if not _siri_circuit_open:
        return False
    # Auto-reset after cooldown so the app can self-heal
    if _time.time() - _siri_circuit_opened_at > _SIRI_CIRCUIT_COOLDOWN:
        _siri_circuit_open = False
        _siri_consecutive_auth_failures = 0
        TrackLogger.circuit("SIRI circuit breaker CLOSED (cooldown expired)")
        return False
    return True


def _record_siri_auth_failure() -> None:
    """Record a SIRI 401/403 failure; trip the breaker after threshold."""
    global _siri_consecutive_auth_failures, _siri_circuit_open, _siri_circuit_opened_at
    _siri_consecutive_auth_failures += 1
    if _siri_consecutive_auth_failures >= _SIRI_FAIL_THRESHOLD and not _siri_circuit_open:
        _siri_circuit_open = True
        _siri_circuit_opened_at = _time.time()
        TrackLogger.circuit(
            f"SIRI circuit breaker OPENED ({_siri_consecutive_auth_failures} consecutive 401/403)"
        )


def _reset_siri_auth_failures() -> None:
    """Reset the consecutive failure counter on a successful SIRI call."""
    global _siri_consecutive_auth_failures
    _siri_consecutive_auth_failures = 0


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
                response = await client.get(url, params=params)
                if response.status_code in (401, 403):
                    if is_siri:
                        _record_siri_auth_failure()
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
    """
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

_nearby_stops_cache: dict[tuple[float, float, int], tuple[float, list[BusStop]]] = {}
_NEARBY_CACHE_TTL = 60.0  # seconds


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
        if _time.monotonic() - ts < _NEARBY_CACHE_TTL:
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
            # Cache successful result
            _nearby_stops_cache[cache_key] = (_time.monotonic(), results)
            return results
        except (httpx.HTTPStatusError, httpx.TimeoutException) as exc:
            last_error = exc
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
    """
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
            # Don't retry if the circuit breaker has opened
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

    max_retries = settings.app_settings.http_max_retries
    retry_delay = settings.app_settings.http_retry_delay_seconds
    last_error: Exception | None = None

    for attempt in range(max_retries + 1):
        try:
            return await _get_route_shape_impl(canonical_id)
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                # Try the alternative agency (MTA NYCT <-> MTABC)
                fallback_id = await _guess_alternative_id(canonical_id)
                if fallback_id:
                    try:
                        return await _get_route_shape_impl(fallback_id)
                    except Exception:
                        pass
                # 404 is not retryable — route genuinely doesn't exist
                raise e
            # Transient errors (403 rate-limit, 503, etc.) — retry
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
    return RouteShape(route_id=route_id, polylines=[], stops=[])


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
