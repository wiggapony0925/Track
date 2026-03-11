#
# test_arc_math.py
# Quick verification of circular arc fillet geometry.
#

import math

import pytest
from shapely.geometry import LineString

from app.services.mapping.corridor_pipeline import (
    _compute_arc_from_directions,
    _generate_circular_arc,
    _get_line_end_direction,
    _get_line_start_direction,
    _nearest_point_index,
    _point_dist,
    MIN_FILLET_RADIUS,
    JUNCTION_SETBACK,
)


class TestCircularArcMath:
    """Validate the circular arc fillet geometry."""

    def test_90_degree_right_turn_produces_arc(self):
        """A 90° right turn should produce a valid quarter-circle arc."""
        seg_in = LineString([(0, 100), (100, 100)])
        seg_out = LineString([(100, 100), (100, 0)])

        result = _compute_arc_from_directions(
            vertex=(100, 100),
            dir_in=(1, 0),
            dir_out=(0, -1),
            seg_in=seg_in,
            seg_out=seg_out,
        )
        assert result is not None, "90° right turn should produce an arc"
        arc, setback_in, setback_out = result
        assert len(arc.coords) >= 10
        assert setback_in > 0
        assert setback_out > 0

    def test_90_degree_left_turn_produces_arc(self):
        """A 90° left turn should produce a valid quarter-circle arc."""
        seg_in = LineString([(0, 100), (100, 100)])
        seg_out = LineString([(100, 100), (100, 200)])

        result = _compute_arc_from_directions(
            vertex=(100, 100),
            dir_in=(1, 0),
            dir_out=(0, 1),
            seg_in=seg_in,
            seg_out=seg_out,
        )
        assert result is not None, "90° left turn should produce an arc"

    def test_straight_line_returns_none(self):
        """Straight continuation (no deflection) should not produce an arc."""
        seg_in = LineString([(0, 100), (100, 100)])
        seg_out = LineString([(100, 100), (200, 100)])

        result = _compute_arc_from_directions(
            vertex=(100, 100),
            dir_in=(1, 0),
            dir_out=(1, 0),
            seg_in=seg_in,
            seg_out=seg_out,
        )
        assert result is None, "Straight continuation should return None"

    def test_concentric_arcs_share_center(self):
        """Parallel lanes using the same vertex should produce concentric arcs."""
        # Inner lane (on the skeleton)
        seg_in_inner = LineString([(0, 100), (100, 100)])
        seg_out_inner = LineString([(100, 100), (100, 0)])

        # Outer lane (offset +12m)
        seg_in_outer = LineString([(0, 112), (100, 112)])
        seg_out_outer = LineString([(112, 100), (112, 0)])

        vertex = (100, 100)  # same skeleton vertex for both!

        r_inner = _compute_arc_from_directions(
            vertex=vertex, dir_in=(1, 0), dir_out=(0, -1),
            seg_in=seg_in_inner, seg_out=seg_out_inner,
        )
        r_outer = _compute_arc_from_directions(
            vertex=vertex, dir_in=(1, 0), dir_out=(0, -1),
            seg_in=seg_in_outer, seg_out=seg_out_outer,
        )
        assert r_inner is not None
        assert r_outer is not None

        arc_inner = r_inner[0]
        arc_outer = r_outer[0]

        # Outer arc should be longer (larger radius, same sweep angle)
        assert arc_outer.length > arc_inner.length, (
            f"Outer arc ({arc_outer.length:.1f}) should be longer than "
            f"inner arc ({arc_inner.length:.1f})"
        )

    def test_near_u_turn_returns_none(self):
        """Near-U-turns (>160° deflection) should be rejected."""
        seg_in = LineString([(200, 100), (100, 100)])
        seg_out = LineString([(100, 100), (200, 101)])  # nearly opposite

        result = _compute_arc_from_directions(
            vertex=(100, 100),
            dir_in=(-1, 0),
            dir_out=(1, 0.01),
            seg_in=seg_in,
            seg_out=seg_out,
        )
        assert result is None, "Near-U-turn should return None"

    def test_generate_circular_arc_basic(self):
        """_generate_circular_arc should produce a valid LineString."""
        arc = _generate_circular_arc(
            center=(0, 0),
            start_pt=(30, 0),
            end_pt=(0, 30),
            r_start=30,
            r_end=30,
            turn_left=True,
        )
        assert arc is not None
        assert len(arc.coords) == 17  # 16 segments + 1

        # All points should be ~30m from center
        for x, y in arc.coords:
            r = math.sqrt(x * x + y * y)
            assert abs(r - 30) < 0.5, f"Point ({x:.1f}, {y:.1f}) has r={r:.1f}, expected ~30"

    def test_direction_helpers(self):
        """_get_line_end_direction and _get_line_start_direction."""
        line = LineString([(0, 0), (10, 0), (10, 10)])

        start_dir = _get_line_start_direction(line)
        assert start_dir is not None
        assert abs(start_dir[0] - 1.0) < 1e-6
        assert abs(start_dir[1]) < 1e-6

        end_dir = _get_line_end_direction(line)
        assert end_dir is not None
        assert abs(end_dir[0]) < 1e-6
        assert abs(end_dir[1] - 1.0) < 1e-6

    def test_nearest_point_index(self):
        """_nearest_point_index finds the closest point."""
        points = [(0, 0), (10, 10), (20, 20)]
        assert _nearest_point_index((9, 11), points) == 1
        assert _nearest_point_index((0, 0), points) == 0
        assert _nearest_point_index((100, 100), points) == 2
        assert _nearest_point_index((5, 5), []) is None
