"""Pydantic schemas for the JSON responses returned to the iOS app.

Core transit response models live in this package root. TrackEngine-specific
schemas are organized separately in ``app.models.track_engine``.
"""
# ruff: noqa: TC003

from __future__ import annotations

import datetime as dt
from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class TrackArrival(BaseModel):
    """A single upcoming train arrival at a station."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "A",
                    "station": "A27N",
                    "station_name": "Jay St-MetroTech",
                    "direction": "Northbound",
                    "destination": "Inwood-207 St",
                    "minutes_away": 3,
                    "arrival_ts": 1719500400,
                    "status": "On Time",
                    "trip_id": "AFA24GEN-A089-Sunday-00_000600_A..N65R",
                    "is_cancelled": False,
                    "stop_lat": 40.6923,
                    "stop_lon": -73.9872,
                }
            ]
        }
    )

    route_id: str = Field("", description="GTFS route ID (e.g. 'A', '7', 'L').")
    station: str = Field(..., description="GTFS stop ID.")
    station_name: str = Field("", description="Human-readable station name.")
    direction: str = Field(
        ..., description="Direction label (e.g. 'Northbound', 'Southbound')."
    )
    destination: str | None = Field(
        None, description="Terminal station name (e.g. 'Wakefield-241 St')."
    )
    minutes_away: int = Field(..., description="Minutes until arrival.")
    arrival_ts: int = Field(0, description="Arrival time as Unix epoch seconds.")
    status: str = Field(
        "On Time", description="Current status: 'On Time', 'Delayed', etc."
    )
    trip_id: str | None = Field(None, description="GTFS trip ID for this vehicle run.")
    is_cancelled: bool = Field(
        False, description="True when the trip is cancelled (GTFS-RT CANCELED)."
    )
    stop_lat: float | None = Field(None, description="Latitude of the stop.")
    stop_lon: float | None = Field(None, description="Longitude of the stop.")


class TransitAlert(BaseModel):
    """A critical MTA service alert (delays, suspensions, planned work)."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "A",
                    "title": "[A] Trains Delayed",
                    "description": "Northbound [A] trains are running with delays after a sick passenger at Fulton St.",
                    "severity": "severe",
                    "mode": "subway",
                    "updated_at": 1719500400,
                    "affected_routes": ["A", "C"],
                    "alert_type": "Delays",
                    "sort_order": 10,
                    "display_before_active": None,
                    "active_period_end": 1719504000,
                }
            ]
        }
    )

    route_id: str | None = Field(
        None, description="Primary affected route ID, if applicable."
    )
    title: str = Field(..., description="Alert headline.")
    description: str = Field(..., description="Full alert description text.")
    severity: str = Field(..., description="Severity level (e.g. 'severe', 'warning').")
    mode: str = Field("subway", description="Transit mode: subway, bus, lirr, or mnr.")
    updated_at: int | None = Field(
        None, description="When the alert was last updated (Unix epoch seconds)."
    )
    affected_routes: list[str] = Field(
        [], description="All route IDs affected by this alert."
    )
    alert_type: str | None = Field(
        None, description="MTA alert type (e.g. 'Delays', 'Planned - Suspended')."
    )
    sort_order: int = Field(0, description="MTA severity rank (higher = more severe).")
    display_before_active: int | None = Field(
        None, description="Seconds before active period to start showing the alert."
    )
    active_period_end: int | None = Field(
        None, description="When the alert expires (Unix epoch seconds)."
    )


class ElevatorStatus(BaseModel):
    """An elevator or escalator that is currently out of service."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "station": "34 St-Penn Station",
                    "equipment_type": "EL",
                    "description": "Downtown platform to mezzanine elevator is out of service.",
                    "outage_since": "2025-06-27T13:15:00-04:00",
                }
            ]
        }
    )

    station: str = Field(
        ..., description="Station name where the equipment is located."
    )
    equipment_type: str = Field(
        ..., description="Type of equipment: 'EL' (elevator) or 'ES' (escalator)."
    )
    description: str = Field(
        ..., description="Human-readable description of the outage."
    )
    outage_since: str | None = Field(
        None, description="When the outage began (ISO 8601 or descriptive text)."
    )


# ---------------------------------------------------------------------------
# Station Accessibility (ADA + full equipment inventory)
# ---------------------------------------------------------------------------


class EquipmentOutage(BaseModel):
    """Outage details for a specific piece of equipment."""

    since: str | None = Field(None, description="When the outage began.")
    estimated_return: str | None = Field(
        None, description="Estimated return to service date."
    )
    reason: str | None = Field(None, description="Reason for the outage.")


class EquipmentDetail(BaseModel):
    """A single elevator or escalator at a station with its current status."""

    equipment_id: str = Field(
        ..., description="MTA equipment identifier (e.g. 'EL293')."
    )
    equipment_type: str = Field(
        ..., description="'EL' (elevator) or 'ES' (escalator)."
    )
    short_description: str = Field(
        "", description="Short name for display (e.g. 'Street to platform')."
    )
    serving: str = Field(
        "", description="Full description of what the equipment serves."
    )
    is_ada: bool = Field(
        False, description="Whether this equipment is part of an ADA-accessible pathway."
    )
    is_active: bool = Field(
        True, description="Whether the equipment is currently in service."
    )
    lines: str = Field(
        "", description="Lines served by this equipment."
    )
    alternative_route: str = Field(
        "", description="Travel alternatives when this equipment is out of service."
    )
    outage: EquipmentOutage | None = Field(
        None, description="Outage details if equipment is out of service."
    )


class StationAccessibility(BaseModel):
    """Full accessibility profile for a station or station complex."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "station_name": "Times Sq-42 St",
                    "gtfs_stop_id": "127",
                    "ada_status": 1,
                    "ada_notes": "",
                    "ada_northbound": True,
                    "ada_southbound": True,
                    "equipment": [],
                    "outage_count": 0,
                    "total_elevators": 4,
                    "total_escalators": 2,
                    "next_accessible_north": "",
                    "next_accessible_south": "",
                }
            ]
        }
    )

    station_name: str = Field("", description="Station display name.")
    gtfs_stop_id: str = Field("", description="GTFS stop ID from the MTA stations dataset.")
    ada_status: int = Field(
        0,
        description="ADA accessibility: 0=not accessible, 1=fully accessible, 2=partially accessible.",
    )
    ada_notes: str = Field(
        "",
        description="Direction notes for partially accessible stations (e.g. 'Uptown only').",
    )
    ada_northbound: bool = Field(False, description="Whether the northbound direction is accessible.")
    ada_southbound: bool = Field(False, description="Whether the southbound direction is accessible.")
    equipment: list[EquipmentDetail] = Field(
        default_factory=list,
        description="All elevators and escalators at this station with current status.",
    )
    outage_count: int = Field(0, description="Number of equipment items currently out of service.")
    total_elevators: int = Field(0, description="Total elevators at this station.")
    total_escalators: int = Field(0, description="Total escalators at this station.")
    next_accessible_north: str = Field(
        "", description="Nearest ADA-accessible station in the northbound direction."
    )
    next_accessible_south: str = Field(
        "", description="Nearest ADA-accessible station in the southbound direction."
    )


