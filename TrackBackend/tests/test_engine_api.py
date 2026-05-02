"""API tests for the /engine routes."""

from __future__ import annotations

import gzip
import os
import sqlite3
import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from fastapi.testclient import TestClient

from app.main import app
from app.services.track_engine.integration import reset_engine_service
from app.auth import require_user, optional_user, AuthUser

if TYPE_CHECKING:
    from pathlib import Path

    from pytest import MonkeyPatch

client = TestClient(app)

# --- Mocks for Auth ---
MOCK_USER_ID = uuid.uuid4()

async def mock_require_user():
    return AuthUser(user_id=MOCK_USER_ID, email="test@example.com")

async def mock_optional_user():
    return AuthUser(user_id=MOCK_USER_ID, email="test@example.com")

app.dependency_overrides[require_user] = mock_require_user
app.dependency_overrides[optional_user] = mock_optional_user


def _build_schedule_db(path: Path) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE routes (
            route_id TEXT PRIMARY KEY,
            route_short_name TEXT,
            route_long_name TEXT,
            route_color TEXT,
            route_type INTEGER
        );
        CREATE TABLE trips (
            trip_id TEXT PRIMARY KEY,
            route_id TEXT,
            service_id TEXT,
            trip_headsign TEXT,
            direction_id INTEGER
        );
        CREATE TABLE stop_times (
            trip_id TEXT,
            arrival_time TEXT,
            departure_time TEXT,
            stop_id TEXT,
            stop_sequence INTEGER
        );
        CREATE TABLE stops (
            stop_id TEXT PRIMARY KEY,
            stop_name TEXT,
            stop_lat REAL,
            stop_lon REAL
        );
        CREATE TABLE calendar (
            service_id TEXT PRIMARY KEY,
            monday INTEGER,
            tuesday INTEGER,
            wednesday INTEGER,
            thursday INTEGER,
            friday INTEGER,
            saturday INTEGER,
            sunday INTEGER,
            start_date TEXT,
            end_date TEXT
        );
        CREATE TABLE calendar_dates (
            service_id TEXT,
            date TEXT,
            exception_type INTEGER
        );
        CREATE INDEX idx_stop_times_stop_dept
            ON stop_times(stop_id, departure_time);
        CREATE INDEX idx_stop_times_trip_seq
            ON stop_times(trip_id, stop_sequence);
        CREATE INDEX idx_stop_times_trip_stop_seq
            ON stop_times(trip_id, stop_id, stop_sequence);
        CREATE INDEX idx_trips_service
            ON trips(service_id);
        CREATE INDEX idx_stops_name
            ON stops(stop_name);
        """
    )
    conn.executemany(
        "INSERT INTO routes VALUES (?, ?, ?, ?, ?)",
        [
            ("R1", "Q9", "Queens Connector", "C218D2", 1),
            ("R2", "B15", "Crosstown", "0078C6", 3),
        ],
    )
    conn.executemany(
        "INSERT INTO trips VALUES (?, ?, ?, ?, ?)",
        [
            ("T1", "R1", "WKD", "Connector", 0),
            ("T2", "R2", "WKD", "Downtown", 0),
        ],
    )
    conn.executemany(
        "INSERT INTO stops VALUES (?, ?, ?, ?)",
        [
            ("STOP_A", "Alpha", 40.00000, -73.00000),
            ("STOP_C", "Charlie", 40.00100, -73.00000),
            ("STOP_E", "Echo", 40.00200, -73.00000),
        ],
    )
    conn.executemany(
        "INSERT INTO stop_times VALUES (?, ?, ?, ?, ?)",
        [
            ("T1", "08:00:00", "08:00:00", "STOP_A", 1),
            ("T1", "08:10:00", "08:10:00", "STOP_C", 2),
            ("T2", "08:14:00", "08:14:00", "STOP_C", 1),
            ("T2", "08:25:00", "08:25:00", "STOP_E", 2),
        ],
    )
    conn.execute(
        """
        INSERT INTO calendar
        VALUES ('WKD', 1, 1, 1, 1, 1, 1, 1, '20240101', '20300101')
        """
    )
    conn.commit()
    conn.close()


def _timestamp(hour: int, minute: int) -> int:
    now = datetime.now().astimezone()
    dt = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    return int(dt.timestamp())


def test_engine_routes_cover_backend_state_without_local_planner(
    tmp_path: Path,
    monkeypatch: MonkeyPatch,
) -> None:
    schedule_db = tmp_path / "schedule.db"
    state_db = tmp_path / "state.db"
    _build_schedule_db(schedule_db)

    monkeypatch.setenv("TRACK_ENGINE_SCHEDULE_DB", str(schedule_db))
    monkeypatch.setenv("TRACK_ENGINE_STATE_DB", str(state_db))
    monkeypatch.setenv("TRACK_ENGINE_STATE_BACKEND", "sqlite")
    monkeypatch.setenv("TRACK_ENGINE_ENABLE_REALTIME_ENRICHMENT", "0")
    monkeypatch.setenv("TRACK_ENGINE_URL", "")
    reset_engine_service()

    save_place_resp = client.post(
        "/engine/places",
        json={
            "user_id": str(MOCK_USER_ID),
            "label": "Work",
            "kind": "work",
            "lat": 40.0020,
            "lon": -73.0000,
            "address": "Echo Ave",
        },
    )
    assert save_place_resp.status_code == 200
    assert save_place_resp.json()["label"] == "Work"

    search_resp = client.get("/engine/search", params={"q": "wo", "user_id": str(MOCK_USER_ID)})
    assert search_resp.status_code == 200
    assert search_resp.json()[0]["label"] == "Work"

    save_trip_resp = client.post(
        "/engine/trips/saved",
        json={
            "user_id": str(MOCK_USER_ID),
            "name": "Morning commute",
            "origin": {
                "label": "Home",
                "lat": 40.0000,
                "lon": -73.0000,
            },
            "destination": {
                "label": "Work",
                "lat": 40.0020,
                "lon": -73.0000,
            },
            "preferred_departure_hour": 8,
            "preferred_arrival_hour": 9,
            "preferred_modes": ["subway", "bus"],
        },
    )
    assert save_trip_resp.status_code == 200
    assert save_trip_resp.json()["name"] == "Morning commute"

    calendar_resp = client.request(
        "PUT",
        "/engine/calendar/events",
        params={"user_id": str(MOCK_USER_ID)},
        json=[
            {
                "external_id": "event-1",
                "title": "Standup",
                "location_label": "Work",
                "lat": 40.0020,
                "lon": -73.0000,
                "starts_at": _timestamp(9, 0),
                "ends_at": _timestamp(10, 0),
            }
        ],
    )
    assert calendar_resp.status_code == 200

    health_resp = client.get("/engine/health")
    assert health_resp.status_code == 200
    health_payload = health_resp.json()
    assert health_payload["routing_backend"] == "backend_state_only"

    plan_resp = client.post(
        "/engine/plan",
        json={
            "user_id": str(MOCK_USER_ID),
            "origin": {
                "label": "Home",
                "lat": 40.0000,
                "lon": -73.0000,
            },
            "destination": {
                "label": "Work",
                "lat": 40.0020,
                "lon": -73.0000,
            },
            "depart_at_ts": _timestamp(7, 58),
            "max_transfers": 1,
            "max_origin_walk_m": 50,
            "max_destination_walk_m": 50,
            "num_itineraries": 2,
        },
    )
    assert plan_resp.status_code == 503
    assert "TRACK_ENGINE_URL is not configured" in plan_resp.json()["detail"]

    go_resp = client.post(
        "/engine/go",
        json={
            "user_id": str(MOCK_USER_ID),
            "origin": {
                "label": "Home",
                "lat": 40.0000,
                "lon": -73.0000,
            },
            "destination": {
                "label": "Work",
                "lat": 40.0020,
                "lon": -73.0000,
            },
            "depart_at_ts": _timestamp(7, 58),
            "now_ts": _timestamp(7, 58),
            "max_transfers": 1,
            "max_origin_walk_m": 50,
            "max_destination_walk_m": 50,
            "num_itineraries": 2,
        },
    )
    assert go_resp.status_code == 503
    assert "TRACK_ENGINE_URL is not configured" in go_resp.json()["detail"]

    recents_resp = client.get("/engine/trips/recent", params={"user_id": str(MOCK_USER_ID)})
    assert recents_resp.status_code == 200
    assert recents_resp.json() == []

    recs_resp = client.get(
        "/engine/recommendations",
        params={
            "user_id": str(MOCK_USER_ID),
            "origin_lat": 40.0000,
            "origin_lon": -73.0000,
            "origin_label": "Home",
            "now_ts": _timestamp(8, 15),
        },
    )
    assert recs_resp.status_code == 200
    assert recs_resp.json()[0]["label"] == "Work"

    os.environ.pop("TRACK_ENGINE_SCHEDULE_DB", None)
    os.environ.pop("TRACK_ENGINE_STATE_DB", None)
    os.environ.pop("TRACK_ENGINE_STATE_BACKEND", None)
    reset_engine_service()


def test_engine_search_bbox_filtering(
    tmp_path: Path,
    monkeypatch: MonkeyPatch,
) -> None:
    schedule_db = tmp_path / "schedule_bbox.db"
    state_db = tmp_path / "state_bbox.db"
    _build_schedule_db(schedule_db)

    monkeypatch.setenv("TRACK_ENGINE_SCHEDULE_DB", str(schedule_db))
    monkeypatch.setenv("TRACK_ENGINE_STATE_DB", str(state_db))
    monkeypatch.setenv("TRACK_ENGINE_STATE_BACKEND", "sqlite")
    monkeypatch.setenv("TRACK_ENGINE_URL", "")
    reset_engine_service()

    # 1. Search without bbox — returns "Alpha" at (40.0, -73.0)
    search_all = client.get("/engine/search", params={"q": "alpha"})
    assert search_all.status_code == 200
    payload_all = search_all.json()
    assert any(r["label"] == "Alpha" for r in payload_all), f"Expected Alpha in {payload_all}"

    # 2. Search with bbox that INCLUDES Alpha (40.0, -73.0)
    # min_lon, min_lat, max_lon, max_lat
    bbox_inc = "-73.1,39.9,-72.9,40.1"
    search_inc = client.get("/engine/search", params={"q": "alpha", "bbox": bbox_inc})
    assert search_inc.status_code == 200
    payload_inc = search_inc.json()
    assert any(r["label"] == "Alpha" for r in payload_inc), f"Expected Alpha in {payload_inc}"

    # 3. Search with bbox that EXCLUDES Alpha (40.0, -73.0)
    # This bbox is far away in NYC (Alpha is at 40.0, -73.0)
    bbox_exc = "-74.1,40.6,-73.9,40.8"
    search_exc = client.get("/engine/search", params={"q": "alpha", "bbox": bbox_exc})
    assert search_exc.status_code == 200
    payload_exc = search_exc.json()
    assert not any(r["label"] == "Alpha" for r in payload_exc), f"Expected NO Alpha in {payload_exc}"

    os.environ.pop("TRACK_ENGINE_SCHEDULE_DB", None)
    os.environ.pop("TRACK_ENGINE_STATE_DB", None)
    os.environ.pop("TRACK_ENGINE_STATE_BACKEND", None)
    reset_engine_service()


def test_engine_search_degrades_when_schedule_db_has_no_stops_table(
    tmp_path: Path,
    monkeypatch: MonkeyPatch,
) -> None:
    schedule_db = tmp_path / "schedule_missing_stops.db"
    state_db = tmp_path / "state.db"
    conn = sqlite3.connect(schedule_db)
    conn.execute("CREATE TABLE calendar (service_id TEXT PRIMARY KEY)")
    conn.commit()
    conn.close()

    monkeypatch.setenv("TRACK_ENGINE_SCHEDULE_DB", str(schedule_db))
    monkeypatch.setenv("TRACK_ENGINE_STATE_DB", str(state_db))
    monkeypatch.setenv("TRACK_ENGINE_STATE_BACKEND", "sqlite")
    monkeypatch.setenv("TRACK_ENGINE_ENABLE_REALTIME_ENRICHMENT", "0")
    monkeypatch.setenv("TRACK_ENGINE_URL", "")
    reset_engine_service()

    save_place_resp = client.post(
        "/engine/places",
        json={
            "user_id": str(MOCK_USER_ID),
            "label": "Richmond Hill High School",
            "kind": "school",
            "lat": 40.6945,
            "lon": -73.8312,
            "address": "89-30 114th St",
        },
    )
    assert save_place_resp.status_code == 200

    search_resp = client.get(
        "/engine/search",
        params={"q": "richmond", "user_id": str(MOCK_USER_ID)},
    )
    assert search_resp.status_code == 200
    payload = search_resp.json()
    assert payload
    assert payload[0]["label"] == "Richmond Hill High School"

    os.environ.pop("TRACK_ENGINE_SCHEDULE_DB", None)
    os.environ.pop("TRACK_ENGINE_STATE_DB", None)
    os.environ.pop("TRACK_ENGINE_STATE_BACKEND", None)
    reset_engine_service()


def test_engine_search_and_health_degrade_when_schedule_db_is_invalid(
    tmp_path: Path,
    monkeypatch: MonkeyPatch,
) -> None:
    schedule_db = tmp_path / "schedule_invalid.db"
    state_db = tmp_path / "state.db"
    schedule_db.write_text("not a sqlite database")

    monkeypatch.setenv("TRACK_ENGINE_SCHEDULE_DB", str(schedule_db))
    monkeypatch.setenv("TRACK_ENGINE_STATE_DB", str(state_db))
    monkeypatch.setenv("TRACK_ENGINE_STATE_BACKEND", "sqlite")
    monkeypatch.setenv("TRACK_ENGINE_ENABLE_REALTIME_ENRICHMENT", "0")
    monkeypatch.setenv("TRACK_ENGINE_URL", "")
    reset_engine_service()

    save_place_resp = client.post(
        "/engine/places",
        json={
            "user_id": str(MOCK_USER_ID),
            "label": "Work",
            "kind": "work",
            "lat": 40.0020,
            "lon": -73.0000,
            "address": "Echo Ave",
        },
    )
    assert save_place_resp.status_code == 200

    search_resp = client.get("/engine/search", params={"q": "wo", "user_id": str(MOCK_USER_ID)})
    assert search_resp.status_code == 200
    assert search_resp.json()[0]["label"] == "Work"

    health_resp = client.get("/engine/health")
    assert health_resp.status_code == 200
    health_payload = health_resp.json()
    assert health_payload["prepared"] is False
    assert health_payload["schedule_db_error"] is not None

    os.environ.pop("TRACK_ENGINE_SCHEDULE_DB", None)
    os.environ.pop("TRACK_ENGINE_STATE_DB", None)
    os.environ.pop("TRACK_ENGINE_STATE_BACKEND", None)
    reset_engine_service()


def test_engine_schedule_artifact_endpoint_exports_gzip_snapshot(
    tmp_path: Path,
    monkeypatch: MonkeyPatch,
) -> None:
    schedule_db = tmp_path / "schedule.db"
    state_db = tmp_path / "state.db"
    exported_db = tmp_path / "exported.db"
    _build_schedule_db(schedule_db)

    monkeypatch.setenv("TRACK_ENGINE_SCHEDULE_DB", str(schedule_db))
    monkeypatch.setenv("TRACK_ENGINE_STATE_DB", str(state_db))
    monkeypatch.setenv("TRACK_ENGINE_STATE_BACKEND", "sqlite")
    monkeypatch.setenv("TRACK_ENGINE_ENABLE_REALTIME_ENRICHMENT", "0")
    monkeypatch.setenv("TRACK_ENGINE_URL", "")
    reset_engine_service()

    response = client.get("/engine/bootstrap/schedule-db.gz")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/gzip")

    exported_db.write_bytes(gzip.decompress(response.content))
    conn = sqlite3.connect(exported_db)
    try:
        stop_names = {
            row[0] for row in conn.execute("SELECT stop_name FROM stops").fetchall()
        }
    finally:
        conn.close()

    assert {"Alpha", "Charlie", "Echo"}.issubset(stop_names)

    os.environ.pop("TRACK_ENGINE_SCHEDULE_DB", None)
    os.environ.pop("TRACK_ENGINE_STATE_DB", None)
    os.environ.pop("TRACK_ENGINE_STATE_BACKEND", None)
    reset_engine_service()
