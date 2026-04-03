"""Tests for _segment_export_path_by_lane_offset.

All offsets use LANE_WIDTH=40 m and _EXPORT_LANE_OFFSET_STEP=0.5, so the
quantisation ladder (in visual lane units) is:
  0 m → 0.0
  20 m → 0.5
  40 m → 1.0
  60 m → 1.5
  …

A segment must be > 700 m long (≥ 36 points at 20 m spacing) to survive the
absorption pass unchanged.
"""

from __future__ import annotations

from app.services.mapping.corridor_pipeline import _segment_export_path_by_lane_offset


def _straight_path(
    point_count: int, spacing_m: float = 20.0
) -> list[tuple[float, float]]:
    """Build a path along the x-axis with uniform *spacing_m* between points."""
    return [(idx * spacing_m, 0.0) for idx in range(point_count)]


def test_segment_export_two_long_segments_different_offsets():
    """Two long sections with different offsets produce two distinct output segments."""
    coords = _straight_path(80)  # 1580 m
    offsets_m = [0.0] * 40 + [20.0] * 40  # 0.0 → 0.0, 20 m → 0.5

    segments = _segment_export_path_by_lane_offset(coords, offsets_m)
    lane_offsets = [lane_offset for _, lane_offset in segments]

    assert lane_offsets == [0.0, 0.5]


def test_segment_export_preserves_sign_change_corridor_switch():
    """Lines crossing from negative to positive offset produce both-sided segments."""
    coords = _straight_path(80)
    offsets_m = [-40.0] * 40 + [40.0] * 40  # full left-to-right lane switch

    segments = _segment_export_path_by_lane_offset(coords, offsets_m)
    lane_offsets = [lane_offset for _, lane_offset in segments]

    assert any(offset < 0.0 for offset in lane_offsets)
    assert any(offset > 0.0 for offset in lane_offsets)


def test_segment_export_three_long_sections_step_half():
    """Three long sections stepping by 20 m each yield [0.0, 0.5, 1.0]."""
    coords = _straight_path(120)  # 2380 m
    offsets_m = [0.0] * 40 + [20.0] * 40 + [40.0] * 40

    segments = _segment_export_path_by_lane_offset(coords, offsets_m)
    lane_offsets = [lane_offset for _, lane_offset in segments]

    assert lane_offsets == [0.0, 0.5, 1.0]


def test_segment_export_middle_section_not_collapsed():
    """The middle segment in a three-section path has enough points to survive."""
    coords = _straight_path(120)
    offsets_m = [0.0] * 40 + [20.0] * 40 + [40.0] * 40

    segments = _segment_export_path_by_lane_offset(coords, offsets_m)

    assert len(segments) == 3
    assert len(segments[1][0]) >= 5


def test_segment_export_five_long_sections_half_step_staircase():
    """Five 40-point sections with 20 m increments produce a full staircase."""
    coords = _straight_path(200)  # 3980 m
    offsets_m = (
        [0.0] * 40
        + [20.0] * 40
        + [40.0] * 40
        + [60.0] * 40
        + [80.0] * 40
    )

    segments = _segment_export_path_by_lane_offset(coords, offsets_m)
    lane_offsets = [lane_offset for _, lane_offset in segments]

    assert lane_offsets == [0.0, 0.5, 1.0, 1.5, 2.0]

