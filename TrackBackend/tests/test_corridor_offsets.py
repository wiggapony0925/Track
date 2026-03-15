#
# test_corridor_offsets.py
# TrackBackend
#
# Tests for the topological graph pipeline (corridor_pipeline.py).
# Validates that co-located subway lines are fanned out perpendicular
# to the track so they don't stack on the same pixel.
#

from __future__ import annotations

import pytest

from app.models import SubwayLineOverlay
from app.services.mapping.corridor_pipeline import apply_topological_offsets
from app.utils.polyline_utils import decode_polyline as _decode_polyline, encode_polyline as _encode_polyline


class TestDecodePolyline:
    """Round-trip encode/decode of Google-encoded polylines."""

    def test_round_trip_simple(self):
        coords = [(40.70000, -73.98000), (40.71000, -73.97000)]
        encoded = _encode_polyline(coords)
        decoded = _decode_polyline(encoded)
        assert len(decoded) == len(coords)
        for (elat, elon), (dlat, dlon) in zip(coords, decoded):
            assert abs(elat - dlat) < 1e-4
            assert abs(elon - dlon) < 1e-4

    def test_round_trip_many_points(self):
        coords = [(40.7 + i * 0.001, -73.9 + i * 0.001) for i in range(20)]
        encoded = _encode_polyline(coords)
        decoded = _decode_polyline(encoded)
        assert len(decoded) == 20

    def test_empty_polyline(self):
        encoded = _encode_polyline([])
        decoded = _decode_polyline(encoded)
        assert decoded == []


class TestApplyTopologicalOffsets:
    """Tests for the topological graph pipeline."""

    def _make_overlay(self, route_id: str, coords: list[list[tuple[float, float]]]) -> SubwayLineOverlay:
        """Helper: create a SubwayLineOverlay with encoded polylines."""
        return SubwayLineOverlay(
            route_id=route_id,
            color_hex="#FF0000",
            polylines=[_encode_polyline(c) for c in coords],
        )

    def test_single_line_passthrough(self):
        """A single subway line should pass through (possibly processed but not broken)."""
        coords = [(40.70 + i * 0.001, -73.90) for i in range(10)]
        overlays = [self._make_overlay("L", [coords])]
        result = apply_topological_offsets(overlays)
        assert len(result) == 1
        assert result[0].route_id == "L"
        # Should have at least one polyline
        assert len(result[0].polylines) >= 1

    def test_two_colocated_lines_produce_output(self):
        """Two lines sharing the same track should produce two valid overlays."""
        shared = [(40.70 + i * 0.001, -73.90) for i in range(10)]
        overlays = [
            self._make_overlay("4", [shared]),
            self._make_overlay("5", [shared]),
        ]
        result = apply_topological_offsets(overlays)
        assert len(result) == 2
        # Both should have valid polylines
        for r in result:
            assert len(r.polylines) >= 1

    def test_three_colocated_lines(self):
        """Three co-located lines should all get processed."""
        shared = [(40.70 + i * 0.001, -73.90) for i in range(10)]
        overlays = [
            self._make_overlay("4", [shared]),
            self._make_overlay("5", [shared]),
            self._make_overlay("6", [shared]),
        ]
        result = apply_topological_offsets(overlays)
        assert len(result) == 3

    def test_non_overlapping_lines(self):
        """Lines on different tracks should both be present in output."""
        line_a = [(40.70 + i * 0.001, -73.90) for i in range(10)]
        line_b = [(40.80 + i * 0.001, -73.80) for i in range(10)]
        overlays = [
            self._make_overlay("A", [line_a]),
            self._make_overlay("L", [line_b]),
        ]
        result = apply_topological_offsets(overlays)
        assert len(result) == 2

    def test_preserves_route_id_and_color(self):
        """Offsets should preserve route_id and color_hex."""
        coords = [(40.70 + i * 0.002, -73.90) for i in range(10)]
        overlays = [
            SubwayLineOverlay(route_id="G", color_hex="#799534",
                              polylines=[_encode_polyline(coords)]),
        ]
        result = apply_topological_offsets(overlays)
        assert result[0].route_id == "G"
        assert result[0].color_hex == "#799534"

    def test_short_polyline_handled(self):
        """Short polylines should pass through without error."""
        coords_short = [(40.70, -73.90)]
        coords_normal = [(40.70 + i * 0.002, -73.90) for i in range(10)]
        overlays = [
            self._make_overlay("1", [coords_short, coords_normal]),
        ]
        result = apply_topological_offsets(overlays)
        assert len(result) == 1
        # Should have at least one polyline
        assert len(result[0].polylines) >= 1

    def test_empty_input(self):
        """Empty overlay list should return empty."""
        result = apply_topological_offsets([])
        assert result == []


