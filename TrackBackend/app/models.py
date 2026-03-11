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
    is_cancelled: bool = False  # GTFS-RT schedule_relationship == CANCELED


class TransitAlert(BaseModel):
    """A critical service alert."""

    route_id: str | None = None
    title: str
    description: str
    severity: str
    mode: str = "subway"
    updated_at: int | None = None  # epoch seconds – active_period start or transit_realtime timestamp
    affected_routes: list[str] = []  # all route_ids touched by this alert
    alert_type: str | None = None  # MercuryAlert.alert_type (e.g. "Delays", "Planned - Suspended")
    sort_order: int = 0  # MTA severity rank (higher = more severe, e.g. Delays=26, Suspended=39)
    display_before_active: int | None = None  # seconds before active_period to show (null = don't show in status box)
    active_period_end: int | None = None  # epoch seconds – when the alert expires


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
    aimed_arrival: datetime | None = None         # SIRI AimedArrivalTime (scheduled)
    schedule_deviation_s: int | None = None       # ExpectedArrival - AimedArrival in seconds (+ve = late)
    distance_meters: float | None = None
    bearing: float | None = None
    direction_ref: int | None = None  # SIRI DirectionRef: 0 or 1
    destination_name: str | None = None  # SIRI DestinationName: e.g. "JAMAICA via BREWER BL"
    # MTA SIRI spooking detection: False when position is estimated from static
    # schedule rather than live GPS (vehicle not actively transmitting telemetry).
    # iOS should show a “Scheduled” indicator instead of “Live” when False.
    is_realtime: bool = True


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
    is_real_time: bool = False  # True when backed by live GTFS-RT or SIRI data
    is_cancelled: bool = False  # True when GTFS-RT reports CANCELED


class DirectionArrivals(BaseModel):
    """Arrivals for a single direction of a route."""

    direction: str
    direction_label: str = ""  # e.g. "Northbound", "Eastbound", or raw destination
    arrivals: list[NearbyTransitArrival]


class InlineAlert(BaseModel):
    """Compact alert embedded in the grouped response (avoids a separate fetch)."""

    title: str
    severity: str  # "severe" or "warning"
    affected_routes: list[str] = []
    alert_type: str | None = None  # MercuryAlert.alert_type (e.g. "Delays")
    sort_order: int = 0  # MTA severity rank (higher = more severe)


class GroupedNearbyTransit(BaseModel):
    """Arrivals grouped by route with directions as sub-groups.

    The iOS app shows one card per route; tapping opens a detail sheet
    with swipeable direction tabs.
    """

    route_id: str
    display_name: str
    mode: str  # "subway", "bus", "lirr", or "mnr"
    color_hex: str | None = None
    directions: list[DirectionArrivals]
    sorting_key: str = ""  # MTA canonical sort order (e.g. subway letters: A before B)
    alerts: list[InlineAlert] = []  # Active service alerts for this route


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
    # MTA SIRI spooking detection: False when vehicle is not actively transmitting
    # GPS data and the position is interpolated from static schedule.
    # The SIRI Monitored field drives this.
    is_realtime: bool = True
    # When the GPS position was last recorded by the vehicle (RecordedAtTime).
    # Stale > 3 min may indicate a vehicle has lost signal.
    position_recorded_at: datetime | None = None


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


class StopPosition(BaseModel):
    """A stop snapped onto a specific route's offset line."""

    route_id: str
    lat: float
    lon: float


class ProcessedStation(BaseModel):
    """A station with positions snapped onto the offset polylines.

    ``is_transfer`` is True when the station spans ≥ 2 trunk groups.
    iOS draws a small circle for single-line stops and a white
    rounded-rect bar connecting dots for transfer stations.
    """

    station_id: str
    name: str
    is_transfer: bool
    positions: list[StopPosition]


class ProcessedStationsResponse(BaseModel):
    """Processed stations with offset-snapped positions."""

    stations: list[ProcessedStation]


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


class BusScheduleDeparture(BaseModel):
    """A single scheduled departure for a bus route."""

    stop_name: str
    stop_id: str
    departure_time: int            # epoch seconds
    headsign: str = ""
    trip_id: str = ""


class BusScheduleDirection(BaseModel):
    """Scheduled departures for one direction of a bus route."""

    route_id: str
    direction: str
    headsign: str = ""
    departures: list[BusScheduleDeparture]


class BusScheduleResponse(BaseModel):
    """Today's upcoming scheduled departures for a bus route."""

    route_id: str
    directions: list[BusScheduleDirection]

