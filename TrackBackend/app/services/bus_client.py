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

from datetime import datetime
from typing import Any
from urllib.parse import quote

import httpx

from app.config import get_settings
from app.models import BusArrival, BusRoute, BusStop, BusVehicle, DirectionShape, RouteShape



import re
import json
import os
from pathlib import Path

# ---------------------------------------------------------------------------
# Load Route Map (Canonical Source of Truth)
# ---------------------------------------------------------------------------
ROUTE_LOOKUP = {}
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

except Exception as e:
    # Log error or silently fail to empty dict (fallback logic will take over)
    print(f"Warning: Could not load early_2026_buses_tag.json: {e}")

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
                print(f"Auto-discovery failed for {agency}: {e}")
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
        print(f"✨ Self-Healed: Discovered new route {clean_id} -> {discovered_id}")
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


def _get_timeout() -> httpx.Timeout:
    """Build an httpx Timeout from settings."""
    settings = get_settings()
    return httpx.Timeout(
        settings.app_settings.http_timeout_seconds,
        connect=settings.app_settings.http_connect_timeout_seconds,
    )


async def _fetch_bus_json(url: str, params: dict[str, str]) -> Any:
    """Fetch JSON from an MTA Bus Time endpoint.

    Raises :class:`httpx.HTTPStatusError` on 4xx/5xx responses so callers
    can translate 401/403 into a clean 503 for the iOS client.
    """
    async with httpx.AsyncClient(timeout=_get_timeout()) as client:
        response = await client.get(url, params=params)
        response.raise_for_status()
        data = response.json()
        if data is None:
            return {}
        return data


# ---------------------------------------------------------------------------
# OBA (Static / Discovery) helpers
# ---------------------------------------------------------------------------


async def get_routes() -> list[BusRoute]:
    """Fetch all bus routes from the OBA ``routes-for-agency`` endpoint."""
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        return []

    url = settings.urls.bus_oba_base + eps.routes_for_agency
    params = {"key": settings.api_keys.mta_bus_key}

    data = await _fetch_bus_json(url, params)
    routes_data: list[dict[str, Any]] = (
        data.get("data", {}).get("list", [])
        if isinstance(data, dict)
        else []
    )

    results: list[BusRoute] = []
    for r in routes_data:
        results.append(
            BusRoute(
                id=r.get("id", ""),
                short_name=r.get("shortName", ""),
                long_name=r.get("longName", ""),
                color=r.get("color", "0039A6"),
                description=r.get("description", ""),
            )
        )
    return results


async def get_stops(route_id: str) -> list[BusStop]:
    """Fetch stops for a specific route from OBA ``stops-for-route``.

    *route_id* must be fully qualified (e.g. ``"MTA NYCT_B63"``).
    Polylines are disabled to keep the payload small.
    """
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        return []

    # If the ID has no prefix, try to resolve it first
    if "_" not in route_id:
        # Try the resolved ID first
        canonical_id = await resolve_bus_id(route_id)
    else:
        canonical_id = route_id # If it already has a prefix, use it directly

    try:
        return await _get_stops_impl(canonical_id)
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404:
            # If our primary guess failed, try a fallback (NYCT vs MTABC flip)
            fallback_id = await _guess_alternative_id(canonical_id)
            if fallback_id:
                return await _get_stops_impl(fallback_id)
        raise e
    
    # The original code had a fallback loop here, but the provided diff replaces it.
    # The diff also had a malformed line `raise e       if trial_id == resolved_id:`
    # I'm interpreting the intent to replace the entire original fallback logic
    # with the new canonical_id / fallback_id approach.
    # The `return await _get_stops_impl(route_id)` at the end of the original
    # `get_stops` function is also replaced by the new try/except block.


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


async def get_nearby_stops(
    lat: float, lon: float, radius_m: int | None = None,
) -> list[BusStop]:
    """Fetch bus stops near a GPS coordinate using OBA ``stops-for-location``.

    *radius_m* is the search radius in meters.  It is converted to a
    degree-based bounding box (``latSpan`` / ``lonSpan``) for the OBA
    API.  One degree of latitude ≈ 111 km; one degree of longitude ≈
    85 km at NYC's latitude.

    Includes retry logic because the MTA OBA API frequently returns 504.
    """
    import asyncio

    settings = get_settings()
    effective_radius = radius_m if radius_m is not None else settings.app_settings.search_radius_meters
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
                    )
                )
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
        "StopMonitoringDetailLevel": "minimum",
    }

    data = await _fetch_bus_json(url, params)

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

        # Route identifier - prefer LineRef, fallback to PublishedLineName
        raw_route = journey.get("LineRef")
        if not raw_route:
            names = journey.get("PublishedLineName", [])
            raw_route = names[0] if names else ""

        arrivals.append(
            BusArrival(
                route_id=raw_route or "",
                vehicle_id=journey.get("VehicleRef", ""),
                stop_id=stop_id,
                status_text=status_text or "En Route",
                expected_arrival=expected_arrival,
                distance_meters=distance_meters,
                bearing=bearing,
            )
        )

    return arrivals