class TestArcOffset:
    """Tests for the arc-based offset engine (v3.2)."""

    def test_arc_offset_maintains_distance_at_90_degree_bend(self):
        """At a 90° bend, arc offset points should maintain constant distance
        from the original vertex (no miter squeeze)."""
        from app.services.mapping.corridor_pipeline import _apply_arc_offset
        import math

        # L-shaped path: east then north (90° left turn at index 1)
        coords = [(0.0, 0.0), (100.0, 0.0), (100.0, 100.0)]
        offsets = [10.0, 10.0, 10.0]  # 10 m left offset

        result = _apply_arc_offset(coords, offsets)

        # Should have MORE than 3 points (arc inserted at the bend)
        assert len(result) > 3, f"Expected arc points at bend, got {len(result)} points"

        # All points near the bend vertex (100, 0) should be ~10 m away
        bend_cx, bend_cy = 100.0, 0.0
        for px, py in result:
            dist_to_bend = math.sqrt((px - bend_cx) ** 2 + (py - bend_cy) ** 2)
            # Only check points that are clearly arc points (near the bend)
            if dist_to_bend < 15.0:
                assert abs(dist_to_bend - 10.0) < 1.0, (
                    f"Arc point ({px:.1f}, {py:.1f}) is {dist_to_bend:.1f}m from "
                    f"bend vertex, expected ~10m"
                )

    def test_arc_offset_no_arc_on_straight_line(self):
        """A perfectly straight line should NOT get arc points."""
        from app.services.mapping.corridor_pipeline import _apply_arc_offset

        coords = [(0.0, 0.0), (50.0, 0.0), (100.0, 0.0)]
        offsets = [10.0, 10.0, 10.0]

        result = _apply_arc_offset(coords, offsets)

        # Straight line: no arcs needed, should stay at 3 points
        assert len(result) == 3

    def test_densify_adds_vertices(self):
        """Densify should subdivide segments longer than max_spacing."""
        from app.services.mapping.corridor_pipeline import _densify_with_offsets

        coords = [(0.0, 0.0), (100.0, 0.0)]  # 100 m segment
        offsets = [5.0, 10.0]

        dense_c, dense_o = _densify_with_offsets(coords, offsets, max_spacing=15.0)

        # 100 m / 15 m = 7 subdivisions → 8 points
        assert len(dense_c) >= 7
        assert len(dense_c) == len(dense_o)

        # Offsets should be linearly interpolated
        assert abs(dense_o[0] - 5.0) < 0.01
        assert abs(dense_o[-1] - 10.0) < 0.01

    def test_rdp_simplify_preserves_shape(self):
        """RDP should remove redundant colinear points but keep corners."""
        from app.services.mapping.corridor_pipeline import _rdp_simplify

        # L-shape with extra colinear points
        coords = [
            (0.0, 0.0), (25.0, 0.0), (50.0, 0.0), (75.0, 0.0), (100.0, 0.0),
            (100.0, 25.0), (100.0, 50.0), (100.0, 75.0), (100.0, 100.0),
        ]
        result = _rdp_simplify(coords, tolerance=1.0)

        # Should reduce to ~3 points (start, corner, end)
        assert len(result) <= 4
        assert len(result) >= 3


class TestLaneOrdering:
    """Tests for the backend shared-corridor lane ordering solver."""

    def test_lane_order_solver_prefers_pairwise_preferences(self):
        from app.services.mapping.corridor_pipeline import (
            _compute_lane_order_scores,
            _solve_lane_order,
        )

        pairwise_preferences = {
            8: {1: 8.0, 3: 8.0},
            1: {3: 5.0},
        }
        scores = _compute_lane_order_scores(pairwise_preferences, {1, 3, 8})

        assert _solve_lane_order({1, 3, 8}, pairwise_preferences, scores) == (8, 1, 3)
        assert _solve_lane_order({1, 8}, pairwise_preferences, scores) == (8, 1)

    def test_compute_corridor_offsets_follows_physical_left_right_order(self):
        from shapely.geometry import LineString

        from app.services.mapping.corridor_pipeline import (
            LANE_WIDTH,
            _compute_corridor_offsets,
        )

        def make_path(y: float) -> LineString:
            return LineString([(i * 5.0, y) for i in range(80)])

        # Physical order is north→south = left→right for an eastbound path.
        # The trunk ids are intentionally out of order so the test proves we
        # are not falling back to canonical trunk sorting.
        trunk_paths = {
            8: [make_path(8.0)],
            1: [make_path(0.0)],
            3: [make_path(-8.0)],
        }

        offsets = _compute_corridor_offsets(trunk_paths)

        def average_core_offset(values: list[float]) -> float:
            core = values[10:-10] if len(values) > 20 else values
            return sum(core) / len(core)

        averages = {
            trunk_idx: average_core_offset(offsets[trunk_idx][0])
            for trunk_idx in trunk_paths
        }

        assert averages[8] < averages[1] < averages[3]
        assert averages[8] < -0.4 * LANE_WIDTH
        assert abs(averages[1]) < 0.25 * LANE_WIDTH
        assert averages[3] > 0.4 * LANE_WIDTH
