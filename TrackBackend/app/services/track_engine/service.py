"""Backend helper service for Track state/search plus remote C++ routing."""

from __future__ import annotations

import asyncio
import gzip
import math
import os
import shutil
import sqlite3
import tempfile
import threading
import time
import contextlib
from contextlib import suppress
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from datetime import time as time_value
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import aiosqlite
import httpx
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

from app.config import get_settings

from .domain import (
    CalendarEvent,
    EnvironmentalImpact,
    FareEstimate,
    GoAction,
    GoResponse,
    GoStep,
    GoTransfer,
    GoTrip,
    HealthStatus,
    Itinerary,
    LegFare,
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
from .engine_cache import get_cached_go, get_cached_plan, set_cached_go, set_cached_plan
from app.utils.brand import (
    bus_color as _brand_bus_color,
    mode_color as _brand_mode_color,
    subway_color as _brand_subway_color,
)

NY_TZ = ZoneInfo("America/New_York")

# ── Crowding lookup tables ──────────────────────────────────────────
# Index = hour (0-23).  O(1) array lookup, no branching.
# Levels: "empty" / "some" / "busy" / "very_busy"
#
# fmt: off
_CROWDING_SUBWAY_WEEKDAY: list[str] = [
    #  0       1       2       3       4       5       6
    "empty","empty","empty","empty","empty","empty","empty",
    #  7           8            9
    "very_busy","very_busy","very_busy",
    # 10     11     12     13     14     15
    "some","some","some","some","some","some",
    # 16          17           18
    "very_busy","very_busy","very_busy",
    # 19     20     21
    "some","some","some",
    # 22      23
    "empty","empty",
]
_CROWDING_SUBWAY_WEEKEND: list[str] = [
    "empty","empty","empty","empty","empty","empty","empty",  # 0-6
    "empty","empty","empty","empty",                          # 7-10
    "some","some","some","some","some","some","some","some","some",  # 11-19
    "busy","busy","busy",                                     # 20-22
    "empty",                                                  # 23
]
_CROWDING_BUS_WEEKDAY: list[str] = [
    "empty","empty","empty","empty","empty","empty","empty",  # 0-6
    "busy","busy",                                            # 7-8
    "some","some","some","some","some","some","some",          # 9-15
    "busy","busy","busy",                                     # 16-18
    "empty","empty","empty","empty","empty",                   # 19-23
]
_CROWDING_BUS_WEEKEND: list[str] = [
    "empty","empty","empty","empty","empty","empty","empty",  # 0-6
    "empty","empty","empty",                                  # 7-9
    "some","some","some","some","some","some","some","some","some",  # 10-18
    "empty","empty","empty","empty","empty",                  # 19-23
]
_CROWDING_RAIL_WEEKDAY: list[str] = [
    "some","some","some","some","some","some",                # 0-5
    "very_busy","very_busy","very_busy","very_busy",          # 6-9
    "some","some","some","some","some","some",                # 10-15
    "very_busy","very_busy","very_busy","very_busy",          # 16-19
    "some","some","some","some",                              # 20-23
]
_CROWDING_RAIL_WEEKEND: list[str] = ["some"] * 24

# Nested dict: mode → is_weekday → 24-element hour list
_CROWDING: dict[str, dict[bool, list[str]]] = {
    "subway": {True: _CROWDING_SUBWAY_WEEKDAY, False: _CROWDING_SUBWAY_WEEKEND},
    "bus":    {True: _CROWDING_BUS_WEEKDAY,    False: _CROWDING_BUS_WEEKEND},
    "lirr":   {True: _CROWDING_RAIL_WEEKDAY,   False: _CROWDING_RAIL_WEEKEND},
    "mnr":    {True: _CROWDING_RAIL_WEEKDAY,   False: _CROWDING_RAIL_WEEKEND},
}
# fmt: on


@dataclass(slots=True)
class StopRecord:
    stop_id: str
    stop_name: str
    lat: float
    lon: float


@dataclass(frozen=True, slots=True)
class ScheduleWindow:
    start_date: date
    end_date: date


@dataclass(frozen=True, slots=True)
class RemotePayloadContext:
    payload: dict[str, Any]
    schedule_note: str | None = None
    timestamp_shift_s: int = 0


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


def bounding_box_degrees(radius_m: float, center_lat: float) -> tuple[float, float]:
    """Return latitude/longitude deltas that bound a circle of *radius_m*."""

    lat_delta = radius_m / 111_000.0
    lon_divisor = 111_320.0 * math.cos(math.radians(center_lat))
    lon_delta = lat_delta if abs(lon_divisor) < 1e-9 else radius_m / lon_divisor
    return lat_delta, lon_delta


def parse_gtfs_date(value: str | None) -> date | None:
    """Parse YYYYMMDD GTFS dates from calendar/calendar_dates rows."""

    if not value:
        return None
    cleaned = str(value).replace("-", "").strip()
    if len(cleaned) != 8 or not cleaned.isdigit():
        return None
    try:
        return date(
            int(cleaned[0:4]),
            int(cleaned[4:6]),
            int(cleaned[6:8]),
        )
    except ValueError:
        return None


def hour_of_day(timestamp_s: int) -> int:
    return datetime.fromtimestamp(timestamp_s, NY_TZ).hour


def weekday_index(timestamp_s: int) -> int:
    return datetime.fromtimestamp(timestamp_s, NY_TZ).weekday()


def service_date_for_timestamp(timestamp_s: int):
    return datetime.fromtimestamp(timestamp_s, NY_TZ).date()


class ScheduleRepository:
    """Async SQLite helper for stop search and engine health.

    Uses ``aiosqlite`` so queries run in a background thread and never block
    the asyncio event loop.  The ``ensure_query_indexes`` method stays
    synchronous because it is called once at startup (before any event loop
    may be running).
    """

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
        self._prepare_error: str | None = None
        self._prepare_lock = threading.Lock()
        self._service_window_lock = threading.Lock()
        self._service_window_cache: dict[str, ScheduleWindow | None] = {}

    def _connect_sync(self) -> sqlite3.Connection:
        """Synchronous connection — used only for startup index creation."""
        conn = sqlite3.connect(self.db_path, timeout=30, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        return conn

    async def _connect(self) -> aiosqlite.Connection:
        """Standalone connection — only used when pool is unavailable."""
        conn = await aiosqlite.connect(str(self.db_path), timeout=30)
        conn.row_factory = aiosqlite.Row
        return conn

    @contextlib.asynccontextmanager
    async def _acquire(self):
        """Borrow a pooled connection; falls back to standalone connect."""
        from app.services.transit.db_pool import schedule_pool
        async with schedule_pool.acquire() as conn:
            yield conn

    def ensure_query_indexes(self) -> None:
        with self._prepare_lock:
            if self._prepared:
                return
            self._prepare_error = None
            conn = self._connect_sync()
            try:
                for sql in self._INDEXES.values():
                    try:
                        conn.execute(sql)
                    except sqlite3.OperationalError:
                        continue
                    except sqlite3.Error as exc:
                        self._prepare_error = str(exc)
                        self._prepared = False
                        return
                conn.commit()
            except sqlite3.Error as exc:
                self._prepare_error = str(exc)
                self._prepared = False
                return
            finally:
                conn.close()
            self._prepared = True
            self._prepare_error = None

    @property
    def prepared(self) -> bool:
        return self._prepared

    @property
    def prepare_error(self) -> str | None:
        return self._prepare_error

    @property
    def prepared_index_names(self) -> tuple[str, ...]:
        return tuple(self._INDEXES)

    async def search_stops(self, query: str, limit: int = 12) -> list[StopRecord]:
        lowered = query.strip().lower()
        if not lowered:
            return []
        async with self._acquire() as conn:
            try:
                cursor = await conn.execute(
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
                )
                rows = await cursor.fetchall()
            except sqlite3.OperationalError as exc:
                if "no such table" in str(exc).lower():
                    return []
                raise
        return [
            StopRecord(
                stop_id=str(row["stop_id"]),
                stop_name=str(row["stop_name"]),
                lat=float(row["stop_lat"]),
                lon=float(row["stop_lon"]),
            )
            for row in rows
        ]

    @staticmethod
    def _route_filter_sql(mode: str) -> str | None:
        metro_north_branches = (
            "'hudson', 'harlem', 'new haven', 'new canaan', "
            "'danbury', 'waterbury'"
        )
        if mode == "bus":
            return "(r.route_type = 3 OR (r.route_type >= 700 AND r.route_type <= 799))"
        if mode == "subway":
            return "(r.route_type = 1 OR r.route_id IN ('SI', 'SIR'))"
        if mode == "mnr":
            return (
                "r.route_type = 2 AND lower(coalesce(r.route_long_name, '')) "
                f"IN ({metro_north_branches})"
            )
        if mode == "lirr":
            return (
                "r.route_type = 2 AND lower(coalesce(r.route_long_name, '')) "
                f"NOT IN ({metro_north_branches})"
            )
        return None

    @staticmethod
    def _stop_mode_filter_sql(mode: str) -> str | None:
        if mode == "bus":
            return "(sm.route_type = 3 OR (sm.route_type >= 700 AND sm.route_type <= 799))"
        if mode == "subway":
            return "(sm.route_type = 1)"
        if mode in {"lirr", "mnr"}:
            return "(sm.route_type = 2)"
        return None

    async def service_window_for_mode(self, mode: str) -> ScheduleWindow | None:
        normalized = mode.strip().lower()
        with self._service_window_lock:
            if normalized in self._service_window_cache:
                return self._service_window_cache[normalized]

        route_filter = self._route_filter_sql(normalized)
        if route_filter is None:
            return None

        async with self._acquire() as conn:
            try:
                cursor = await conn.execute(
                    f"""
                    WITH mode_service_ids AS (
                        SELECT DISTINCT t.service_id
                        FROM trips t
                        JOIN routes r ON r.route_id = t.route_id
                        WHERE {route_filter}
                    ),
                    ranges AS (
                        SELECT c.start_date AS start_date, c.end_date AS end_date
                        FROM calendar c
                        JOIN mode_service_ids ms ON ms.service_id = c.service_id
                        UNION ALL
                        SELECT cd.date AS start_date, cd.date AS end_date
                        FROM calendar_dates cd
                        JOIN mode_service_ids ms ON ms.service_id = cd.service_id
                        WHERE cd.exception_type = 1
                    )
                    SELECT MIN(start_date) AS earliest, MAX(end_date) AS latest
                    FROM ranges
                    """
                )
                row = await cursor.fetchone()
            except sqlite3.OperationalError:
                row = None

        window: ScheduleWindow | None = None
        if row is not None:
            start_date = parse_gtfs_date(row["earliest"])
            end_date = parse_gtfs_date(row["latest"])
            if start_date is not None and end_date is not None:
                window = ScheduleWindow(start_date=start_date, end_date=end_date)

        with self._service_window_lock:
            self._service_window_cache[normalized] = window
        return window

    async def has_nearby_stop_for_mode(
        self,
        *,
        lat: float,
        lon: float,
        radius_m: int,
        mode: str,
    ) -> bool:
        route_filter = self._stop_mode_filter_sql(mode.strip().lower())
        normalized_mode = mode.strip().lower()
        if route_filter is None:
            return False

        lat_delta, lon_delta = bounding_box_degrees(radius_m, lat)
        async with self._acquire() as conn:
            try:
                cursor = await conn.execute(
                    f"""
                    SELECT s.stop_lat, s.stop_lon
                    FROM stops s
                    JOIN stop_modes sm ON sm.stop_id = s.stop_id
                    WHERE s.stop_lat BETWEEN ? AND ?
                      AND s.stop_lon BETWEEN ? AND ?
                      AND {route_filter}
                    LIMIT 200
                    """,
                    (
                        lat - lat_delta,
                        lat + lat_delta,
                        lon - lon_delta,
                        lon + lon_delta,
                    ),
                )
                rows = await cursor.fetchall()
            except sqlite3.OperationalError:
                route_join_filter = self._route_filter_sql(normalized_mode)
                if route_join_filter is None:
                    return False
                cursor = await conn.execute(
                    f"""
                    SELECT DISTINCT s.stop_lat, s.stop_lon
                    FROM stops s
                    JOIN stop_times st ON st.stop_id = s.stop_id
                    JOIN trips t ON t.trip_id = st.trip_id
                    JOIN routes r ON r.route_id = t.route_id
                    WHERE s.stop_lat BETWEEN ? AND ?
                      AND s.stop_lon BETWEEN ? AND ?
                      AND {route_join_filter}
                    LIMIT 200
                    """,
                    (
                        lat - lat_delta,
                        lat + lat_delta,
                        lon - lon_delta,
                        lon + lon_delta,
                    ),
                )
                rows = await cursor.fetchall()

        for row in rows:
            distance = haversine_m(
                lat,
                lon,
                float(row["stop_lat"]),
                float(row["stop_lon"]),
            )
            if distance <= radius_m:
                return True
        return False

    async def nearby_route_ids_for_mode(
        self,
        *,
        lat: float,
        lon: float,
        radius_m: int,
        mode: str,
    ) -> list[str]:
        route_filter = self._route_filter_sql(mode.strip().lower())
        if route_filter is None:
            return []

        lat_delta, lon_delta = bounding_box_degrees(radius_m, lat)
        async with self._acquire() as conn:
            try:
                cursor = await conn.execute(
                    f"""
                    SELECT DISTINCT s.stop_id, s.stop_lat, s.stop_lon, t.route_id
                    FROM stops s
                    JOIN stop_times st ON st.stop_id = s.stop_id
                    JOIN trips t ON t.trip_id = st.trip_id
                    JOIN routes r ON r.route_id = t.route_id
                    WHERE s.stop_lat BETWEEN ? AND ?
                      AND s.stop_lon BETWEEN ? AND ?
                      AND {route_filter}
                    LIMIT 5000
                    """,
                    (
                        lat - lat_delta,
                        lat + lat_delta,
                        lon - lon_delta,
                        lon + lon_delta,
                    ),
                )
                rows = await cursor.fetchall()
            except sqlite3.OperationalError:
                return []

        route_ids: set[str] = set()
        for row in rows:
            distance = haversine_m(
                lat,
                lon,
                float(row["stop_lat"]),
                float(row["stop_lon"]),
            )
            if distance <= radius_m:
                route_ids.add(str(row["route_id"]))
        return sorted(route_ids)

    async def route_has_service_on_date(self, route_id: str, target_date: date) -> bool:
        weekday_columns = (
            "monday",
            "tuesday",
            "wednesday",
            "thursday",
            "friday",
            "saturday",
            "sunday",
        )
        weekday_column = weekday_columns[target_date.weekday()]
        date_value = target_date.strftime("%Y%m%d")

        async with self._acquire() as conn:
            try:
                cursor = await conn.execute(
                    f"""
                    WITH route_services AS (
                        SELECT DISTINCT service_id
                        FROM trips
                        WHERE route_id = ?
                    ),
                    removed AS (
                        SELECT service_id
                        FROM calendar_dates
                        WHERE date = ? AND exception_type = 2
                    ),
                    added AS (
                        SELECT service_id
                        FROM calendar_dates
                        WHERE date = ? AND exception_type = 1
                    )
                    SELECT 1
                    FROM (
                        SELECT a.service_id
                        FROM added a
                        JOIN route_services rs ON rs.service_id = a.service_id
                        UNION
                        SELECT c.service_id
                        FROM calendar c
                        JOIN route_services rs ON rs.service_id = c.service_id
                        WHERE c.{weekday_column} = 1
                          AND c.start_date <= ?
                          AND c.end_date >= ?
                          AND c.service_id NOT IN (SELECT service_id FROM removed)
                    )
                    LIMIT 1
                    """,
                    (
                        route_id,
                        date_value,
                        date_value,
                        date_value,
                        date_value,
                    ),
                )
                row = await cursor.fetchone()
            except sqlite3.OperationalError:
                return False
        return row is not None


class TrackEngineService:
    """Facade used by the FastAPI router."""

    VERSION = "0.3.0"
    _RENDER_INTERNAL_ENGINE_URL = get_settings().urls.track_engine_internal_url

    def __init__(self, *, schedule_db: Path, state_db: Path):
        self.schedule_db = Path(schedule_db)
        self.state_db = Path(state_db)
        self.repository = ScheduleRepository(self.schedule_db)
        self.store = self._build_store(self.state_db)
        self._schedule_artifact_lock = threading.Lock()
        self.state_backend = self.store.backend_name
        self.state_store_description = self.store.description
        self._last_remote_engine_version: str | None = None
        self.remote_engine_url = self._resolve_remote_engine_url()
        _timeout_s = float(os.environ.get("TRACK_ENGINE_TIMEOUT_S", "12"))
        self.remote_engine_timeout = httpx.Timeout(
            connect=5.0,    # fail fast if engine is down/restarting
            read=_timeout_s, # allow long reads for complex routes
            write=5.0,
            pool=5.0,
        )
        self.remote_engine_timeout_s = _timeout_s  # kept for _try_future_days_plan
        # ── Circuit breaker ──
        self._engine_fail_ts: float = 0.0
        self._ENGINE_CIRCUIT_COOLDOWN_S: float = 10.0
        self._ENGINE_MAX_RETRIES: int = 3        # 1 initial + 2 retries
        self._ENGINE_BACKOFF_BASE_S: float = 1.0 # exponential: 1s, 2s
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
        # ── Lazy-initialized shared async HTTP client (connection-pooled) ──
        self._http: httpx.AsyncClient | None = None
        self._http_loop: asyncio.AbstractEventLoop | None = None
        self._http_limits = httpx.Limits(
            max_connections=20,
            max_keepalive_connections=10,
            keepalive_expiry=30,
        )

    @property
    def http(self) -> httpx.AsyncClient:
        """Lazy-init the async HTTP client bound to the running event loop.

        If the event loop changed (e.g. between TestClient requests),
        discard the old client and create a fresh one.
        """
        loop = asyncio.get_running_loop()
        if (
            self._http is None
            or self._http.is_closed
            or self._http_loop is not loop
        ):
            self._http = httpx.AsyncClient(
                timeout=self.remote_engine_timeout,
                limits=self._http_limits,
            )
            self._http_loop = loop
        return self._http

    async def close(self) -> None:
        """Gracefully close the shared HTTP connection pool."""
        if self._http is not None and not self._http.is_closed:
            await self._http.aclose()

    async def _engine_health_probe(self) -> bool:
        """Quick /health ping to check if the engine is reachable (half-open circuit)."""
        if not self.remote_engine_url:
            return False
        try:
            resp = await self.http.get(
                f"{self.remote_engine_url}/health",
                timeout=httpx.Timeout(connect=3.0, read=3.0, write=3.0, pool=3.0),
            )
            return resp.status_code == 200
        except Exception:
            return False

    async def _engine_post(self, endpoint: str, payload: dict, *, label: str = "") -> dict:
        """POST to the C++ engine with automatic retries and circuit-breaker logic.

        Uses tenacity for exponential backoff.  The circuit breaker (half-open
        health probe) is checked *before* the retry loop starts; individual
        503 responses trip the breaker immediately and are not retried.
        """
        tag = label or endpoint.lstrip("/")
        # ── Circuit breaker: fail instantly if engine went down recently ──
        since_fail = time.time() - self._engine_fail_ts
        if self._engine_fail_ts and since_fail < self._ENGINE_CIRCUIT_COOLDOWN_S:
            if not await self._engine_health_probe():
                raise RuntimeError(
                    f"TrackEngine circuit open – engine failed {since_fail:.0f}s ago, health probe failed"
                )

        @retry(
            stop=stop_after_attempt(self._ENGINE_MAX_RETRIES),
            wait=wait_exponential(
                multiplier=self._ENGINE_BACKOFF_BASE_S,
                min=self._ENGINE_BACKOFF_BASE_S,
                max=self._ENGINE_BACKOFF_BASE_S * 4,
            ),
            retry=retry_if_exception_type(
                (httpx.ConnectError, httpx.TimeoutException, httpx.HTTPError)
            ),
            reraise=True,
        )
        async def _do_post() -> dict:
            response = await self.http.post(
                f"{self.remote_engine_url}{endpoint}",
                json=payload,
                timeout=self.remote_engine_timeout,
            )
            if response.status_code == 503:
                self._engine_fail_ts = time.time()
                raise RuntimeError(
                    f"TrackEngine {tag} returned 503: {response.text[:200]}"
                )
            response.raise_for_status()
            return response.json()

        try:
            data = await _do_post()
        except RuntimeError:
            raise
        except (httpx.ConnectError, httpx.TimeoutException, httpx.HTTPError) as exc:
            self._engine_fail_ts = time.time()
            raise RuntimeError(
                f"TrackEngine {tag} failed after {self._ENGINE_MAX_RETRIES} attempts: {exc}"
            ) from exc

        self._engine_fail_ts = 0.0  # success — reset circuit
        return data

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
        if Path("/app/app").exists():
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

    def _schedule_artifact_path(self) -> Path:
        return self.schedule_db.with_name(f"{self.schedule_db.name}.gz")

    def _schedule_artifact_is_fresh(self, artifact_path: Path) -> bool:
        if not artifact_path.exists() or not self.schedule_db.exists():
            return False

        dependency_mtime = self.schedule_db.stat().st_mtime
        wal_path = self.schedule_db.with_name(f"{self.schedule_db.name}-wal")
        if wal_path.exists():
            dependency_mtime = max(dependency_mtime, wal_path.stat().st_mtime)
        return artifact_path.stat().st_mtime >= dependency_mtime

    def ensure_schedule_artifact(self) -> Path:
        artifact_path = self._schedule_artifact_path()
        if self._schedule_artifact_is_fresh(artifact_path):
            return artifact_path
        if not self.schedule_db.exists():
            raise FileNotFoundError(f"Schedule DB not found: {self.schedule_db}")

        with self._schedule_artifact_lock:
            if self._schedule_artifact_is_fresh(artifact_path):
                return artifact_path

            artifact_path.parent.mkdir(parents=True, exist_ok=True)
            compresslevel = int(
                os.environ.get("TRACK_ENGINE_SCHEDULE_ARTIFACT_COMPRESSLEVEL", "5")
            )
            with tempfile.NamedTemporaryFile(
                suffix=".db",
                prefix="trackengine-snapshot-",
                dir=str(artifact_path.parent),
                delete=False,
            ) as tmp_snapshot_handle:
                tmp_snapshot = Path(tmp_snapshot_handle.name)
            tmp_artifact = artifact_path.with_suffix(f"{artifact_path.suffix}.tmp")

            try:
                source = sqlite3.connect(
                    self.schedule_db,
                    timeout=30,
                    check_same_thread=False,
                )
                try:
                    snapshot = sqlite3.connect(tmp_snapshot)
                    try:
                        source.backup(snapshot)
                    finally:
                        snapshot.close()
                finally:
                    source.close()

                with tmp_snapshot.open("rb") as source_stream, gzip.open(
                    tmp_artifact,
                    "wb",
                    compresslevel=max(1, min(compresslevel, 9)),
                ) as artifact_stream:
                    shutil.copyfileobj(
                        source_stream,
                        artifact_stream,
                        length=1024 * 1024,
                    )

                os.replace(tmp_artifact, artifact_path)
            finally:
                with suppress(FileNotFoundError):
                    tmp_snapshot.unlink()
                with suppress(FileNotFoundError):
                    tmp_artifact.unlink()

        return artifact_path

    @property
    def planner_version(self) -> str:
        return self._last_remote_engine_version or self.VERSION

    async def health(self) -> HealthStatus:
        schedule_db_error = None
        try:
            self.prepare()
        except Exception as exc:  # pragma: no cover
            schedule_db_error = str(exc)
        if schedule_db_error is None:
            schedule_db_error = self.repository.prepare_error
        remote_healthy = None
        remote_version = None
        remote_error = None
        routing_backend = "backend_state_only"
        if self.remote_engine_url:
            routing_backend = "cpp_remote"
            try:
                response = await self.http.get(
                    f"{self.remote_engine_url}/health",
                    timeout=min(self.remote_engine_timeout_s, 5.0),
                )
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
            prepared=self.repository.prepared and schedule_db_error is None,
            prepared_indexes=self.repository.prepared_index_names,
            schedule_db_error=schedule_db_error,
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

    @staticmethod
    def _format_schedule_date(target_date: date) -> str:
        return f"{target_date.strftime('%A, %b')} {target_date.day}"

    @staticmethod
    def _shift_timestamp_to_date(timestamp_s: int, target_date: date) -> int:
        source_dt = datetime.fromtimestamp(timestamp_s, NY_TZ)
        shifted_dt = datetime.combine(
            target_date,
            source_dt.timetz().replace(tzinfo=None),
            tzinfo=NY_TZ,
        )
        return int(shifted_dt.timestamp())

    @staticmethod
    def _matching_weekday_on_or_before(
        latest_date: date,
        weekday: int,
        *,
        earliest_date: date,
    ) -> date | None:
        for offset in range(7):
            candidate = latest_date - timedelta(days=offset)
            if candidate < earliest_date:
                return None
            if candidate.weekday() == weekday:
                return candidate
        return None

    @staticmethod
    def _matching_weekday_on_or_after(
        earliest_date: date,
        weekday: int,
        *,
        latest_date: date,
    ) -> date | None:
        for offset in range(7):
            candidate = earliest_date + timedelta(days=offset)
            if candidate > latest_date:
                return None
            if candidate.weekday() == weekday:
                return candidate
        return None

    async def _location_needs_bus(self, location: LocationInput, *, radius_m: int) -> bool:
        if location.lat is None or location.lon is None:
            return False

        capped_radius = max(300, min(radius_m, 1_200))
        bus_nearby = await self.repository.has_nearby_stop_for_mode(
            lat=location.lat,
            lon=location.lon,
            radius_m=capped_radius,
            mode="bus",
        )
        if not bus_nearby:
            return False

        for rail_mode in ("subway", "lirr", "mnr"):
            if await self.repository.has_nearby_stop_for_mode(
                lat=location.lat,
                lon=location.lon,
                radius_m=capped_radius,
                mode=rail_mode,
            ):
                return False
        return True

    async def _candidate_bus_routes(self, request: PlanRequest) -> list[str]:
        routes: set[str] = set()
        locations = (
            (request.origin, request.max_origin_walk_m),
            (request.destination, request.max_destination_walk_m),
        )
        for location, radius_m in locations:
            if location.lat is None or location.lon is None:
                continue
            capped_radius = max(300, min(radius_m, 1_200))
            if not await self._location_needs_bus(location, radius_m=capped_radius):
                continue
            routes.update(
                await self.repository.nearby_route_ids_for_mode(
                    lat=location.lat,
                    lon=location.lon,
                    radius_m=capped_radius,
                    mode="bus",
                )
            )
        return sorted(routes)

    async def _fallback_bus_schedule_date(
        self,
        route_ids: list[str],
        requested_date: date,
    ) -> tuple[date, str] | None:
        if not route_ids:
            return None
        for route_id in route_ids:
            if await self.repository.route_has_service_on_date(route_id, requested_date):
                return None

        async def has_service(candidate_date: date) -> bool:
            for route_id in route_ids:
                if await self.repository.route_has_service_on_date(route_id, candidate_date):
                    return True
            return False

        for offset in range(7, 36, 7):
            past_date = requested_date - timedelta(days=offset)
            if await has_service(past_date):
                return past_date, (
                    f"Using latest available bus schedule from "
                    f"{self._format_schedule_date(past_date)}"
                )

            future_date = requested_date + timedelta(days=offset)
            if await has_service(future_date):
                return future_date, (
                    f"Using next available bus schedule from "
                    f"{self._format_schedule_date(future_date)}"
                )

        for offset in range(1, 15):
            past_date = requested_date - timedelta(days=offset)
            if await has_service(past_date):
                return past_date, (
                    f"Using latest available bus schedule from "
                    f"{self._format_schedule_date(past_date)}"
                )

            future_date = requested_date + timedelta(days=offset)
            if await has_service(future_date):
                return future_date, (
                    f"Using next available bus schedule from "
                    f"{self._format_schedule_date(future_date)}"
                )
        return None

    async def _stale_bus_schedule_override(
        self,
        request: PlanRequest,
        query_ts: int,
    ) -> tuple[date, str] | None:
        if "bus" not in request.modes:
            return None
        if not (
            await self._location_needs_bus(
                request.origin,
                radius_m=request.max_origin_walk_m,
            )
            or await self._location_needs_bus(
                request.destination,
                radius_m=request.max_destination_walk_m,
            )
        ):
            return None

        requested_date = service_date_for_timestamp(query_ts)
        route_override = await self._fallback_bus_schedule_date(
            await self._candidate_bus_routes(request),
            requested_date,
        )
        if route_override is not None:
            return route_override

        bus_window = await self.repository.service_window_for_mode("bus")
        if bus_window is None:
            return None
        if bus_window.start_date <= requested_date <= bus_window.end_date:
            return None

        if requested_date > bus_window.end_date:
            adjusted_date = self._matching_weekday_on_or_before(
                bus_window.end_date,
                requested_date.weekday(),
                earliest_date=bus_window.start_date,
            )
            label = "latest available bus schedule"
        else:
            adjusted_date = self._matching_weekday_on_or_after(
                bus_window.start_date,
                requested_date.weekday(),
                latest_date=bus_window.end_date,
            )
            label = "next available bus schedule"

        if adjusted_date is None:
            return None
        return adjusted_date, (
            f"Using {label} from {self._format_schedule_date(adjusted_date)}"
        )

    def _future_day_payload(
        self,
        request: PlanRequest,
        day_offset: int,
        *,
        now_ts: int | None = None,
    ) -> dict:
        """Build an engine payload shifted to *day_offset* days in the future.

        Keeps origin/destination but replaces timestamps so the engine
        queries for the future service day.  We pick 8 AM local as a
        reasonable departure time for the lookahead query.
        """
        today_ny = datetime.now(NY_TZ).date()
        future_date = today_ny + timedelta(days=day_offset)
        future_8am = datetime.combine(future_date, time_value(8, 0), tzinfo=NY_TZ)
        future_ts = int(future_8am.timestamp())
        future_midnight = datetime.combine(future_date, time_value.min, tzinfo=NY_TZ)

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
            "depart_at_ts": future_ts,
            "arrive_by_ts": None,
            "query_ts": future_ts,
            "service_day_yyyymmdd": int(future_date.strftime("%Y%m%d")),
            "service_weekday": future_date.weekday(),
            "service_day_midnight_ts": int(future_midnight.timestamp()),
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
        if getattr(request, "priority", None):
            payload["priority"] = request.priority
        if getattr(request, "accessibility_priority", False):
            payload["accessibility_priority"] = True
        return payload

    @staticmethod
    def _schedule_note_for_date(future_date) -> str:
        """Build a human-readable schedule note like 'Next trips available Monday, Apr 14'."""
        return f"Next trips available {future_date.strftime('%A, %b')} {future_date.day}"

    async def _remote_payload_context(
        self,
        request: PlanRequest,
        *,
        now_ts: int | None = None,
    ) -> RemotePayloadContext:
        query_ts = self._query_timestamp(request)
        depart_at_ts = request.depart_at_ts
        arrive_by_ts = request.arrive_by_ts
        adjusted_now_ts = now_ts
        schedule_note = None
        timestamp_shift_s = 0

        override = await self._stale_bus_schedule_override(request, query_ts)
        if override is not None:
            adjusted_date, schedule_note = override
            adjusted_query_ts = self._shift_timestamp_to_date(query_ts, adjusted_date)
            timestamp_shift_s = query_ts - adjusted_query_ts
            query_ts = adjusted_query_ts
            if depart_at_ts is not None:
                depart_at_ts = self._shift_timestamp_to_date(depart_at_ts, adjusted_date)
            if arrive_by_ts is not None:
                arrive_by_ts = self._shift_timestamp_to_date(arrive_by_ts, adjusted_date)
            if adjusted_now_ts is not None:
                adjusted_now_ts = self._shift_timestamp_to_date(
                    adjusted_now_ts,
                    adjusted_date,
                )

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
            "depart_at_ts": depart_at_ts,
            "arrive_by_ts": arrive_by_ts,
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
        if adjusted_now_ts is not None:
            payload["now_ts"] = adjusted_now_ts
        if getattr(request, "priority", None):
            payload["priority"] = request.priority
        if getattr(request, "accessibility_priority", False):
            payload["accessibility_priority"] = True
        return RemotePayloadContext(
            payload=payload,
            schedule_note=schedule_note,
            timestamp_shift_s=timestamp_shift_s,
        )

    @staticmethod
    def _enrich_color(
        mode: str | None,
        route_id: str | None,
        raw_color: str | None,
        *,
        step_kind: str | None = None,
    ) -> str | None:
        """Apply brand-correct color for subway/bus, fallback to mode default.

        For go steps that lack an explicit ``mode`` we infer it from
        ``route_id`` (subway colors map, or bus-like route name pattern).
        """
        from app.routers.nearby import _classify_bus_service_type
        from app.utils.brand import SUBWAY_COLORS

        # Infer mode when missing (common for go steps where C++ omits mode)
        if not mode and route_id and route_id != "walk":
            if route_id in SUBWAY_COLORS:
                mode = "subway"
            elif step_kind == "ride":
                mode = "bus"

        if mode == "subway" and route_id:
            return _brand_subway_color(route_id)
        if mode == "bus" and route_id:
            svc_type = _classify_bus_service_type(route_id)
            return _brand_bus_color(svc_type)
        if not raw_color and mode:
            return _brand_mode_color(mode)
        return raw_color

    def _parse_itinerary(
        self,
        item,
        *,
        timestamp_shift_s: int = 0,
    ) -> Itinerary:
        from app.routers.nearby import _classify_bus_service_type

        parsed_legs: list[TransitLeg] = []
        for leg in item.get("legs", []):
            mode = leg["mode"]
            route_name = leg["route_name"]
            color_hex = leg.get("color_hex")
            bus_service_type: str | None = None

            # For bus legs, classify service type and apply the correct color
            if mode == "bus" and route_name:
                bus_service_type = _classify_bus_service_type(route_name)
                color_hex = _brand_bus_color(bus_service_type)

            # Guarantee color_hex is never null — fall back to mode default
            if not color_hex:
                color_hex = _brand_mode_color(mode)

            parsed_legs.append(
                TransitLeg(
                    mode=mode,
                    route_id=leg["route_id"],
                    route_name=route_name,
                    color_hex=color_hex,
                    headsign=leg.get("headsign"),
                    trip_id=leg.get("trip_id"),
                    board_stop_id=leg["board_stop_id"],
                    board_stop_name=leg["board_stop_name"],
                    alight_stop_id=leg["alight_stop_id"],
                    alight_stop_name=leg["alight_stop_name"],
                    departure_ts=leg["departure_ts"] + timestamp_shift_s,
                    arrival_ts=leg["arrival_ts"] + timestamp_shift_s,
                    duration_s=leg["duration_s"],
                    stop_count=leg["stop_count"],
                    walk_meters=leg.get("walk_meters", 0.0),
                    bus_service_type=bus_service_type,
                )
            )
        return Itinerary(
            itinerary_id=item["itinerary_id"],
            leave_at_ts=item["leave_at_ts"] + timestamp_shift_s,
            arrive_at_ts=item["arrive_at_ts"] + timestamp_shift_s,
            total_duration_s=item["total_duration_s"],
            in_vehicle_s=item["in_vehicle_s"],
            walking_s=item["walking_s"],
            waiting_s=item["waiting_s"],
            transfer_count=item["transfer_count"],
            walk_meters=item["walk_meters"],
            score=float(item["score"]),
            summary=item["summary"],
            legs=parsed_legs,
        )

    def _parse_go_action(
        self,
        payload,
        *,
        timestamp_shift_s: int = 0,
    ) -> GoAction | None:
        if payload is None:
            return None
        return GoAction(
            status=payload["status"],
            title=payload["title"],
            subtitle=payload["subtitle"],
            due_at_ts=payload["due_at_ts"] + timestamp_shift_s,
            due_in_s=payload["due_in_s"],
        )

    def _parse_go_trip(
        self,
        payload,
        *,
        timestamp_shift_s: int = 0,
    ) -> GoTrip:
        return GoTrip(
            itinerary=self._parse_itinerary(
                payload["itinerary"],
                timestamp_shift_s=timestamp_shift_s,
            ),
            route_chips=[
                RouteChip(
                    kind=chip["kind"],
                    label=chip["label"],
                    route_id=chip.get("route_id"),
                    color_hex=self._enrich_color(
                        chip.get("mode"), chip.get("route_id"), chip.get("color_hex"),
                    ),
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
                    start_ts=step["start_ts"] + timestamp_shift_s,
                    end_ts=step["end_ts"] + timestamp_shift_s,
                    route_id=step.get("route_id"),
                    route_name=step.get("route_name"),
                    color_hex=self._enrich_color(
                        step.get("mode"),
                        step.get("route_id"),
                        step.get("color_hex"),
                        step_kind=step["kind"],
                    ),
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
                    arrival_ts=transfer["arrival_ts"] + timestamp_shift_s,
                    boarding_ts=transfer["boarding_ts"] + timestamp_shift_s,
                    wait_s=transfer["wait_s"],
                    walk_s=transfer["walk_s"],
                    walk_meters=transfer["walk_meters"],
                )
                for transfer in payload.get("transfers", [])
            ],
            next_action=self._parse_go_action(
                payload.get("next_action"),
                timestamp_shift_s=timestamp_shift_s,
            ),
            status=payload["status"],
            leave_in_s=payload["leave_in_s"],
            arrive_in_s=payload["arrive_in_s"],
            duration_label=payload["duration_label"],
            leave_label=payload["leave_label"],
            arrive_label=payload["arrive_label"],
        )

    async def _remote_plan(self, request: PlanRequest) -> tuple[list[Itinerary], str | None]:
        """Plan trip, falling back to upcoming days when today has no service.

        Returns ``(itineraries, schedule_note)`` where *schedule_note* is
        ``None`` when the results are for the originally requested time.
        """
        if not self.remote_engine_url:
            raise RuntimeError(
                "TRACK_ENGINE_URL is not configured. Routing now runs only in the "
                "standalone C++ TrackEngine service."
            )

        context = await self._remote_payload_context(request)
        payload = context.payload

        # ── Redis cache check ──
        cached_data = get_cached_plan(payload)
        if cached_data is not None:
            remote_version = cached_data.get("engine_version")
            if remote_version:
                self._last_remote_engine_version = str(remote_version)
            itineraries = [
                self._parse_itinerary(
                    item,
                    timestamp_shift_s=context.timestamp_shift_s,
                )
                for item in cached_data.get("itineraries", [])
            ]
            if itineraries:
                return itineraries, context.schedule_note

        data = await self._engine_post("/plan", payload, label="plan")
        remote_version = data.get("engine_version")
        if remote_version:
            self._last_remote_engine_version = str(remote_version)

        itineraries = [
            self._parse_itinerary(
                item,
                timestamp_shift_s=context.timestamp_shift_s,
            )
            for item in data.get("itineraries", [])
        ]
        if itineraries:
            set_cached_plan(payload, data)
            return itineraries, context.schedule_note

        # ---- next-service-day fallback ----
        if self._engine_fail_ts == 0.0:
            schedule_note = await self._try_future_days_plan(request)
            if schedule_note is not None:
                return schedule_note
        return [], None

    async def _try_future_days_plan(
        self, request: PlanRequest, *, max_lookahead: int = 3
    ) -> tuple[list[Itinerary], str] | None:
        """Try up to *max_lookahead* future days, returning the first day with results."""
        today_ny = datetime.now(NY_TZ).date()
        for offset in range(1, max_lookahead + 1):
            future_date = today_ny + timedelta(days=offset)
            payload = self._future_day_payload(request, offset)
            try:
                resp = await self.http.post(
                    f"{self.remote_engine_url}/plan",
                    json=payload,
                    timeout=min(self.remote_engine_timeout_s, 8.0),
                )
                resp.raise_for_status()
                data = resp.json()
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code == 503:
                    return None  # engine down — stop immediately
                continue
            except httpx.HTTPError:
                continue
            items = [self._parse_itinerary(item) for item in data.get("itineraries", [])]
            if items:
                return items, self._schedule_note_for_date(future_date)
        return None

    async def _remote_go(self, request: PlanRequest, *, now_ts: int) -> GoResponse:
        if not self.remote_engine_url:
            raise RuntimeError(
                "TRACK_ENGINE_URL is not configured. Routing now runs only in the "
                "standalone C++ TrackEngine service."
            )

        context = await self._remote_payload_context(request, now_ts=now_ts)
        payload = context.payload

        # ── Redis cache check ──
        cached_data = get_cached_go(payload)
        if cached_data is not None:
            remote_version = cached_data.get("engine_version")
            if remote_version:
                self._last_remote_engine_version = str(remote_version)
            primary = cached_data.get("primary_trip")
            if primary is not None:
                return GoResponse(
                    engine_version=str(cached_data["engine_version"]),
                    requested_at_ts=int(cached_data["requested_at_ts"]),
                    now_ts=int(cached_data["now_ts"]) + context.timestamp_shift_s,
                    origin=request.origin,
                    destination=request.destination,
                    session_kind=str(cached_data["session_kind"]),
                    primary_trip=self._parse_go_trip(
                        primary,
                        timestamp_shift_s=context.timestamp_shift_s,
                    ),
                    alternatives=[
                        self._parse_go_trip(
                            item,
                            timestamp_shift_s=context.timestamp_shift_s,
                        )
                        for item in cached_data.get("alternatives", [])
                    ],
                    schedule_note=context.schedule_note,
                )

        data = await self._engine_post("/go", payload, label="go")
        remote_version = data.get("engine_version")
        if remote_version:
            self._last_remote_engine_version = str(remote_version)

        # ── Cache the raw response ──
        if data.get("primary_trip") is not None:
            set_cached_go(payload, data)

        go_response = GoResponse(
            engine_version=str(data["engine_version"]),
            requested_at_ts=int(data["requested_at_ts"]),
            now_ts=int(data["now_ts"]) + context.timestamp_shift_s,
            origin=request.origin,
            destination=request.destination,
            session_kind=str(data["session_kind"]),
            primary_trip=(
                self._parse_go_trip(
                    data["primary_trip"],
                    timestamp_shift_s=context.timestamp_shift_s,
                )
                if data.get("primary_trip") is not None
                else None
            ),
            alternatives=[
                self._parse_go_trip(
                    item,
                    timestamp_shift_s=context.timestamp_shift_s,
                )
                for item in data.get("alternatives", [])
            ],
            schedule_note=context.schedule_note,
        )

        # ---- next-service-day fallback ----
        if go_response.primary_trip is None and not go_response.alternatives:
            if self._engine_fail_ts == 0.0:
                fallback = await self._try_future_days_go(request, now_ts=now_ts)
                if fallback is not None:
                    return fallback
        return go_response

    async def _try_future_days_go(
        self, request: PlanRequest, *, now_ts: int, max_lookahead: int = 3
    ) -> GoResponse | None:
        """Try future days for the /go endpoint."""
        today_ny = datetime.now(NY_TZ).date()
        for offset in range(1, max_lookahead + 1):
            future_date = today_ny + timedelta(days=offset)
            payload = self._future_day_payload(request, offset, now_ts=now_ts)
            try:
                resp = await self.http.post(
                    f"{self.remote_engine_url}/go",
                    json=payload,
                    timeout=min(self.remote_engine_timeout_s, 8.0),
                )
                resp.raise_for_status()
                data = resp.json()
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code == 503:
                    return None  # engine down — stop immediately
                continue
            except httpx.HTTPError:
                continue
            primary = data.get("primary_trip")
            if primary is not None:
                return GoResponse(
                    engine_version=str(data["engine_version"]),
                    requested_at_ts=int(data["requested_at_ts"]),
                    now_ts=int(data["now_ts"]),
                    origin=request.origin,
                    destination=request.destination,
                    session_kind=str(data["session_kind"]),
                    primary_trip=self._parse_go_trip(primary),
                    alternatives=[
                        self._parse_go_trip(item) for item in data.get("alternatives", [])
                    ],
                    schedule_note=self._schedule_note_for_date(future_date),
                )
        return None

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

    def _ranking_score(
        self,
        trip: GoTrip,
        *,
        priority: str | None = None,
    ) -> float:
        # Adjust weights based on user priority preference
        transfer_weight = 480.0
        walk_weight = 0.45
        wait_weight = 0.25
        if priority == "fewer_transfers":
            transfer_weight = 1200.0  # much stronger penalty per transfer
        elif priority == "less_walking":
            walk_weight = 1.5  # triple walking penalty

        score = (
            float(trip.itinerary.total_duration_s)
            + trip.itinerary.transfer_count * transfer_weight
            + trip.itinerary.walking_s * walk_weight
            + trip.itinerary.waiting_s * wait_weight
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

    # ------------------------------------------------------------------
    # Transfer safety analysis  (no competitor does this well)
    # ------------------------------------------------------------------

    def _analyze_transfer_safety(self, trip: GoTrip) -> None:
        """Evaluate each transfer's connection safety given real-time delays.

        Sets ``GoTransfer.safety`` to one of:
        * ``safe``   – ≥5 min buffer after accounting for incoming delay
        * ``tight``  – 2-5 min buffer
        * ``at_risk`` – 0-2 min buffer; connection may be missed
        * ``missed`` – negative buffer; incoming train arrives after next departs
        * ``unknown`` – no real-time data to judge
        """
        if not trip.transfers:
            return

        transit_legs = [leg for leg in trip.itinerary.legs if leg.mode != "walk"]

        for transfer in trip.transfers:
            # Find the incoming leg that feeds this transfer
            incoming_leg = None
            for leg in transit_legs:
                if (leg.alight_stop_id == transfer.arrival_stop_id
                        and leg.arrival_ts <= transfer.arrival_ts + 60):
                    incoming_leg = leg

            incoming_delay_s = 0
            has_rt = False
            if incoming_leg and incoming_leg.live_status:
                ls = incoming_leg.live_status
                if ls.status != "no_data":
                    has_rt = True
                    incoming_delay_s = max(ls.delay_s or 0, 0)

            if not has_rt:
                transfer.safety = "unknown"
                continue

            # Effective buffer = scheduled wait minus how late the incoming leg is
            effective_buffer_s = transfer.wait_s - incoming_delay_s

            if effective_buffer_s >= 300:
                transfer.safety = "safe"
            elif effective_buffer_s >= 120:
                transfer.safety = "tight"
            elif effective_buffer_s >= 0:
                transfer.safety = "at_risk"
            else:
                transfer.safety = "missed"

    # ------------------------------------------------------------------
    # Crowding prediction  (time-of-day heuristic for NYC transit)
    # ------------------------------------------------------------------

    @staticmethod
    def _estimate_crowding(trip: GoTrip) -> None:
        """Predict crowding on each transit leg using NYC ridership patterns.

        O(1) table lookup per leg — no branching.
        Levels: ``empty`` / ``some`` / ``busy`` / ``very_busy``
        """
        for leg in trip.itinerary.legs:
            table = _CROWDING.get(leg.mode)
            if table is None:          # walk or unknown mode
                continue
            dt = datetime.fromtimestamp(leg.departure_ts, NY_TZ)
            leg.crowding = table[dt.weekday() < 5][dt.hour]

    # ------------------------------------------------------------------
    # Fare estimation
    # ------------------------------------------------------------------

    # MTA fare rules (2024/2025):
    #   - Subway + local bus: $2.90 (OMNY / MetroCard)
    #   - Express bus: $7.00
    #   - Free transfers: subway↔bus and bus↔bus within 2 hours
    #   - LIRR / MNR: zone-based, approximate at $5.75 peak / $4.25 off-peak
    _BASE_FARE_CENTS = 290
    _EXPRESS_BUS_FARE_CENTS = 700
    _LIRR_PEAK_CENTS = 575
    _LIRR_OFF_PEAK_CENTS = 425
    _MNR_PEAK_CENTS = 575
    _MNR_OFF_PEAK_CENTS = 425
    _TRANSFER_WINDOW_S = 7200  # 2 hours
    _PEAK_HOURS = set(range(6, 10)) | set(range(16, 20))

    @staticmethod
    def _estimate_fare(trip: GoTrip) -> None:
        """Attach MTA fare estimate to the trip itinerary.

        Applies free-transfer rules (subway↔bus / bus↔bus within 2 h).
        LIRR/MNR use simple peak/off-peak approximation.
        """
        itin = trip.itinerary
        transit_legs = [leg for leg in itin.legs if leg.mode != "walk"]
        if not transit_legs:
            itin.fare = FareEstimate(total_cents=0, description="Walking — no transit fare")
            return

        leg_fares: list[LegFare] = []
        total_cents = 0
        free_transfers = 0

        # Track the first fare-paying timestamp for free-transfer window
        first_paid_ts: int | None = None
        first_paid_mode: str | None = None  # "subway" or "bus"

        for leg in transit_legs:
            mode = leg.mode
            route_id = leg.route_id or ""
            is_express_bus = (
                mode == "bus"
                and getattr(leg, "bus_service_type", None) == "express"
            )

            if is_express_bus:
                fare_cents = 700  # Express bus — no free transfer
                is_free = False
                first_paid_ts = leg.departure_ts
                first_paid_mode = None  # express resets transfer chain
            elif mode in {"subway", "bus"}:
                fare_cents = 290
                is_free = False

                # Check free-transfer eligibility
                if first_paid_ts is not None:
                    within_window = (leg.departure_ts - first_paid_ts) < 7200
                    eligible_pair = (
                        # subway → bus, bus → subway, bus → bus
                        (first_paid_mode == "subway" and mode == "bus")
                        or (first_paid_mode == "bus" and mode in {"subway", "bus"})
                    )
                    if within_window and eligible_pair:
                        fare_cents = 0
                        is_free = True
                        free_transfers += 1

                if not is_free:
                    first_paid_ts = leg.departure_ts
                    first_paid_mode = mode
            elif mode == "lirr":
                dt = datetime.fromtimestamp(leg.departure_ts, NY_TZ)
                if dt.weekday() < 5 and dt.hour in EngineService._PEAK_HOURS:
                    fare_cents = 575
                else:
                    fare_cents = 425
                is_free = False
                first_paid_ts = leg.departure_ts
                first_paid_mode = None
            elif mode == "mnr":
                dt = datetime.fromtimestamp(leg.departure_ts, NY_TZ)
                if dt.weekday() < 5 and dt.hour in EngineService._PEAK_HOURS:
                    fare_cents = 575
                else:
                    fare_cents = 425
                is_free = False
                first_paid_ts = leg.departure_ts
                first_paid_mode = None
            else:
                fare_cents = 0
                is_free = False

            total_cents += fare_cents
            leg_fares.append(LegFare(
                mode=mode,
                route_id=route_id,
                fare_cents=fare_cents,
                is_free_transfer=is_free,
            ))

        # Build description
        dollars = total_cents / 100
        parts: list[str] = []
        if free_transfers:
            parts.append(f"includes {free_transfers} free transfer{'s' if free_transfers > 1 else ''}")
        desc = f"${dollars:.2f} with OMNY"
        if parts:
            desc += f" ({', '.join(parts)})"

        itin.fare = FareEstimate(
            total_cents=total_cents,
            description=desc,
            legs=leg_fares,
            free_transfers_used=free_transfers,
        )

    # ------------------------------------------------------------------
    # Environmental impact (CO₂ savings + calorie burn)
    # ------------------------------------------------------------------

    # Average CO₂ per passenger-km (grams):
    #   Car: ~192 g/km  |  Subway: ~35 g/km  |  Bus: ~89 g/km
    #   Walking / cycling: 0
    # Calorie burn: ~50 kcal per km walked (avg adult)
    _CO2_CAR_G_PER_KM = 192
    _CO2_SUBWAY_G_PER_KM = 35
    _CO2_BUS_G_PER_KM = 89
    _CO2_RAIL_G_PER_KM = 40
    _CALORIES_PER_KM_WALK = 50

    # Rough average transit speed (km/h) for distance estimation from duration
    _AVG_SPEED: dict[str, float] = {
        "subway": 30.0,
        "bus": 15.0,
        "lirr": 55.0,
        "mnr": 50.0,
    }

    @staticmethod
    def _estimate_environmental_impact(trip: GoTrip) -> None:
        """Attach CO₂ savings and calorie estimates to the itinerary.

        Compares transit trip to driving the same distance.
        """
        itin = trip.itinerary
        walk_m = itin.walk_meters or 0.0

        transit_co2_g = 0.0
        car_distance_km = walk_m / 1000.0  # walking portion counted as car distance too

        for leg in itin.legs:
            if leg.mode == "walk":
                continue
            # Estimate distance from in-vehicle duration × average speed
            duration_h = leg.duration_s / 3600.0
            speed = EngineService._AVG_SPEED.get(leg.mode, 20.0)
            distance_km = duration_h * speed
            car_distance_km += distance_km

            if leg.mode == "subway":
                transit_co2_g += distance_km * 35
            elif leg.mode == "bus":
                transit_co2_g += distance_km * 89
            elif leg.mode in {"lirr", "mnr"}:
                transit_co2_g += distance_km * 40

        car_co2_g = car_distance_km * 192
        saved = max(0, int(car_co2_g - transit_co2_g))

        # Calories: walking only
        walk_km = walk_m / 1000.0
        calories = int(walk_km * 50)

        itin.environmental_impact = EnvironmentalImpact(
            co2_saved_grams=saved,
            calories_burned=calories,
            walk_meters=walk_m,
            equivalent_car_co2_grams=int(car_co2_g),
        )

    # ------------------------------------------------------------------
    # Confidence scoring  (unified intelligence score)
    # ------------------------------------------------------------------

    def _compute_confidence(self, trip: GoTrip) -> int:
        """Compute a 0-100 confidence score that unifies:
        - Realtime data quality  (feeds alive and matching?)
        - Transfer safety        (tight / at_risk / missed?)
        - Disruption severity    (cancelled legs, severe alerts?)
        - Crowding pressure      (very_busy legs?)
        - Accessibility          (inaccessible for mobility-impaired?)

        Google shows "usually X min late".  Transit shows countdowns.
        Track's confidence gives the rider a single, honest answer:
        "How much should I trust this trip plan right now?"
        """
        score = 100.0

        transit_legs = [leg for leg in trip.itinerary.legs if leg.mode != "walk"]

        # ── Realtime data quality ──
        for leg in transit_legs:
            ls = leg.live_status
            if ls is None or ls.status == "no_data":
                score -= 5
            elif ls.status == "cancelled":
                score -= 40
            elif ls.status == "delayed":
                delay = max(ls.delay_s or 0, 0)
                if delay > 600:
                    score -= 20
                elif delay > 300:
                    score -= 12
                elif delay > 120:
                    score -= 6
            elif ls.status == "scheduled":
                score -= 3  # scheduled-only, no live confirmation

        # ── Transfer safety ──
        for transfer in trip.transfers:
            if transfer.safety == "missed":
                score -= 35
            elif transfer.safety == "at_risk":
                score -= 18
            elif transfer.safety == "tight":
                score -= 8

        # ── Crowding pressure ──
        for leg in transit_legs:
            if leg.crowding == "very_busy":
                score -= 4
            elif leg.crowding == "busy":
                score -= 2

        # ── Severe alerts ──
        for alert in trip.service_alerts:
            if alert.severity == "severe":
                score -= 15
            elif alert.severity == "warning":
                score -= 5

        # ── Accessibility gap ──
        if trip.itinerary.accessible is False:
            score -= 3

        return max(0, min(100, int(round(score))))

    # ------------------------------------------------------------------
    # Disruption-aware re-routing  (two-pass engine calls)
    # ------------------------------------------------------------------

    async def _disruption_reroute(
        self,
        response: GoResponse,
        request: PlanRequest,
        *,
        now_ts: int,
    ) -> GoResponse:
        """When the primary trip has cancelled or missed-connection legs,
        request extra alternatives from the engine with a shifted departure.

        This is the #1 feature Google/Transit App have that basic engines lack:
        instead of just telling the user "your trip is disrupted", we find them
        a working alternative automatically.
        """
        primary = response.primary_trip
        if primary is None:
            return response

        # Check if primary trip is severely disrupted
        has_cancellation = any(
            leg.live_status is not None and leg.live_status.status == "cancelled"
            for leg in primary.itinerary.legs
            if leg.mode != "walk"
        )
        has_missed = any(
            transfer.safety == "missed" for transfer in primary.transfers
        )
        if not has_cancellation and not has_missed:
            return response

        # Collect disrupted route IDs to identify which alternatives avoid them
        disrupted_routes: set[str] = set()
        for leg in primary.itinerary.legs:
            if leg.mode == "walk":
                continue
            if (leg.live_status and leg.live_status.status == "cancelled"):
                disrupted_routes.add(self._normalize_route_key(leg.route_id))

        # Request more itineraries with a +3min departure offset
        from copy import copy
        reroute_request = copy(request)
        reroute_request.num_itineraries = max(request.num_itineraries, 5)
        offset_ts = (request.depart_at_ts or now_ts) + 180
        reroute_request.depart_at_ts = offset_ts
        reroute_request.record_recent = False

        try:
            extra_itineraries, _ = await self._remote_plan(reroute_request)
        except Exception:
            return response  # engine unavailable — keep original results

        if not extra_itineraries:
            return response

        # Filter: keep itineraries that do NOT use the disrupted routes
        surviving: list[GoTrip] = []
        for itin in extra_itineraries:
            uses_disrupted = False
            for leg in itin.legs:
                if leg.mode == "walk":
                    continue
                if self._normalize_route_key(leg.route_id) in disrupted_routes:
                    uses_disrupted = True
                    break
            if not uses_disrupted:
                go_trip = GoTrip(itinerary=itin, status="upcoming")
                surviving.append(go_trip)

        if not surviving:
            return response

        # Merge: add surviving clean alternatives, remove duplicates
        existing_ids = {
            alt.itinerary.itinerary_id for alt in response.alternatives
        }
        if response.primary_trip:
            existing_ids.add(response.primary_trip.itinerary.itinerary_id)
        for clean_trip in surviving[:3]:
            if clean_trip.itinerary.itinerary_id not in existing_ids:
                response.alternatives.append(clean_trip)
                existing_ids.add(clean_trip.itinerary.itinerary_id)

        return response

    def _enrich_trip(
        self,
        trip: GoTrip,
        *,
        alerts_by_key: dict[str, list[ServiceAlertSummary]],
        subway_arrivals_by_key: dict[str, list[Any]],
        rail_arrivals_by_mode: dict[str, list[Any]],
        bus_arrivals_by_stop: dict[str, list[Any]],
        priority: str | None = None,
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
        trip.ranking_score = self._ranking_score(trip, priority=priority)

        # ── New intelligence layers ──
        self._estimate_crowding(trip)
        self._analyze_transfer_safety(trip)
        self._estimate_fare(trip)
        self._estimate_environmental_impact(trip)
        trip.confidence = self._compute_confidence(trip)

        # Factor transfer safety into ranking: unsafe transfers are strongly
        # penalised so the rider sees solid alternatives first.
        for transfer in trip.transfers:
            if transfer.safety == "missed":
                trip.ranking_score += 1200.0
            elif transfer.safety == "at_risk":
                trip.ranking_score += 400.0
            elif transfer.safety == "tight":
                trip.ranking_score += 120.0

        return trip

    async def _enrich_go_response(
        self,
        response: GoResponse,
        *,
        priority: str | None = None,
    ) -> GoResponse:
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
                trip.ranking_score = self._ranking_score(trip, priority=priority)
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
                    priority=priority,
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

    async def go(self, request: PlanRequest, *, now_ts: int | None = None) -> GoResponse:
        session_now_ts = now_ts or int(time.time())
        response = await self._remote_go(request, now_ts=session_now_ts)
        user_priority = getattr(request, "priority", None)
        if self.enable_realtime_enrichment:
            with suppress(Exception):
                response = await self._enrich_go_response(response, priority=user_priority)
        # Tag ADA accessibility on go trips
        go_itineraries = []
        if response.primary_trip is not None:
            go_itineraries.append(response.primary_trip.itinerary)
        for alt in response.alternatives:
            go_itineraries.append(alt.itinerary)
        if go_itineraries:
            self._tag_ada_accessibility(go_itineraries)

        # Disruption-aware re-routing: when the primary trip has a cancelled
        # leg or a missed transfer, automatically fetch clean alternatives
        # from the engine using a shifted departure time.
        with suppress(Exception):
            response = await self._disruption_reroute(
                response, request, now_ts=session_now_ts,
            )

        # When accessibility is prioritised, swap primary if a better option exists
        if getattr(request, "accessibility_priority", False) and response.alternatives:
            if (response.primary_trip is not None
                    and not response.primary_trip.itinerary.accessible):
                for i, alt in enumerate(response.alternatives):
                    if alt.itinerary.accessible is True:
                        # Swap: promote the first accessible alternative
                        response.alternatives[i] = response.primary_trip
                        response.primary_trip = alt
                        break
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

    async def search(
        self,
        *,
        query: str,
        user_id: str | None = None,
        near_lat: float | None = None,
        near_lon: float | None = None,
        limit: int = 12,
    ) -> list[SearchResult]:
        schedule_ready = True
        try:
            self.prepare()
        except Exception:
            schedule_ready = False
        if self.repository.prepare_error is not None:
            schedule_ready = False
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
            try:
                saved_places = self.store.list_saved_places(user_id)
            except Exception:
                saved_places = []
            for place in saved_places:
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

            try:
                recent_destinations = self.store.list_recent_destinations(
                    user_id,
                    limit=limit,
                )
            except Exception:
                recent_destinations = []
            for recent in recent_destinations:
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
            stop_results = (
                await self.repository.search_stops(query, limit=limit * 2)
                if schedule_ready
                else []
            )
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

    # ------------------------------------------------------------------
    # ADA accessibility tagging for itineraries
    # ------------------------------------------------------------------

    @staticmethod
    def _tag_ada_accessibility(itineraries: list[Itinerary]) -> None:
        """Tag each subway leg with ``ada_accessible`` and each itinerary
        with ``accessible`` using the in-memory ADA cache.

        Bus and walk legs are left as ``None`` (street-level, generally
        accessible).  Subway, LIRR, and Metro-North stops are checked
        against the MTA Stations CSV.
        """
        from app.services.transit.ada_service import lookup_ada_batch

        # Collect all subway/rail stop IDs across all itineraries
        stop_ids: set[str] = set()
        for itin in itineraries:
            for leg in itin.legs:
                if leg.mode in ("subway",):
                    stop_ids.add(leg.board_stop_id)
                    stop_ids.add(leg.alight_stop_id)

        if not stop_ids:
            return

        ada_map = lookup_ada_batch(list(stop_ids))

        for itin in itineraries:
            has_subway = False
            all_accessible = True
            for leg in itin.legs:
                if leg.mode not in ("subway",):
                    continue
                has_subway = True
                # Strip N/S suffix for lookup
                board_base = leg.board_stop_id.rstrip("NSns")
                alight_base = leg.alight_stop_id.rstrip("NSns")
                board_ada = ada_map.get(board_base.upper())
                alight_ada = ada_map.get(alight_base.upper())
                # Accessible if ADA status is 1 (full) or 2 (partial)
                board_ok = board_ada is not None and board_ada >= 1
                alight_ok = alight_ada is not None and alight_ada >= 1
                leg.ada_accessible = board_ok and alight_ok
                if not leg.ada_accessible:
                    all_accessible = False
            if has_subway:
                itin.accessible = all_accessible

    @staticmethod
    def _rerank_for_accessibility(itineraries: list[Itinerary]) -> list[Itinerary]:
        """Re-sort itineraries so fully accessible trips come first.

        Never removes itineraries — only reorders.  Accessible trips
        keep their relative order; inaccessible ones are appended after.
        """
        accessible: list[Itinerary] = []
        rest: list[Itinerary] = []
        for itin in itineraries:
            if itin.accessible is True:
                accessible.append(itin)
            else:
                rest.append(itin)
        return accessible + rest

    async def plan(self, request: PlanRequest) -> tuple[list, str | None]:
        itineraries, schedule_note = await self._remote_plan(request)
        # Tag ADA accessibility on all results so iOS always has the data
        self._tag_ada_accessibility(itineraries)
        # When the user prioritises accessibility, push accessible trips first
        if getattr(request, "accessibility_priority", False):
            itineraries = self._rerank_for_accessibility(itineraries)
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
        return itineraries, schedule_note
