"""Backend domain models for Track engine features."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(slots=True)
class LocationInput:
    """Origin or destination supplied by the caller."""

    label: str
    lat: float | None = None
    lon: float | None = None
    stop_id: str | None = None
    address: str | None = None


@dataclass(slots=True)
class ServiceAlertSummary:
    """Compact service-alert metadata attached to a trip or leg."""

    route_id: str | None
    severity: str
    title: str
    description: str
    mode: str
    alert_type: str | None = None
    active_period_end: int | None = None


@dataclass(slots=True)
class LegLiveStatus:
    """Realtime state for a single transit leg."""

    source: str
    status: str
    predicted_departure_ts: int | None = None
    predicted_arrival_ts: int | None = None
    delay_s: int | None = None
    status_text: str | None = None
    is_realtime: bool | None = None
    matched_trip_id: str | None = None


@dataclass(slots=True)
class TransitLeg:
    """A single leg of an itinerary."""

    mode: str
    route_id: str
    route_name: str
    color_hex: str | None
    headsign: str | None
    trip_id: str | None
    board_stop_id: str
    board_stop_name: str
    alight_stop_id: str
    alight_stop_name: str
    departure_ts: int
    arrival_ts: int
    duration_s: int
    stop_count: int
    walk_meters: float = 0.0
    live_status: LegLiveStatus | None = None
    alerts: list[ServiceAlertSummary] = field(default_factory=list)


@dataclass(slots=True)
class Itinerary:
    """A full trip plan from origin to destination."""

    itinerary_id: str
    leave_at_ts: int
    arrive_at_ts: int
    total_duration_s: int
    in_vehicle_s: int
    walking_s: int
    waiting_s: int
    transfer_count: int
    walk_meters: float
    score: float
    summary: str
    legs: list[TransitLeg] = field(default_factory=list)


@dataclass(slots=True)
class RouteChip:
    """Compact chip metadata for trip cards and route summaries."""

    kind: str
    label: str
    route_id: str | None = None
    color_hex: str | None = None
    mode: str | None = None
    duration_s: int | None = None
    walk_meters: float | None = None


@dataclass(slots=True)
class GoStep:
    """A single step in the live trip flow."""

    kind: str
    title: str
    subtitle: str
    start_ts: int
    end_ts: int
    route_id: str | None = None
    route_name: str | None = None
    color_hex: str | None = None
    stop_id: str | None = None
    stop_name: str | None = None


@dataclass(slots=True)
class GoTransfer:
    """Transfer metadata between two transit legs."""

    from_route_id: str
    from_route_name: str
    to_route_id: str
    to_route_name: str
    arrival_stop_id: str
    arrival_stop_name: str
    boarding_stop_id: str
    boarding_stop_name: str
    arrival_ts: int
    boarding_ts: int
    wait_s: int
    walk_s: int
    walk_meters: float


@dataclass(slots=True)
class GoAction:
    """The next high-priority instruction for the rider."""

    status: str
    title: str
    subtitle: str
    due_at_ts: int
    due_in_s: int


@dataclass(slots=True)
class GoTrip:
    """Frontend-ready Go trip presentation built from an itinerary."""

    itinerary: Itinerary
    route_chips: list[RouteChip] = field(default_factory=list)
    steps: list[GoStep] = field(default_factory=list)
    transfers: list[GoTransfer] = field(default_factory=list)
    next_action: GoAction | None = None
    status: str = "upcoming"
    leave_in_s: int = 0
    arrive_in_s: int = 0
    duration_label: str = ""
    leave_label: str = ""
    arrive_label: str = ""
    reliability_score: int = 100
    ranking_score: float = 0.0
    disruption_level: str = "normal"
    service_alerts: list[ServiceAlertSummary] = field(default_factory=list)


@dataclass(slots=True)
class GoResponse:
    """Full Go session payload for the frontend."""

    engine_version: str
    requested_at_ts: int
    now_ts: int
    origin: LocationInput
    destination: LocationInput
    session_kind: str
    primary_trip: GoTrip | None
    alternatives: list[GoTrip] = field(default_factory=list)


@dataclass(slots=True)
class PlanRequest:
    """Planner request passed from the backend router."""

    origin: LocationInput
    destination: LocationInput
    user_id: str | None = None
    depart_at_ts: int | None = None
    arrive_by_ts: int | None = None
    max_transfers: int = 1
    max_origin_walk_m: int = 1200
    max_destination_walk_m: int = 1200
    max_transfer_walk_m: int = 250
    search_window_minutes: int = 180
    num_itineraries: int = 3
    modes: tuple[str, ...] = ("subway", "bus", "lirr", "mnr")
    record_recent: bool = True


@dataclass(slots=True)
class SearchResult:
    """Merged search result for saved places, recents, and transit stops."""

    source: str
    label: str
    subtitle: str
    lat: float
    lon: float
    score: float
    stop_id: str | None = None
    place_id: int | None = None
    icon: str | None = None
    mode: str | None = None


@dataclass(slots=True)
class SavedPlace:
    """Persisted user place."""

    place_id: int
    user_id: str
    label: str
    kind: str
    lat: float
    lon: float
    address: str | None
    icon: str | None
    created_at: int
    updated_at: int
    last_used_at: int | None = None


@dataclass(slots=True)
class SavedTrip:
    """Persisted user trip template."""

    trip_id: int
    user_id: str
    name: str
    origin_label: str
    origin_lat: float
    origin_lon: float
    destination_label: str
    destination_lat: float
    destination_lon: float
    preferred_departure_hour: int | None
    preferred_arrival_hour: int | None
    preferred_modes: tuple[str, ...]
    created_at: int
    updated_at: int
    last_used_at: int | None = None


@dataclass(slots=True)
class RecentTrip:
    """A recently planned trip."""

    recent_trip_id: int
    user_id: str
    origin_label: str
    origin_lat: float
    origin_lon: float
    destination_label: str
    destination_lat: float
    destination_lon: float
    requested_at: int
    leave_at_ts: int
    arrive_at_ts: int
    summary: str
    route_tokens: tuple[str, ...]


@dataclass(slots=True)
class RecentDestination:
    """Aggregated recent-destination signal for recommendations."""

    label: str
    lat: float
    lon: float
    trip_count: int
    last_used_at: int


@dataclass(slots=True)
class CalendarEvent:
    """A normalized calendar event with a resolved location."""

    external_id: str
    title: str
    location_label: str
    starts_at: int
    ends_at: int | None
    lat: float | None = None
    lon: float | None = None
    notes: str | None = None


@dataclass(slots=True)
class Recommendation:
    """A destination suggestion returned to the app."""

    source: str
    label: str
    subtitle: str
    lat: float
    lon: float
    score: float
    reason: str
    upcoming_at: int | None = None
    place_id: int | None = None
    saved_trip_id: int | None = None


@dataclass(slots=True)
class HealthStatus:
    """Health metadata for the engine service."""

    version: str
    schedule_db_path: str
    state_db_path: str
    state_backend: str
    prepared: bool
    prepared_indexes: tuple[str, ...]
    routing_backend: str = "backend_state_only"
    remote_engine_url: str | None = None
    remote_engine_healthy: bool | None = None
    remote_engine_version: str | None = None
    remote_engine_error: str | None = None
