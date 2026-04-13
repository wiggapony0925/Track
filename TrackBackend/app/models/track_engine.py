"""Pydantic schemas for the TrackEngine API."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field, model_validator


class EngineLocationPayload(BaseModel):
    """Origin or destination payload."""

    label: str = Field(..., description="User-facing label for the location.")
    lat: float | None = Field(
        None,
        description="Latitude in WGS84. Required when stop_id is absent.",
    )
    lon: float | None = Field(
        None,
        description="Longitude in WGS84. Required when stop_id is absent.",
    )
    stop_id: str | None = Field(
        None,
        description="Optional GTFS stop_id when the frontend already resolved it.",
    )
    address: str | None = Field(
        None,
        description="Optional address or subtitle for display.",
    )

    @model_validator(mode="after")
    def _validate_resolution(self):
        if self.stop_id is None and (self.lat is None or self.lon is None):
            raise ValueError("Provide either stop_id or both lat/lon.")
        return self


class EngineSearchResult(BaseModel):
    """Merged search result for saved places, recent destinations, and stops."""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "source": "saved_place",
                "label": "Home",
                "subtitle": "Jackson Heights, Queens",
                "lat": 40.7554,
                "lon": -73.8892,
                "score": 0.98,
                "stop_id": None,
                "place_id": 12,
                "icon": "house.fill",
                "mode": None,
            }
        }
    )

    source: str = Field(..., description="saved_place, recent_destination, or stop.")
    label: str = Field(..., description="Primary display text.")
    subtitle: str = Field(..., description="Secondary display text.")
    lat: float = Field(..., description="Latitude in WGS84.")
    lon: float = Field(..., description="Longitude in WGS84.")
    score: float = Field(..., description="Internal ranking score.")
    stop_id: str | None = Field(None, description="Resolved GTFS stop_id when available.")
    place_id: int | None = Field(None, description="Saved place ID when available.")
    icon: str | None = Field(None, description="Optional frontend icon hint.")
    mode: str | None = Field(None, description="Transit mode when known.")


class EngineSavedPlaceUpsert(BaseModel):
    """Create or update a saved place."""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "user_id": "ios-user-42",
                "label": "Work",
                "kind": "work",
                "lat": 40.758,
                "lon": -73.9855,
                "address": "Times Sq, Manhattan, NY",
                "icon": "briefcase.fill",
                "place_id": None,
            }
        }
    )

    user_id: str = Field(..., description="Stable user identifier from the app.")
    label: str = Field(..., description="Display label, e.g. Home or Work.")
    kind: str = Field(..., description="home, work, school, gym, custom, etc.")
    lat: float = Field(..., description="Latitude in WGS84.")
    lon: float = Field(..., description="Longitude in WGS84.")
    address: str | None = Field(None, description="Optional human-readable address.")
    icon: str | None = Field(None, description="Optional icon token for the app.")
    place_id: int | None = Field(
        None,
        description="Existing place ID when editing an existing saved place.",
    )


class EngineSavedPlace(BaseModel):
    """Saved user place."""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "place_id": 12,
                "user_id": "ios-user-42",
                "label": "Work",
                "kind": "work",
                "lat": 40.758,
                "lon": -73.9855,
                "address": "Times Sq, Manhattan, NY",
                "icon": "briefcase.fill",
                "created_at": 1735603200,
                "updated_at": 1735606800,
                "last_used_at": 1735693200,
            }
        }
    )

    place_id: int = Field(..., description="Saved place primary key.")
    user_id: str = Field(..., description="Stable user identifier.")
    label: str = Field(..., description="Display label.")
    kind: str = Field(..., description="Saved place category.")
    lat: float = Field(..., description="Latitude in WGS84.")
    lon: float = Field(..., description="Longitude in WGS84.")
    address: str | None = Field(None, description="Human-readable address.")
    icon: str | None = Field(None, description="Optional icon token.")
    created_at: int = Field(..., description="Unix timestamp when the row was created.")
    updated_at: int = Field(..., description="Unix timestamp when the row was updated.")
    last_used_at: int | None = Field(
        None,
        description="Unix timestamp when the place was last used.",
    )


class EngineSavedTripUpsert(BaseModel):
    """Create or update a saved trip."""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "user_id": "ios-user-42",
                "name": "Morning commute",
                "origin": {
                    "label": "Home",
                    "lat": 40.7554,
                    "lon": -73.8892,
                    "stop_id": None,
                    "address": "Jackson Heights, Queens",
                },
                "destination": {
                    "label": "Office",
                    "lat": 40.758,
                    "lon": -73.9855,
                    "stop_id": None,
                    "address": "Times Sq, Manhattan",
                },
                "preferred_departure_hour": 8,
                "preferred_arrival_hour": None,
                "preferred_modes": ["subway", "bus"],
                "trip_id": None,
            }
        }
    )

    user_id: str = Field(..., description="Stable user identifier from the app.")
    name: str = Field(..., description="Human-friendly name for the saved trip.")
    origin: EngineLocationPayload = Field(..., description="Trip origin.")
    destination: EngineLocationPayload = Field(..., description="Trip destination.")
    preferred_departure_hour: int | None = Field(
        None,
        description="Preferred departure hour in local time (0-23).",
    )
    preferred_arrival_hour: int | None = Field(
        None,
        description="Preferred arrival hour in local time (0-23).",
    )
    preferred_modes: list[str] = Field(
        default_factory=list,
        description="Preferred transit modes for this saved trip.",
    )
    trip_id: int | None = Field(
        None,
        description="Existing saved trip ID when editing.",
    )


class EngineSavedTrip(BaseModel):
    """Saved trip template."""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "trip_id": 7,
                "user_id": "ios-user-42",
                "name": "Morning commute",
                "origin_label": "Home",
                "origin_lat": 40.7554,
                "origin_lon": -73.8892,
                "destination_label": "Office",
                "destination_lat": 40.758,
                "destination_lon": -73.9855,
                "preferred_departure_hour": 8,
                "preferred_arrival_hour": None,
                "preferred_modes": ["subway", "bus"],
                "created_at": 1735603200,
                "updated_at": 1735606800,
                "last_used_at": 1735693200,
            }
        }
    )

    trip_id: int = Field(..., description="Saved trip primary key.")
    user_id: str = Field(..., description="Stable user identifier.")
    name: str = Field(..., description="Saved trip name.")
    origin_label: str = Field(..., description="Origin display label.")
    origin_lat: float = Field(..., description="Origin latitude.")
    origin_lon: float = Field(..., description="Origin longitude.")
    destination_label: str = Field(..., description="Destination display label.")
    destination_lat: float = Field(..., description="Destination latitude.")
    destination_lon: float = Field(..., description="Destination longitude.")
    preferred_departure_hour: int | None = Field(
        None,
        description="Preferred departure hour in local time (0-23).",
    )
    preferred_arrival_hour: int | None = Field(
        None,
        description="Preferred arrival hour in local time (0-23).",
    )
    preferred_modes: list[str] = Field(
        default_factory=list,
        description="Preferred transit modes for this trip.",
    )
    created_at: int = Field(..., description="Unix timestamp when created.")
    updated_at: int = Field(..., description="Unix timestamp when updated.")
    last_used_at: int | None = Field(
        None,
        description="Unix timestamp when last used.",
    )


class EngineCalendarEventInput(BaseModel):
    """Normalized calendar event sent by the frontend."""

    external_id: str = Field(..., description="Stable event identifier from the device.")
    title: str = Field(..., description="Calendar event title.")
    location_label: str = Field(..., description="Resolved event location label.")
    starts_at: int = Field(..., description="Unix timestamp when the event starts.")
    ends_at: int | None = Field(
        None,
        description="Unix timestamp when the event ends.",
    )
    lat: float | None = Field(
        None,
        description="Resolved latitude when the frontend geocoded the event.",
    )
    lon: float | None = Field(
        None,
        description="Resolved longitude when the frontend geocoded the event.",
    )
    notes: str | None = Field(None, description="Optional event notes.")


class EngineRecommendation(BaseModel):
    """Suggested destination for the app to highlight."""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "source": "calendar",
                "label": "Dentist",
                "subtitle": "39-01 Main St, Flushing",
                "lat": 40.7601,
                "lon": -73.8303,
                "score": 0.88,
                "reason": "Calendar event starts in 55 minutes",
                "upcoming_at": 1735756200,
                "place_id": None,
                "saved_trip_id": None,
            }
        }
    )

    source: str = Field(..., description="saved_place, saved_trip, recent_trip, or calendar.")
    label: str = Field(..., description="Destination label.")
    subtitle: str = Field(..., description="Secondary display text.")
    lat: float = Field(..., description="Latitude in WGS84.")
    lon: float = Field(..., description="Longitude in WGS84.")
    score: float = Field(..., description="Internal ranking score.")
    reason: str = Field(..., description="Why this destination was suggested.")
    upcoming_at: int | None = Field(
        None,
        description="Unix timestamp of the related event, when applicable.",
    )
    place_id: int | None = Field(None, description="Saved place ID when applicable.")
    saved_trip_id: int | None = Field(
        None,
        description="Saved trip ID when applicable.",
    )


class EngineTripLeg(BaseModel):
    """One itinerary leg."""

    mode: str = Field(..., description="walk, subway, bus, lirr, or mnr.")
    route_id: str = Field(..., description="GTFS route_id or walk for walking legs.")
    route_name: str = Field(..., description="Human-friendly route label.")
    color_hex: str | None = Field(None, description="Hex route color when available.")
    text_color_hex: str | None = Field(None, description="Contrasting text color for legibility on color_hex background.")
    mode_name: str | None = Field(None, description="Human-readable mode label, e.g. Subway, Bus, LIRR, Metro-North.")
    headsign: str | None = Field(None, description="Trip headsign or destination label.")
    trip_id: str | None = Field(None, description="GTFS trip_id when applicable.")
    board_stop_id: str = Field(..., description="Boarding stop identifier.")
    board_stop_name: str = Field(..., description="Boarding stop name.")
    alight_stop_id: str = Field(..., description="Alighting stop identifier.")
    alight_stop_name: str = Field(..., description="Alighting stop name.")
    departure_ts: int = Field(..., description="Unix departure timestamp.")
    arrival_ts: int = Field(..., description="Unix arrival timestamp.")
    duration_s: int = Field(..., description="Leg duration in seconds.")
    stop_count: int = Field(..., description="Number of downstream stops traversed.")
    walk_meters: float = Field(
        0.0,
        description="Walking distance in meters for walk legs.",
    )
    bus_service_type: str | None = Field(
        None,
        description="Bus service classification: Local, Limited, Local / Limited, Select Bus Service, Express, or School.",
    )
    live_status: EngineLegLiveStatus | None = Field(
        None,
        description="Realtime signal for this leg when live data matched it.",
    )
    ada_accessible: bool | None = Field(
        None,
        description="Whether the boarding/alighting stops on this leg are wheelchair-accessible. "
                    "null for walk/bus legs; true/false for subway legs based on MTA ADA data.",
    )
    crowding: str | None = Field(
        None,
        description="Predicted crowding level based on time-of-day ridership patterns: "
                    "empty, some, busy, or very_busy. null for walk legs.",
    )
    alerts: list[EngineServiceAlert] = Field(
        default_factory=list,
        description="Active service alerts relevant to this leg.",
    )


class EngineLegFare(BaseModel):
    """Fare for a single transit leg."""

    mode: str = Field(..., description="subway, bus, express_bus, rail, walk.")
    route_id: str = Field(..., description="Route identifier for the leg.")
    fare_cents: int = Field(..., description="Fare in US cents for this leg.")
    is_free_transfer: bool = Field(False, description="Whether this leg was a free transfer.")
    fare_media: str = Field("omny", description="Payment method (omny, metrocard).")


class EngineFareEstimate(BaseModel):
    """Fare estimate for a complete trip."""

    total_cents: int = Field(..., description="Total fare in US cents.")
    currency: str = Field("USD", description="Currency code.")
    description: str = Field("", description="Human-readable fare summary.")
    legs: list[EngineLegFare] = Field(default_factory=list, description="Per-leg fare breakdown.")
    free_transfers_used: int = Field(0, description="Number of free transfers applied.")


class EngineEnvironmentalImpact(BaseModel):
    """CO₂ savings and calorie burn compared to driving."""

    co2_saved_grams: int = Field(0, description="Grams of CO₂ saved vs driving.")
    calories_burned: int = Field(0, description="Approx calories burned from walking legs.")
    walk_meters: float = Field(0.0, description="Total walking distance contributing to calories.")
    equivalent_car_co2_grams: int = Field(0, description="CO₂ a car would emit for the same trip.")


class EngineItinerary(BaseModel):
    """A complete itinerary."""

    itinerary_id: str = Field(..., description="Stable ID for the itinerary response.")
    leave_at_ts: int = Field(..., description="Unix timestamp when the user should leave.")
    arrive_at_ts: int = Field(..., description="Unix timestamp for final arrival.")
    total_duration_s: int = Field(..., description="Total journey duration in seconds.")
    in_vehicle_s: int = Field(..., description="Total in-vehicle time in seconds.")
    walking_s: int = Field(..., description="Total walking time in seconds.")
    waiting_s: int = Field(..., description="Total waiting time in seconds.")
    transfer_count: int = Field(..., description="Number of transit transfers.")
    walk_meters: float = Field(..., description="Total walking distance in meters.")
    score: float = Field(..., description="Internal itinerary score.")
    summary: str = Field(..., description="Compact summary for recent-trip cards.")
    accessible: bool | None = Field(
        None,
        description="Whether all subway stations in this itinerary are wheelchair-accessible. "
                    "null when no subway legs are present; false if any station lacks ADA access.",
    )
    legs: list[EngineTripLeg] = Field(..., description="Ordered itinerary legs.")
    fare: EngineFareEstimate | None = Field(None, description="Trip fare estimate.")
    environmental_impact: EngineEnvironmentalImpact | None = Field(
        None,
        description="CO₂ savings and calorie burn for this trip.",
    )


class EngineRouteChip(BaseModel):
    """Compact route chip for trip cards."""

    kind: str = Field(..., description="walk or transit.")
    label: str = Field(..., description="Display label, e.g. Q10 or Walk 4 min.")
    route_id: str | None = Field(None, description="Route ID when the chip represents transit.")
    color_hex: str | None = Field(None, description="Route color when available.")
    text_color_hex: str | None = Field(None, description="Contrasting text color for legibility on color_hex background.")
    mode: str | None = Field(None, description="Transit mode or walk.")
    mode_name: str | None = Field(None, description="Human-readable mode label.")
    duration_s: int | None = Field(None, description="Duration represented by the chip.")
    walk_meters: float | None = Field(None, description="Walking distance for walk chips.")


class EngineServiceAlert(BaseModel):
    """Compact alert summary for legs and trip cards."""

    route_id: str | None = Field(None, description="Affected route ID when known.")
    severity: str = Field(..., description="severe, warning, or informational status.")
    title: str = Field(..., description="Alert headline.")
    description: str = Field(..., description="Alert body text.")
    mode: str = Field(..., description="Transit mode affected by the alert.")
    alert_type: str | None = Field(None, description="MTA alert type when available.")
    active_period_end: int | None = Field(
        None,
        description="Unix timestamp when the alert is expected to expire.",
    )


class EngineLegLiveStatus(BaseModel):
    """Realtime status for a transit leg."""

    source: str = Field(..., description="subway_gtfs_rt, rail_gtfs_rt, bus_siri, or none.")
    status: str = Field(..., description="live, delayed, scheduled, cancelled, or no_data.")
    predicted_departure_ts: int | None = Field(
        None,
        description="Predicted departure/boarding time when matched.",
    )
    predicted_arrival_ts: int | None = Field(
        None,
        description="Predicted arrival/alight time when matched.",
    )
    delay_s: int | None = Field(
        None,
        description="Positive for late, negative for early, relative to the schedule.",
    )
    status_text: str | None = Field(
        None,
        description="Human-readable live status text from the upstream feed.",
    )
    is_realtime: bool | None = Field(
        None,
        description="False when the signal came from schedule-based fallback data.",
    )
    matched_trip_id: str | None = Field(
        None,
        description="Realtime trip identifier when the feed exposed one.",
    )


class EngineGoStep(BaseModel):
    """A single Go step."""

    kind: str = Field(..., description="leave, walk, ride, wait, or arrive.")
    title: str = Field(..., description="Primary instruction.")
    subtitle: str = Field(..., description="Supporting detail for the instruction.")
    start_ts: int = Field(..., description="Unix timestamp when the step starts.")
    end_ts: int = Field(..., description="Unix timestamp when the step ends.")
    route_id: str | None = Field(None, description="Transit route ID when applicable.")
    route_name: str | None = Field(None, description="Transit route label when applicable.")
    color_hex: str | None = Field(None, description="Route color when applicable.")
    text_color_hex: str | None = Field(None, description="Contrasting text color for legibility on color_hex background.")
    stop_id: str | None = Field(None, description="Relevant stop ID when applicable.")
    stop_name: str | None = Field(None, description="Relevant stop name when applicable.")


class EngineGoTransfer(BaseModel):
    """Transfer metadata between two transit legs."""

    from_route_id: str = Field(..., description="Previous route ID.")
    from_route_name: str = Field(..., description="Previous route display label.")
    to_route_id: str = Field(..., description="Next route ID.")
    to_route_name: str = Field(..., description="Next route display label.")
    arrival_stop_id: str = Field(..., description="Stop ID where the incoming leg ends.")
    arrival_stop_name: str = Field(..., description="Stop name where the incoming leg ends.")
    boarding_stop_id: str = Field(..., description="Stop ID where the outgoing leg boards.")
    boarding_stop_name: str = Field(..., description="Stop name where the outgoing leg boards.")
    arrival_ts: int = Field(..., description="Unix arrival timestamp of the incoming leg.")
    boarding_ts: int = Field(..., description="Unix boarding timestamp of the outgoing leg.")
    wait_s: int = Field(..., description="Pure wait time before the next vehicle.")
    walk_s: int = Field(..., description="Walking time inside the transfer.")
    walk_meters: float = Field(..., description="Walking distance for the transfer.")
    safety: str = Field(
        "unknown",
        description="Transfer connection safety: safe (≥5 min buffer), tight (2-5 min), "
                    "at_risk (0-2 min), missed (negative — incoming train arrives after "
                    "connecting train departs), or unknown (no RT data).",
    )


class EngineGoAction(BaseModel):
    """Next key action for the rider."""

    status: str = Field(..., description="upcoming, walking, waiting, riding, or arrived.")
    title: str = Field(..., description="Primary call to action.")
    subtitle: str = Field(..., description="Supporting detail for the action.")
    due_at_ts: int = Field(..., description="Unix timestamp when the action becomes due.")
    due_in_s: int = Field(..., description="Seconds until the action is due.")


class EngineRecentTrip(BaseModel):
    """Recently planned trip."""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "recent_trip_id": 91,
                "user_id": "ios-user-42",
                "origin_label": "Home",
                "origin_lat": 40.7554,
                "origin_lon": -73.8892,
                "destination_label": "Grand Central Terminal",
                "destination_lat": 40.7527,
                "destination_lon": -73.9772,
                "requested_at": 1735693200,
                "leave_at_ts": 1735693500,
                "arrive_at_ts": 1735695900,
                "summary": "7 to Grand Central • 1 transfer",
                "route_tokens": ["7", "S"],
            }
        }
    )

    recent_trip_id: int = Field(..., description="Recent trip primary key.")
    user_id: str = Field(..., description="Stable user identifier.")
    origin_label: str = Field(..., description="Origin label.")
    origin_lat: float = Field(..., description="Origin latitude.")
    origin_lon: float = Field(..., description="Origin longitude.")
    destination_label: str = Field(..., description="Destination label.")
    destination_lat: float = Field(..., description="Destination latitude.")
    destination_lon: float = Field(..., description="Destination longitude.")
    requested_at: int = Field(..., description="Unix timestamp when the trip was requested.")
    leave_at_ts: int = Field(..., description="Unix timestamp when to leave.")
    arrive_at_ts: int = Field(..., description="Unix timestamp when the trip arrives.")
    summary: str = Field(..., description="Compact itinerary summary.")
    route_tokens: list[str] = Field(
        default_factory=list,
        description="Ordered route labels used for recent-trip chips.",
    )


class EnginePlanRequest(BaseModel):
    """Trip planning request for /engine/plan."""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "origin": {
                    "label": "Home",
                    "lat": 40.7554,
                    "lon": -73.8892,
                    "stop_id": None,
                    "address": "Jackson Heights, Queens",
                },
                "destination": {
                    "label": "Penn Station",
                    "lat": 40.7506,
                    "lon": -73.9935,
                    "stop_id": None,
                    "address": "Penn Station, Manhattan",
                },
                "user_id": "ios-user-42",
                "depart_at_ts": 1735700400,
                "arrive_by_ts": None,
                "max_transfers": 2,
                "max_origin_walk_m": 1200,
                "max_destination_walk_m": 1200,
                "max_transfer_walk_m": 250,
                "search_window_minutes": 180,
                "num_itineraries": 3,
                "modes": ["subway", "bus", "lirr", "mnr"],
                "record_recent": True,
            }
        }
    )

    origin: EngineLocationPayload = Field(..., description="Origin.")
    destination: EngineLocationPayload = Field(..., description="Destination.")
    user_id: str | None = Field(
        None,
        description="Stable user identifier. When present, the top itinerary is recorded as a recent trip.",
    )
    depart_at_ts: int | None = Field(
        None,
        description="Unix timestamp for earliest departure from the origin.",
    )
    arrive_by_ts: int | None = Field(
        None,
        description="Unix timestamp for latest acceptable arrival.",
    )
    max_transfers: int = Field(
        2,
        ge=0,
        le=3,
        description="Maximum number of transit transfers to allow.",
    )
    max_origin_walk_m: int = Field(
        1200,
        ge=0,
        le=5000,
        description="Maximum walking distance from the origin to the first stop.",
    )
    max_destination_walk_m: int = Field(
        1200,
        ge=0,
        le=5000,
        description="Maximum walking distance from the last stop to the destination.",
    )
    max_transfer_walk_m: int = Field(
        250,
        ge=0,
        le=1000,
        description="Maximum walking distance allowed while transferring.",
    )
    search_window_minutes: int = Field(
        180,
        ge=30,
        le=720,
        description="How far forward the planner should search from the query time.",
    )
    num_itineraries: int = Field(
        3,
        ge=1,
        le=10,
        description="Number of itineraries to return.",
    )
    modes: list[str] = Field(
        default_factory=lambda: ["subway", "bus", "lirr", "mnr"],
        description="Allowed transit modes.",
    )
    record_recent: bool = Field(
        True,
        description="Whether to record the best itinerary into recent trips when user_id is provided.",
    )
    priority: str | None = Field(
        None,
        description="Routing priority: quick (default), fewer_transfers, or less_walking.",
    )
    accessibility_priority: bool = Field(
        False,
        description="When true, prefer wheelchair-accessible stations/stops.",
    )

    @model_validator(mode="after")
    def _validate_times(self):
        if self.depart_at_ts is not None and self.arrive_by_ts is not None:
            raise ValueError("Provide either depart_at_ts or arrive_by_ts, not both.")
        return self


class EnginePlanResponse(BaseModel):
    """Planner response."""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "engine_version": "0.3.0",
                "requested_at_ts": 1735700100,
                "origin": {
                    "label": "Home",
                    "lat": 40.7554,
                    "lon": -73.8892,
                    "stop_id": None,
                    "address": "Jackson Heights, Queens",
                },
                "destination": {
                    "label": "Penn Station",
                    "lat": 40.7506,
                    "lon": -73.9935,
                    "stop_id": None,
                    "address": "Penn Station, Manhattan",
                },
                "depart_at_ts": 1735700400,
                "arrive_by_ts": None,
                "itineraries": [
                    {
                        "itinerary_id": "itin_1",
                        "leave_at_ts": 1735700400,
                        "arrive_at_ts": 1735702680,
                        "total_duration_s": 2280,
                        "in_vehicle_s": 1620,
                        "walking_s": 420,
                        "waiting_s": 240,
                        "transfer_count": 1,
                        "walk_meters": 540.0,
                        "score": 0.93,
                        "summary": "7 to Times Sq • Walk to Penn Station",
                        "legs": []
                    }
                ],
                "schedule_note": None,
            }
        }
    )

    engine_version: str = Field(..., description="TrackEngine version string.")
    requested_at_ts: int = Field(..., description="Unix timestamp when the backend handled the query.")
    origin: EngineLocationPayload = Field(..., description="Resolved origin payload echo.")
    destination: EngineLocationPayload = Field(..., description="Resolved destination payload echo.")
    depart_at_ts: int | None = Field(
        None,
        description="Unix earliest-departure constraint when provided.",
    )
    arrive_by_ts: int | None = Field(
        None,
        description="Unix latest-arrival constraint when provided.",
    )
    itineraries: list[EngineItinerary] = Field(..., description="Returned itineraries.")
    schedule_note: str | None = Field(
        None,
        description="Human-readable note when trips are shown for a future service day.",
    )


class EngineGoTrip(BaseModel):
    """Frontend-ready Go trip."""

    itinerary: EngineItinerary = Field(..., description="Underlying itinerary.")
    route_chips: list[EngineRouteChip] = Field(
        default_factory=list,
        description="Compact route chips for cards and summaries.",
    )
    steps: list[EngineGoStep] = Field(
        default_factory=list,
        description="Ordered live instructions for the trip.",
    )
    transfers: list[EngineGoTransfer] = Field(
        default_factory=list,
        description="Transfer timing blocks extracted from the itinerary.",
    )
    next_action: EngineGoAction | None = Field(
        None,
        description="The next action the rider should take right now.",
    )
    status: str = Field(..., description="upcoming, walking, waiting, riding, or arrived.")
    leave_in_s: int = Field(..., description="Seconds until the trip should start.")
    arrive_in_s: int = Field(..., description="Seconds until final arrival.")
    duration_label: str = Field(..., description="Formatted total duration label.")
    leave_label: str = Field(..., description="Formatted local leave time.")
    arrive_label: str = Field(..., description="Formatted local arrival time.")
    reliability_score: int = Field(
        100,
        description="0-100 estimate of how operationally reliable this trip looks right now.",
    )
    ranking_score: float = Field(
        0.0,
        description="Composite trip ranking score after realtime/alert penalties.",
    )
    disruption_level: str = Field(
        "normal",
        description="normal, watch, or disrupted based on live conditions.",
    )
    confidence: int = Field(
        100,
        description="0-100 unified confidence score combining realtime data quality, "
                    "transfer safety, crowding, disruption severity, and accessibility. "
                    "Higher = more reliable trip.",
    )
    service_alerts: list[EngineServiceAlert] = Field(
        default_factory=list,
        description="Active alerts aggregated across the trip's transit legs.",
    )


class EngineGoRequest(EnginePlanRequest):
    """Request for the Transit-style Go endpoint."""

    record_recent: bool = Field(
        False,
        description="Whether this Go request should also be recorded into recent trips.",
    )
    now_ts: int | None = Field(
        None,
        description="Unix timestamp used to compute live trip state. Defaults to now.",
    )


class EngineGoResponse(BaseModel):
    """Go session response."""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "engine_version": "0.3.0",
                "requested_at_ts": 1735700100,
                "now_ts": 1735700100,
                "origin": {
                    "label": "Home",
                    "lat": 40.7554,
                    "lon": -73.8892,
                    "stop_id": None,
                    "address": "Jackson Heights, Queens",
                },
                "destination": {
                    "label": "Grand Central Terminal",
                    "lat": 40.7527,
                    "lon": -73.9772,
                    "stop_id": None,
                    "address": "89 E 42nd St, Manhattan",
                },
                "session_kind": "leave_now",
                "primary_trip": None,
                "alternatives": [],
                "schedule_note": None,
            }
        }
    )

    engine_version: str = Field(..., description="TrackEngine version string.")
    requested_at_ts: int = Field(..., description="Unix timestamp when the backend handled the query.")
    now_ts: int = Field(..., description="Unix timestamp used to compute trip state.")
    origin: EngineLocationPayload = Field(..., description="Resolved origin payload echo.")
    destination: EngineLocationPayload = Field(..., description="Resolved destination payload echo.")
    session_kind: str = Field(..., description="leave_now, depart_at, or arrive_by.")
    primary_trip: EngineGoTrip | None = Field(
        None,
        description="Best trip option for the current query.",
    )
    alternatives: list[EngineGoTrip] = Field(
        default_factory=list,
        description="Alternative trip options returned by the engine.",
    )
    schedule_note: str | None = Field(
        None,
        description="Human-readable note when trips are shown for a future service day.",
    )


class EngineHealth(BaseModel):
    """Health response for /engine/health."""

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "version": "0.3.0",
                "schedule_db_path": "app/data/transit_schedule.db",
                "state_db_path": "supabase://track_engine_state",
                "state_backend": "supabase",
                "prepared": True,
                "prepared_indexes": ["stops_name_idx", "stop_times_trip_idx"],
                "schedule_db_error": None,
                "routing_backend": "cpp_remote",
                "remote_engine_url": "http://trackengine:10000",
                "remote_engine_healthy": True,
                "remote_engine_version": "0.3.0",
                "remote_engine_error": None,
            }
        }
    )

    version: str = Field(..., description="TrackEngine version string.")
    schedule_db_path: str = Field(..., description="Resolved schedule DB path.")
    state_db_path: str = Field(..., description="Resolved state store descriptor.")
    state_backend: str = Field(..., description="sqlite or supabase.")
    prepared: bool = Field(..., description="Whether planner indexes have been prepared.")
    prepared_indexes: list[str] = Field(
        default_factory=list,
        description="Planner-owned SQLite indexes.",
    )
    schedule_db_error: str | None = Field(
        None,
        description="Planner-side schedule DB error when GTFS search data is unavailable.",
    )
    routing_backend: str = Field(
        ...,
        description="backend_state_only when only backend helpers are active, or cpp_remote when routing is delegated to the standalone C++ engine.",
    )
    remote_engine_url: str | None = Field(
        None,
        description="Configured standalone engine base URL when remote routing is enabled.",
    )
    remote_engine_healthy: bool | None = Field(
        None,
        description="Whether the standalone C++ engine health check succeeded.",
    )
    remote_engine_version: str | None = Field(
        None,
        description="Version returned by the standalone C++ engine.",
    )
    remote_engine_error: str | None = Field(
        None,
        description="Last remote engine health error, when unhealthy.",
    )