class BusRoute(BaseModel):
    """A normalized bus route from the OBA API."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "id": "MTA NYCT_Q9",
                    "short_name": "Q9",
                    "long_name": "Jamaica - South Ozone Park",
                    "color": "6CBE45",
                    "description": "Limited-stop corridor between Jamaica Center and South Ozone Park.",
                }
            ]
        }
    )

    id: str = Field(
        ..., description="Fully-qualified OBA route ID (e.g. 'MTA NYCT_B63')."
    )
    short_name: str = Field(
        ..., description="Short route name displayed on the bus (e.g. 'B63')."
    )
    long_name: str = Field(
        ..., description="Full route name (e.g. 'Atlantic Av / 5 Av')."
    )
    color: str = Field(
        ..., description="Route brand colour as a hex string (e.g. '00AEEF')."
    )
    description: str = Field(
        ..., description="Route description or service area summary."
    )


class BusStop(BaseModel):
    """A normalized bus stop from the OBA API."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "id": "MTA_308214",
                    "name": "SUTPHIN BLVD/ARCHER AV",
                    "lat": 40.7004,
                    "lon": -73.8087,
                    "direction": "N",
                    "route_ids": ["MTA NYCT_Q9", "MTA NYCT_Q40", "MTA NYCT_Q44"],
                }
            ]
        }
    )

    id: str = Field(..., description="OBA stop ID (e.g. 'MTA_308214').")
    name: str = Field(..., description="Human-readable stop name.")
    lat: float = Field(..., description="Stop latitude (WGS 84).")
    lon: float = Field(..., description="Stop longitude (WGS 84).")
    direction: str | None = Field(
        None,
        description="Cardinal direction the bus travels at this stop (e.g. 'N', 'SW').",
    )
    route_ids: list[str] = Field(
        [], description="Fully-qualified route IDs served by this stop."
    )


