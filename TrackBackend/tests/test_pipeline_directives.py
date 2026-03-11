"""Smoke tests for the 4 corridor_pipeline directives."""

import math

import pytest
from shapely.geometry import LineString

from app.services.mapping.corridor_pipeline import (
    CROSSING_ALIGNMENT_MIN,
    GRID_SNAP_ANGLE_DEG,
    MAX_SETBACK_FRACTION,
    RDP_TOLERANCE,
    STRAIGHT_DEFLECTION_LIMIT,
    _compute_arc_from_directions,
    _fix_self_intersecting,
    _grid_snap_segment,
    _postprocess_route_geometries,
)


# ── Constants ──────────────────────────────────────────────────────────────

class TestConstants:
    def test_rdp_tolerance_increased(self):
        assert RDP_TOLERANCE == 18.0

    def test_straight_deflection_limit(self):
        assert STRAIGHT_DEFLECTION_LIMIT == 0.26

    def test_crossing_alignment_min(self):
        assert CROSSING_ALIGNMENT_MIN == 0.707

    def test_grid_snap_angle(self):
        assert GRID_SNAP_ANGLE_DEG == 10.0

    def test_max_setback_fraction(self):
        assert MAX_SETBACK_FRACTION == 0.4


# ── Directive 1: Straight-Line Immunity ────────────────────────────────────

class TestStraightLineImmunity:
    def test_near_straight_returns_none(self):
        """A ~5° deflection should be immune — no arc produced."""
        seg_in = LineString([(0, 0), (100, 0)])
        seg_out = LineString([(100, 0), (200, 8.7)])
        result = _compute_arc_from_directions(
            vertex=(100, 0),
            dir_in=(1, 0),
            dir_out=(0.9962, 0.087),  # ~5° off straight
            seg_in=seg_in,
            seg_out=seg_out,
        )
        assert result is None

    def test_real_turn_produces_arc(self):
        """A 90° turn should produce a valid arc fillet."""
        seg_in = LineString([(0, 0), (200, 0)])
        seg_out = LineString([(200, 0), (200, 200)])
        result = _compute_arc_from_directions(
            vertex=(200, 0),
            dir_in=(1, 0),
            dir_out=(0, 1),
            seg_in=seg_in,
            seg_out=seg_out,
        )
        assert result is not None
        arc_geom, setback_in, setback_out = result
        assert arc_geom.length > 0
        assert setback_in > 0
        assert setback_out > 0

    def test_u_turn_returns_none(self):
        """A near-U-turn (>160°) should also be rejected."""
        seg_in = LineString([(0, 0), (100, 0)])
        seg_out = LineString([(100, 0), (0, 1)])
        result = _compute_arc_from_directions(
            vertex=(100, 0),
            dir_in=(1, 0),
            dir_out=(-1, 0.01),
            seg_in=seg_in,
            seg_out=seg_out,
        )
        assert result is None


# ── Directive 3: Grid Snapping ─────────────────────────────────────────────

class TestGridSnapping:
    def test_near_vertical_straightened(self):
        """A mostly-north line with micro-jitter becomes 2 points."""
        wobbly = LineString([(0, 0), (1, 50), (-0.5, 100), (0.8, 150), (0, 200)])
        snapped = _grid_snap_segment(wobbly)
        assert len(list(snapped.coords)) == 2

    def test_near_horizontal_straightened(self):
        """A mostly-east line with jitter becomes 2 points."""
        wobbly = LineString([(0, 0), (50, 0.5), (100, -0.3), (200, 0.1)])
        snapped = _grid_snap_segment(wobbly)
        assert len(list(snapped.coords)) == 2

    def test_diagonal_preserved(self):
        """A 30° diagonal should keep all its vertices."""
        diagonal = LineString([(0, 0), (50, 30), (100, 60), (150, 90)])
        kept = _grid_snap_segment(diagonal)
        assert len(list(kept.coords)) == 4

    def test_two_point_segment_unchanged(self):
        """A segment with only 2 points is already straight."""
        seg = LineString([(0, 0), (100, 100)])
        result = _grid_snap_segment(seg)
        assert len(list(result.coords)) == 2


# ── Directive 4: Post-processing Sweep ─────────────────────────────────────

class TestPostProcessing:
    def test_empty_segments_dropped(self):
        segments = {
            "A": [LineString([(0, 0), (100, 100)]), LineString([])],
        }
        cleaned = _postprocess_route_geometries(segments)
        assert "A" in cleaned
        assert len(cleaned["A"]) == 1

    def test_short_segments_dropped(self):
        """Segments shorter than MIN_EDGE_LENGTH are removed."""
        segments = {
            "B": [LineString([(0, 0), (1, 1)])],
        }
        cleaned = _postprocess_route_geometries(segments)
        assert "B" not in cleaned

    def test_valid_segment_preserved(self):
        segments = {
            "C": [LineString([(0, 0), (200, 200)])],
        }
        cleaned = _postprocess_route_geometries(segments)
        assert "C" in cleaned
        assert len(cleaned["C"]) == 1

    def test_fix_self_intersecting_simple_line(self):
        line = LineString([(0, 0), (100, 0), (100, 100)])
        result = _fix_self_intersecting(line)
        assert result is not None
        assert result.is_simple

    def test_fix_self_intersecting_bowtie(self):
        bowtie = LineString([(0, 0), (10, 10), (10, 0), (0, 10)])
        result = _fix_self_intersecting(bowtie)
        assert result is not None


# ── Dynamic Setback Fraction ───────────────────────────────────────────────

class TestDynamicSetback:
    def test_setback_capped_at_fraction(self):
        """The arc setback should never exceed MAX_SETBACK_FRACTION of segment."""
        seg_in = LineString([(0, 0), (200, 0)])
        seg_out = LineString([(200, 0), (200, 200)])
        result = _compute_arc_from_directions(
            vertex=(200, 0),
            dir_in=(1, 0),
            dir_out=(0, 1),
            seg_in=seg_in,
            seg_out=seg_out,
        )
        assert result is not None
        _, setback_in, setback_out = result
        assert setback_in <= seg_in.length * MAX_SETBACK_FRACTION + 0.01
        assert setback_out <= seg_out.length * MAX_SETBACK_FRACTION + 0.01
