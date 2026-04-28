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
            stop_id TEXT PRIMARY KEY,
            stop_name TEXT,
            stop_lat REAL,
            stop_lon REAL
        );
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
            direction_id INTEGER
        );
        CREATE TABLE stop_times (
            trip_id TEXT,
            stop_id TEXT,
            departure_time TEXT,
            stop_sequence INTEGER
        );
        CREATE TABLE calendar (
            service_id TEXT PRIMARY KEY,
            monday INTEGER,
            tuesday INTEGER,
            wednesday INTEGER,
            thursday INTEGER,
            friday INTEGER,
            saturday INTEGER,
            sunday INTEGER
        );
        """
    )
    conn.execute("INSERT INTO calendar VALUES ('WKD', 1, 1, 1, 1, 1, 0, 0)")
    for index, route_id in enumerate(routes):
        conn.execute(
            "INSERT INTO routes VALUES (?, ?, ?, ?, ?)",
            (route_id, route_id, f"{route_id} train", "123456", 1),
        )
        trip_id = f"{route_id}-trip"
        conn.execute("INSERT INTO trips VALUES (?, ?, 'WKD', ?)", (trip_id, route_id, index % 2))
        for stop_index in range(2):
            stop_id = f"{route_id}{stop_index}"
            conn.execute(
                "INSERT OR IGNORE INTO stops VALUES (?, ?, ?, ?)",
                (stop_id, f"{route_id} Stop {stop_index}", 40.0 + index, -73.0 - stop_index),
            )
            conn.execute(
                "INSERT INTO stop_times VALUES (?, ?, ?, ?)",
                (trip_id, stop_id, f"0{stop_index}:00:00", stop_index + 1),
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
