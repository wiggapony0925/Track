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

import httpx

from app.config import get_settings
from app.models import BusArrival, BusRoute, BusStop, BusVehicle, RouteShape


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
        return response.json()


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

    path = eps.stops_for_route.replace("{route_id}", route_id)
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
        return RouteShape(route_id=route_id, polylines=[], stops=[])

    path = eps.stops_for_route.replace("{route_id}", route_id)
    url = settings.urls.bus_oba_base + path
    params = {
        "key": settings.api_keys.mta_bus_key,
        "includePolylines": "true",
        "version": "2",
    }

    data = await _fetch_bus_json(url, params)

    # Extract polylines
    polylines: list[str] = []
    entry = data.get("data", {}).get("entry", {}) if isinstance(data, dict) else {}
    for poly in entry.get("polylines", []):
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

    return RouteShape(route_id=route_id, polylines=polylines, stops=stops)
