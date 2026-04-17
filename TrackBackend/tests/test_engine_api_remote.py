"""Remote C++ engine integration tests for the /engine routes."""

from __future__ import annotations

import json
import os
import shutil
import socket
import sqlite3
import subprocess
import time
import urllib.request
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.services.track_engine.integration import reset_engine_service
from app.services.transit.db_pool import schedule_pool

client = TestClient(app)
NY_TZ = ZoneInfo("America/New_York")


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
        CREATE TABLE stop_modes (
            stop_id TEXT,
            route_type INTEGER
        );
        CREATE INDEX idx_stop_modes_stop_type
            ON stop_modes(stop_id, route_type);
        """
    )
    conn.executemany(
        "INSERT INTO routes VALUES (?, ?, ?, ?, ?)",
        [
            ("R1", "Q7", "Queens Bus 7", "F9A825", 3),
            ("R2", "Q37", "Queens Bus 37", "59ADEB", 3),
            ("R3", "E", "8 Avenue Local", "2850AD", 1),
        ],
    )
    conn.executemany(
        "INSERT INTO trips VALUES (?, ?, ?, ?, ?)",
        [
            ("T1", "R1", "WKD", "Queens Village", 0),
            ("T2", "R2", "WKD", "Kew Gardens", 0),
            ("T3", "R3", "WKD", "Manhattan", 0),
        ],
    )
    conn.executemany(
        "INSERT INTO stops VALUES (?, ?, ?, ?)",
        [
            ("STOP_A", "Origin Stop", 40.00000, -73.00000),
            ("STOP_B", "Transfer One", 40.00070, -73.00000),
            ("STOP_C", "Transfer Two", 40.00140, -73.00000),
            ("STOP_D", "Destination Stop", 40.01000, -73.00000),
        ],
    )
    conn.executemany(
        "INSERT INTO stop_times VALUES (?, ?, ?, ?, ?)",
        [
            ("T1", "08:00:00", "08:00:00", "STOP_A", 1),
            ("T1", "08:05:00", "08:05:00", "STOP_B", 2),
            ("T2", "08:09:00", "08:09:00", "STOP_B", 1),
            ("T2", "08:14:00", "08:14:00", "STOP_C", 2),
            ("T3", "08:18:00", "08:18:00", "STOP_C", 1),
            ("T3", "08:24:00", "08:24:00", "STOP_D", 2),
        ],
    )
    conn.execute(
        """
        INSERT INTO calendar
        VALUES ('WKD', 1, 1, 1, 1, 1, 1, 1, '20240101', '20300101')
        """
    )
    conn.executemany(
        "INSERT INTO stop_modes VALUES (?, ?)",
        [
            ("STOP_A", 3),  # bus
            ("STOP_B", 3),  # bus
            ("STOP_C", 1),  # subway
            ("STOP_C", 3),  # bus
            ("STOP_D", 1),  # subway
        ],
    )
    conn.commit()
    conn.close()


def _build_stale_bus_schedule_db(path: Path) -> None:
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
        CREATE TABLE stop_modes (
            stop_id TEXT,
            route_type INTEGER
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
        CREATE INDEX idx_stop_modes_stop_type
            ON stop_modes(stop_id, route_type);
        """
    )
    conn.executemany(
        "INSERT INTO routes VALUES (?, ?, ?, ?, ?)",
        [
            ("SUB", "A", "Subway Connector", "2850AD", 1),
            ("BUS", "Q10", "Neighborhood Bus", "C218D2", 3),
        ],
    )
    conn.executemany(
        "INSERT INTO trips VALUES (?, ?, ?, ?, ?)",
        [
            ("SUB_TRIP", "SUB", "SUBWAY_ALWAYS", "Transfer Stop", 0),
            ("BUS_TRIP", "BUS", "BUS_EXPIRED", "Destination Stop", 0),
        ],
    )
    conn.executemany(
        "INSERT INTO stops VALUES (?, ?, ?, ?)",
        [
            ("STOP_ORIGIN", "Origin Stop", 40.00000, -73.00000),
            ("STOP_SUBWAY", "Subway Transfer", 40.00070, -73.00000),
            ("STOP_BUS", "Bus Transfer", 40.00072, -73.00008),
            ("STOP_DEST", "Destination Stop", 40.01000, -73.00000),
        ],
    )
    conn.executemany(
        "INSERT INTO stop_times VALUES (?, ?, ?, ?, ?)",
        [
            ("SUB_TRIP", "20:00:00", "20:00:00", "STOP_ORIGIN", 1),
            ("SUB_TRIP", "20:05:00", "20:05:00", "STOP_SUBWAY", 2),
            ("BUS_TRIP", "20:08:00", "20:08:00", "STOP_BUS", 1),
            ("BUS_TRIP", "20:18:00", "20:18:00", "STOP_DEST", 2),
        ],
    )
    conn.executemany(
        "INSERT INTO calendar VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
            ("SUBWAY_ALWAYS", 1, 1, 1, 1, 1, 1, 1, "20240101", "20300101"),
            ("BUS_EXPIRED", 0, 0, 0, 0, 0, 1, 0, "20260101", "20260328"),
        ],
    )
    conn.executemany(
        "INSERT INTO stop_modes VALUES (?, ?)",
        [
            ("STOP_ORIGIN", 1),
            ("STOP_SUBWAY", 1),
            ("STOP_BUS", 3),
            ("STOP_DEST", 3),
        ],
    )
    conn.commit()
    conn.close()