class BusArrival(BaseModel):
    """A normalized real-time bus arrival from the SIRI API."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "MTA NYCT_B63",
                    "vehicle_id": "7560",
                    "stop_id": "MTA_308214",
                    "stop_name": "5 AV/9 ST",
                    "status_text": "COBBLE HILL via 5 AV — 4 min",
                    "status": "Live",
                    "expected_arrival": "2025-06-27T18:34:00Z",
                    "aimed_arrival": "2025-06-27T18:32:00Z",
                    "schedule_deviation_s": 120,
                    "distance_meters": 850.5,
                    "bearing": 215.0,
                    "direction_ref": 0,
                    "destination_name": "COBBLE HILL Baltic ST via 5 AV",
                    "is_realtime": True,
                }
            ]
        }
    )

    route_id: str = Field(
        ..., description="Fully-qualified bus route ID (e.g. 'MTA NYCT_B63')."
    )
    vehicle_id: str = Field(..., description="MTA vehicle ID.")
    stop_id: str = Field(..., description="Stop ID where this arrival is predicted.")
    stop_name: str | None = Field(None, description="Human-readable stop name.")
    status_text: str = Field(
        ..., description="Display text combining destination and ETA."
    )
    status: str = Field(
        "Live", description="Status indicator: 'Live', 'Scheduled', or 'Approaching'."
    )
    expected_arrival: dt.datetime | None = Field(
        None, description="Predicted arrival time (UTC ISO 8601)."
    )
    aimed_arrival: dt.datetime | None = Field(
        None, description="Scheduled arrival time from SIRI AimedArrivalTime."
    )
    schedule_deviation_s: int | None = Field(
        None, description="Delay in seconds (positive = late, negative = early)."
    )
    distance_meters: float | None = Field(
        None, description="Distance from the vehicle to this stop in meters."
    )
    bearing: float | None = Field(
        None, description="Vehicle heading in degrees (0-360)."
    )
    direction_ref: int | None = Field(
        None, description="SIRI direction reference: 0 or 1."
    )
    destination_name: str | None = Field(
        None, description="Trip destination (e.g. 'JAMAICA via BREWER BL')."
    )
    is_realtime: bool = Field(
        True,
        description="False when position is estimated from schedule, not live GPS.",
    )


class NearbyTransitArrival(BaseModel):
    """A single upcoming transit arrival (bus or train) near the user."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "7",
                    "stop_name": "Times Sq-42 St",
                    "direction": "Queensbound",
                    "destination": "Flushing-Main St",
                    "minutes_away": 2,
                    "arrival_ts": 1719500400,
                    "status": "On Time",
                    "mode": "subway",
                    "stop_lat": 40.7553,
                    "stop_lon": -73.987,
                    "stop_id": "726N",
                    "vehicle_id": None,
                    "trip_id": "080350_7..N",
                    "distance_m": 94.6,
                    "is_real_time": True,
                    "is_cancelled": False,
                    "is_express": False,
                    "color_hex": "#B933AD",
                    "bus_service_type": None,
                }
            ]
        }
    )

    route_id: str = Field(..., description="GTFS route ID (e.g. 'A', 'B63').")
    stop_name: str = Field(..., description="Human-readable stop name.")
    direction: str = Field(..., description="Direction label (e.g. 'Northbound').")
    destination: str | None = Field(
        None, description="Terminal station name (e.g. 'Wakefield-241 St')."
    )
    minutes_away: int = Field(..., description="Minutes until arrival.")
    arrival_ts: int | None = Field(
        None, description="Arrival time as Unix epoch seconds."
    )
    status: str = Field(
        "On Time", description="Current status: 'On Time', 'Delayed', etc."
    )
    mode: str = Field(
        ..., description="Transit mode: 'subway', 'bus', 'lirr', or 'mnr'."
    )
    stop_lat: float | None = Field(None, description="Stop latitude (WGS 84).")
    stop_lon: float | None = Field(None, description="Stop longitude (WGS 84).")
    stop_id: str | None = Field(None, description="GTFS stop ID.")
    vehicle_id: str | None = Field(None, description="Vehicle ID when available.")
    trip_id: str | None = Field(None, description="GTFS trip ID for this vehicle run.")
    distance_m: float | None = Field(
        None, description="Haversine distance from user to stop in meters."
    )
    is_real_time: bool = Field(
        False, description="True when backed by live GTFS-RT or SIRI data."
    )
    is_cancelled: bool = Field(False, description="True when GTFS-RT reports CANCELED.")
    is_express: bool = Field(
        False,
        description=(
            "True when this trip runs express/limited service — "
            "i.e. it skips stops that a local trip on the same corridor "
            "would serve.  Covers subway express routes (A, B, D, E, 2-5, "
            "N, Q, Z, 6X, 7X, FX), SBS/express/limited buses."
        ),
    )
    color_hex: str | None = Field(
        None,
        description="Resolved brand-correct route color for UI badges and chips.",
    )
    bus_service_type: str | None = Field(
        None,
        description=(
            "Resolved bus service type when mode='bus' (e.g. 'Local', "
            "'Limited', 'Select Bus Service', 'Express')."
        ),
    )

    def model_post_init(self, __context: Any) -> None:
        """Backfill brand metadata so every arrival carries the correct UI color."""
        if self.color_hex:
            return

        mode = (self.mode or "").strip().lower()
        route_id = (self.route_id or "").strip()
        if not mode or not route_id:
            return

        from app.utils.brand import bus_color as _brand_bus_color
        from app.utils.brand import mode_color as _brand_mode_color
        from app.utils.transit_utils import get_subway_color

        if mode == "bus":
            from app.routers.nearby import _classify_bus_service_type

            short_route_id = route_id
            for prefix in ("MTA NYCT_", "MTA BUS_", "MTABC_"):
                if short_route_id.upper().startswith(prefix):
                    short_route_id = short_route_id[len(prefix):]
                    break

            svc = self.bus_service_type or _classify_bus_service_type(short_route_id)
            self.bus_service_type = svc
            self.color_hex = _brand_bus_color(svc)
            return

        if mode in {"subway", "lirr", "mnr"}:
            self.color_hex = get_subway_color(route_id)
            return

        self.color_hex = _brand_mode_color(mode)


