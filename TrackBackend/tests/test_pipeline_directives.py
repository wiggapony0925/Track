"""Smoke tests for corridor_pipeline damage-control rewrite.

Tests cover:
- Reverted constants (RDP 5m, SNAP 8m)
- Despike algorithm
- Degree-2 pass-through rule
- Arc fillet straight-line immunity (10° threshold)
- Post-processing sweep
- Dynamic setback fraction
"""

import math

import networkx as nx
import pytest
from shapely.geometry import LineString

from app.services.mapping.corridor_pipeline import (
    CROSSING_ALIGNMENT_MIN,
    DESPIKE_MAX_EXCURSION,
    DESPIKE_MIN_ANGLE_DEG,
    LANE_WIDTH,
    MAX_SETBACK_FRACTION,
    RDP_TOLERANCE,
    SNAP_TOLERANCE,
    _compute_arc_from_directions,
    _despike_linestring,
    _fix_self_intersecting,
    _is_pass_through,
    _postprocess_route_geometries,
)


# ── Constants ──────────────────────────────────────────────────────────────


class TestConstants:
    def test_rdp_tolerance_conservative(self):
        assert RDP_TOLERANCE == 5.0

    def test_snap_tolerance_conservative(self):
        assert SNAP_TOLERANCE == 8.0

    def test_crossing_alignment_min(self):
        assert CROSSING_ALIGNMENT_MIN == 0.707

    def test_max_setback_fraction(self):
        assert MAX_SETBACK_FRACTION == 0.35

    def test_despike_min_angle(self):
        assert DESPIKE_MIN_ANGLE_DEG == 30.0

    def test_despike_max_excursion(self):
        assert DESPIKE_MAX_EXCURSION == 0.5


# ── Despike Algorithm ──────────────────────────────────────────────────────


class TestDespike:
    def test_clean_line_unchanged(self):
        """A smooth line should pass through despike untouched."""
        line = LineString([(0, 0), (50, 50), (100, 100), (150, 150)])
        result = _despike_linestring(line)
        assert len(list(result.coords)) == 4

    def test_acute_spike_removed(self):
        """A vertex forming a ~10° acute spike should be dropped."""
        # The spike vertex at (100, 200) creates an acute switchback
        line = LineString([(0, 0), (50, 0), (100, 200), (150, 0), (200, 0)])
        result = _despike_linestring(line)
        coords = list(result.coords)
        # The spike vertex (100, 200) should be removed
        assert len(coords) < 5

    def test_two_point_line_unchanged(self):
        """A 2-point line has no interior vertices to spike."""
        line = LineString([(0, 0), (100, 100)])
        result = _despike_linestring(line)
        assert len(list(result.coords)) == 2

    def test_three_point_line_unchanged(self):
        """A 3-point line (only 1 interior vertex) is kept as-is."""
        line = LineString([(0, 0), (50, 50), (100, 0)])
        result = _despike_linestring(line)
        assert len(list(result.coords)) == 3

    def test_excursion_spike_removed(self):
        """A vertex that flies far from its neighbours' chord is dropped."""
        # Chord from (0,0) to (100,0) is 100 units. Vertex at (50, 200)
        # has perp distance 200, ratio 2.0 >> DESPIKE_MAX_EXCURSION.
        line = LineString([(0, 0), (25, 0), (50, 200), (75, 0), (100, 0)])
        result = _despike_linestring(line)
        coords = list(result.coords)
        # Should drop (50, 200)
        for c in coords:
            assert c[1] < 10  # No vertex near y=200

    def test_endpoints_always_kept(self):
        """First and last vertices are always preserved."""
        line = LineString([(0, 0), (50, 200), (100, 0)])
        result = _despike_linestring(line)
        coords = list(result.coords)
        assert coords[0] == (0, 0)
        assert coords[-1] == (100, 0)


# ── Degree-2 Pass-Through ─────────────────────────────────────────────────


class TestPassThrough:
    """Tests for _is_pass_through using real nx.Graph structures."""

    @staticmethod
    def _make_graph_and_edges(edges_list, lanes_dict):
        """Build a small nx.Graph and edge_lanes dict.

        edges_list: [(u, v), ...]
        lanes_dict: {(u, v): {"route_A": lane_idx, ...}, ...}
        """
        G = nx.Graph()
        for u, v in edges_list:
            G.add_edge(u, v, geometry=LineString([(0, 0), (100, 0)]))
        return G, lanes_dict

    def test_pass_through_same_offset(self):
        """Route with 2 edges at same lane → pass-through."""
        G, el = self._make_graph_and_edges(
            [(1, 2), (2, 3)],
            {(1, 2): {"A": 0}, (2, 3): {"A": 0}},
        )
        route_edges = {(1, 2), (2, 3)}
        assert _is_pass_through("A", 2, G, el, route_edges) is True

    def test_not_pass_through_three_edges(self):
        """Route with 3 edges at a node is NOT pass-through."""
        G, el = self._make_graph_and_edges(
            [(1, 2), (2, 3), (2, 4)],
            {(1, 2): {"A": 0}, (2, 3): {"A": 0}, (2, 4): {"A": 0}},
        )
        route_edges = {(1, 2), (2, 3), (2, 4)}
        assert _is_pass_through("A", 2, G, el, route_edges) is False

    def test_not_pass_through_different_corridor_width(self):
        """Route edges with different corridor sizes → NOT pass-through."""
        G, el = self._make_graph_and_edges(
            [(1, 2), (2, 3)],
            # Edge (1,2) has 1 route → lane 0, center 0 → offset 0
            # Edge (2,3) has 3 routes → lane 0, center 1.0 → offset -LANE_WIDTH
            {(1, 2): {"A": 0}, (2, 3): {"A": 0, "B": 1, "C": 2}},
        )
        route_edges = {(1, 2), (2, 3)}
        # offset1 = 0, offset2 = (0 - 1.0)*LANE_WIDTH = -LANE_WIDTH
        # If LANE_WIDTH > 1m, these offsets differ by more than 1m
        if LANE_WIDTH > 1.0:
            assert _is_pass_through("A", 2, G, el, route_edges) is False

    def test_pass_through_close_offsets(self):
        """Route with same lane index and same corridor width → pass-through."""
        G, el = self._make_graph_and_edges(
            [(1, 2), (2, 3)],
            {(1, 2): {"A": 0, "B": 1}, (2, 3): {"A": 0, "B": 1}},
        )
        route_edges = {(1, 2), (2, 3)}
        assert _is_pass_through("A", 2, G, el, route_edges) is True


# ── Straight-Line Immunity ─────────────────────────────────────────────────


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


# ── Post-processing Sweep ──────────────────────────────────────────────────


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
