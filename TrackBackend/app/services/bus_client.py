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
from app.models import BusArrival, BusRoute, BusStop

_TIMEOUT = httpx.Timeout(15.0, connect=10.0)


async def _fetch_bus_json(url: str, params: dict[str, str]) -> Any:
    """Fetch JSON from an MTA Bus Time endpoint.

    Raises :class:`httpx.HTTPStatusError` on 4xx/5xx responses so callers
    can translate 401/403 into a clean 503 for the iOS client.
    """
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
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


async def get_nearby_stops(lat: float, lon: float) -> list[BusStop]:
    """Fetch bus stops near a GPS coordinate using OBA ``stops-for-location``."""
    settings = get_settings()
    eps = settings.urls.bus_endpoints
    if eps is None:
        return []

    url = settings.urls.bus_oba_base + eps.stops_near_location
    params = {
        "key": settings.api_keys.mta_bus_key,
        "lat": str(lat),
        "lon": str(lon),
        "latSpan": "0.005",
        "lonSpan": "0.005",
    }

    data = await _fetch_bus_json(url, params)
    stops_data: list[dict[str, Any]] = (
        data.get("data", {}).get("list", [])
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

        arrivals.append(
            BusArrival(
                route_id=journey.get("LineRef", ""),
                vehicle_id=journey.get("VehicleRef", ""),
                stop_id=stop_id,
                status_text=status_text or "En Route",
                expected_arrival=expected_arrival,
                distance_meters=distance_meters,
                bearing=bearing,
            )
        )

    return arrivals
