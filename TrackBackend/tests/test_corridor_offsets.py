#
# test_corridor_offsets.py
# TrackBackend
#
# Tests for the server-side corridor offset computation (Audit Item 5).
# Validates that co-located subway lines are fanned out perpendicular
# to the track so they don't stack on the same pixel.
#

from __future__ import annotations

import pytest

from app.models import SubwayLineOverlay
from app.routers.subway import _apply_corridor_offsets, _decode_polyline, _encode_polyline


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


class TestApplyCorridorOffsets:
    """Tests for _apply_corridor_offsets."""

    def _make_overlay(self, route_id: str, coords: list[list[tuple[float, float]]]) -> SubwayLineOverlay:
        """Helper: create a SubwayLineOverlay with encoded polylines."""
        return SubwayLineOverlay(
            route_id=route_id,
            color_hex="#FF0000",
            polylines=[_encode_polyline(c) for c in coords],
        )

    def test_single_line_no_offset(self):
        """A single subway line should have no offset applied."""
        coords = [(40.70 + i * 0.001, -73.90) for i in range(10)]
        overlays = [self._make_overlay("1", [coords])]
        result = _apply_corridor_offsets(overlays)
        assert len(result) == 1

        decoded_in = _decode_polyline(overlays[0].polylines[0])
        decoded_out = _decode_polyline(result[0].polylines[0])

        # Coordinates should be unchanged (no shared corridor)
        for (ilat, ilon), (olat, olon) in zip(decoded_in, decoded_out):
            assert abs(ilat - olat) < 1e-5
            assert abs(ilon - olon) < 1e-5

    def test_two_colocated_lines_offset(self):
        """Two lines sharing the same track should be offset from each other."""
        # Same coordinates for both lines (co-located corridor)
        shared = [(40.70 + i * 0.001, -73.90) for i in range(10)]
        overlays = [
            self._make_overlay("4", [shared]),
            self._make_overlay("5", [shared]),
        ]
        result = _apply_corridor_offsets(overlays, offset_meters=22.0, grid_size=0.0003)
        assert len(result) == 2

        decoded_4 = _decode_polyline(result[0].polylines[0])
        decoded_5 = _decode_polyline(result[1].polylines[0])

        # The two lines should differ (offset applied)
        diffs = [
            abs(decoded_4[i][1] - decoded_5[i][1])
            for i in range(len(decoded_4))
        ]
        avg_diff = sum(diffs) / len(diffs)
        # Expect non-zero offset (at least some difference due to 22m offset)
        assert avg_diff > 1e-6, f"Expected offset between lines but avg diff was {avg_diff}"

    def test_three_colocated_lines_centered(self):
        """Three co-located lines: the middle one (alphabetically) should be near the original."""
        shared = [(40.70 + i * 0.001, -73.90) for i in range(10)]
        overlays = [
            self._make_overlay("4", [shared]),
            self._make_overlay("5", [shared]),
            self._make_overlay("6", [shared]),
        ]
        result = _apply_corridor_offsets(overlays, offset_meters=22.0)

        # After sorting alphabetically: 4, 5, 6
        # Slots: 4→0, 5→1, 6→2  →  center_offsets: -1, 0, +1
        # The "5" line (index 1 in result) should be closest to original
        decoded_orig = _decode_polyline(overlays[1].polylines[0])
        decoded_5 = _decode_polyline(result[1].polylines[0])

        for (olat, olon), (dlat, dlon) in zip(decoded_orig, decoded_5):
            # center_offset == 0 for "5" → no offset
            assert abs(olat - dlat) < 1e-4
            assert abs(olon - dlon) < 1e-4

    def test_non_overlapping_lines_untouched(self):
        """Lines on different tracks should not be offset."""
        line_a = [(40.70 + i * 0.001, -73.90) for i in range(10)]
        line_b = [(40.80 + i * 0.001, -73.80) for i in range(10)]  # Far away
        overlays = [
            self._make_overlay("A", [line_a]),
            self._make_overlay("L", [line_b]),
        ]
        result = _apply_corridor_offsets(overlays)

        decoded_a_in = _decode_polyline(overlays[0].polylines[0])
        decoded_a_out = _decode_polyline(result[0].polylines[0])

        for (ilat, ilon), (olat, olon) in zip(decoded_a_in, decoded_a_out):
            assert abs(ilat - olat) < 1e-5
            assert abs(ilon - olon) < 1e-5

    def test_preserves_route_id_and_color(self):
        """Offsets should preserve route_id and color_hex."""
        coords = [(40.70, -73.90), (40.71, -73.91)]
        overlays = [
            SubwayLineOverlay(route_id="G", color_hex="#6CBE45", polylines=[_encode_polyline(coords)]),
        ]
        result = _apply_corridor_offsets(overlays)
        assert result[0].route_id == "G"
        assert result[0].color_hex == "#6CBE45"

    def test_short_polyline_handled(self):
        """Single-point polylines should pass through without error."""
        coords_short = [(40.70, -73.90)]
        coords_normal = [(40.70, -73.90), (40.71, -73.91)]
        overlays = [
            self._make_overlay("1", [coords_short, coords_normal]),
        ]
        result = _apply_corridor_offsets(overlays)
        assert len(result) == 1
        # Should have 2 polylines still
        assert len(result[0].polylines) == 2

    def test_offset_symmetry(self):
        """For two co-located lines, offsets should be symmetric around the centerline."""
        shared = [(40.70 + i * 0.001, -73.90) for i in range(10)]
        overlays = [
            self._make_overlay("A", [shared]),
            self._make_overlay("C", [shared]),
        ]
        result = _apply_corridor_offsets(overlays, offset_meters=22.0)

        decoded_a = _decode_polyline(result[0].polylines[0])
        decoded_c = _decode_polyline(result[1].polylines[0])
        decoded_orig = _decode_polyline(overlays[0].polylines[0])

        # Check symmetry: midpoint of A and C should be near original
        for i in range(len(decoded_orig)):
            mid_lat = (decoded_a[i][0] + decoded_c[i][0]) / 2
            mid_lon = (decoded_a[i][1] + decoded_c[i][1]) / 2
            assert abs(mid_lat - decoded_orig[i][0]) < 1e-4
            assert abs(mid_lon - decoded_orig[i][1]) < 1e-4
