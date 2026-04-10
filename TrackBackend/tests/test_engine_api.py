"""API tests for the /engine routes."""

from __future__ import annotations

import os
import sqlite3
from datetime import datetime
from typing import TYPE_CHECKING

from fastapi.testclient import TestClient

from app.main import app
from app.services.track_engine.integration import reset_engine_service

client = TestClient(app)

if TYPE_CHECKING:
    from pathlib import Path

    from pytest import MonkeyPatch


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
    monkeypatch.setenv("TRACK_ENGINE_ENABLE_REALTIME_ENRICHMENT", "0")
    reset_engine_service()

    save_place_resp = client.post(
        "/engine/places",
        json={
            "user_id": "user-1",
            "label": "Work",
            "kind": "work",
            "lat": 40.0020,
            "lon": -73.0000,
            "address": "Echo Ave",
        },
    )
    assert save_place_resp.status_code == 200
    assert save_place_resp.json()["label"] == "Work"

    search_resp = client.get("/engine/search", params={"q": "wo", "user_id": "user-1"})
    assert search_resp.status_code == 200
    assert search_resp.json()[0]["label"] == "Work"

    save_trip_resp = client.post(
        "/engine/trips/saved",
        json={
            "user_id": "user-1",
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
        params={"user_id": "user-1"},
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
    assert health_resp.json()["routing_backend"] == "backend_state_only"

    plan_resp = client.post(
        "/engine/plan",
        json={
            "user_id": "user-1",
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
            "user_id": "user-1",
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

    recents_resp = client.get("/engine/trips/recent", params={"user_id": "user-1"})
    assert recents_resp.status_code == 200
    assert recents_resp.json() == []

    recs_resp = client.get(
        "/engine/recommendations",
        params={
            "user_id": "user-1",
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
    reset_engine_service()
