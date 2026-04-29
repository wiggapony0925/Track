"""Regression tests for mobile GTFS route inventory drift."""

from __future__ import annotations

import sqlite3

import pytest

from app.services.gtfs import mobile_bundle


def _make_source_db(path, routes=("A", "S", "X")):
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE stops (
            feed_id TEXT NOT NULL,
            stop_id TEXT NOT NULL,
            stop_name TEXT,
            stop_lat REAL,
            stop_lon REAL,
            PRIMARY KEY (feed_id, stop_id)
        );
        CREATE TABLE routes (
            feed_id TEXT NOT NULL,
            route_id TEXT NOT NULL,
            route_short_name TEXT,
            route_long_name TEXT,
            route_color TEXT,
            route_type INTEGER,
            PRIMARY KEY (feed_id, route_id)
        );
        CREATE TABLE trips (
            feed_id TEXT NOT NULL,
            trip_id TEXT NOT NULL,
            route_id TEXT,
            service_id TEXT,
            direction_id INTEGER,
            PRIMARY KEY (feed_id, trip_id)
        );
        CREATE TABLE stop_times (
            feed_id TEXT NOT NULL,
            trip_id TEXT,
            stop_id TEXT,
            departure_time TEXT,
            stop_sequence INTEGER
        );
        CREATE TABLE calendar (
            feed_id TEXT NOT NULL,
            service_id TEXT,
            monday INTEGER,
            tuesday INTEGER,
            wednesday INTEGER,
            thursday INTEGER,
            friday INTEGER,
            saturday INTEGER,
            sunday INTEGER,
            PRIMARY KEY (feed_id, service_id)
        );
        """
    )
    conn.execute("INSERT INTO calendar VALUES ('subway', 'WKD', 1, 1, 1, 1, 1, 0, 0)")
    for index, route_id in enumerate(routes):
        conn.execute(
            "INSERT INTO routes VALUES (?, ?, ?, ?, ?, ?)",
            ("subway", route_id, route_id, f"{route_id} train", "123456", 1),
        )
        trip_id = f"{route_id}-trip"
        conn.execute(
            "INSERT INTO trips VALUES (?, ?, ?, 'WKD', ?)",
            ("subway", trip_id, route_id, index % 2),
        )
        for stop_index in range(2):
            stop_id = f"{route_id}{stop_index}"
            conn.execute(
                "INSERT OR IGNORE INTO stops VALUES (?, ?, ?, ?, ?)",
                ("subway", stop_id, f"{route_id} Stop {stop_index}", 40.0 + index, -73.0 - stop_index),
            )
            conn.execute(
                "INSERT INTO stop_times VALUES (?, ?, ?, ?, ?)",
                ("subway", trip_id, stop_id, f"0{stop_index}:00:00", stop_index + 1),
            )
    conn.commit()
    conn.close()


def test_build_bundle_publishes_current_active_route_inventory(tmp_path):
    source_db = tmp_path / "transit_schedule.db"
    bundle_dir = tmp_path / "gtfs"
    _make_source_db(source_db, routes=("A", "S", "X"))

    entry = mobile_bundle.build_bundle(source_db=source_db, bundle_dir=bundle_dir)

    assert entry["active_routes_count"] == 3
    assert len(entry["route_inventory_sha256"]) == 64

    bundle_path = bundle_dir / entry["filename"]
    conn = sqlite3.connect(bundle_path)
    route_ids = {row[0] for row in conn.execute("SELECT route_id FROM routes")}
    served_ids = {row[0] for row in conn.execute("SELECT DISTINCT route_id FROM route_stops")}
    metadata = dict(conn.execute("SELECT key, value FROM metadata"))
    conn.close()

    assert {"A", "S", "X"}.issubset(route_ids)
    assert {"A", "S", "X"}.issubset(served_ids)
    assert metadata["active_routes_count"] == "3"
    assert metadata["route_inventory_sha256"] == entry["route_inventory_sha256"]


def test_validate_route_inventory_fails_when_active_route_is_not_served(tmp_path):
    source_db = tmp_path / "transit_schedule.db"
    _make_source_db(source_db, routes=("A", "S"))
    src = sqlite3.connect(source_db)
    src.row_factory = sqlite3.Row
    dst = mobile_bundle._init_target(tmp_path / "mobile.sqlite")

    try:
        mobile_bundle._copy_routes(src, dst)
        dst.execute(
            "INSERT INTO route_stops(route_id, stop_id, direction_id) VALUES ('A', 'A0', 0)"
        )
        dst.commit()

        with pytest.raises(RuntimeError, match="missing route_stops entries: S"):
            mobile_bundle._validate_route_inventory(src, dst)
    finally:
        dst.close()
        src.close()


def test_numeric_commuter_rail_routes_keep_agency_mode(tmp_path):
    source_db = tmp_path / "transit_schedule.db"
    bundle_dir = tmp_path / "gtfs"
    _make_source_db(source_db, routes=())

    conn = sqlite3.connect(source_db)
    conn.execute(
        "INSERT INTO routes VALUES (?, ?, ?, ?, ?, ?)",
        ("lirr", "7", None, "Far Rockaway Branch", "6E3219", 2),
    )
    conn.execute(
        "INSERT INTO routes VALUES (?, ?, ?, ?, ?, ?)",
        ("mnr", "1", None, "Hudson", "009B3A", 2),
    )
    for feed_id, route_id in (("lirr", "7"), ("mnr", "1")):
        trip_id = f"{route_id}-trip"
        stop_id = f"{route_id}-stop"
        conn.execute("INSERT INTO trips VALUES (?, ?, ?, 'WKD', 0)", (feed_id, trip_id, route_id))
        conn.execute(
            "INSERT OR IGNORE INTO stops VALUES (?, ?, ?, ?, ?)",
            (feed_id, stop_id, f"{route_id} Stop", 40.0, -73.0),
        )
        conn.execute("INSERT INTO stop_times VALUES (?, ?, ?, '08:00:00', 1)", (feed_id, trip_id, stop_id))
    conn.commit()
    conn.close()

    entry = mobile_bundle.build_bundle(source_db=source_db, bundle_dir=bundle_dir)

    conn = sqlite3.connect(bundle_dir / entry["filename"])
    modes = dict(conn.execute("SELECT route_id, mode FROM routes WHERE route_id IN ('1', '7')"))
    conn.close()

    assert modes == {"1": "mnr", "7": "lirr"}
