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

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.services.track_engine.integration import reset_engine_service

client = TestClient(app)


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
    conn.commit()
    conn.close()


def _timestamp(hour: int, minute: int) -> int:
    now = datetime.now().astimezone()
    dt = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    return int(dt.timestamp())


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
        monkeypatch.setenv("TRACK_ENGINE_URL", f"http://127.0.0.1:{port}")
        monkeypatch.setenv("TRACK_ENGINE_ENABLE_REALTIME_ENRICHMENT", "0")
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
        assert payload["engine_version"] == "0.3.0"
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
