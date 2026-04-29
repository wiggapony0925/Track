"""Tests for materialized GTFS file checks used by refresh."""

from __future__ import annotations

import sqlite3


def test_copy_subway_root_files_materializes_routes_txt(monkeypatch, tmp_path):
    from app.services.gtfs import gtfs_refresh

    data_dir = tmp_path / "data"
    source_dir = tmp_path / "supplemented_GTFS"
    source_dir.mkdir()
    for filename in ("shapes.txt", "trips.txt", "stops.txt", "routes.txt"):
        (source_dir / filename).write_text(f"{filename}\n")

    monkeypatch.setattr(gtfs_refresh, "_DATA_DIR", data_dir)

    gtfs_refresh._copy_subway_root_files(source_dir)

    assert (data_dir / "shapes.txt").read_text() == "shapes.txt\n"
    assert (data_dir / "trips.txt").read_text() == "trips.txt\n"
    assert (data_dir / "stops.txt").read_text() == "stops.txt\n"
    assert (
        data_dir / "subway" / "regular_GTFS" / "routes.txt"
    ).read_text() == "routes.txt\n"


def test_missing_materialized_files_requires_subway_routes(monkeypatch, tmp_path):
    from app.services.gtfs import gtfs_refresh

    data_dir = tmp_path / "data"
    (data_dir / "subway" / "supplemented_GTFS").mkdir(parents=True)
    for relative in (
        "shapes.txt",
        "trips.txt",
        "stops.txt",
        "subway/supplemented_GTFS/stop_times.txt",
    ):
        path = data_dir / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("ok\n")

    monkeypatch.setattr(gtfs_refresh, "_DATA_DIR", data_dir)

    missing = gtfs_refresh._missing_materialized_files("subway")

    assert missing == [data_dir / "subway" / "regular_GTFS" / "routes.txt"]


def _write_gtfs_file(path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join([header, *rows]) + "\n")


def test_rebuild_schedule_db_scopes_duplicate_route_ids_by_feed(monkeypatch, tmp_path):
    from app.services.gtfs import gtfs_refresh

    data_dir = tmp_path / "data"
    subway_dir = data_dir / "subway" / "supplemented_GTFS"
    lirr_dir = data_dir / "lirr" / "gtfslirr"

    for feed_dir, long_name, route_type, trip_id, stop_id in (
        (subway_dir, "Flushing Local", "1", "subway-trip", "subway-stop"),
        (lirr_dir, "Far Rockaway Branch", "2", "lirr-trip", "lirr-stop"),
    ):
        _write_gtfs_file(
            feed_dir / "routes.txt",
            "route_id,route_short_name,route_long_name,route_color,route_type",
            [f"7,7,{long_name},123456,{route_type}"],
        )
        _write_gtfs_file(
            feed_dir / "trips.txt",
            "route_id,service_id,trip_id,trip_headsign,direction_id",
            [f"7,WKD,{trip_id},Terminal,0"],
        )
        _write_gtfs_file(
            feed_dir / "stops.txt",
            "stop_id,stop_name,stop_lat,stop_lon",
            [f"{stop_id},Test Stop,40.0,-73.0"],
        )
        _write_gtfs_file(
            feed_dir / "stop_times.txt",
            "trip_id,arrival_time,departure_time,stop_id,stop_sequence",
            [f"{trip_id},08:00:00,08:00:00,{stop_id},1"],
        )
        _write_gtfs_file(
            feed_dir / "calendar.txt",
            "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date",
            ["WKD,1,1,1,1,1,0,0,20260401,20260601"],
        )
        _write_gtfs_file(
            feed_dir / "calendar_dates.txt",
            "service_id,date,exception_type",
            [],
        )

    monkeypatch.setattr(gtfs_refresh, "_DATA_DIR", data_dir)

    assert gtfs_refresh._rebuild_schedule_db()

    conn = sqlite3.connect(data_dir / "transit_schedule.db")
    try:
        rows = conn.execute(
            """
            SELECT feed_id, route_id, route_short_name, route_long_name, route_type
            FROM routes
            WHERE route_id = '7'
            ORDER BY feed_id
            """
        ).fetchall()
        assert rows == [
            ("lirr", "7", "7", "Far Rockaway Branch", 2),
            ("subway", "7", "7", "Flushing Local", 1),
        ]

        trip_counts = conn.execute(
            """
            SELECT r.feed_id, COUNT(*)
            FROM routes r
            JOIN trips t ON t.feed_id = r.feed_id AND t.route_id = r.route_id
            WHERE r.route_id = '7'
            GROUP BY r.feed_id
            ORDER BY r.feed_id
            """
        ).fetchall()
        assert trip_counts == [("lirr", 1), ("subway", 1)]
    finally:
        conn.close()
