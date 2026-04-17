"""
Cross-stack integration tests: iOS payload → Python backend → C++ engine.

Verifies that user-configurable parameters (mode toggles, arrive_by,
search_window, priority, num_itineraries) flow correctly through the
full pipeline and that the backend parses / returns the engine's
response with all fields intact.

Requires: c++ compiler, Python backend dependencies in the venv.
"""

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

client = TestClient(app)
NY_TZ = ZoneInfo("America/New_York")

# ── Database builder ──────────────────────────────────────────────

_SCHEMA = """
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


def _gtfs(minutes_from_midnight: int) -> str:
    """Convert minutes-from-midnight to HH:MM:SS GTFS time string."""
    h, m = divmod(minutes_from_midnight, 60)
    return f"{h:02d}:{m:02d}:00"


def _build_rich_db(path: Path, base_minutes: int) -> None:
    """
    Build a schedule with trips relative to *base_minutes* (minutes
    past midnight).  This ensures tests pass no matter what time of
    day they run.

      - 2 bus routes (BUS_A, BUS_B) serving SA→SB and SB→SD
      - 1 subway route (E) serving SA→SD (direct, faster)
      - Multiple trips at staggered times around base_minutes
      - A "late" bus trip 120 min after base (outside any 30-min window)
      - stop_modes table (mirrors production schema)
    """
    conn = sqlite3.connect(path)
    conn.executescript(_SCHEMA)
    conn.execute(
        "INSERT INTO calendar "
        "VALUES ('WKD',1,1,1,1,1,1,1,'20240101','20300101')"
    )
    conn.executemany("INSERT INTO routes VALUES (?,?,?,?,?)", [
        ("BUS_A",  "Q7",  "Queens Bus 7",       "F9A825", 3),    # bus
        ("BUS_B",  "Q37", "Queens Bus 37",       "59ADEB", 3),    # bus
        ("E",      None,  "8 Avenue Local",      "2850AD", 1),    # subway
    ])
    trips = []
    stimes = []
    B = base_minutes  # shorthand

    # --- Bus A trips: SA→SB (5 trips, depart B+0 .. B+20 every 5 min) ---
    for i in range(5):
        tid = f"BA{i}"
        dep = B + i * 5
        arr = dep + 8
        trips.append((tid, "BUS_A", "WKD", "Queens Village", 0))
        stimes.append((tid, _gtfs(dep), _gtfs(dep), "SA", 1))
        stimes.append((tid, _gtfs(arr), _gtfs(arr), "SB", 2))

    # --- Bus B trips: SB→SD (5 trips, depart B+12 .. B+32 every 5 min) ---
    for i in range(5):
        tid = f"BB{i}"
        dep = B + 12 + i * 5
        arr = dep + 10
        trips.append((tid, "BUS_B", "WKD", "Kew Gardens", 0))
        stimes.append((tid, _gtfs(dep), _gtfs(dep), "SB", 1))
        stimes.append((tid, _gtfs(arr), _gtfs(arr), "SD", 2))

    # --- Subway E: SA→SD direct (depart B+2, arrive B+10) ---
    trips.append(("SUB1", "E", "WKD", "World Trade Center", 0))
    stimes.append(("SUB1", _gtfs(B + 2), _gtfs(B + 2), "SA", 1))
    stimes.append(("SUB1", _gtfs(B + 10), _gtfs(B + 10), "SD", 2))

    # --- Late bus trip (B+120, well outside any 30-min window) ---
    trips.append(("BA_LATE", "BUS_A", "WKD", "Queens Village", 0))
    stimes.append(("BA_LATE", _gtfs(B + 120), _gtfs(B + 120), "SA", 1))
    stimes.append(("BA_LATE", _gtfs(B + 128), _gtfs(B + 128), "SB", 2))

    trips.append(("BB_LATE", "BUS_B", "WKD", "Kew Gardens", 0))
    stimes.append(("BB_LATE", _gtfs(B + 132), _gtfs(B + 132), "SB", 1))
    stimes.append(("BB_LATE", _gtfs(B + 142), _gtfs(B + 142), "SD", 2))

    conn.executemany("INSERT INTO trips VALUES (?,?,?,?,?)", trips)
    conn.executemany("INSERT INTO stops VALUES (?,?,?,?)", [
        ("SA", "Origin Stop",       40.70000, -74.00000),
        ("SB", "Transfer Stop",     40.70070, -74.00000),
        ("SD", "Destination Stop",  40.70900, -74.00000),
    ])
    conn.executemany("INSERT INTO stop_modes VALUES (?,?)", [
        ("SA", 1),   # subway
        ("SA", 3),   # bus
        ("SB", 3),   # bus
        ("SD", 1),   # subway
        ("SD", 3),   # bus
    ])
    conn.executemany("INSERT INTO stop_times VALUES (?,?,?,?,?)", stimes)
    conn.commit()
    conn.close()


# ── Helpers ───────────────────────────────────────────────────────

def _now_minutes() -> int:
    """Current time as minutes past midnight in NY timezone."""
    now = datetime.now(NY_TZ)
    return now.hour * 60 + now.minute


def _ts_from_offset(base_ts: int, offset_minutes: int) -> int:
    """Return a Unix timestamp that is base_ts + offset_minutes*60."""
    return base_ts + offset_minutes * 60


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


# ── Fixture: shared engine process ────────────────────────────────

@pytest.fixture(scope="module")
def engine_env(tmp_path_factory):
    """Build engine, create schedule DB, start the C++ server once.

    Trip times are anchored 2 minutes in the future from "now" so
    that the engine always has findable trips regardless of wall-clock
    time.
    """
    tmp = tmp_path_factory.mktemp("cross_stack")
    schedule_db = tmp / "schedule.db"
    state_db = tmp / "state.db"

    # Anchor trips 2 min from now so they're always future
    now_ny = datetime.now(NY_TZ)
    base_minutes = now_ny.hour * 60 + now_ny.minute + 2
    base_ts = int(now_ny.replace(second=0, microsecond=0).timestamp()) + 120
    _build_rich_db(schedule_db, base_minutes)

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

    proc = subprocess.Popen(
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
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/health", timeout=2
            ) as resp:
                if json.loads(resp.read().decode()).get("ready"):
                    break
        except Exception:
            time.sleep(0.3)
    else:
        output = proc.stdout.read() if proc.stdout else ""
        proc.kill()
        raise AssertionError(f"engine never became healthy\n{output}")

    yield {
        "proc": proc,
        "port": port,
        "schedule_db": str(schedule_db),
        "state_db": str(state_db),
        "base_ts": base_ts,
    }

    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


@pytest.fixture(autouse=True)
def _configure_backend(engine_env, monkeypatch):
    """Point the Python backend at the running C++ engine.

    Also redirect the shared schedule_pool to the test DB so that
    backend-side schedule queries (stale-bus override, ADA lookup, etc.)
    operate on the same schedule as the engine rather than the
    production DB opened at startup.
    """
    from app.services.transit.db_pool import schedule_pool

    monkeypatch.setenv("TRACK_ENGINE_SCHEDULE_DB", engine_env["schedule_db"])
    monkeypatch.setenv("TRACK_ENGINE_STATE_DB", engine_env["state_db"])
    monkeypatch.setenv("TRACK_ENGINE_STATE_BACKEND", "sqlite")
    monkeypatch.setenv("TRACK_ENGINE_URL", f"http://127.0.0.1:{engine_env['port']}")
    monkeypatch.setenv("TRACK_ENGINE_ENABLE_REALTIME_ENRICHMENT", "0")

    # Redirect the schedule_pool to the test DB.  This avoids the
    # "unable to open database file" error that occurs when the pool
    # connections (opened during app startup for the production DB)
    # become stale or mismatched with the request's event loop.
    monkeypatch.setattr(schedule_pool, "_db_path", Path(engine_env["schedule_db"]))
    monkeypatch.setattr(schedule_pool, "_opened", False)
    monkeypatch.setattr(schedule_pool, "_pool", None)
    monkeypatch.setattr(schedule_pool, "_connections", [])

    reset_engine_service()
    yield
    monkeypatch.delenv("TRACK_ENGINE_URL", raising=False)
    reset_engine_service()


# ──────────────────────────────────────────────────────────────────
#  Test 1: Mode filter flows through backend → engine (bus only)
# ──────────────────────────────────────────────────────────────────

@pytest.mark.skipif(shutil.which("c++") is None, reason="c++ not installed")
def test_cross_stack_mode_filter_bus_only(engine_env):
    """
    User toggles modes=["bus"] in TripSettingsSheet.
    Subway legs must NOT appear in the backend response.
    """
    base_ts = engine_env["base_ts"]
    resp = client.post(
        "/engine/plan",
        json={
            "origin": {"label": "Home", "lat": 40.70000, "lon": -74.00000},
            "destination": {"label": "Work", "lat": 40.70900, "lon": -74.00000},
            "depart_at_ts": base_ts,
            "max_transfers": 2,
            "max_origin_walk_m": 50,
            "max_destination_walk_m": 50,
            "max_transfer_walk_m": 50,
            "modes": ["bus"],
            "num_itineraries": 3,
        },
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.json()}"
    payload = resp.json()
    itins = payload["itineraries"]
    assert itins, "should find at least one bus itinerary"
    for itin in itins:
        for leg in itin["legs"]:
            if leg["mode"] != "walk":
                assert leg["mode"] == "bus", (
                    f"expected only bus legs, got mode={leg['mode']}"
                )


# ──────────────────────────────────────────────────────────────────
#  Test 2: arrive_by_ts flows through backend → engine
# ──────────────────────────────────────────────────────────────────

@pytest.mark.skipif(shutil.which("c++") is None, reason="c++ not installed")
def test_cross_stack_arrive_by_filters(engine_env):
    """
    User picks "arrive by base+15 min" in DepartureTimePickerSheet.
    No itinerary should arrive after the deadline.
    The backend model requires EITHER depart_at_ts OR arrive_by_ts, not both.
    """
    base_ts = engine_env["base_ts"]
    arrive_by = _ts_from_offset(base_ts, 15)  # base + 15 min
    resp = client.post(
        "/engine/plan",
        json={
            "origin": {"label": "Home", "lat": 40.70000, "lon": -74.00000},
            "destination": {"label": "Work", "lat": 40.70900, "lon": -74.00000},
            "arrive_by_ts": arrive_by,
            "max_transfers": 2,
            "max_origin_walk_m": 50,
            "max_destination_walk_m": 50,
            "max_transfer_walk_m": 50,
            "modes": ["subway", "bus"],
            "num_itineraries": 5,
        },
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.json()}"
    payload = resp.json()
    itins = payload["itineraries"]
    assert itins, "should find at least one itinerary before arrive_by deadline"
    for itin in itins:
        assert itin["arrive_at_ts"] <= arrive_by, (
            f"arrive_at_ts {itin['arrive_at_ts']} exceeds arrive_by {arrive_by}"
        )


# ──────────────────────────────────────────────────────────────────
#  Test 3: num_itineraries cap flows through backend
# ──────────────────────────────────────────────────────────────────

@pytest.mark.skipif(shutil.which("c++") is None, reason="c++ not installed")
def test_cross_stack_num_itineraries_cap(engine_env):
    """
    User is served num_itineraries=2.
    Backend should return at most 2.
    """
    base_ts = engine_env["base_ts"]
    resp = client.post(
        "/engine/plan",
        json={
            "origin": {"label": "Home", "lat": 40.70000, "lon": -74.00000},
            "destination": {"label": "Work", "lat": 40.70900, "lon": -74.00000},
            "depart_at_ts": base_ts,
            "max_transfers": 2,
            "max_origin_walk_m": 50,
            "max_destination_walk_m": 50,
            "max_transfer_walk_m": 50,
            "modes": ["subway", "bus"],
            "num_itineraries": 2,
        },
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.json()}"
    itins = resp.json()["itineraries"]
    assert len(itins) <= 2, f"expected ≤2 itineraries, got {len(itins)}"


# ──────────────────────────────────────────────────────────────────
#  Test 4: /go endpoint returns full GoTrip structure
# ──────────────────────────────────────────────────────────────────

@pytest.mark.skipif(shutil.which("c++") is None, reason="c++ not installed")
def test_cross_stack_go_returns_complete_trip(engine_env):
    """
    Full /engine/go round-trip: verify route_chips, transfers,
    next_action, status, duration_label, leave_label, arrive_label.
    """
    base_ts = engine_env["base_ts"]
    resp = client.post(
        "/engine/go",
        json={
            "origin": {"label": "Home", "lat": 40.70000, "lon": -74.00000},
            "destination": {"label": "Work", "lat": 40.70900, "lon": -74.00000},
            "depart_at_ts": base_ts,
            "now_ts": base_ts,
            "max_transfers": 2,
            "max_origin_walk_m": 50,
            "max_destination_walk_m": 50,
            "max_transfer_walk_m": 50,
            "modes": ["subway", "bus"],
            "num_itineraries": 3,
        },
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.json()}"
    go = resp.json()
    trip = go["primary_trip"]
    assert trip is not None, "primary_trip should not be null"

    # Route chips
    assert "route_chips" in trip
    assert len(trip["route_chips"]) >= 1
    for chip in trip["route_chips"]:
        assert "kind" in chip
        assert "label" in chip
        assert chip["kind"] in ("transit", "walk")

    # Itinerary inside GoTrip
    itin = trip["itinerary"]
    assert "legs" in itin
    assert itin["total_duration_s"] > 0
    assert itin["arrive_at_ts"] > itin["leave_at_ts"]

    # Each leg has required fields
    for leg in itin["legs"]:
        assert "mode" in leg
        assert "departure_ts" in leg
        assert "arrival_ts" in leg
        assert "board_stop_id" in leg
        assert "alight_stop_id" in leg

    # Status and labels
    assert trip["status"] in ("upcoming", "now", "past")
    assert "next_action" in trip
    assert "title" in trip["next_action"]
    assert "duration_label" in trip
    assert "leave_label" in trip
    assert "arrive_label" in trip
    assert trip["leave_in_s"] >= 0
    assert trip["arrive_in_s"] >= 0


# ──────────────────────────────────────────────────────────────────
#  Test 5: search_window_minutes flows through backend
# ──────────────────────────────────────────────────────────────────

@pytest.mark.skipif(shutil.which("c++") is None, reason="c++ not installed")
def test_cross_stack_search_window(engine_env):
    """
    search_window_minutes=30.  Late trips at 11:00 must not appear.
    """
    base_ts = engine_env["base_ts"]
    query_ts = base_ts
    cutoff = query_ts + 30 * 60
    resp = client.post(
        "/engine/plan",
        json={
            "origin": {"label": "Home", "lat": 40.70000, "lon": -74.00000},
            "destination": {"label": "Work", "lat": 40.70900, "lon": -74.00000},
            "depart_at_ts": query_ts,
            "max_transfers": 2,
            "max_origin_walk_m": 50,
            "max_destination_walk_m": 50,
            "max_transfer_walk_m": 50,
            "search_window_minutes": 30,
            "modes": ["subway", "bus"],
            "num_itineraries": 10,
        },
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.json()}"
    itins = resp.json()["itineraries"]
    assert itins, "should find trips within 30-min window"
    for itin in itins:
        for leg in itin["legs"]:
            if leg["mode"] != "walk":
                assert leg["departure_ts"] <= cutoff, (
                    f"transit departure {leg['departure_ts']} exceeds "
                    f"search window cutoff {cutoff}"
                )


# ──────────────────────────────────────────────────────────────────
#  Test 6: priority=fewer_transfers flows through backend
# ──────────────────────────────────────────────────────────────────

@pytest.mark.skipif(shutil.which("c++") is None, reason="c++ not installed")
def test_cross_stack_priority_fewer_transfers(engine_env):
    """
    With priority=fewer_transfers, the first itinerary should
    prefer fewer legs even if it arrives slightly later.
    """
    base_ts = engine_env["base_ts"]
    resp = client.post(
        "/engine/plan",
        json={
            "origin": {"label": "Home", "lat": 40.70000, "lon": -74.00000},
            "destination": {"label": "Work", "lat": 40.70900, "lon": -74.00000},
            "depart_at_ts": base_ts,
            "max_transfers": 2,
            "max_origin_walk_m": 50,
            "max_destination_walk_m": 50,
            "max_transfer_walk_m": 50,
            "modes": ["subway", "bus"],
            "num_itineraries": 5,
            "priority": "fewer_transfers",
        },
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.json()}"
    itins = resp.json()["itineraries"]
    assert itins, "should find itineraries"
    # First itinerary should be direct (0 transfers) because the
    # subway E goes SA→SD directly
    first = itins[0]
    assert first["transfer_count"] == 0, (
        f"priority=fewer_transfers: first result has "
        f"{first['transfer_count']} transfers, expected 0"
    )


# ──────────────────────────────────────────────────────────────────
#  Test 7: /go with bus-only mode has no subway in route_chips
# ──────────────────────────────────────────────────────────────────

@pytest.mark.skipif(shutil.which("c++") is None, reason="c++ not installed")
def test_cross_stack_go_mode_filter_bus_only(engine_env):
    """
    /engine/go with modes=["bus"]: route_chips must not contain
    any subway transit chips.
    """
    base_ts = engine_env["base_ts"]
    resp = client.post(
        "/engine/go",
        json={
            "origin": {"label": "Home", "lat": 40.70000, "lon": -74.00000},
            "destination": {"label": "Work", "lat": 40.70900, "lon": -74.00000},
            "depart_at_ts": base_ts,
            "now_ts": base_ts,
            "max_transfers": 2,
            "max_origin_walk_m": 50,
            "max_destination_walk_m": 50,
            "max_transfer_walk_m": 50,
            "modes": ["bus"],
            "num_itineraries": 3,
        },
    )
    assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.json()}"
    go = resp.json()
    trip = go["primary_trip"]
    assert trip is not None
    for chip in trip["route_chips"]:
        if chip["kind"] == "transit":
            assert chip.get("mode") != "subway", (
                f"bus-only request returned subway chip: {chip}"
            )
    for leg in trip["itinerary"]["legs"]:
        if leg["mode"] != "walk":
            assert leg["mode"] == "bus", (
                f"bus-only request got mode={leg['mode']}"
            )
