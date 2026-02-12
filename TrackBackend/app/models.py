#
# models.py
# TrackBackend
#
# Pydantic schemas for the JSON responses returned to the iOS app.
#

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel


class TrackArrival(BaseModel):
    """A single upcoming train arrival at a station."""

    route_id: str = ""
    station: str
    direction: str
    minutes_away: int
    status: str = "On Time"


class TransitAlert(BaseModel):
    """A critical service alert."""

    route_id: str | None = None
    title: str
    description: str
    severity: str


class ElevatorStatus(BaseModel):
    """An elevator or escalator that is currently out of service."""

    station: str
    equipment_type: str
    description: str
    outage_since: str | None = None


class BusRoute(BaseModel):
    """A normalized bus route from the OBA API."""

    id: str
    short_name: str
    long_name: str
    color: str
    description: str


class BusStop(BaseModel):
    """A normalized bus stop from the OBA API."""

    id: str
    name: str
    lat: float
    lon: float
    direction: str | None = None


class BusArrival(BaseModel):
    """A normalized real-time bus arrival from the SIRI API."""

    route_id: str
    vehicle_id: str
    stop_id: str
    status_text: str
    expected_arrival: datetime | None = None
    distance_meters: float | None = None
    bearing: float | None = None


class NearbyTransitArrival(BaseModel):
    """A single upcoming transit arrival (bus or train) near the user."""

    route_id: str
    stop_name: str
    direction: str
    minutes_away: int
    status: str = "On Time"
    mode: str  # "subway" or "bus"
    stop_lat: float | None = None
    stop_lon: float | None = None


class DirectionArrivals(BaseModel):
    """Arrivals for a single direction of a route."""

    direction: str
    arrivals: list[NearbyTransitArrival]


class GroupedNearbyTransit(BaseModel):
    """Arrivals grouped by route with directions as sub-groups.

    The iOS app shows one card per route; tapping opens a detail sheet
    with swipeable direction tabs.
    """

    route_id: str
    display_name: str
    mode: str  # "subway" or "bus"
    color_hex: str | None = None
    directions: list[DirectionArrivals]


class BusVehicle(BaseModel):
    """A live bus vehicle position from the SIRI vehicle-monitoring API."""

    vehicle_id: str
    route_id: str
    lat: float
    lon: float
    bearing: float | None = None
    next_stop: str | None = None
    status_text: str | None = None


class RouteShape(BaseModel):
    """Encoded polyline and stop list for a bus route."""

    route_id: str
    polylines: list[str]
    stops: list[BusStop]