# ---------------------------------------------------------------------------
# SIRI (Vehicle Monitoring) helpers
# ---------------------------------------------------------------------------


async def get_vehicle_positions(route_id: str) -> list[BusVehicle]:
    """Fetch live vehicle positions for a bus route via SIRI ``vehicle-monitoring``.

    Navigates ``Siri.ServiceDelivery.VehicleMonitoringDelivery[0]
    .VehicleActivity`` and extracts GPS position, bearing, and status.

    *route_id* must be fully qualified (e.g. ``"MTA NYCT_B63"``).
    """
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        return []

    # If the ID has no prefix, try to resolve it first
    if "_" not in route_id:
        # Try the resolved ID first
        canonical_id = await resolve_bus_id(route_id)
    else:
        canonical_id = route_id

    try:
        return await _get_vehicles_impl(canonical_id)
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404:
            fallback_id = await _guess_alternative_id(canonical_id)
            if fallback_id:
                return await _get_vehicles_impl(fallback_id)
        raise e
    
    # Similar to get_stops, the original fallback loop is replaced by the new logic.


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

    data = await _fetch_bus_json(url, params)

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

        vehicles.append(
            BusVehicle(
                vehicle_id=journey.get("VehicleRef", ""),
                route_id=journey.get("LineRef", route_id),
                lat=lat_f,
                lon=lon_f,
                bearing=bearing,
                next_stop=next_stop,
                status_text=status_text,
            )
        )

    return vehicles


async def get_route_shape(route_id: str) -> RouteShape:
    """Fetch the route shape (polylines + stops) from OBA ``stops-for-route``.

    Returns encoded polylines for drawing the route on a map, along with
    all stops on the route. *route_id* must be fully qualified.
    """
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        print(f"[BUS_SHAPE] No bus endpoints configured")
        return RouteShape(route_id=route_id, polylines=[], stops=[])

    # 1. Resolve to a canonical ID (e.g. "Q112" -> "MTABC_Q112")
    if "_" not in route_id:
        canonical_id = await resolve_bus_id(route_id)
    else:
        canonical_id = route_id
    
    try:
        return await _get_route_shape_impl(canonical_id)
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404:
            # Try the alternative agency
            fallback_id = await _guess_alternative_id(canonical_id)
            if fallback_id:
                return await _get_route_shape_impl(fallback_id)
        raise e


async def _get_route_shape_impl(route_id: str) -> RouteShape:
    """Internal implementation of get_route_shape."""
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        print(f"[BUS_SHAPE] No bus endpoints configured")
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

    print(f"[BUS_SHAPE] Fetching shape for {route_id} from {url}")
    data = await _fetch_bus_json(url, params)

    # Extract polylines
    polylines: list[str] = []
    entry = data.get("data", {}).get("entry", {}) if isinstance(data, dict) else {}
    raw_polylines = entry.get("polylines", [])
    print(f"[BUS_SHAPE] Got {len(raw_polylines)} raw polylines from API")
    
    for poly in raw_polylines:
        encoded = poly.get("points", "")
        if encoded:
            polylines.append(encoded)

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

    # Build per-direction shapes from OBA stopGroupings
    directions: list[DirectionShape] = []
    stop_groupings = entry.get("stopGroupings", [])
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
            dir_poly_ids = set(sg.get("polylines", []))
            dir_stop_ids = set(sg.get("stopIds", []))

            # Match polylines for this direction by index
            dir_polylines = [polylines[i] for i in range(len(polylines))
                             if i < len(raw_polylines) and raw_polylines[i].get("id", str(i)) in dir_poly_ids]
            # If no explicit polyline IDs matched, fall back to index-based split
            if not dir_polylines and polylines:
                mid = len(polylines) // 2
                dir_polylines = polylines[:mid] if dir_id == 0 else polylines[mid:]

            dir_stops = [s for s in stops if s.id in dir_stop_ids]

            directions.append(DirectionShape(
                direction_id=dir_id,
                headsign=headsign,
                polylines=dir_polylines,
                stops=dir_stops,
            ))

    # Fallback: if no stopGroupings, split polylines in half as a heuristic
    if not directions and len(polylines) >= 2:
        mid = len(polylines) // 2
        directions.append(DirectionShape(
            direction_id=0, headsign="", polylines=polylines[:mid], stops=[],
        ))
        directions.append(DirectionShape(
            direction_id=1, headsign="", polylines=polylines[mid:], stops=[],
        ))

    print(f"[BUS_SHAPE] Returning {len(polylines)} polylines, {len(stops)} stops, {len(directions)} directions for {route_id}")
    return RouteShape(route_id=route_id, polylines=polylines, stops=stops, directions=directions)
