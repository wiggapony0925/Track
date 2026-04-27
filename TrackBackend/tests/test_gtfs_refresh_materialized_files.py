"""Tests for materialized GTFS file checks used by refresh."""

from __future__ import annotations


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