"""SQLite persistence for backend-owned engine state."""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path

from .domain import (
    CalendarEvent,
    Itinerary,
    RecentDestination,
    RecentTrip,
    SavedPlace,
    SavedTrip,
)


def recent_route_tokens(itinerary: Itinerary) -> tuple[str, ...]:
    tokens: list[str] = []
    for leg in itinerary.legs:
        if leg.mode == "walk":
            minutes = max(1, round(leg.duration_s / 60))
            tokens.append(f"Walk {minutes} min")
            continue
        tokens.append(leg.route_name)
    return tuple(tokens)


class EngineStore:
    """Local persistence for TrackEngine user state."""

    def __init__(self, db_path: Path):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._schema_lock = threading.Lock()
        self._schema_ready = False
        self._ensure_schema()
        self.backend_name = "sqlite"
        self.description = str(self.db_path)

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=30, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        return conn

    def _ensure_schema(self) -> None:
        with self._schema_lock:
            if self._schema_ready:
                return
            conn = self._connect()
            conn.executescript(
                """
                PRAGMA journal_mode = WAL;

                CREATE TABLE IF NOT EXISTS saved_places (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT NOT NULL,
                    label TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    lat REAL NOT NULL,
                    lon REAL NOT NULL,
                    address TEXT,
                    icon TEXT,
                    visible_on_map INTEGER NOT NULL DEFAULT 1,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    last_used_at INTEGER
                );
                CREATE INDEX IF NOT EXISTS idx_saved_places_user
                    ON saved_places(user_id, updated_at DESC);

                CREATE TABLE IF NOT EXISTS saved_trips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    origin_label TEXT NOT NULL,
                    origin_lat REAL NOT NULL,
                    origin_lon REAL NOT NULL,
                    destination_label TEXT NOT NULL,
                    destination_lat REAL NOT NULL,
                    destination_lon REAL NOT NULL,
                    preferred_departure_hour INTEGER,
                    preferred_arrival_hour INTEGER,
                    preferred_modes TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    last_used_at INTEGER
                );
                CREATE INDEX IF NOT EXISTS idx_saved_trips_user
                    ON saved_trips(user_id, updated_at DESC);

                CREATE TABLE IF NOT EXISTS recent_trips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT NOT NULL,
                    origin_label TEXT NOT NULL,
                    origin_lat REAL NOT NULL,
                    origin_lon REAL NOT NULL,
                    destination_label TEXT NOT NULL,
                    destination_lat REAL NOT NULL,
                    destination_lon REAL NOT NULL,
                    requested_at INTEGER NOT NULL,
                    leave_at_ts INTEGER NOT NULL,
                    arrive_at_ts INTEGER NOT NULL,
                    summary TEXT NOT NULL,
                    route_tokens TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_recent_trips_user
                    ON recent_trips(user_id, requested_at DESC);

                CREATE TABLE IF NOT EXISTS calendar_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT NOT NULL,
                    external_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    location_label TEXT NOT NULL,
                    lat REAL,
                    lon REAL,
                    starts_at INTEGER NOT NULL,
                    ends_at INTEGER,
                    notes TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE(user_id, external_id) ON CONFLICT REPLACE
                );
                CREATE INDEX IF NOT EXISTS idx_calendar_events_user
                    ON calendar_events(user_id, starts_at);
                """
            )
            conn.commit()
            existing_columns = {
                row[1]
                for row in conn.execute("PRAGMA table_info(saved_places)").fetchall()
            }
            if "visible_on_map" not in existing_columns:
                conn.execute(
                    "ALTER TABLE saved_places "
                    "ADD COLUMN visible_on_map INTEGER NOT NULL DEFAULT 1"
                )
                conn.commit()
            conn.close()
            self._schema_ready = True

    def list_saved_places(self, user_id: str) -> list[SavedPlace]:
        conn = self._connect()
        rows = conn.execute(
            """
            SELECT id, user_id, label, kind, lat, lon, address, icon,
                     visible_on_map, created_at, updated_at, last_used_at
            FROM saved_places
            WHERE user_id = ?
            ORDER BY kind ASC, updated_at DESC, label COLLATE NOCASE ASC
            """,
            (user_id,),
        ).fetchall()
        conn.close()
        return [
            SavedPlace(
                place_id=int(row["id"]),
                user_id=str(row["user_id"]),
                label=str(row["label"]),
                kind=str(row["kind"]),
                lat=float(row["lat"]),
                lon=float(row["lon"]),
                address=row["address"],
                icon=row["icon"],
                visible_on_map=bool(row["visible_on_map"]),
                created_at=int(row["created_at"]),
                updated_at=int(row["updated_at"]),
                last_used_at=(
                    int(row["last_used_at"])
                    if row["last_used_at"] is not None
                    else None
                ),
            )
            for row in rows
        ]

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
        visible_on_map: bool = True,
        place_id: int | None = None,
    ) -> SavedPlace:
        now_ts = int(time.time())
        conn = self._connect()
        if place_id is None:
            cursor = conn.execute(
                """
                INSERT INTO saved_places (
                    user_id, label, kind, lat, lon, address, icon,
                    visible_on_map, created_at, updated_at, last_used_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    user_id,
                    label,
                    kind,
                    lat,
                    lon,
                    address,
                    icon,
                    1 if visible_on_map else 0,
                    now_ts,
                    now_ts,
                    None,
                ),
            )
            place_id = int(cursor.lastrowid)
        else:
            conn.execute(
                """
                UPDATE saved_places
                SET label = ?, kind = ?, lat = ?, lon = ?, address = ?,
                    icon = ?, visible_on_map = ?, updated_at = ?
                WHERE id = ? AND user_id = ?
                """,
                (
                    label,
                    kind,
                    lat,
                    lon,
                    address,
                    icon,
                    1 if visible_on_map else 0,
                    now_ts,
                    place_id,
                    user_id,
                ),
            )
        conn.commit()
        conn.close()
        return next(
            place
            for place in self.list_saved_places(user_id)
            if place.place_id == place_id
        )

    def delete_saved_place(self, user_id: str, place_id: int) -> None:
        conn = self._connect()
        conn.execute(
            "DELETE FROM saved_places WHERE user_id = ? AND id = ?",
            (user_id, place_id),
        )
        conn.commit()
        conn.close()

    def touch_saved_place(self, user_id: str, place_id: int) -> None:
        conn = self._connect()
        conn.execute(
            """
            UPDATE saved_places
            SET last_used_at = ?, updated_at = ?
            WHERE user_id = ? AND id = ?
            """,
            (int(time.time()), int(time.time()), user_id, place_id),
        )
        conn.commit()
        conn.close()

    def list_saved_trips(self, user_id: str) -> list[SavedTrip]:
        conn = self._connect()
        rows = conn.execute(
            """
            SELECT id, user_id, name, origin_label, origin_lat, origin_lon,
                   destination_label, destination_lat, destination_lon,
                   preferred_departure_hour, preferred_arrival_hour,
                   preferred_modes, created_at, updated_at, last_used_at
            FROM saved_trips
            WHERE user_id = ?
            ORDER BY updated_at DESC, name COLLATE NOCASE ASC
            """,
            (user_id,),
        ).fetchall()
        conn.close()
        return [
            SavedTrip(
                trip_id=int(row["id"]),
                user_id=str(row["user_id"]),
                name=str(row["name"]),
                origin_label=str(row["origin_label"]),
                origin_lat=float(row["origin_lat"]),
                origin_lon=float(row["origin_lon"]),
                destination_label=str(row["destination_label"]),
                destination_lat=float(row["destination_lat"]),
                destination_lon=float(row["destination_lon"]),
                preferred_departure_hour=(
                    int(row["preferred_departure_hour"])
                    if row["preferred_departure_hour"] is not None
                    else None
                ),
                preferred_arrival_hour=(
                    int(row["preferred_arrival_hour"])
                    if row["preferred_arrival_hour"] is not None
                    else None
                ),
                preferred_modes=tuple(json.loads(row["preferred_modes"])),
                created_at=int(row["created_at"]),
                updated_at=int(row["updated_at"]),
                last_used_at=(
                    int(row["last_used_at"])
                    if row["last_used_at"] is not None
                    else None
                ),
            )
            for row in rows
        ]

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
        now_ts = int(time.time())
        preferred_modes_json = json.dumps(list(preferred_modes))
        conn = self._connect()
        if trip_id is None:
            cursor = conn.execute(
                """
                INSERT INTO saved_trips (
                    user_id, name, origin_label, origin_lat, origin_lon,
                    destination_label, destination_lat, destination_lon,
                    preferred_departure_hour, preferred_arrival_hour,
                    preferred_modes, created_at, updated_at, last_used_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    user_id,
                    name,
                    origin_label,
                    origin_lat,
                    origin_lon,
                    destination_label,
                    destination_lat,
                    destination_lon,
                    preferred_departure_hour,
                    preferred_arrival_hour,
                    preferred_modes_json,
                    now_ts,
                    now_ts,
                    None,
                ),
            )
            trip_id = int(cursor.lastrowid)
        else:
            conn.execute(
                """
                UPDATE saved_trips
                SET name = ?, origin_label = ?, origin_lat = ?, origin_lon = ?,
                    destination_label = ?, destination_lat = ?, destination_lon = ?,
                    preferred_departure_hour = ?, preferred_arrival_hour = ?,
                    preferred_modes = ?, updated_at = ?
                WHERE user_id = ? AND id = ?
                """,
                (
                    name,
                    origin_label,
                    origin_lat,
                    origin_lon,
                    destination_label,
                    destination_lat,
                    destination_lon,
                    preferred_departure_hour,
                    preferred_arrival_hour,
                    preferred_modes_json,
                    now_ts,
                    user_id,
                    trip_id,
                ),
            )
        conn.commit()
        conn.close()
        return next(
            trip
            for trip in self.list_saved_trips(user_id)
            if trip.trip_id == trip_id
        )

    def delete_saved_trip(self, user_id: str, trip_id: int) -> None:
        conn = self._connect()
        conn.execute(
            "DELETE FROM saved_trips WHERE user_id = ? AND id = ?",
            (user_id, trip_id),
        )
        conn.commit()
        conn.close()

    def touch_saved_trip(self, user_id: str, trip_id: int) -> None:
        now_ts = int(time.time())
        conn = self._connect()
        conn.execute(
            """
            UPDATE saved_trips
            SET last_used_at = ?, updated_at = ?
            WHERE user_id = ? AND id = ?
            """,
            (now_ts, now_ts, user_id, trip_id),
        )
        conn.commit()
        conn.close()

    def record_recent_trip(
        self,
        user_id: str,
        *,
        origin_label: str,
        origin_lat: float,
        origin_lon: float,
        destination_label: str,
        destination_lat: float,
        destination_lon: float,
        itinerary: Itinerary,
    ) -> RecentTrip:
        now_ts = int(time.time())
        route_tokens = recent_route_tokens(itinerary)
        conn = self._connect()
        cursor = conn.execute(
            """
            INSERT INTO recent_trips (
                user_id, origin_label, origin_lat, origin_lon,
                destination_label, destination_lat, destination_lon,
                requested_at, leave_at_ts, arrive_at_ts, summary, route_tokens
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                user_id,
                origin_label,
                origin_lat,
                origin_lon,
                destination_label,
                destination_lat,
                destination_lon,
                now_ts,
                itinerary.leave_at_ts,
                itinerary.arrive_at_ts,
                itinerary.summary,
                json.dumps(list(route_tokens)),
            ),
        )
        conn.execute(
            """
            DELETE FROM recent_trips
            WHERE user_id = ?
              AND id NOT IN (
                SELECT id
                FROM recent_trips
                WHERE user_id = ?
                ORDER BY requested_at DESC
                LIMIT 100
              )
            """,
            (user_id, user_id),
        )
        conn.commit()
        recent_trip_id = int(cursor.lastrowid)
        row = conn.execute(
            """
            SELECT id, user_id, origin_label, origin_lat, origin_lon,
                   destination_label, destination_lat, destination_lon,
                   requested_at, leave_at_ts, arrive_at_ts, summary, route_tokens
            FROM recent_trips
            WHERE id = ?
            """,
            (recent_trip_id,),
        ).fetchone()
        conn.close()
        return RecentTrip(
            recent_trip_id=int(row["id"]),
            user_id=str(row["user_id"]),
            origin_label=str(row["origin_label"]),
            origin_lat=float(row["origin_lat"]),
            origin_lon=float(row["origin_lon"]),
            destination_label=str(row["destination_label"]),
            destination_lat=float(row["destination_lat"]),
            destination_lon=float(row["destination_lon"]),
            requested_at=int(row["requested_at"]),
            leave_at_ts=int(row["leave_at_ts"]),
            arrive_at_ts=int(row["arrive_at_ts"]),
            summary=str(row["summary"]),
            route_tokens=tuple(json.loads(row["route_tokens"])),
        )

    def list_recent_trips(self, user_id: str, limit: int = 20) -> list[RecentTrip]:
        conn = self._connect()
        rows = conn.execute(
            """
            SELECT id, user_id, origin_label, origin_lat, origin_lon,
                   destination_label, destination_lat, destination_lon,
                   requested_at, leave_at_ts, arrive_at_ts, summary, route_tokens
            FROM recent_trips
            WHERE user_id = ?
            ORDER BY requested_at DESC
            LIMIT ?
            """,
            (user_id, limit),
        ).fetchall()
        conn.close()
        return [
            RecentTrip(
                recent_trip_id=int(row["id"]),
                user_id=str(row["user_id"]),
                origin_label=str(row["origin_label"]),
                origin_lat=float(row["origin_lat"]),
                origin_lon=float(row["origin_lon"]),
                destination_label=str(row["destination_label"]),
                destination_lat=float(row["destination_lat"]),
                destination_lon=float(row["destination_lon"]),
                requested_at=int(row["requested_at"]),
                leave_at_ts=int(row["leave_at_ts"]),
                arrive_at_ts=int(row["arrive_at_ts"]),
                summary=str(row["summary"]),
                route_tokens=tuple(json.loads(row["route_tokens"])),
            )
            for row in rows
        ]

    def list_recent_destinations(
        self,
        user_id: str,
        limit: int = 20,
    ) -> list[RecentDestination]:
        conn = self._connect()
        rows = conn.execute(
            """
            SELECT destination_label,
                   destination_lat,
                   destination_lon,
                   COUNT(*) AS trip_count,
                   MAX(requested_at) AS last_used_at
            FROM recent_trips
            WHERE user_id = ?
            GROUP BY destination_label,
                     ROUND(destination_lat, 4),
                     ROUND(destination_lon, 4)
            ORDER BY trip_count DESC, last_used_at DESC
            LIMIT ?
            """,
            (user_id, limit),
        ).fetchall()
        conn.close()
        return [
            RecentDestination(
                label=str(row["destination_label"]),
                lat=float(row["destination_lat"]),
                lon=float(row["destination_lon"]),
                trip_count=int(row["trip_count"]),
                last_used_at=int(row["last_used_at"]),
            )
            for row in rows
        ]

    def replace_calendar_events(
        self,
        user_id: str,
        events: list[CalendarEvent],
    ) -> list[CalendarEvent]:
        now_ts = int(time.time())
        conn = self._connect()
        conn.execute("DELETE FROM calendar_events WHERE user_id = ?", (user_id,))
        for event in events:
            conn.execute(
                """
                INSERT INTO calendar_events (
                    user_id, external_id, title, location_label,
                    lat, lon, starts_at, ends_at, notes,
                    created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    user_id,
                    event.external_id,
                    event.title,
                    event.location_label,
                    event.lat,
                    event.lon,
                    event.starts_at,
                    event.ends_at,
                    event.notes,
                    now_ts,
                    now_ts,
                ),
            )
        conn.commit()
        conn.close()
        return events

    def list_calendar_events(
        self,
        user_id: str,
        *,
        starts_after: int | None = None,
        starts_before: int | None = None,
        limit: int = 25,
    ) -> list[CalendarEvent]:
        query = (
            """
            SELECT external_id, title, location_label, lat, lon,
                   starts_at, ends_at, notes
            FROM calendar_events
            WHERE user_id = ?
            """
        )
        params: list[object] = [user_id]
        if starts_after is not None:
            query += " AND starts_at >= ?"
            params.append(starts_after)
        if starts_before is not None:
            query += " AND starts_at <= ?"
            params.append(starts_before)
        query += " ORDER BY starts_at ASC LIMIT ?"
        params.append(limit)
        conn = self._connect()
        rows = conn.execute(query, params).fetchall()
        conn.close()
        return [
            CalendarEvent(
                external_id=str(row["external_id"]),
                title=str(row["title"]),
                location_label=str(row["location_label"]),
                starts_at=int(row["starts_at"]),
                ends_at=(
                    int(row["ends_at"]) if row["ends_at"] is not None else None
                ),
                lat=float(row["lat"]) if row["lat"] is not None else None,
                lon=float(row["lon"]) if row["lon"] is not None else None,
                notes=row["notes"],
            )
            for row in rows
        ]
