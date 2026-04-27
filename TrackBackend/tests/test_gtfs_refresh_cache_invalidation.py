"""Regression tests for GTFS refresh cache invalidation."""

from __future__ import annotations


def test_clear_gtfs_caches_invalidates_subway_shapes_response_cache(monkeypatch, tmp_path):
    from app.models import AllSubwayLinesResponse, SubwayLineOverlay
    from app.routers import subway
    from app.services.gtfs import gtfs_refresh

    response = AllSubwayLinesResponse(
        lines=[
            SubwayLineOverlay(
                route_id="A",
                color_hex="#2850AD",
                polylines=["_p~iF~ps|U_ulLnnqC"],
            )
        ]
    )
    subway.set_shapes_all_cache(response)
    subway._shapes_all_building = True

    assert subway._shapes_all_cache is not None
    assert subway._shapes_all_json_bytes is not None

    disk_cache = tmp_path / "_cache_shapes_all_vtest.json"
    disk_cache.write_text("{}")
    monkeypatch.setattr(subway, "_SHAPES_DISK_CACHE_PATH", disk_cache)

    gtfs_refresh._clear_gtfs_caches()

    assert subway._shapes_all_cache is None
    assert subway._shapes_all_json_bytes is None
    assert subway._shapes_all_building is False
    assert not disk_cache.exists()