class DirectionArrivals(BaseModel):
    """Arrivals for a single direction of a route."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "direction": "0",
                    "direction_label": "Queensbound",
                    "arrivals": [
                        {
                            "route_id": "7",
                            "stop_name": "Times Sq-42 St",
                            "direction": "Queensbound",
                            "destination": "Flushing-Main St",
                            "minutes_away": 2,
                            "arrival_ts": 1719500400,
                            "status": "On Time",
                            "mode": "subway",
                            "stop_lat": 40.7553,
                            "stop_lon": -73.987,
                            "stop_id": "726N",
                            "vehicle_id": None,
                            "trip_id": "080350_7..N",
                            "distance_m": 94.6,
                            "is_real_time": True,
                            "is_cancelled": False,
                            "is_express": False,
                            "color_hex": "#B933AD",
                            "bus_service_type": None,
                        }
                    ],
                }
            ]
        }
    )

    direction: str = Field(..., description="Direction identifier (e.g. '0', '1').")
    direction_label: str = Field(
        "", description="Human-readable label (e.g. 'Northbound', 'Eastbound')."
    )
    arrivals: list[NearbyTransitArrival] = Field(
        ..., description="Upcoming arrivals in this direction."
    )


class InlineAlert(BaseModel):
    """Compact alert embedded in the grouped response (avoids a separate fetch)."""

    title: str = Field(..., description="Alert headline.")
    severity: str = Field(..., description="Severity level: 'severe' or 'warning'.")
    affected_routes: list[str] = Field(
        [], description="Route IDs affected by this alert."
    )
    alert_type: str | None = Field(
        None, description="MTA alert type (e.g. 'Delays', 'Planned - Suspended')."
    )
    sort_order: int = Field(0, description="MTA severity rank (higher = more severe).")


class GroupedNearbyTransit(BaseModel):
    """Arrivals grouped by route with direction sub-groups.

    Each group represents one transit route card on the home screen.
    """

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "A",
                    "display_name": "A",
                    "mode": "subway",
                    "color_hex": "#0039A6",
                    "directions": [
                        {
                            "direction": "0",
                            "direction_label": "Northbound",
                            "arrivals": [
                                {
                                    "route_id": "A",
                                    "stop_name": "Jay St-MetroTech",
                                    "direction": "Northbound",
                                    "destination": "Inwood-207 St",
                                    "minutes_away": 3,
                                    "arrival_ts": 1719500400,
                                    "status": "On Time",
                                    "mode": "subway",
                                    "stop_lat": 40.6923,
                                    "stop_lon": -73.9872,
                                    "stop_id": "A27N",
                                    "vehicle_id": None,
                                    "trip_id": "AFA24GEN-A089-Sunday-00_000600_A..N65R",
                                    "distance_m": 150.3,
                                    "is_real_time": True,
                                    "is_cancelled": False,
                                }
                            ],
                        }
                    ],
                    "sorting_key": "A",
                    "alerts": [],
                    "bus_service_type": None,
                },
                {
                    "route_id": "MTA NYCT_M34+",
                    "display_name": "M34-SBS",
                    "mode": "bus",
                    "color_hex": "#00B2E3",
                    "directions": [
                        {
                            "direction": "0",
                            "direction_label": "Eastbound",
                            "arrivals": [
                                {
                                    "route_id": "MTA NYCT_M34+",
                                    "stop_name": "W 34 St / 8 Av",
                                    "direction": "Eastbound",
                                    "destination": "Waterside",
                                    "minutes_away": 5,
                                    "arrival_ts": 1719500520,
                                    "status": "On Time",
                                    "mode": "bus",
                                    "stop_lat": 40.7527,
                                    "stop_lon": -73.9934,
                                    "stop_id": "MTA_400878",
                                    "vehicle_id": "MTA NYCT_7432",
                                    "trip_id": None,
                                    "distance_m": 82.1,
                                    "is_real_time": True,
                                    "is_cancelled": False,
                                }
                            ],
                        }
                    ],
                    "sorting_key": "M034",
                    "alerts": [],
                    "bus_service_type": "Select Bus Service",
                },
            ]
        }
    )

    route_id: str = Field(..., description="GTFS route ID (e.g. 'A', 'B63').")
    display_name: str = Field(..., description="Human-readable route name for display.")
    mode: str = Field(..., description="Transit mode: subway, bus, lirr, or mnr.")
    color_hex: str | None = Field(
        None, description="Route brand colour as hex (e.g. '#0039A6')."
    )
    text_color_hex: str | None = Field(
        None, description="Contrasting text color for legibility on color_hex background."
    )
    mode_name: str | None = Field(
        None, description="Human-readable mode label, e.g. 'Subway', 'Bus', 'LIRR', 'Metro-North'."
    )
    directions: list[DirectionArrivals] = Field(
        ..., description="Arrivals split by direction (e.g. Northbound / Southbound)."
    )
    sorting_key: str = Field(
        "", description="MTA canonical sort key for consistent ordering."
    )
    alerts: list[InlineAlert] = Field(
        [], description="Active service alerts for this route."
    )
    express_routes: list[str] = Field(
        [],
        description=(
            "Express subway variants merged into this group "
            "(e.g. ['7X']).  Empty for non-express routes."
        ),
    )
    bus_service_type: str | None = Field(
        None,
        description=(
            "Bus service classification: 'Local', 'Limited', "
            "'Local / Limited', 'Select Bus Service', 'Express', "
            "'School', or null for non-bus routes."
        ),
    )


class InactiveRoute(BaseModel):
    """A transit route that serves the area but has no active service right now.

    Lightweight model — no arrivals, just identification info.
    """

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "W",
                    "display_name": "W",
                    "mode": "subway",
                    "color_hex": "#FCCC0A",
                    "text_color_hex": "#000000",
                    "mode_name": "Subway",
                    "bus_service_type": None,
                    "sorting_key": "W",
                }
            ]
        }
    )

    route_id: str = Field(..., description="GTFS route ID.")
    display_name: str = Field(..., description="Human-readable route name.")
    mode: str = Field(..., description="Transit mode: subway, bus, lirr, mnr.")
    color_hex: str | None = Field(None, description="Route brand colour as hex.")
    text_color_hex: str | None = Field(None, description="Contrasting text color for legibility on color_hex background.")
    mode_name: str | None = Field(None, description="Human-readable mode label.")
    bus_service_type: str | None = Field(
        None,
        description="Bus service classification, or null for non-bus routes.",
    )
    sorting_key: str = Field("", description="MTA canonical sort key.")


class BusVehicle(BaseModel):
    """A live bus vehicle position from the SIRI vehicle-monitoring API."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "vehicle_id": "7560",
                    "route_id": "MTA NYCT_Q9",
                    "lat": 40.6891,
                    "lon": -73.7961,
                    "bearing": 42.0,
                    "next_stop": "MTA_550123",
                    "status_text": "Approaching LIBERTY AV/110 ST",
                    "direction_ref": 0,
                    "expected_arrival": "2025-06-27T18:36:00Z",
                    "onward_calls": [
                        {
                            "route_id": "MTA NYCT_Q9",
                            "vehicle_id": "7560",
                            "stop_id": "MTA_550123",
                            "stop_name": "LIBERTY AV/110 ST",
                            "status_text": "SOUTH OZONE PARK via LINCOLN ST — 2 min",
                            "status": "Live",
                            "expected_arrival": "2025-06-27T18:36:00Z",
                            "aimed_arrival": "2025-06-27T18:35:00Z",
                            "schedule_deviation_s": 60,
                            "distance_meters": 245.0,
                            "bearing": 42.0,
                            "direction_ref": 0,
                            "destination_name": "SOUTH OZONE PARK LINCOLN ST",
                            "is_realtime": True,
                        }
                    ],
                    "is_realtime": True,
                    "position_recorded_at": "2025-06-27T18:34:42Z",
                }
            ]
        }
    )

    vehicle_id: str = Field(..., description="MTA vehicle ID.")
    route_id: str = Field(..., description="Fully-qualified bus route ID.")
    lat: float = Field(..., description="Vehicle latitude (WGS 84).")
    lon: float = Field(..., description="Vehicle longitude (WGS 84).")
    bearing: float | None = Field(
        None, description="Vehicle heading in degrees (0-360)."
    )
    next_stop: str | None = Field(
        None, description="ID of the next stop the vehicle will serve."
    )
    status_text: str | None = Field(None, description="Human-readable status text.")
    direction_ref: int | None = Field(
        None, description="SIRI direction reference: 0 or 1."
    )
    expected_arrival: dt.datetime | None = Field(
        None, description="Expected arrival at the next stop (UTC ISO 8601)."
    )
    onward_calls: list[BusArrival] = Field(
        [], description="Downstream stop predictions for this vehicle."
    )
    is_realtime: bool = Field(
        True, description="False when position is interpolated from static schedule."
    )
    position_recorded_at: dt.datetime | None = Field(
        None,
        description="When the GPS position was last recorded (RecordedAtTime). Stale > 3 min may indicate signal loss.",
    )