def _build_future_bus_schedule_db(path: Path) -> None:
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
        CREATE TABLE stop_modes (
            stop_id TEXT,
            route_type INTEGER
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
        CREATE INDEX idx_stop_modes_stop_type
            ON stop_modes(stop_id, route_type);
        """
    )
    conn.executemany(
        "INSERT INTO routes VALUES (?, ?, ?, ?, ?)",
        [
            ("SUB", "A", "Subway Connector", "2850AD", 1),
            ("BUS", "Q10", "Neighborhood Bus", "C218D2", 3),
        ],
    )
    conn.executemany(
        "INSERT INTO trips VALUES (?, ?, ?, ?, ?)",
        [
            ("SUB_TRIP", "SUB", "SUBWAY_ALWAYS", "Transfer Stop", 0),
            ("BUS_TRIP", "BUS", "BUS_FUTURE", "Destination Stop", 0),
        ],
    )
    conn.executemany(
        "INSERT INTO stops VALUES (?, ?, ?, ?)",
        [
            ("STOP_ORIGIN", "Origin Stop", 40.00000, -73.00000),
            ("STOP_SUBWAY", "Subway Transfer", 40.00070, -73.00000),
            ("STOP_BUS", "Bus Transfer", 40.00072, -73.00008),
            ("STOP_DEST", "Destination Stop", 40.01000, -73.00000),
        ],
    )
    conn.executemany(
        "INSERT INTO stop_times VALUES (?, ?, ?, ?, ?)",
        [
            ("SUB_TRIP", "20:00:00", "20:00:00", "STOP_ORIGIN", 1),
            ("SUB_TRIP", "20:05:00", "20:05:00", "STOP_SUBWAY", 2),
            ("BUS_TRIP", "20:08:00", "20:08:00", "STOP_BUS", 1),
            ("BUS_TRIP", "20:18:00", "20:18:00", "STOP_DEST", 2),
        ],
    )
    conn.executemany(
        "INSERT INTO calendar VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
            ("SUBWAY_ALWAYS", 1, 1, 1, 1, 1, 1, 1, "20240101", "20300101"),
            ("BUS_FUTURE", 0, 0, 0, 0, 0, 1, 0, "20260418", "20260627"),
        ],
    )
    conn.executemany(
        "INSERT INTO stop_modes VALUES (?, ?)",
        [
            ("STOP_ORIGIN", 1),
            ("STOP_SUBWAY", 1),
            ("STOP_BUS", 3),
            ("STOP_DEST", 3),
        ],
    )
    conn.commit()
    conn.close()


def _timestamp(hour: int, minute: int) -> int:
    now = datetime.now().astimezone()
    dt = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    return int(dt.timestamp())


def _fixed_timestamp(year: int, month: int, day: int, hour: int, minute: int) -> int:
    return int(datetime(year, month, day, hour, minute, tzinfo=NY_TZ).timestamp())


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


@pytest.mark.skipif(shutil.which("c++") is None, reason="c++ compiler not installed")
def test_backend_plan_route_uses_remote_cpp_engine(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    schedule_db = tmp_path / "schedule.db"
    state_db = tmp_path / "state.db"
    _build_schedule_db(schedule_db)

    repo_root = Path(__file__).resolve().parents[2]
    engine_root = repo_root / "TrackEngine"
    build = subprocess.run(
        [str(engine_root / "scripts" / "build.sh")],
        cwd=repo_root,
        check=True,
        capture_output=True,
        text=True,
    )
    binary = build.stdout.strip().splitlines()[-1]
    port = _free_port()
    process = subprocess.Popen(
        [binary],
        cwd=repo_root,
        env={
            **os.environ,
            "PORT": str(port),
            "TRACK_ENGINE_SCHEDULE_DB": str(schedule_db),
        },
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as response:
                    payload = json.loads(response.read().decode())
                    if payload["ready"]:
                        assert payload["missing_indexes"] == []
                        break
            except Exception:
                time.sleep(0.2)
        else:
            output = process.stdout.read() if process.stdout else ""
            raise AssertionError(f"remote engine never became healthy\n{output}")

        monkeypatch.setenv("TRACK_ENGINE_SCHEDULE_DB", str(schedule_db))
        monkeypatch.setenv("TRACK_ENGINE_STATE_DB", str(state_db))
        monkeypatch.setenv("TRACK_ENGINE_STATE_BACKEND", "sqlite")
        monkeypatch.setenv("TRACK_ENGINE_URL", f"http://127.0.0.1:{port}")
        monkeypatch.setenv("TRACK_ENGINE_ENABLE_REALTIME_ENRICHMENT", "0")
        monkeypatch.setattr(schedule_pool, "_db_path", Path(str(schedule_db)))
        monkeypatch.setattr(schedule_pool, "_opened", False)
        monkeypatch.setattr(schedule_pool, "_pool", None)
        monkeypatch.setattr(schedule_pool, "_connections", [])
        reset_engine_service()

        health_resp = client.get("/engine/health")
        assert health_resp.status_code == 200
        assert health_resp.json()["routing_backend"] == "cpp_remote"
        assert health_resp.json()["remote_engine_healthy"] is True

        plan_resp = client.post(
            "/engine/plan",
            json={
                "user_id": "user-1",
                "origin": {"label": "Home", "lat": 40.00001, "lon": -73.00000},
                "destination": {"label": "Work", "lat": 40.01001, "lon": -73.00000},
                "depart_at_ts": _timestamp(7, 58),
                "max_transfers": 2,
                "max_origin_walk_m": 50,
                "max_destination_walk_m": 50,
                "max_transfer_walk_m": 50,
                "num_itineraries": 3,
            },
        )
        assert plan_resp.status_code == 200
        payload = plan_resp.json()
        assert payload["engine_version"] == health_resp.json()["remote_engine_version"]
        assert payload["itineraries"]
        assert payload["itineraries"][0]["transfer_count"] == 2
        route_ids = [
            leg["route_id"]
            for leg in payload["itineraries"][0]["legs"]
            if leg["mode"] != "walk"
        ]
        assert route_ids == ["R1", "R2", "R3"]

        go_resp = client.post(
            "/engine/go",
            json={
                "user_id": "user-1",
                "origin": {"label": "Home", "lat": 40.00001, "lon": -73.00000},
                "destination": {"label": "Work", "lat": 40.01001, "lon": -73.00000},
                "depart_at_ts": _timestamp(7, 58),
                "now_ts": _timestamp(7, 58),
                "max_transfers": 2,
                "max_origin_walk_m": 50,
                "max_destination_walk_m": 50,
                "max_transfer_walk_m": 50,
                "num_itineraries": 3,
            },
        )
        assert go_resp.status_code == 200
        go_payload = go_resp.json()
        assert go_payload["primary_trip"] is not None
        transit_chip_labels = [
            chip["label"]
            for chip in go_payload["primary_trip"]["route_chips"]
            if chip["kind"] == "transit"
        ]
        assert transit_chip_labels == ["Q7", "Q37", "E"]
        assert len(go_payload["primary_trip"]["transfers"]) == 2
        assert go_payload["primary_trip"]["status"] == "upcoming"
        assert go_payload["primary_trip"]["next_action"]["title"].startswith("Leave")

        recents_resp = client.get("/engine/trips/recent", params={"user_id": "user-1"})
        assert recents_resp.status_code == 200
        assert recents_resp.json()[0]["destination_label"] == "Work"
        assert recents_resp.json()[0]["route_tokens"][1:4] == ["Q7", "Q37", "E"]
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
        monkeypatch.delenv("TRACK_ENGINE_URL", raising=False)
        reset_engine_service()


@pytest.mark.skipif(shutil.which("c++") is None, reason="c++ compiler not installed")
def test_backend_bus_schedule_fallback_preserves_requested_day(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    schedule_db = tmp_path / "stale_bus.db"
    state_db = tmp_path / "state.db"
    _build_stale_bus_schedule_db(schedule_db)

    repo_root = Path(__file__).resolve().parents[2]
    engine_root = repo_root / "TrackEngine"
    build = subprocess.run(
        [str(engine_root / "scripts" / "build.sh")],
        cwd=repo_root,
        check=True,
        capture_output=True,
        text=True,
    )
    binary = build.stdout.strip().splitlines()[-1]
    port = _free_port()
    process = subprocess.Popen(
        [binary],
        cwd=repo_root,
        env={
            **os.environ,
            "PORT": str(port),
            "TRACK_ENGINE_SCHEDULE_DB": str(schedule_db),
        },
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as response:
                    payload = json.loads(response.read().decode())
                    if payload["ready"]:
                        break
            except Exception:
                time.sleep(0.2)
        else:
            output = process.stdout.read() if process.stdout else ""
            raise AssertionError(f"remote engine never became healthy\n{output}")

        monkeypatch.setenv("TRACK_ENGINE_SCHEDULE_DB", str(schedule_db))
        monkeypatch.setenv("TRACK_ENGINE_STATE_DB", str(state_db))
        monkeypatch.setenv("TRACK_ENGINE_STATE_BACKEND", "sqlite")
        monkeypatch.setenv("TRACK_ENGINE_URL", f"http://127.0.0.1:{port}")
        monkeypatch.setenv("TRACK_ENGINE_ENABLE_REALTIME_ENRICHMENT", "0")
        monkeypatch.setattr(schedule_pool, "_db_path", Path(str(schedule_db)))
        monkeypatch.setattr(schedule_pool, "_opened", False)
        monkeypatch.setattr(schedule_pool, "_pool", None)
        monkeypatch.setattr(schedule_pool, "_connections", [])
        reset_engine_service()

        depart_at = _fixed_timestamp(2026, 4, 11, 19, 58)
        go_now = _fixed_timestamp(2026, 4, 11, 19, 58)

        plan_resp = client.post(
            "/engine/plan",
            json={
                "origin": {"label": "Home", "lat": 40.00001, "lon": -73.00000},
                "destination": {"label": "Work", "lat": 40.01001, "lon": -73.00000},
                "depart_at_ts": depart_at,
                "max_transfers": 1,
                "max_origin_walk_m": 50,
                "max_destination_walk_m": 50,
                "max_transfer_walk_m": 50,
                "modes": ["subway", "bus"],
                "num_itineraries": 2,
            },
        )
        assert plan_resp.status_code == 200
        plan_payload = plan_resp.json()
        assert plan_payload["itineraries"]
        assert plan_payload["schedule_note"] == "Using latest available bus schedule from Saturday, Mar 28"
        assert any(
            leg["mode"] == "bus"
            for leg in plan_payload["itineraries"][0]["legs"]
        )
        leave_at = datetime.fromtimestamp(
            plan_payload["itineraries"][0]["leave_at_ts"],
            NY_TZ,
        )
        assert leave_at.date().isoformat() == "2026-04-11"

        go_resp = client.post(
            "/engine/go",
            json={
                "origin": {"label": "Home", "lat": 40.00001, "lon": -73.00000},
                "destination": {"label": "Work", "lat": 40.01001, "lon": -73.00000},
                "depart_at_ts": depart_at,
                "now_ts": go_now,
                "max_transfers": 1,
                "max_origin_walk_m": 50,
                "max_destination_walk_m": 50,
                "max_transfer_walk_m": 50,
                "modes": ["subway", "bus"],
                "num_itineraries": 2,
            },
        )
        assert go_resp.status_code == 200
        go_payload = go_resp.json()
        assert go_payload["schedule_note"] == "Using latest available bus schedule from Saturday, Mar 28"
        assert go_payload["primary_trip"] is not None
        assert go_payload["primary_trip"]["leave_in_s"] >= 0
        assert any(
            leg["mode"] == "bus"
            for leg in go_payload["primary_trip"]["itinerary"]["legs"]
        )
        go_leave_at = datetime.fromtimestamp(
            go_payload["primary_trip"]["itinerary"]["leave_at_ts"],
            NY_TZ,
        )
        assert go_leave_at.date().isoformat() == "2026-04-11"
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
        monkeypatch.delenv("TRACK_ENGINE_URL", raising=False)
        reset_engine_service()


@pytest.mark.skipif(shutil.which("c++") is None, reason="c++ compiler not installed")
def test_backend_future_bus_schedule_fallback_uses_next_matching_service_day(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    schedule_db = tmp_path / "future_bus.db"
    state_db = tmp_path / "state.db"
    _build_future_bus_schedule_db(schedule_db)

    repo_root = Path(__file__).resolve().parents[2]
    engine_root = repo_root / "TrackEngine"
    build = subprocess.run(
        [str(engine_root / "scripts" / "build.sh")],
        cwd=repo_root,
        check=True,
        capture_output=True,
        text=True,
    )
    binary = build.stdout.strip().splitlines()[-1]
    port = _free_port()
    process = subprocess.Popen(
        [binary],
        cwd=repo_root,
        env={
            **os.environ,
            "PORT": str(port),
            "TRACK_ENGINE_SCHEDULE_DB": str(schedule_db),
        },
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as response:
                    payload = json.loads(response.read().decode())
                    if payload["ready"]:
                        break
            except Exception:
                time.sleep(0.2)
        else:
            output = process.stdout.read() if process.stdout else ""
            raise AssertionError(f"remote engine never became healthy\n{output}")

        monkeypatch.setenv("TRACK_ENGINE_SCHEDULE_DB", str(schedule_db))
        monkeypatch.setenv("TRACK_ENGINE_STATE_DB", str(state_db))
        monkeypatch.setenv("TRACK_ENGINE_STATE_BACKEND", "sqlite")
        monkeypatch.setenv("TRACK_ENGINE_URL", f"http://127.0.0.1:{port}")
        monkeypatch.setenv("TRACK_ENGINE_ENABLE_REALTIME_ENRICHMENT", "0")
        monkeypatch.setattr(schedule_pool, "_db_path", Path(str(schedule_db)))
        monkeypatch.setattr(schedule_pool, "_opened", False)
        monkeypatch.setattr(schedule_pool, "_pool", None)
        monkeypatch.setattr(schedule_pool, "_connections", [])
        reset_engine_service()

        depart_at = _fixed_timestamp(2026, 4, 11, 19, 58)
        go_now = _fixed_timestamp(2026, 4, 11, 19, 58)

        plan_resp = client.post(
            "/engine/plan",
            json={
                "origin": {"label": "Home", "lat": 40.00001, "lon": -73.00000},
                "destination": {"label": "Work", "lat": 40.01001, "lon": -73.00000},
                "depart_at_ts": depart_at,
                "max_transfers": 1,
                "max_origin_walk_m": 50,
                "max_destination_walk_m": 50,
                "max_transfer_walk_m": 50,
                "modes": ["subway", "bus"],
                "num_itineraries": 2,
            },
        )
        assert plan_resp.status_code == 200
        plan_payload = plan_resp.json()
        assert plan_payload["itineraries"]
        assert (
            plan_payload["schedule_note"]
            == "Using next available bus schedule from Saturday, Apr 18"
        )
        assert any(
            leg["mode"] == "bus"
            for leg in plan_payload["itineraries"][0]["legs"]
        )
        leave_at = datetime.fromtimestamp(
            plan_payload["itineraries"][0]["leave_at_ts"],
            NY_TZ,
        )
        assert leave_at.date().isoformat() == "2026-04-11"

        go_resp = client.post(
            "/engine/go",
            json={
                "origin": {"label": "Home", "lat": 40.00001, "lon": -73.00000},
                "destination": {"label": "Work", "lat": 40.01001, "lon": -73.00000},
                "depart_at_ts": depart_at,
                "now_ts": go_now,
                "max_transfers": 1,
                "max_origin_walk_m": 50,
                "max_destination_walk_m": 50,
                "max_transfer_walk_m": 50,
                "modes": ["subway", "bus"],
                "num_itineraries": 2,
            },
        )
        assert go_resp.status_code == 200
        go_payload = go_resp.json()
        assert (
            go_payload["schedule_note"]
            == "Using next available bus schedule from Saturday, Apr 18"
        )
        assert go_payload["primary_trip"] is not None
        assert any(
            leg["mode"] == "bus"
            for leg in go_payload["primary_trip"]["itinerary"]["legs"]
        )
        go_leave_at = datetime.fromtimestamp(
            go_payload["primary_trip"]["itinerary"]["leave_at_ts"],
            NY_TZ,
        )
        assert go_leave_at.date().isoformat() == "2026-04-11"
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
        monkeypatch.delenv("TRACK_ENGINE_URL", raising=False)
        reset_engine_service()
