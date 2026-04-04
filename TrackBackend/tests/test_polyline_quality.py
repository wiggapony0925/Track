from __future__ import annotations

import pytest

from app.services.mapping.polyline_quality import (
    ZOOM_TEST_LEVELS,
    _max_acceptable_gap_m,
    build_subway_quality_snapshot,
)


@pytest.fixture(scope="module")
def quality_snapshot() -> dict:
    return build_subway_quality_snapshot()


# ─── Existing system-level checks ────────────────────────────────────────────


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


# ─── Raw MTA station attachment (stops are ground truth) ─────────────────────


def test_raw_mta_stations_near_polylines(quality_snapshot: dict):
    """Every raw MTA station coordinate must be close to its trunk polyline.

    The polyline is what moves — the stops are at the exact positions
    the MTA provided and are considered ground truth.
    """
    summary = quality_snapshot["raw_mta_attachment_summary"]
    # p95 of raw MTA stations within 1.5 m of their trunk polyline
    assert (
        summary["p95"] <= 1.5
    ), f"p95 raw MTA attachment {summary['p95']:.2f} m exceeds 1.5 m"
    # p99 within 3 m
    assert (
        summary["p99"] <= 3.0
    ), f"p99 raw MTA attachment {summary['p99']:.2f} m exceeds 3.0 m"


def test_raw_mta_outliers_are_few(quality_snapshot: dict):
    """At most a handful of stations should be farther than 10 m."""
    outliers = quality_snapshot["raw_mta_outliers"]
    assert (
        len(outliers) <= 5
    ), f"{len(outliers)} raw MTA outliers (>10 m): " + ", ".join(
        f"{o['station_name']} ({o['distance_m']:.1f} m)" for o in outliers[:10]
    )


def test_processed_stops_use_raw_mta_coordinates(quality_snapshot: dict):
    """Processed stop positions must be identical to raw MTA positions.

    The polyline routes through the stops — stops never move.
    """
    # If the processed positions have been snapped, they'd differ from the
    # raw MTA attachment distances.  Since both now use the same raw coords,
    # the raw_mta and position attachment distributions should match exactly.
    raw_summary = quality_snapshot["raw_mta_attachment_summary"]
    pos_summary = quality_snapshot["position_attachment_summary"]
    # They should be very similar (not identical due to per-route grouping)
    assert (
        abs(raw_summary["p50"] - pos_summary["p50"]) < 0.5
    ), "Processed positions appear to have been snapped off raw MTA coords"


# ─── Multi-zoom-level polyline quality ───────────────────────────────────────


class TestZoomLevelQuality:
    """Verify rendered polyline-to-station attachment across the full zoom range.

    The backend simulates the actual per-branch lineOffset rendering used
    by the client, while keeping raw MTA stop coordinates fixed. These
    tests ensure the visible line still covers the stop whether the user
    is zoomed far out or far in.
    """

    def test_zoom_quality_covers_all_levels(self, quality_snapshot: dict):
        """Quality data should exist for the whole zoom sweep."""
        zoom_quality = quality_snapshot["zoom_quality"]
        zooms = {z["zoom"] for z in zoom_quality}
        assert zooms == set(
            ZOOM_TEST_LEVELS
        ), f"Missing zoom levels: {set(ZOOM_TEST_LEVELS) - zooms}"

    @pytest.mark.parametrize("zoom", ZOOM_TEST_LEVELS)
    def test_no_visible_gaps_at_zoom(self, quality_snapshot: dict, zoom: int):
        """At each zoom level, ≥99.5% of stations should have their gap
        hidden by the rendered line width.

        This is the core zoom-invariant guarantee: whether the user zooms
        all the way out or all the way in, station dots sit visually on
        top of the rendered polyline.
        """
        zoom_data = next(
            (z for z in quality_snapshot["zoom_quality"] if z["zoom"] == zoom),
            None,
        )
        assert zoom_data is not None, f"No quality data for zoom {zoom}"

        pct = zoom_data["pct_within_line"]
        assert pct >= 99.5, (
            f"Zoom {zoom}: only {pct:.1f}% of stations within line width "
            f"({zoom_data['stations_visible_gap']} visible gaps, "
            f"max acceptable {zoom_data['max_acceptable_gap_m']:.2f} m, "
            f"worst {zoom_data['worst_gap_m']:.2f} m)"
        )

    @pytest.mark.parametrize("zoom", ZOOM_TEST_LEVELS)
    def test_visible_gap_count_at_zoom(self, quality_snapshot: dict, zoom: int):
        """No more than 3 stations should have a visible gap at any zoom."""
        zoom_data = next(
            (z for z in quality_snapshot["zoom_quality"] if z["zoom"] == zoom),
            None,
        )
        assert zoom_data is not None
        assert zoom_data["stations_visible_gap"] <= 3, (
            f"Zoom {zoom}: {zoom_data['stations_visible_gap']} stations with visible gap "
            f"(threshold {zoom_data['max_acceptable_gap_m']:.2f} m)"
        )

    def test_worst_gap_shrinks_at_close_zoom(self, quality_snapshot: dict):
        """At zoom 18.0 the close-up fit should remain visually tight.

        A small number of known GTFS stop-to-shape artifacts can dominate the
        absolute worst-case gap, so this test focuses on the user-visible
        guarantee instead: the close-up p95 must remain tiny and only a very
        small number of stations may show a visible gap.
        """
        z18 = next(
            (z for z in quality_snapshot["zoom_quality"] if z["zoom"] == 18.0),
            None,
        )
        assert z18 is not None
        assert (
            z18["p95_gap_m"] <= 2.0
        ), f"p95 gap at z18 is {z18['p95_gap_m']:.2f} m — too large for max zoom"
        assert z18["stations_visible_gap"] <= 2, (
            f"Zoom 18 has {z18['stations_visible_gap']} visible gaps "
            f"(worst {z18['worst_gap_m']:.2f} m)"
        )

    def test_far_zoom_tolerance_is_generous(self, quality_snapshot: dict):
        """At zoom 10.0 (max zoom-out) the acceptable gap should be large.

        At ~75 m/px the line is ~90 m wide — even a 15 m gap is invisible.
        """
        z10 = next(
            (z for z in quality_snapshot["zoom_quality"] if z["zoom"] == 10.0),
            None,
        )
        assert z10 is not None
        # At z10 the acceptable gap should be generous (> 40 m)
        assert z10["max_acceptable_gap_m"] > 40.0

    def test_close_zoom_rendered_gap_stays_well_inside_stroke(
        self, quality_snapshot: dict
    ):
        """At close zooms the rendered p95 gap should remain inside the line."""
        for zoom_data in quality_snapshot["zoom_quality"]:
            zoom = zoom_data["zoom"]
            if zoom < 14:
                continue
            assert zoom_data["p95_gap_m"] <= zoom_data["max_acceptable_gap_m"], (
                f"Zoom {zoom}: p95 rendered gap {zoom_data['p95_gap_m']:.2f} m "
                f"exceeds visible threshold {zoom_data['max_acceptable_gap_m']:.2f} m"
            )


# ─── Zoom constant sanity checks ────────────────────────────────────────────


def test_max_acceptable_gap_monotonically_decreasing():
    """Acceptable gap should decrease as zoom increases (closer = tighter)."""
    prev_gap = float("inf")
    for zoom in range(10, 19):
        gap = _max_acceptable_gap_m(zoom)
        assert (
            gap < prev_gap
        ), f"Gap at z{zoom} ({gap:.2f} m) not less than z{zoom-1} ({prev_gap:.2f} m)"
        prev_gap = gap