class TransitVehicle(BaseModel):
    """A live subway or commuter rail vehicle position from GTFS-RT."""

    vehicle_id: str = Field(..., description="GTFS vehicle ID (or trip_id).")
    route_id: str = Field(..., description="GTFS route ID (e.g. 'A', 'LIRR').")
    trip_id: str | None = Field(None, description="GTFS trip ID.")
    lat: float = Field(..., description="Vehicle latitude (WGS 84).")
    lon: float = Field(..., description="Vehicle longitude (WGS 84).")
    bearing: float | None = Field(None, description="Vehicle heading in degrees.")
    speed_mph: float | None = Field(None, description="Current speed in mph.")
    current_stop_id: str | None = Field(None, description="ID of current or next stop.")
    current_stop_name: str | None = Field(None, description="Name of current or next stop.")
    status: str = Field(
        "IN_TRANSIT_TO",
        description="GTFS VehicleStopStatus: INCOMING_AT, STOPPED_AT, IN_TRANSIT_TO.",
    )
    mode: str = Field("subway", description="Transit mode (subway, lirr, mnr).")
    timestamp: int | None = Field(None, description="Unix timestamp of position report.")
    color_hex: str | None = Field(None, description="Brand color for the route.")


class DirectionShape(BaseModel):
    """Polylines and stops for one direction of a route."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "direction_id": 0,
                    "headsign": "Manhattan",
                    "polylines": ["owuwF~btbM?e@tDkJxAeE"],
                    "stops": [
                        {
                            "id": "MTA_308214",
                            "name": "5 AV/9 ST",
                            "lat": 40.6708,
                            "lon": -73.9896,
                            "direction": "N",
                            "route_ids": ["MTA NYCT_B63"],
                        }
                    ],
                    "service_type": "local",
                    "local_only_stop_ids": [],
                }
            ]
        }
    )

    direction_id: int = Field(..., description="GTFS direction_id: 0 or 1.")
    headsign: str = Field(
        "", description="Trip headsign (e.g. 'Manhattan', 'Far Rockaway')."
    )
    polylines: list[str] = Field(
        ..., description="Google-encoded polylines for this direction."
    )
    stops: list[BusStop] = Field(..., description="Ordered stops for this direction.")
    service_type: str | None = Field(
        None, description="Service pattern: 'express', 'local', 'mixed', or null."
    )
    local_only_stop_ids: list[str] = Field(
        [],
        description=(
            "Stop IDs that only appear in the local (longer) shapes for this "
            "direction.  Express trains skip these stops.  Empty when the route "
            "has no express/local split or only one shape per direction."
        ),
    )


class RouteShape(BaseModel):
    """Encoded polyline and stop list for a route.

    ``polylines`` and ``stops`` hold the combined data (all directions merged)
    for backwards compatibility.  ``directions`` (when present) splits them
    by GTFS direction_id so the iOS app can show only the selected direction.
    """

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "A",
                    "polylines": ["owuwF~btbM?e@tDkJxAeEfDkL"],
                    "stops": [
                        {
                            "id": "A27N",
                            "name": "Jay St-MetroTech",
                            "lat": 40.6922,
                            "lon": -73.9871,
                            "direction": None,
                            "route_ids": ["A", "C", "F"],
                        },
                        {
                            "id": "A28N",
                            "name": "Hoyt-Schermerhorn Sts",
                            "lat": 40.6885,
                            "lon": -73.9851,
                            "direction": None,
                            "route_ids": ["A", "C", "G"],
                        },
                    ],
                    "directions": [
                        {
                            "direction_id": 0,
                            "headsign": "Inwood-207 St",
                            "polylines": ["owuwF~btbM?e@tDkJxAeEfDkL"],
                            "stops": [
                                {
                                    "id": "A27N",
                                    "name": "Jay St-MetroTech",
                                    "lat": 40.6922,
                                    "lon": -73.9871,
                                    "direction": None,
                                    "route_ids": ["A", "C", "F"],
                                }
                            ],
                            "service_type": "express",
                            "local_only_stop_ids": [],
                        }
                    ],
                    "service_type": "express",
                }
            ]
        }
    )

    route_id: str = Field(..., description="GTFS route ID.")
    polylines: list[str] = Field(
        ..., description="Google-encoded polylines (all directions merged)."
    )
    stops: list[BusStop] = Field(
        ..., description="Ordered stop list (all directions merged)."
    )
    directions: list[DirectionShape] = Field(
        [], description="Per-direction shapes when available."
    )
    service_type: str | None = Field(
        None,
        description="Service pattern: 'express', 'local', 'mixed', or null.",
    )


class SubwayLineOverlay(BaseModel):
    """Lightweight shape for drawing a single subway line on the map.

    Intentionally excludes stops to keep the all-lines payload small.
    """

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "E",
                    "color_hex": "#0039A6",
                    "polylines": ["owuwF~btbM?e@tDkJxAeEfDkL"],
                }
            ]
        }
    )

    route_id: str = Field(..., description="Subway route ID (e.g. 'A', '7', 'L').")
    color_hex: str = Field(
        ..., description="Route brand colour as hex (e.g. '#0039A6')."
    )
    polylines: list[str] = Field(
        ..., description="Google-encoded polylines for this line."
    )


class TrunkGroupPolylines(BaseModel):
    """Pre-merged polylines for one MTA trunk colour group.

    Produced by the corridor pipeline's Phase 1 (merge) + Phase 3 (offset).
    These are the authoritative geometry for the system map — one set of
    continuous polylines per colour group (e.g. one blue trunk + branch stubs
    for A/C/E).  The iOS client renders these directly, avoiding the need to
    re-merge overlapping per-route GTFS polylines.
    """

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "trunk_index": 7,
                    "color_hex": "#0039A6",
                    "route_ids": ["A", "C", "E"],
                    "polylines": ["owuwF~btbM?e@tDkJxAeEfDkL"],
                    "lane_offset": 2.5,
                    "polyline_lane_offsets": [0.0, 2.5],
                }
            ]
        }
    )

    trunk_index: int = Field(
        ..., description="Trunk group index (0-10) matching TRUNK_GROUPS order."
    )
    color_hex: str = Field(
        ..., description="Trunk group colour as hex (e.g. '#0039A6')."
    )
    route_ids: list[str] = Field(
        ..., description="All route IDs in this trunk group (e.g. ['A', 'C', 'E'])."
    )
    polylines: list[str] = Field(
        ..., description="Google-encoded polylines (merged trunk + branches)."
    )
    lane_offset: float = Field(
        0.0,
        description="Signed perpendicular offset in meters for low-zoom pixel separation.",
    )
    polyline_lane_offsets: list[float] = Field(
        [], description="Per-polyline local lane offsets for zoom-dependent rendering."
    )


class CrossingPoint(BaseModel):
    """A point where two trunk groups cross at a significant angle.

    Used by the client to render casing breaks — small gaps in the
    lower trunk's casing layer that create an over/under visual effect.
    """

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "lat": 40.7518,
                    "lng": -73.9936,
                    "trunk_indices": [3, 7],
                }
            ]
        }
    )

    lat: float = Field(..., description="Crossing latitude (WGS 84).")
    lng: float = Field(..., description="Crossing longitude (WGS 84).")
    trunk_indices: list[int] = Field(
        ..., description="The two trunk group indices that cross here."
    )


class AllSubwayLinesResponse(BaseModel):
    """All subway line overlays for drawing the full system map."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "lines": [
                        {
                            "route_id": "E",
                            "color_hex": "#0039A6",
                            "polylines": ["owuwF~btbM?e@tDkJxAeEfDkL"],
                        },
                        {
                            "route_id": "7",
                            "color_hex": "#B933AD",
                            "polylines": ["s~mxFv`vbM{BmKyAcG_BgI"],
                        },
                    ],
                    "trunk_polylines": [
                        {
                            "trunk_index": 7,
                            "color_hex": "#0039A6",
                            "route_ids": ["A", "C", "E"],
                            "polylines": ["owuwF~btbM?e@tDkJxAeEfDkL"],
                            "lane_offset": 2.5,
                            "polyline_lane_offsets": [0.0, 2.5],
                        }
                    ],
                    "crossings": [
                        {
                            "lat": 40.7518,
                            "lng": -73.9936,
                            "trunk_indices": [3, 7],
                        }
                    ],
                }
            ]
        }
    )

    lines: list[SubwayLineOverlay] = Field(
        ..., description="Per-route subway line overlays."
    )
    trunk_polylines: list[TrunkGroupPolylines] = Field(
        [], description="Pre-merged trunk geometry for multi-line corridors."
    )
    crossings: list[CrossingPoint] = Field(
        [], description="Trunk crossing points for casing-break rendering."
    )


