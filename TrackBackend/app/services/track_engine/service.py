"""Backend helper service for Track state/search plus remote C++ routing."""

from __future__ import annotations

import asyncio
import math
import os
import sqlite3
import threading
import time
from contextlib import suppress
from dataclasses import dataclass
from datetime import datetime
from datetime import time as time_value
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import httpx

from .domain import (
    CalendarEvent,
    GoAction,
    GoResponse,
    GoStep,
    GoTransfer,
    GoTrip,
    HealthStatus,
    Itinerary,
    LegLiveStatus,
    LocationInput,
    PlanRequest,
    RecentTrip,
    Recommendation,
    RouteChip,
    SavedPlace,
    SavedTrip,
    SearchResult,
    ServiceAlertSummary,
    TransitLeg,
)
from .store import EngineStore
from .store_supabase import SupabaseEngineStore

NY_TZ = ZoneInfo("America/New_York")


@dataclass(slots=True)
class StopRecord:
    stop_id: str
    stop_name: str
    lat: float
    lon: float


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in meters."""

    earth_radius_m = 6_371_009.0
    rlat1 = math.radians(lat1)
    rlat2 = math.radians(lat2)
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (
        math.sin(dlat / 2) ** 2
        + math.cos(rlat1) * math.cos(rlat2) * math.sin(dlon / 2) ** 2
    )
    return earth_radius_m * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def hour_of_day(timestamp_s: int) -> int:
    return datetime.fromtimestamp(timestamp_s, NY_TZ).hour


def weekday_index(timestamp_s: int) -> int:
    return datetime.fromtimestamp(timestamp_s, NY_TZ).weekday()


def service_date_for_timestamp(timestamp_s: int):
    return datetime.fromtimestamp(timestamp_s, NY_TZ).date()


class ScheduleRepository:
    """Tiny SQLite helper used only for stop search and engine health."""

    _INDEXES: dict[str, str] = {
        "idx_stop_times_trip_seq": (
            "CREATE INDEX IF NOT EXISTS idx_stop_times_trip_seq "
            "ON stop_times(trip_id, stop_sequence)"
        ),
        "idx_stop_times_trip_stop_seq": (
            "CREATE INDEX IF NOT EXISTS idx_stop_times_trip_stop_seq "
            "ON stop_times(trip_id, stop_id, stop_sequence)"
        ),
        "idx_stop_times_stop_dept": (
            "CREATE INDEX IF NOT EXISTS idx_stop_times_stop_dept "
            "ON stop_times(stop_id, departure_time)"
        ),
        "idx_trips_service": (
            "CREATE INDEX IF NOT EXISTS idx_trips_service ON trips(service_id)"
        ),
        "idx_calendar_date": (
            "CREATE INDEX IF NOT EXISTS idx_calendar_date ON calendar_dates(date)"
        ),
        "idx_calendar_service": (
            "CREATE INDEX IF NOT EXISTS idx_calendar_service ON calendar(service_id)"
        ),
        "idx_stops_name": (
            "CREATE INDEX IF NOT EXISTS idx_stops_name ON stops(stop_name)"
        ),
    }

    def __init__(self, db_path: Path):
        self.db_path = Path(db_path)
        self._prepared = False
        self._prepare_lock = threading.Lock()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=30, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        return conn

    def ensure_query_indexes(self) -> None:
        with self._prepare_lock:
            if self._prepared:
                return
            conn = self._connect()
            try:
                for sql in self._INDEXES.values():
                    try:
                        conn.execute(sql)
                    except sqlite3.OperationalError:
                        continue
                conn.commit()
            finally:
                conn.close()
            self._prepared = True

    @property
    def prepared(self) -> bool:
        return self._prepared

    @property
    def prepared_index_names(self) -> tuple[str, ...]:
        return tuple(self._INDEXES)

    def search_stops(self, query: str, limit: int = 12) -> list[StopRecord]:
        lowered = query.strip().lower()
        if not lowered:
            return []
        conn = self._connect()
        try:
            try:
                rows = conn.execute(
                    """
                    SELECT stop_id, stop_name, stop_lat, stop_lon
                    FROM stops
                    WHERE lower(stop_name) LIKE ?
                       OR lower(stop_id) LIKE ?
                    ORDER BY
                        CASE
                            WHEN lower(stop_name) = ? THEN 0
                            WHEN lower(stop_name) LIKE ? THEN 1
                            WHEN lower(stop_id) = ? THEN 2
                            ELSE 3
                        END,
                        length(stop_name),
                        stop_name COLLATE NOCASE
                    LIMIT ?
                    """,
                    (
                        f"%{lowered}%",
                        f"%{lowered}%",
                        lowered,
                        f"{lowered}%",
                        lowered,
                        limit,
                    ),
                ).fetchall()
            except sqlite3.OperationalError as exc:
                # Some production snapshots may temporarily lack the GTFS stops
                # table while the main backend is still bootstrapping data.
                # Search should still work for saved places/recents instead of
                # failing the entire request with a 500.
                if "no such table" in str(exc).lower():
                    return []
                raise
        finally:
            conn.close()
        return [
            StopRecord(
                stop_id=str(row["stop_id"]),
                stop_name=str(row["stop_name"]),
                lat=float(row["stop_lat"]),
                lon=float(row["stop_lon"]),
            )
            for row in rows
        ]


class TrackEngineService:
    """Facade used by the FastAPI router."""

    VERSION = "0.3.0"
    _RENDER_INTERNAL_ENGINE_URL = "http://trackegine:10000"

    def __init__(self, *, schedule_db: Path, state_db: Path):
        self.schedule_db = Path(schedule_db)
        self.state_db = Path(state_db)
        self.repository = ScheduleRepository(self.schedule_db)
        self.store = self._build_store(self.state_db)
        self.state_backend = self.store.backend_name
        self.state_store_description = self.store.description
        self._last_remote_engine_version: str | None = None
        self.remote_engine_url = self._resolve_remote_engine_url()
        self.remote_engine_timeout_s = float(
            os.environ.get("TRACK_ENGINE_TIMEOUT_S", "25")
        )
        self.enable_realtime_enrichment = (
            os.environ.get("TRACK_ENGINE_ENABLE_REALTIME_ENRICHMENT", "1")
            .strip()
            .lower()
            not in {"0", "false", "no", "off"}
        )
        self.realtime_timeout_s = float(
            os.environ.get("TRACK_ENGINE_REALTIME_TIMEOUT_S", "4.0")
        )
        self.alert_timeout_s = float(
            os.environ.get("TRACK_ENGINE_ALERT_TIMEOUT_S", "4.0")
        )

    def _resolve_remote_engine_url(self) -> str | None:
        explicit = (
            os.environ.get("TRACK_ENGINE_URL")
            or os.environ.get("TRACK_ENGINE_INTERNAL_URL")
            or ""
        ).strip().rstrip("/")
        if explicit:
            return explicit

        # Render production currently runs this backend from /TrackBackend and
        # the private C++ engine is addressable by its internal service name.
        # Falling back here removes the need for a separate env var just to
        # connect the two services inside the same Render workspace.
        if Path("/TrackBackend").exists():
            return self._RENDER_INTERNAL_ENGINE_URL
        return None

    def _build_store(self, state_db: Path):
        state_backend = os.environ.get("TRACK_ENGINE_STATE_BACKEND", "").strip().lower()
        supabase_url = os.environ.get("SUPABASE_URL", "").strip().rstrip("/")
        supabase_key = (
            os.environ.get("SUPABASE_SERVICE_KEY")
            or os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
            or ""
        ).strip()
        if not state_backend and supabase_url and supabase_key:
            state_backend = "supabase"
        if state_backend == "supabase":
            if not supabase_url or not supabase_key:
                raise RuntimeError(
                    "TRACK_ENGINE_STATE_BACKEND=supabase requires SUPABASE_URL and "
                    "SUPABASE_SERVICE_KEY or SUPABASE_SERVICE_ROLE_KEY."
                )
            return SupabaseEngineStore(
                supabase_url=supabase_url,
                service_key=supabase_key,
                timeout_s=float(os.environ.get("TRACK_ENGINE_STATE_TIMEOUT_S", "10")),
            )
        if state_backend == "auto" and supabase_url and supabase_key:
            return SupabaseEngineStore(
                supabase_url=supabase_url,
                service_key=supabase_key,
                timeout_s=float(os.environ.get("TRACK_ENGINE_STATE_TIMEOUT_S", "10")),
            )
        return EngineStore(state_db)

    def prepare(self) -> None:
        self.repository.ensure_query_indexes()

    @property
    def planner_version(self) -> str:
        return self._last_remote_engine_version or self.VERSION

    def health(self) -> HealthStatus:
        self.prepare()
        remote_healthy = None
        remote_version = None
        remote_error = None
        routing_backend = "backend_state_only"
        if self.remote_engine_url:
            routing_backend = "cpp_remote"
            try:
                with httpx.Client(timeout=min(self.remote_engine_timeout_s, 5.0)) as client:
                    response = client.get(f"{self.remote_engine_url}/health")
                    response.raise_for_status()
                    payload = response.json()
                remote_healthy = bool(payload.get("ready", True))
                remote_version = payload.get("version")
                if remote_version:
                    self._last_remote_engine_version = str(remote_version)
            except Exception as exc:  # pragma: no cover
                remote_healthy = False
                remote_error = str(exc)
        return HealthStatus(
            version=self.VERSION,
            schedule_db_path=str(self.schedule_db),
            state_db_path=self.state_store_description,
            state_backend=self.state_backend,
            prepared=self.repository.prepared,
            prepared_indexes=self.repository.prepared_index_names,
            routing_backend=routing_backend,
            remote_engine_url=self.remote_engine_url,
            remote_engine_healthy=remote_healthy,
            remote_engine_version=remote_version,
            remote_engine_error=remote_error,
        )

    def _query_timestamp(self, request: PlanRequest) -> int:
        now_ts = int(time.time())
        if request.depart_at_ts is not None:
            return request.depart_at_ts
        if request.arrive_by_ts is not None:
            return max(now_ts, request.arrive_by_ts - request.search_window_minutes * 60)
        return now_ts

    def _service_day_context(self, query_ts: int) -> tuple[int, int, int]:
        service_day = service_date_for_timestamp(query_ts)
        midnight = datetime.combine(service_day, time_value.min, tzinfo=NY_TZ)
        return (
            int(service_day.strftime("%Y%m%d")),
            service_day.weekday(),
            int(midnight.timestamp()),
        )

    def _remote_payload(self, request: PlanRequest, *, now_ts: int | None = None):
        query_ts = self._query_timestamp(request)
        service_day_yyyymmdd, service_weekday, service_day_midnight_ts = (
            self._service_day_context(query_ts)
        )
        payload = {
            "origin": {
                "label": request.origin.label,
                "lat": request.origin.lat,
                "lon": request.origin.lon,
                "stop_id": request.origin.stop_id,
                "address": request.origin.address,
            },
            "destination": {
                "label": request.destination.label,
                "lat": request.destination.lat,
                "lon": request.destination.lon,
                "stop_id": request.destination.stop_id,
                "address": request.destination.address,
            },
            "depart_at_ts": request.depart_at_ts,
            "arrive_by_ts": request.arrive_by_ts,
            "query_ts": query_ts,
            "service_day_yyyymmdd": service_day_yyyymmdd,
            "service_weekday": service_weekday,
            "service_day_midnight_ts": service_day_midnight_ts,
            "max_transfers": request.max_transfers,
            "max_origin_walk_m": request.max_origin_walk_m,
            "max_destination_walk_m": request.max_destination_walk_m,
            "max_transfer_walk_m": request.max_transfer_walk_m,
            "search_window_minutes": request.search_window_minutes,
            "num_itineraries": request.num_itineraries,
            "modes": list(request.modes),
        }
        if now_ts is not None:
            payload["now_ts"] = now_ts
        return payload

    def _parse_itinerary(self, item) -> Itinerary:
        legs = [
            TransitLeg(
                mode=leg["mode"],
                route_id=leg["route_id"],
                route_name=leg["route_name"],
                color_hex=leg.get("color_hex"),
                headsign=leg.get("headsign"),
                trip_id=leg.get("trip_id"),
                board_stop_id=leg["board_stop_id"],
                board_stop_name=leg["board_stop_name"],
                alight_stop_id=leg["alight_stop_id"],
                alight_stop_name=leg["alight_stop_name"],
                departure_ts=leg["departure_ts"],
                arrival_ts=leg["arrival_ts"],
                duration_s=leg["duration_s"],
                stop_count=leg["stop_count"],
                walk_meters=leg.get("walk_meters", 0.0),
            )
            for leg in item.get("legs", [])
        ]
        return Itinerary(
            itinerary_id=item["itinerary_id"],
            leave_at_ts=item["leave_at_ts"],
            arrive_at_ts=item["arrive_at_ts"],
            total_duration_s=item["total_duration_s"],
            in_vehicle_s=item["in_vehicle_s"],
            walking_s=item["walking_s"],
            waiting_s=item["waiting_s"],
            transfer_count=item["transfer_count"],
            walk_meters=item["walk_meters"],
            score=float(item["score"]),
            summary=item["summary"],
            legs=legs,
        )

    def _parse_go_action(self, payload) -> GoAction | None:
        if payload is None:
            return None
        return GoAction(
            status=payload["status"],
            title=payload["title"],
            subtitle=payload["subtitle"],
            due_at_ts=payload["due_at_ts"],
            due_in_s=payload["due_in_s"],
        )

    def _parse_go_trip(self, payload) -> GoTrip:
        return GoTrip(
            itinerary=self._parse_itinerary(payload["itinerary"]),
            route_chips=[
                RouteChip(
                    kind=chip["kind"],
                    label=chip["label"],
                    route_id=chip.get("route_id"),
                    color_hex=chip.get("color_hex"),
                    mode=chip.get("mode"),
                    duration_s=chip.get("duration_s"),
                    walk_meters=chip.get("walk_meters"),
                )
                for chip in payload.get("route_chips", [])
            ],
            steps=[
                GoStep(
                    kind=step["kind"],
                    title=step["title"],
                    subtitle=step["subtitle"],
                    start_ts=step["start_ts"],
                    end_ts=step["end_ts"],
                    route_id=step.get("route_id"),
                    route_name=step.get("route_name"),
                    color_hex=step.get("color_hex"),
                    stop_id=step.get("stop_id"),
                    stop_name=step.get("stop_name"),
                )
                for step in payload.get("steps", [])
            ],
            transfers=[
                GoTransfer(
                    from_route_id=transfer["from_route_id"],
                    from_route_name=transfer["from_route_name"],
                    to_route_id=transfer["to_route_id"],
                    to_route_name=transfer["to_route_name"],
                    arrival_stop_id=transfer["arrival_stop_id"],
                    arrival_stop_name=transfer["arrival_stop_name"],
                    boarding_stop_id=transfer["boarding_stop_id"],
                    boarding_stop_name=transfer["boarding_stop_name"],
                    arrival_ts=transfer["arrival_ts"],
                    boarding_ts=transfer["boarding_ts"],
                    wait_s=transfer["wait_s"],
                    walk_s=transfer["walk_s"],
                    walk_meters=transfer["walk_meters"],
                )
                for transfer in payload.get("transfers", [])
            ],
            next_action=self._parse_go_action(payload.get("next_action")),
            status=payload["status"],
            leave_in_s=payload["leave_in_s"],
            arrive_in_s=payload["arrive_in_s"],
            duration_label=payload["duration_label"],
            leave_label=payload["leave_label"],
            arrive_label=payload["arrive_label"],
        )

    def _remote_plan(self, request: PlanRequest) -> list[Itinerary]:
        if not self.remote_engine_url:
            raise RuntimeError(
                "TRACK_ENGINE_URL is not configured. Routing now runs only in the "
                "standalone C++ TrackEngine service."
            )

        payload = self._remote_payload(request)
        with httpx.Client(timeout=self.remote_engine_timeout_s) as client:
            response = client.post(f"{self.remote_engine_url}/plan", json=payload)
            response.raise_for_status()
            data = response.json()
        remote_version = data.get("engine_version")
        if remote_version:
            self._last_remote_engine_version = str(remote_version)

        return [self._parse_itinerary(item) for item in data.get("itineraries", [])]

    def _remote_go(self, request: PlanRequest, *, now_ts: int) -> GoResponse:
        if not self.remote_engine_url:
            raise RuntimeError(
                "TRACK_ENGINE_URL is not configured. Routing now runs only in the "
                "standalone C++ TrackEngine service."
            )

        payload = self._remote_payload(request, now_ts=now_ts)
        with httpx.Client(timeout=self.remote_engine_timeout_s) as client:
            response = client.post(f"{self.remote_engine_url}/go", json=payload)
            response.raise_for_status()
            data = response.json()
        remote_version = data.get("engine_version")
        if remote_version:
            self._last_remote_engine_version = str(remote_version)

        return GoResponse(
            engine_version=str(data["engine_version"]),
            requested_at_ts=int(data["requested_at_ts"]),
            now_ts=int(data["now_ts"]),
            origin=request.origin,
            destination=request.destination,
            session_kind=str(data["session_kind"]),
            primary_trip=(
                self._parse_go_trip(data["primary_trip"])
                if data.get("primary_trip") is not None
                else None
            ),
            alternatives=[
                self._parse_go_trip(item) for item in data.get("alternatives", [])
            ],
        )

    def _normalize_route_key(self, value: str | None) -> str:
        if not value:
            return ""
        route_key = value.upper().strip()
        if "_" in route_key:
            route_key = route_key.split("_")[-1]
        return route_key.replace(" ", "")

    def _route_keys_for_leg(self, leg: TransitLeg) -> tuple[str, ...]:
        keys = {
            self._normalize_route_key(leg.route_id),
            self._normalize_route_key(leg.route_name),
        }
        return tuple(sorted(key for key in keys if key))

    def _severity_rank(self, severity: str) -> int:
        normalized = severity.strip().lower()
        if normalized == "severe":
            return 2
        if normalized == "warning":
            return 1
        return 0

    def _dedupe_alerts(
        self,
        alerts: list[ServiceAlertSummary],
        *,
        limit: int | None = None,
    ) -> list[ServiceAlertSummary]:
        ordered = sorted(
            alerts,
            key=lambda alert: (
                -self._severity_rank(alert.severity),
                -(alert.active_period_end or 0),
                alert.title,
                alert.route_id or "",
            ),
        )
        deduped: list[ServiceAlertSummary] = []
        seen: set[tuple[str, str | None, str]] = set()
        for alert in ordered:
            key = (alert.title, alert.route_id, alert.mode)
            if key in seen:
                continue
            seen.add(key)
            deduped.append(alert)
            if limit is not None and len(deduped) >= limit:
                break
        return deduped

    async def _run_with_timeout(self, awaitable, timeout_s: float, fallback):
        try:
            return await asyncio.wait_for(awaitable, timeout=timeout_s)
        except Exception:
            return fallback

    async def _load_alert_index(
        self,
        transit_legs: list[TransitLeg],
    ) -> dict[str, list[ServiceAlertSummary]]:
        if not transit_legs:
            return {}

        from app.services.gtfs.realtime_parser import get_alerts

        raw_alerts = await self._run_with_timeout(
            get_alerts(),
            self.alert_timeout_s,
            [],
        )
        index: dict[str, list[ServiceAlertSummary]] = {}
        for alert in raw_alerts:
            summary = ServiceAlertSummary(
                route_id=alert.route_id,
                severity=alert.severity,
                title=alert.title,
                description=alert.description,
                mode=alert.mode,
                alert_type=alert.alert_type,
                active_period_end=alert.active_period_end,
            )
            route_keys = {
                self._normalize_route_key(alert.route_id),
                *(
                    self._normalize_route_key(route_id)
                    for route_id in alert.affected_routes
                ),
            }
            for route_key in route_keys:
                if not route_key:
                    continue
                index.setdefault(route_key, []).append(summary)
        return {
            route_key: self._dedupe_alerts(alerts, limit=4)
            for route_key, alerts in index.items()
        }

    async def _load_subway_arrivals(
        self,
        transit_legs: list[TransitLeg],
    ) -> dict[str, list[Any]]:
        from app.services.gtfs.realtime_parser import get_arrivals_for_line

        requested_lines = sorted(
            {
                (leg.route_name or leg.route_id).strip()
                for leg in transit_legs
                if leg.mode == "subway" and (leg.route_name or leg.route_id)
            }
        )
        if not requested_lines:
            return {}

        results = await asyncio.gather(
            *[
                self._run_with_timeout(
                    get_arrivals_for_line(line_id),
                    self.realtime_timeout_s,
                    [],
                )
                for line_id in requested_lines
            ]
        )
        arrivals_by_key: dict[str, list[Any]] = {}
        for arrivals in results:
            for arrival in arrivals:
                route_key = self._normalize_route_key(arrival.route_id)
                if route_key:
                    arrivals_by_key.setdefault(route_key, []).append(arrival)
        return arrivals_by_key

    async def _load_rail_arrivals(
        self,
        transit_legs: list[TransitLeg],
    ) -> dict[str, list[Any]]:
        from app.clients.rail_client import fetch_rail_arrivals

        agencies = [
            agency
            for agency in ("lirr", "mnr")
            if any(leg.mode == agency for leg in transit_legs)
        ]
        if not agencies:
            return {}

        agency_lookup = {
            "lirr": "lirr",
            "mnr": "metro_north",
        }
        results = await asyncio.gather(
            *[
                self._run_with_timeout(
                    fetch_rail_arrivals(agency_lookup[agency]),
                    self.realtime_timeout_s,
                    [],
                )
                for agency in agencies
            ]
        )
        return dict(zip(agencies, results, strict=False))

    async def _load_bus_arrivals(
        self,
        transit_legs: list[TransitLeg],
    ) -> dict[str, list[Any]]:
        from app.clients.bus_client import get_realtime_arrivals

        stop_ids = sorted(
            {
                leg.board_stop_id
                for leg in transit_legs
                if leg.mode == "bus" and leg.board_stop_id
            }
        )
        if not stop_ids:
            return {}

        results = await asyncio.gather(
            *[
                self._run_with_timeout(
                    get_realtime_arrivals(stop_id),
                    self.realtime_timeout_s,
                    [],
                )
                for stop_id in stop_ids
            ]
        )
        return dict(zip(stop_ids, results, strict=False))

    def _closest_track_arrival(
        self,
        arrivals: list[Any],
        *,
        stop_id: str,
        scheduled_ts: int,
        trip_id: str | None,
        route_keys: set[str],
    ):
        candidates = []
        if trip_id:
            candidates = [
                arrival
                for arrival in arrivals
                if arrival.station == stop_id and arrival.trip_id == trip_id
            ]
        if not candidates:
            candidates = [
                arrival
                for arrival in arrivals
                if arrival.station == stop_id
                and self._normalize_route_key(arrival.route_id) in route_keys
            ]
        if not candidates:
            return None
        best = min(
            candidates,
            key=lambda arrival: abs((arrival.arrival_ts or scheduled_ts) - scheduled_ts),
        )
        if abs((best.arrival_ts or scheduled_ts) - scheduled_ts) > 45 * 60:
            return None
        return best

    def _build_track_live_status(
        self,
        leg: TransitLeg,
        arrivals: list[Any],
        *,
        source: str,
    ) -> LegLiveStatus:
        route_keys = set(self._route_keys_for_leg(leg))
        board_match = self._closest_track_arrival(
            arrivals,
            stop_id=leg.board_stop_id,
            scheduled_ts=leg.departure_ts,
            trip_id=leg.trip_id,
            route_keys=route_keys,
        )
        alight_match = self._closest_track_arrival(
            arrivals,
            stop_id=leg.alight_stop_id,
            scheduled_ts=leg.arrival_ts,
            trip_id=leg.trip_id,
            route_keys=route_keys,
        )
        if board_match is None and alight_match is None:
            return LegLiveStatus(source=source, status="no_data")

        predicted_departure_ts = board_match.arrival_ts if board_match is not None else None
        predicted_arrival_ts = alight_match.arrival_ts if alight_match is not None else None
        if predicted_arrival_ts is None and predicted_departure_ts is not None:
            predicted_arrival_ts = predicted_departure_ts + leg.duration_s

        delay_s = None
        if predicted_departure_ts is not None:
            delay_s = predicted_departure_ts - leg.departure_ts
        elif predicted_arrival_ts is not None:
            delay_s = predicted_arrival_ts - leg.arrival_ts

        status_text = (
            board_match.status
            if board_match is not None
            else alight_match.status if alight_match is not None else None
        )
        if (
            (board_match is not None and board_match.is_cancelled)
            or (alight_match is not None and alight_match.is_cancelled)
        ):
            status = "cancelled"
            status_text = "Cancelled"
        elif delay_s is not None and delay_s > 120:
            status = "delayed"
        else:
            status = "live"

        return LegLiveStatus(
            source=source,
            status=status,
            predicted_departure_ts=predicted_departure_ts,
            predicted_arrival_ts=predicted_arrival_ts,
            delay_s=delay_s,
            status_text=status_text,
            is_realtime=True,
            matched_trip_id=(
                board_match.trip_id
                if board_match is not None
                else alight_match.trip_id if alight_match is not None else None
            ),
        )

    def _build_bus_live_status(
        self,
        leg: TransitLeg,
        arrivals: list[Any],
    ) -> LegLiveStatus:
        route_keys = set(self._route_keys_for_leg(leg))
        candidates = []
        for arrival in arrivals:
            route_key = self._normalize_route_key(arrival.route_id)
            if route_key not in route_keys or arrival.expected_arrival is None:
                continue
            predicted_departure_ts = int(arrival.expected_arrival.timestamp())
            candidates.append((arrival, predicted_departure_ts))

        if not candidates:
            return LegLiveStatus(source="bus_siri", status="no_data")

        match, predicted_departure_ts = min(
            candidates,
            key=lambda item: abs(item[1] - leg.departure_ts),
        )
        if abs(predicted_departure_ts - leg.departure_ts) > 45 * 60:
            return LegLiveStatus(source="bus_siri", status="no_data")

        delay_s = (
            match.schedule_deviation_s
            if match.schedule_deviation_s is not None
            else predicted_departure_ts - leg.departure_ts
        )
        predicted_arrival_ts = (
            leg.arrival_ts + delay_s if delay_s is not None else None
        )
        status = "scheduled" if match.is_realtime is False else "live"
        if delay_s is not None and delay_s > 120:
            status = "delayed"

        return LegLiveStatus(
            source="bus_siri",
            status=status,
            predicted_departure_ts=predicted_departure_ts,
            predicted_arrival_ts=predicted_arrival_ts,
            delay_s=delay_s,
            status_text=match.status_text,
            is_realtime=match.is_realtime,
            matched_trip_id=None,
        )

    def _alerts_for_leg(
        self,
        leg: TransitLeg,
        alerts_by_key: dict[str, list[ServiceAlertSummary]],
    ) -> list[ServiceAlertSummary]:
        alerts: list[ServiceAlertSummary] = []
        for route_key in self._route_keys_for_leg(leg):
            alerts.extend(alerts_by_key.get(route_key, []))
        return self._dedupe_alerts(alerts, limit=2)

    def _disruption_level(
        self,
        trip: GoTrip,
    ) -> str:
        transit_legs = [leg for leg in trip.itinerary.legs if leg.mode != "walk"]
        if any(
            leg.live_status is not None and leg.live_status.status == "cancelled"
            for leg in transit_legs
        ) or any(
            self._severity_rank(alert.severity) >= 2 for alert in trip.service_alerts
        ):
            return "disrupted"
        if any(
            leg.live_status is not None
            and leg.live_status.status in {"delayed", "scheduled", "no_data"}
            for leg in transit_legs
        ) or any(self._severity_rank(alert.severity) >= 1 for alert in trip.service_alerts):
            return "watch"
        return "normal"

    def _reliability_score(self, trip: GoTrip) -> int:
        transit_legs = [leg for leg in trip.itinerary.legs if leg.mode != "walk"]
        score = 100 - trip.itinerary.transfer_count * 8
        for leg in transit_legs:
            live_status = leg.live_status
            if live_status is None or live_status.status == "no_data":
                score -= 4
            elif live_status.status == "scheduled":
                score -= 6
            elif live_status.status == "delayed":
                score -= min(
                    24,
                    max(6, int(max(live_status.delay_s or 0, 0) / 60) * 2),
                )
            elif live_status.status == "cancelled":
                score -= 45
        for alert in trip.service_alerts:
            if alert.severity == "severe":
                score -= 18
            elif alert.severity == "warning":
                score -= 8
        return max(0, min(100, score))

    def _ranking_score(self, trip: GoTrip) -> float:
        score = (
            float(trip.itinerary.total_duration_s)
            + trip.itinerary.transfer_count * 480.0
            + trip.itinerary.walking_s * 0.45
            + trip.itinerary.waiting_s * 0.25
        )
        for leg in trip.itinerary.legs:
            if leg.mode == "walk":
                continue
            live_status = leg.live_status
            if live_status is None or live_status.status == "no_data":
                score += 120.0
                continue
            if live_status.status == "scheduled":
                score += 180.0
            elif live_status.status == "delayed":
                score += max(180.0, float(max(live_status.delay_s or 0, 0)))
            elif live_status.status == "cancelled":
                score += 1_800.0
        for alert in trip.service_alerts:
            if alert.severity == "severe":
                score += 900.0
            elif alert.severity == "warning":
                score += 300.0
        return round(score, 2)

    def _enrich_trip(
        self,
        trip: GoTrip,
        *,
        alerts_by_key: dict[str, list[ServiceAlertSummary]],
        subway_arrivals_by_key: dict[str, list[Any]],
        rail_arrivals_by_mode: dict[str, list[Any]],
        bus_arrivals_by_stop: dict[str, list[Any]],
    ) -> GoTrip:
        for leg in trip.itinerary.legs:
            if leg.mode == "walk":
                continue
            leg.alerts = self._alerts_for_leg(leg, alerts_by_key)
            if leg.mode == "subway":
                arrivals: list[Any] = []
                for route_key in self._route_keys_for_leg(leg):
                    arrivals.extend(subway_arrivals_by_key.get(route_key, []))
                leg.live_status = self._build_track_live_status(
                    leg,
                    arrivals,
                    source="subway_gtfs_rt",
                )
            elif leg.mode in {"lirr", "mnr"}:
                leg.live_status = self._build_track_live_status(
                    leg,
                    rail_arrivals_by_mode.get(leg.mode, []),
                    source="rail_gtfs_rt",
                )
            elif leg.mode == "bus":
                leg.live_status = self._build_bus_live_status(
                    leg,
                    bus_arrivals_by_stop.get(leg.board_stop_id, []),
                )

        trip.service_alerts = self._dedupe_alerts(
            [
                alert
                for leg in trip.itinerary.legs
                if leg.mode != "walk"
                for alert in leg.alerts
            ],
            limit=4,
        )
        trip.reliability_score = self._reliability_score(trip)
        trip.disruption_level = self._disruption_level(trip)
        trip.ranking_score = self._ranking_score(trip)
        return trip

    async def _enrich_go_response(self, response: GoResponse) -> GoResponse:
        trips = [
            trip
            for trip in [response.primary_trip, *response.alternatives]
            if trip is not None
        ]
        if not trips:
            return response

        transit_legs = [
            leg
            for trip in trips
            for leg in trip.itinerary.legs
            if leg.mode != "walk"
        ]
        if not transit_legs:
            for trip in trips:
                trip.reliability_score = self._reliability_score(trip)
                trip.disruption_level = self._disruption_level(trip)
                trip.ranking_score = self._ranking_score(trip)
            response.primary_trip = trips[0]
            response.alternatives = trips[1:]
            return response

        (
            alerts_by_key,
            subway_arrivals_by_key,
            rail_arrivals_by_mode,
            bus_arrivals_by_stop,
        ) = await asyncio.gather(
            self._load_alert_index(transit_legs),
            self._load_subway_arrivals(transit_legs),
            self._load_rail_arrivals(transit_legs),
            self._load_bus_arrivals(transit_legs),
        )

        ranked_trips = sorted(
            [
                self._enrich_trip(
                    trip,
                    alerts_by_key=alerts_by_key,
                    subway_arrivals_by_key=subway_arrivals_by_key,
                    rail_arrivals_by_mode=rail_arrivals_by_mode,
                    bus_arrivals_by_stop=bus_arrivals_by_stop,
                )
                for trip in trips
            ],
            key=lambda trip: (
                trip.ranking_score,
                trip.itinerary.arrive_at_ts,
                trip.itinerary.transfer_count,
                trip.itinerary.walk_meters,
            ),
        )
        response.primary_trip = ranked_trips[0]
        response.alternatives = ranked_trips[1:]
        return response

    def go(self, request: PlanRequest, *, now_ts: int | None = None) -> GoResponse:
        session_now_ts = now_ts or int(time.time())
        response = self._remote_go(request, now_ts=session_now_ts)
        if self.enable_realtime_enrichment:
            with suppress(Exception):
                response = asyncio.run(self._enrich_go_response(response))
        if request.user_id and request.record_recent and response.primary_trip is not None:
            self.store.record_recent_trip(
                request.user_id,
                origin_label=request.origin.label,
                origin_lat=request.origin.lat or 0.0,
                origin_lon=request.origin.lon or 0.0,
                destination_label=request.destination.label,
                destination_lat=request.destination.lat or 0.0,
                destination_lon=request.destination.lon or 0.0,
                itinerary=response.primary_trip.itinerary,
            )
        return response

    def search(
        self,
        *,
        query: str,
        user_id: str | None = None,
        near_lat: float | None = None,
        near_lon: float | None = None,
        limit: int = 12,
    ) -> list[SearchResult]:
        self.prepare()
        lowered = query.strip().lower()
        if not lowered:
            return []

        merged: dict[tuple[str, int, int], SearchResult] = {}

        def add_result(result: SearchResult) -> None:
            key = (
                result.label.lower(),
                round(result.lat * 10_000),
                round(result.lon * 10_000),
            )
            existing = merged.get(key)
            if existing is None or result.score > existing.score:
                merged[key] = result

        if user_id:
            for place in self.store.list_saved_places(user_id):
                haystack = " ".join(
                    part for part in (place.label, place.kind, place.address or "") if part
                ).lower()
                if lowered not in haystack:
                    continue
                score = 110.0 if place.label.lower().startswith(lowered) else 95.0
                add_result(
                    SearchResult(
                        source="saved_place",
                        label=place.label,
                        subtitle=place.address or place.kind.title(),
                        lat=place.lat,
                        lon=place.lon,
                        score=score,
                        place_id=place.place_id,
                        icon=place.icon,
                    )
                )

            for recent in self.store.list_recent_destinations(user_id, limit=limit):
                if lowered not in recent.label.lower():
                    continue
                score = 80.0 + min(20.0, recent.trip_count * 4.0)
                add_result(
                    SearchResult(
                        source="recent_destination",
                        label=recent.label,
                        subtitle=f"Recent trip x{recent.trip_count}",
                        lat=recent.lat,
                        lon=recent.lon,
                        score=score,
                    )
                )

        try:
            stop_results = self.repository.search_stops(query, limit=limit * 2)
        except sqlite3.Error:
            stop_results = []

        for stop in stop_results:
            distance_bonus = 0.0
            subtitle = "Transit stop"
            if near_lat is not None and near_lon is not None:
                distance = haversine_m(near_lat, near_lon, stop.lat, stop.lon)
                distance_bonus = max(0.0, 10.0 - min(distance / 200.0, 10.0))
                subtitle = f"Transit stop • {round(distance)}m away"
            add_result(
                SearchResult(
                    source="stop",
                    label=stop.stop_name,
                    subtitle=subtitle,
                    lat=stop.lat,
                    lon=stop.lon,
                    score=60.0 + distance_bonus,
                    stop_id=stop.stop_id,
                )
            )

        results = list(merged.values())
        results.sort(key=lambda item: (-item.score, item.label.lower()))
        return results[:limit]

    def list_saved_places(self, user_id: str) -> list[SavedPlace]:
        return self.store.list_saved_places(user_id)

    def upsert_saved_place(
        self,
        *,
        user_id: str,
        label: str,
        kind: str,
        lat: float,
        lon: float,
        address: str | None = None,
        icon: str | None = None,
        place_id: int | None = None,
    ) -> SavedPlace:
        return self.store.upsert_saved_place(
            user_id=user_id,
            label=label,
            kind=kind,
            lat=lat,
            lon=lon,
            address=address,
            icon=icon,
            place_id=place_id,
        )

    def delete_saved_place(self, user_id: str, place_id: int) -> None:
        self.store.delete_saved_place(user_id, place_id)

    def list_saved_trips(self, user_id: str) -> list[SavedTrip]:
        return self.store.list_saved_trips(user_id)

    def upsert_saved_trip(
        self,
        *,
        user_id: str,
        name: str,
        origin_label: str,
        origin_lat: float,
        origin_lon: float,
        destination_label: str,
        destination_lat: float,
        destination_lon: float,
        preferred_departure_hour: int | None,
        preferred_arrival_hour: int | None,
        preferred_modes: tuple[str, ...],
        trip_id: int | None = None,
    ) -> SavedTrip:
        return self.store.upsert_saved_trip(
            user_id=user_id,
            name=name,
            origin_label=origin_label,
            origin_lat=origin_lat,
            origin_lon=origin_lon,
            destination_label=destination_label,
            destination_lat=destination_lat,
            destination_lon=destination_lon,
            preferred_departure_hour=preferred_departure_hour,
            preferred_arrival_hour=preferred_arrival_hour,
            preferred_modes=preferred_modes,
            trip_id=trip_id,
        )

    def delete_saved_trip(self, user_id: str, trip_id: int) -> None:
        self.store.delete_saved_trip(user_id, trip_id)

    def list_recent_trips(self, user_id: str, limit: int = 20) -> list[RecentTrip]:
        return self.store.list_recent_trips(user_id, limit=limit)

    def replace_calendar_events(
        self,
        *,
        user_id: str,
        events: list[CalendarEvent],
    ) -> list[CalendarEvent]:
        return self.store.replace_calendar_events(user_id, events)

    def recommendations(
        self,
        *,
        user_id: str,
        origin: LocationInput | None = None,
        limit: int = 6,
        now_ts: int | None = None,
    ) -> list[Recommendation]:
        now_ts = now_ts or int(time.time())
        saved_places = self.store.list_saved_places(user_id)
        saved_trips = self.store.list_saved_trips(user_id)
        recent_destinations = self.store.list_recent_destinations(user_id, limit=20)
        events = self.store.list_calendar_events(
            user_id,
            starts_after=now_ts - 3600,
            starts_before=now_ts + 86_400,
            limit=20,
        )

        candidates: dict[tuple[int, int], Recommendation] = {}

        def add_candidate(candidate: Recommendation) -> None:
            key = (
                round(candidate.lat * 10_000),
                round(candidate.lon * 10_000),
            )
            existing = candidates.get(key)
            if existing is None or candidate.score > existing.score:
                candidates[key] = candidate

        current_hour = hour_of_day(now_ts)
        current_weekday = weekday_index(now_ts)

        for place in saved_places:
            if (
                origin
                and origin.lat is not None
                and origin.lon is not None
                and haversine_m(origin.lat, origin.lon, place.lat, place.lon) < 90
            ):
                continue
            score = 25.0
            reason = "Saved place"
            if place.kind == "work" and current_weekday < 5 and current_hour < 11:
                score += 18.0
                reason = "Morning commute to work"
            elif place.kind == "home" and current_hour >= 16:
                score += 16.0
                reason = "Likely trip back home"
            elif place.kind == "school" and current_weekday < 5 and current_hour < 10:
                score += 14.0
                reason = "School commute"
            add_candidate(
                Recommendation(
                    source="saved_place",
                    label=place.label,
                    subtitle=place.address or place.kind.title(),
                    lat=place.lat,
                    lon=place.lon,
                    score=score,
                    reason=reason,
                    place_id=place.place_id,
                )
            )

        for saved_trip in saved_trips:
            if origin and origin.lat is not None and origin.lon is not None:
                origin_distance = haversine_m(
                    origin.lat,
                    origin.lon,
                    saved_trip.origin_lat,
                    saved_trip.origin_lon,
                )
            else:
                origin_distance = 0.0
            score = 40.0
            if origin_distance < 250:
                score += 22.0
            if (
                saved_trip.preferred_departure_hour is not None
                and abs(saved_trip.preferred_departure_hour - current_hour) <= 2
            ):
                score += 14.0
            add_candidate(
                Recommendation(
                    source="saved_trip",
                    label=saved_trip.destination_label,
                    subtitle=saved_trip.name,
                    lat=saved_trip.destination_lat,
                    lon=saved_trip.destination_lon,
                    score=score,
                    reason="Saved trip",
                    saved_trip_id=saved_trip.trip_id,
                )
            )

        for recent in recent_destinations:
            if (
                origin
                and origin.lat is not None
                and origin.lon is not None
                and haversine_m(origin.lat, origin.lon, recent.lat, recent.lon) < 90
            ):
                continue
            hours_ago = max(1.0, (now_ts - recent.last_used_at) / 3600.0)
            recency_bonus = max(0.0, 24.0 - min(hours_ago, 24.0))
            score = 35.0 + min(36.0, recent.trip_count * 6.0) + recency_bonus
            add_candidate(
                Recommendation(
                    source="recent_trip",
                    label=recent.label,
                    subtitle=f"Recent trip x{recent.trip_count}",
                    lat=recent.lat,
                    lon=recent.lon,
                    score=score,
                    reason="Frequent recent destination",
                )
            )

        for event in events:
            if event.lat is None or event.lon is None:
                continue
            if (
                origin
                and origin.lat is not None
                and origin.lon is not None
                and haversine_m(origin.lat, origin.lon, event.lat, event.lon) < 90
            ):
                continue
            minutes_until = max(0, int((event.starts_at - now_ts) / 60))
            score = 120.0 - min(80.0, minutes_until / 6.0)
            add_candidate(
                Recommendation(
                    source="calendar",
                    label=event.location_label,
                    subtitle=event.title,
                    lat=event.lat,
                    lon=event.lon,
                    score=score,
                    reason="Upcoming calendar event",
                    upcoming_at=event.starts_at,
                )
            )

        ordered = sorted(
            candidates.values(),
            key=lambda candidate: (-candidate.score, candidate.label.lower()),
        )
        return ordered[:limit]

    def plan(self, request: PlanRequest):
        itineraries = self._remote_plan(request)
        if request.user_id and request.record_recent and itineraries:
            self.store.record_recent_trip(
                request.user_id,
                origin_label=request.origin.label,
                origin_lat=request.origin.lat or 0.0,
                origin_lon=request.origin.lon or 0.0,
                destination_label=request.destination.label,
                destination_lat=request.destination.lat or 0.0,
                destination_lon=request.destination.lon or 0.0,
                itinerary=itineraries[0],
            )
        return itineraries
