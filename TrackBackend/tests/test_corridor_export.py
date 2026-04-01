from __future__ import annotations

from app.services.mapping.corridor_pipeline import _segment_export_path_by_lane_offset


def _straight_path(
    point_count: int, spacing_m: float = 20.0
) -> list[tuple[float, float]]:
    return [(idx * spacing_m, 0.0) for idx in range(point_count)]


def test_segment_export_absorbs_short_same_sign_transition_run():
    coords = _straight_path(9)
    offsets_m = [0.0, 0.0, 10.0, 10.0, 20.0, 20.0, 20.0, 20.0, 20.0]

    segments = _segment_export_path_by_lane_offset(coords, offsets_m)
    lane_offsets = [lane_offset for _, lane_offset in segments]

    assert lane_offsets == [0.0, 0.5]


def test_segment_export_preserves_sign_change_corridor_switch():
    coords = _straight_path(8)
    offsets_m = [-20.0, -20.0, -10.0, -10.0, 10.0, 10.0, 20.0, 20.0]

    segments = _segment_export_path_by_lane_offset(coords, offsets_m)
    lane_offsets = [lane_offset for _, lane_offset in segments]

    assert any(offset < 0.0 for offset in lane_offsets)
    assert any(offset > 0.0 for offset in lane_offsets)


def test_segment_export_keeps_visible_y_split_transition_step():
    coords = _straight_path(8)
    offsets_m = [0.0, 0.0, 20.0, 20.0, 40.0, 40.0, 40.0, 40.0]

    segments = _segment_export_path_by_lane_offset(coords, offsets_m)
    lane_offsets = [lane_offset for _, lane_offset in segments]

    assert lane_offsets == [0.0, 0.5, 1.0]


def test_segment_export_expands_short_y_split_transition_for_visibility():
    coords = _straight_path(8)
    offsets_m = [0.0, 0.0, 20.0, 40.0, 40.0, 40.0, 40.0, 40.0]

    segments = _segment_export_path_by_lane_offset(coords, offsets_m)
    lane_offsets = [lane_offset for _, lane_offset in segments]

    assert lane_offsets == [0.0, 0.5, 1.0]
    assert len(segments[1][0]) >= 5


def test_segment_export_preserves_quarter_step_inside_long_fanout_ramp():
    coords = _straight_path(10)
    offsets_m = [0.0, 0.0, 10.0, 10.0, 20.0, 20.0, 30.0, 30.0, 40.0, 40.0]

    segments = _segment_export_path_by_lane_offset(coords, offsets_m)
    lane_offsets = [lane_offset for _, lane_offset in segments]

    assert lane_offsets == [0.0, 0.25, 0.5, 0.75, 1.0]