class SubwayStation(BaseModel):
    """A subway station marker with list of lines served."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "id": "R16",
                    "name": "Times Sq-42 St",
                    "lat": 40.7553,
                    "lon": -73.987,
                    "routes": ["1", "2", "3", "7", "N", "Q", "R", "W", "S"],
                }
            ]
        }
    )

    id: str = Field(..., description="GTFS stop ID.")
    name: str = Field(..., description="Human-readable station name.")
    lat: float = Field(..., description="Station latitude (WGS 84).")
    lon: float = Field(..., description="Station longitude (WGS 84).")
    routes: list[str] = Field(
        ..., description="Route IDs served at this station (e.g. ['A', 'C', 'E'])."
    )


class AllSubwayStationsResponse(BaseModel):
    """All subway stations for the system map."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "stations": [
                        {
                            "id": "R16",
                            "name": "Times Sq-42 St",
                            "lat": 40.7553,
                            "lon": -73.987,
                            "routes": ["1", "2", "3", "7", "N", "Q", "R", "W", "S"],
                        },
                        {
                            "id": "A27",
                            "name": "Jay St-MetroTech",
                            "lat": 40.6922,
                            "lon": -73.9871,
                            "routes": ["A", "C", "F", "R"],
                        },
                    ]
                }
            ]
        }
    )

    stations: list[SubwayStation] = Field(..., description="All subway stations.")


class StopPosition(BaseModel):
    """A stop snapped onto a specific route's offset line."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "7",
                    "lat": 40.7544,
                    "lon": -73.9837,
                }
            ]
        }
    )

    route_id: str = Field(..., description="Route ID this position is snapped to.")
    lat: float = Field(..., description="Snapped latitude (WGS 84).")
    lon: float = Field(..., description="Snapped longitude (WGS 84).")


class ProcessedStation(BaseModel):
    """A station with positions snapped onto the offset polylines.

    ``is_transfer`` is True when the station spans ≥ 2 trunk groups.
    iOS draws a small circle for single-line stops and a white
    rounded-rect bar connecting dots for transfer stations.
    """

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "station_id": "R16",
                    "name": "Times Sq-42 St",
                    "is_transfer": True,
                    "positions": [
                        {
                            "route_id": "7",
                            "lat": 40.7544,
                            "lon": -73.9837,
                        },
                        {
                            "route_id": "N",
                            "lat": 40.7547,
                            "lon": -73.9861,
                        },
                    ],
                }
            ]
        }
    )

    station_id: str = Field(..., description="GTFS stop ID.")
    name: str = Field(..., description="Human-readable station name.")
    is_transfer: bool = Field(
        ..., description="True when station spans 2+ trunk groups (transfer hub)."
    )
    positions: list[StopPosition] = Field(
        ..., description="Per-route snapped positions for circle placement."
    )


class ProcessedStationsResponse(BaseModel):
    """Processed stations with offset-snapped positions."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "stations": [
                        {
                            "station_id": "R16",
                            "name": "Times Sq-42 St",
                            "is_transfer": True,
                            "positions": [
                                {
                                    "route_id": "7",
                                    "lat": 40.7544,
                                    "lon": -73.9837,
                                },
                                {
                                    "route_id": "N",
                                    "lat": 40.7547,
                                    "lon": -73.9861,
                                },
                            ],
                        },
                        {
                            "station_id": "A65",
                            "name": "80 St",
                            "is_transfer": False,
                            "positions": [
                                {
                                    "route_id": "A",
                                    "lat": 40.6794,
                                    "lon": -73.8582,
                                }
                            ],
                        },
                    ]
                }
            ]
        }
    )

    stations: list[ProcessedStation] = Field(
        ..., description="All processed subway stations."
    )


