from __future__ import annotations

import pytest

from app.services.mapping.polyline_quality import build_subway_quality_snapshot


@pytest.fixture(scope="module")
def quality_snapshot() -> dict:
    return build_subway_quality_snapshot()


def test_quality_snapshot_covers_full_system(quality_snapshot: dict):
    assert quality_snapshot["trunk_count"] == 10
    assert quality_snapshot["polyline_count"] >= 30
    assert quality_snapshot["station_count"] >= 490


def test_station_attachment_stays_tight(quality_snapshot: dict):
    summary = quality_snapshot["station_attachment_summary"]
    assert summary["p95"] <= 1.0
    assert summary["p99"] <= 2.0
    assert len(quality_snapshot["attachment_outliers"]) <= 4


def test_shared_corridor_neighbors_keep_visible_spacing(quality_snapshot: dict):
    summary = quality_snapshot["lane_neighbor_delta_summary"]
    assert summary["count"] >= 10
    assert summary["min"] >= 0.95


def test_exported_trunk_geometry_remains_continuous(quality_snapshot: dict):
    summary = quality_snapshot["segment_length_summary"]
    assert summary["p99"] <= 200.0
    assert summary["max"] <= 700.0
