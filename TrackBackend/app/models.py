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
    station_name: str = ""
    direction: str
    destination: str | None = None  # e.g. "Wakefield-241 St"
    minutes_away: int
    arrival_ts: int = 0
    status: str = "On Time"
    trip_id: str | None = None


class TransitAlert(BaseModel):
    """A critical service alert."""

    route_id: str | None = None
    title: str
    description: str
    severity: str
    mode: str = "subway"
    updated_at: int | None = None  # epoch seconds – active_period start or transit_realtime timestamp
    affected_routes: list[str] = []  # all route_ids touched by this alert


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
    route_ids: list[str] = []  # Fully-qualified route IDs served by this stop


class BusArrival(BaseModel):
    """A normalized real-time bus arrival from the SIRI API."""

    route_id: str
    vehicle_id: str
    stop_id: str
    stop_name: str | None = None
    status_text: str
    status: str = "Live"
    expected_arrival: datetime | None = None
    distance_meters: float | None = None
    bearing: float | None = None
    direction_ref: int | None = None  # SIRI DirectionRef: 0 or 1
    destination_name: str | None = None  # SIRI DestinationName: e.g. "JAMAICA via BREWER BL"


class NearbyTransitArrival(BaseModel):
    """A single upcoming transit arrival (bus or train) near the user."""

    route_id: str
    stop_name: str
    direction: str
    destination: str | None = None  # e.g. "Wakefield-241 St"
    minutes_away: int
    arrival_ts: int | None = None
    status: str = "On Time"
    mode: str  # "subway", "bus", "lirr", or "mnr"
    stop_lat: float | None = None
    stop_lon: float | None = None
    stop_id: str | None = None
    vehicle_id: str | None = None
    trip_id: str | None = None
    distance_m: float | None = None  # haversine distance from user to this stop (meters)


class DirectionArrivals(BaseModel):
    """Arrivals for a single direction of a route."""

    direction: str
    direction_label: str = ""  # e.g. "Northbound", "Eastbound", or raw destination
    arrivals: list[NearbyTransitArrival]


class GroupedNearbyTransit(BaseModel):
    """Arrivals grouped by route with directions as sub-groups.

    The iOS app shows one card per route; tapping opens a detail sheet
    with swipeable direction tabs.
    """

    route_id: str
    display_name: str
    mode: str  # "subway", "bus", or "lirr"
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
    direction_ref: int | None = None
    expected_arrival: datetime | None = None
    onward_calls: list[BusArrival] = []


class DirectionShape(BaseModel):
    """Polylines and stops for one direction of a route."""

    direction_id: int  # 0 or 1 (matches GTFS direction_id)
    headsign: str = ""  # e.g. "Manhattan", "Far Rockaway"
    polylines: list[str]
    stops: list[BusStop]
    service_type: str | None = None  # "express", "local", "mixed", or None


class RouteShape(BaseModel):
    """Encoded polyline and stop list for a route.

    ``polylines`` and ``stops`` hold the combined data (all directions merged)
    for backwards compatibility.  ``directions`` (when present) splits them
    by GTFS direction_id so the iOS app can show only the selected direction.
    """

    route_id: str
    polylines: list[str]
    stops: list[BusStop]
    directions: list[DirectionShape] = []
    service_type: str | None = None  # "express", "local", "mixed", or None


class SubwayLineOverlay(BaseModel):
    """Lightweight shape for drawing a single subway line on the map.

    Intentionally excludes stops to keep the all-lines payload small.
    """

    route_id: str
    color_hex: str
    polylines: list[str]


class AllSubwayLinesResponse(BaseModel):
    """All subway line overlays for drawing the full system map."""

    lines: list[SubwayLineOverlay]


class SubwayStation(BaseModel):
    """A subway station marker with list of lines served."""

    id: str
    name: str
    lat: float
    lon: float
    routes: list[str]


class AllSubwayStationsResponse(BaseModel):
    """All subway stations for the system map."""

    stations: list[SubwayStation]


class CommuterRailLineOverlay(BaseModel):
    """Lightweight shape for drawing a single commuter rail line on the map."""

    route_id: str
    name: str
    color_hex: str
    polylines: list[str]
    mode: str  # "lirr" or "mnr"


class AllCommuterRailLinesResponse(BaseModel):
    """All LIRR and MNR line overlays for the full system map."""

    lines: list[CommuterRailLineOverlay]