class CommuterRailStop(BaseModel):
    """A single commuter rail stop (station) with coordinates."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "stop_id": "Babylon",
                    "name": "Babylon",
                    "lat": 40.7079,
                    "lon": -73.3225,
                }
            ]
        }
    )

    stop_id: str = Field(..., description="GTFS stop ID.")
    name: str = Field(..., description="Human-readable station name.")
    lat: float = Field(..., description="Station latitude (WGS 84).")
    lon: float = Field(..., description="Station longitude (WGS 84).")


class CommuterRailLineOverlay(BaseModel):
    """Lightweight shape for drawing a single commuter rail line on the map."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "LIRR_9",
                    "name": "Babylon",
                    "color_hex": "#00985F",
                    "polylines": ["gopwFnyubM}CyOa@uC_AiG"],
                    "mode": "lirr",
                    "stops": [
                        {
                            "stop_id": "Penn Station",
                            "name": "Penn Station",
                            "lat": 40.7506,
                            "lon": -73.9935,
                        },
                        {
                            "stop_id": "Babylon",
                            "name": "Babylon",
                            "lat": 40.7079,
                            "lon": -73.3225,
                        },
                    ],
                }
            ]
        }
    )

    route_id: str = Field(..., description="GTFS route ID (e.g. 'LIRR_9', 'MNR_1').")
    name: str = Field(..., description="Line/branch name (e.g. 'Babylon', 'Hudson').")
    color_hex: str = Field(
        ..., description="Line brand colour as hex (e.g. '#00985F')."
    )
    polylines: list[str] = Field(
        ..., description="Google-encoded polylines for this line."
    )
    mode: str = Field(..., description="Transit mode: 'lirr' or 'mnr'.")
    stops: list[CommuterRailStop] = Field(
        [], description="Ordered stations along this line."
    )


class AllCommuterRailLinesResponse(BaseModel):
    """All LIRR and MNR line overlays for the full system map."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "lines": [
                        {
                            "route_id": "LIRR_9",
                            "name": "Babylon",
                            "color_hex": "#00985F",
                            "polylines": ["gopwFnyubM}CyOa@uC_AiG"],
                            "mode": "lirr",
                            "stops": [
                                {
                                    "stop_id": "Penn Station",
                                    "name": "Penn Station",
                                    "lat": 40.7506,
                                    "lon": -73.9935,
                                },
                                {
                                    "stop_id": "Babylon",
                                    "name": "Babylon",
                                    "lat": 40.7079,
                                    "lon": -73.3225,
                                },
                            ],
                        },
                        {
                            "route_id": "MNR_1",
                            "name": "Hudson",
                            "color_hex": "#0039A6",
                            "polylines": ["_twwFbeubMfBvJz@xFf@rC"],
                            "mode": "mnr",
                            "stops": [
                                {
                                    "stop_id": "Grand Central",
                                    "name": "Grand Central",
                                    "lat": 40.7527,
                                    "lon": -73.9772,
                                },
                                {
                                    "stop_id": "Croton-Harmon",
                                    "name": "Croton-Harmon",
                                    "lat": 41.1904,
                                    "lon": -73.8829,
                                },
                            ],
                        },
                    ]
                }
            ]
        }
    )

    lines: list[CommuterRailLineOverlay] = Field(
        ..., description="All commuter rail line overlays."
    )


class BusScheduleDeparture(BaseModel):
    """A single scheduled departure for a bus route."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "stop_name": "SUTPHIN BLVD/ARCHER AV",
                    "stop_id": "MTA_550001",
                    "departure_time": 1751049600,
                    "headsign": "South Ozone Park Lincoln St",
                    "trip_id": "Q9_20250627_1820",
                }
            ]
        }
    )

    stop_name: str = Field(..., description="Human-readable stop name.")
    stop_id: str = Field(..., description="OBA stop ID.")
    departure_time: int = Field(
        ..., description="Scheduled departure as Unix epoch seconds."
    )
    headsign: str = Field("", description="Trip headsign (terminal destination).")
    trip_id: str = Field("", description="GTFS trip ID.")


class BusScheduleDirection(BaseModel):
    """Scheduled departures for one direction of a bus route."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "MTA NYCT_Q9",
                    "direction": "0",
                    "headsign": "South Ozone Park Lincoln St",
                    "departures": [
                        {
                            "stop_name": "SUTPHIN BLVD/ARCHER AV",
                            "stop_id": "MTA_550001",
                            "departure_time": 1751049600,
                            "headsign": "South Ozone Park Lincoln St",
                            "trip_id": "Q9_20250627_1820",
                        }
                    ],
                }
            ]
        }
    )

    route_id: str = Field(..., description="Fully-qualified bus route ID.")
    direction: str = Field(..., description="Direction identifier.")
    headsign: str = Field("", description="Trip headsign for this direction.")
    departures: list[BusScheduleDeparture] = Field(
        ..., description="Upcoming scheduled departures."
    )


class BusScheduleResponse(BaseModel):
    """Today's upcoming scheduled departures for a bus route."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "MTA NYCT_Q9",
                    "directions": [
                        {
                            "route_id": "MTA NYCT_Q9",
                            "direction": "0",
                            "headsign": "South Ozone Park Lincoln St",
                            "departures": [
                                {
                                    "stop_name": "SUTPHIN BLVD/ARCHER AV",
                                    "stop_id": "MTA_550001",
                                    "departure_time": 1751049600,
                                    "headsign": "South Ozone Park Lincoln St",
                                    "trip_id": "Q9_20250627_1820",
                                }
                            ],
                        }
                    ],
                }
            ]
        }
    )

    route_id: str = Field(..., description="Requested bus route ID.")
    directions: list[BusScheduleDirection] = Field(
        ..., description="Departures grouped by direction."
    )


# ── Shared error response schema ─────────────────────────────────────────
# Used by the `responses=` parameter on endpoint decorators to document
# error status codes in the OpenAPI spec (and thus in the Scalar docs).


class ErrorDetail(BaseModel):
    """Standard error body returned by the API."""

    detail: str = Field(
        ...,
        description="Human-readable error message.",
        examples=["Resource not found"],
    )


class WeatherResponse(BaseModel):
    """Current weather conditions from Open-Meteo."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "temperature_c": 28.5,
                    "temperature_f": 83.3,
                    "wmo_code": 2,
                    "symbol": "cloud.sun.fill",
                    "description": "Partly Cloudy",
                    "category": "clear",
                    "windspeed_kmh": 14.2,
                    "is_day": True,
                }
            ]
        }
    )

    temperature_c: float | None = Field(None, description="Temperature in Celsius.")
    temperature_f: float | None = Field(None, description="Temperature in Fahrenheit.")
    wmo_code: int | None = Field(None, description="WMO weather code (0-99).")
    symbol: str = Field(
        "", description="SF Symbol name for the condition (e.g. 'sun.max.fill')."
    )
    description: str = Field(
        "", description="Human-readable condition (e.g. 'Partly Cloudy')."
    )
    category: str = Field(
        "", description="WeatherCondition category (e.g. 'clear', 'rain')."
    )
    windspeed_kmh: float | None = Field(None, description="Wind speed in km/h.")
    is_day: bool = Field(
        True, description="True during daytime hours at the requested location."
    )


class ReloadModelResponse(BaseModel):
    """Result of the ML model hot-reload operation."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "success": True,
                    "message": "Delay model reloaded from /app/models/latest.joblib.",
                }
            ]
        }
    )

    success: bool = Field(
        ..., description="Whether the model was reloaded successfully."
    )
    message: str = Field(..., description="Human-readable status message.")


# ---------------------------------------------------------------------------
# Bus Tile Data (pre-baked system map)
# ---------------------------------------------------------------------------


class BusTileRoute(BaseModel):
    """Compact bus route representation for tile baking."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "route_id": "Q9",
                    "short_name": "Q9",
                    "color": "6CBE45",
                    "polylines": ["mpvwF`_wbM~AeGhCoN_BoH"],
                }
            ]
        }
    )

    route_id: str = Field(..., description="Short route ID (e.g. 'B63').")
    short_name: str = Field(..., description="Display name (e.g. 'B63').")
    color: str = Field(
        "1A73E8",
        description="Hex color for map rendering (no '#' prefix).",
    )
    polylines: list[str] = Field(
        ..., description="Google-encoded polylines (all directions merged)."
    )


class BusTileStop(BaseModel):
    """Compact bus stop representation for tile baking."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "id": "550001",
                    "name": "SUTPHIN BLVD/ARCHER AV",
                    "lat": 40.7004,
                    "lon": -73.8087,
                }
            ]
        }
    )

    id: str = Field(..., description="Stop ID.")
    name: str = Field(..., description="Human-readable stop name.")
    lat: float = Field(..., description="Latitude (WGS 84).")
    lon: float = Field(..., description="Longitude (WGS 84).")


class BusTileData(BaseModel):
    """All NYC bus route shapes and stops for pre-baked map tile rendering."""

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "routes": [
                        {
                            "route_id": "Q9",
                            "short_name": "Q9",
                            "color": "6CBE45",
                            "polylines": ["mpvwF`_wbM~AeGhCoN_BoH"],
                        },
                        {
                            "route_id": "Q80",
                            "short_name": "Q80",
                            "color": "C60C30",
                            "polylines": ["otvwFxfwbM{AgFqBcL"],
                        },
                    ],
                    "stops": [
                        {
                            "id": "550001",
                            "name": "SUTPHIN BLVD/ARCHER AV",
                            "lat": 40.7004,
                            "lon": -73.8087,
                        },
                        {
                            "id": "550144",
                            "name": "LIBERTY AV/110 ST",
                            "lat": 40.6843,
                            "lon": -73.8275,
                        },
                    ],
                }
            ]
        }
    )

    routes: list[BusTileRoute] = Field(
        ..., description="All bus route polylines."
    )
    stops: list[BusTileStop] = Field(
        ..., description="All bus stops."
    )


# Pre-built response dicts — import these in router files to avoid repetition.
# Usage:  @router.get("/path", responses={**RESP_404, **RESP_502})

RESP_400: dict = {
    400: {
        "model": ErrorDetail,
        "description": "Bad request — invalid parameters.",
        "content": {
            "application/json": {
                "example": {"detail": "Provide either depart_at_ts or arrive_by_ts, not both."}
            }
        },
    },
}
RESP_403: dict = {
    403: {
        "model": ErrorDetail,
        "description": "Forbidden — endpoint restricted to localhost.",
        "content": {
            "application/json": {
                "example": {"detail": "localhost only"}
            }
        },
    },
}
RESP_404: dict = {
    404: {
        "model": ErrorDetail,
        "description": "Resource not found.",
        "content": {
            "application/json": {
                "example": {"detail": "Unknown subway line: ZZ"}
            }
        },
    },
}
RESP_502: dict = {
    502: {
        "model": ErrorDetail,
        "description": "Upstream MTA/OBA service error.",
        "content": {
            "application/json": {
                "example": {"detail": "Upstream service temporarily unavailable."}
            }
        },
    },
}
RESP_503: dict = {
    503: {
        "model": ErrorDetail,
        "description": "Service unavailable — server is warming up. Retry after the `Retry-After` header value.",
        "headers": {
            "Retry-After": {
                "description": "Number of seconds the client should wait before retrying.",
                "schema": {"type": "string", "example": "5"},
            }
        },
        "content": {
            "application/json": {
                "example": {"detail": "Feeds warming up"}
            }
        },
    },
}
