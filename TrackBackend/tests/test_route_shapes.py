#
# test_route_shapes.py
# TrackBackend
#
# Tests that EVERY subway line, LIRR branch, and MNR line returns actual
# track geometry (polylines) when tapped. Also tests bus route shape
# endpoint returns polylines + stops.
#
# This validates the full "tap → track" pipeline: the shape endpoints
# must never return empty polylines for known routes.
#

from __future__ import annotations

import pytest
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.main import app
from app.models import BusStop, RouteShape
from app.services.subway_shapes import get_subway_route_shape
from app.services.commuter_rail_shapes import (
    get_all_lirr_lines,
    get_all_mnr_lines,
    get_single_lirr_line,
    get_single_mnr_line,
)
from app.utils.transit_utils import get_all_subway_lines, get_subway_color

client = TestClient(app)


# ===================================================================
# SUBWAY: Every line must return track geometry + stops
# ===================================================================

# The canonical subway lines that users can tap on.
# Express/shuttle variants share tracks so the main list is what matters.
SUBWAY_LINES_CORE = [
    "1", "2", "3", "4", "5", "6",
    "7", "A", "C", "E", "B", "D", "F", "M",
    "G", "J", "Z", "L", "N", "Q", "R", "W",
]

# Shuttles and express overlays may not have separate shapes
SUBWAY_SHUTTLES = ["GS", "FS", "SI"]


class TestSubwayShapeData:
    """Verify GTFS static data returns polylines and stops for every subway line."""

    @pytest.mark.parametrize("line_id", SUBWAY_LINES_CORE)
    def test_subway_line_has_shape_data(self, line_id: str):
        """Every core subway line MUST have polyline + stop data in GTFS."""
        result = get_subway_route_shape(line_id)
        assert result is not None, f"No shape data for subway line {line_id}"
        polylines, stops, directions = result
        assert len(polylines) > 0, f"Subway {line_id}: no polylines"
        total_points = sum(len(p) for p in polylines)
        assert total_points > 2, f"Subway {line_id}: only {total_points} points"
        assert len(stops) > 0, f"Subway {line_id}: no stops"
        assert len(directions) >= 1, f"Subway {line_id}: no direction data"

    @pytest.mark.parametrize("line_id", SUBWAY_LINES_CORE)
    def test_subway_line_stops_have_coords(self, line_id: str):
        """Every stop must have valid lat/lon coordinates."""
        result = get_subway_route_shape(line_id)
        assert result is not None
        _, stops, _ = result
        for stop in stops:
            assert stop.lat != 0.0, f"Subway {line_id} stop {stop.name}: lat is 0"
            assert stop.lon != 0.0, f"Subway {line_id} stop {stop.name}: lon is 0"
            # NYC bounding box check
            assert 40.4 < stop.lat < 41.0, f"Subway {line_id} stop {stop.name}: lat {stop.lat} out of NYC"
            assert -74.3 < stop.lon < -73.6, f"Subway {line_id} stop {stop.name}: lon {stop.lon} out of NYC"


class TestSubwayBranches:
    """Verify that branching subway lines include ALL branch stops and polylines.

    Several NYC subway lines split into branches — the shape dedup must keep
    every shape that serves at least one unique stop, not just the longest one.
    """

    def test_a_train_lefferts_blvd_branch(self):
        """A train must include the Lefferts Blvd branch (A63–A65)."""
        result = get_subway_route_shape("A")
        assert result is not None
        _, stops, _ = result
        stop_names = {s.name for s in stops}
        for name in ["104 St", "111 St", "Ozone Park-Lefferts Blvd"]:
            assert name in stop_names, f"A train missing Lefferts stop: {name}"

    def test_a_train_rockaway_park_branch(self):
        """A train must include the Rockaway Park shuttle stops (H12–H15)."""
        result = get_subway_route_shape("A")
        assert result is not None
        _, stops, _ = result
        stop_names = {s.name for s in stops}
        for name in ["Beach 90 St", "Beach 98 St", "Rockaway Park-Beach 116 St"]:
            assert name in stop_names, f"A train missing Rockaway Park stop: {name}"

    def test_a_train_has_multiple_polylines_per_direction(self):
        """A train should have > 1 polyline per direction (trunk + branches)."""
        result = get_subway_route_shape("A")
        assert result is not None
        _, _, dirs = result
        for d in dirs:
            assert len(d.polylines) >= 2, (
                f"A train dir {d.direction_id}: only {len(d.polylines)} polyline — "
                "branches should produce multiple polylines"
            )

    def test_2_train_new_lots_branch(self):
        """2 train must include the New Lots Av branch (248–257)."""
        result = get_subway_route_shape("2")
        assert result is not None
        _, stops, _ = result
        stop_names = {s.name for s in stops}
        for name in ["Nostrand Av", "Crown Hts-Utica Av", "New Lots Av"]:
            assert name in stop_names, f"2 train missing New Lots stop: {name}"

    def test_5_train_dyre_ave_branch(self):
        """5 train must include the Dyre Ave branch."""
        result = get_subway_route_shape("5")
        assert result is not None
        _, stops, _ = result
        stop_names = {s.name for s in stops}
        assert "Eastchester-Dyre Av" in stop_names, "5 train missing Dyre Av terminal"

    def test_n_train_has_all_express_stops(self):
        """N train must include Broadway express stops (e.g. Lex/63)."""
        result = get_subway_route_shape("N")
        assert result is not None
        _, stops, _ = result
        stop_names = {s.name for s in stops}
        assert "Lexington Av/63 St" in stop_names, "N train missing Lex/63 St"

    @pytest.mark.parametrize("line_id", ["A", "N", "2", "5"])
    def test_branching_line_total_stops_exceed_single_shape(self, line_id: str):
        """Branching lines must have MORE total stops than their longest single shape."""
        result = get_subway_route_shape(line_id)
        assert result is not None
        _, stops, dirs = result
        max_single_dir_stops = max(len(d.stops) for d in dirs)
        assert len(stops) > max_single_dir_stops, (
            f"{line_id} train: total {len(stops)} stops should exceed "
            f"single-direction max {max_single_dir_stops} (branches missing?)"
        )


class TestSubwayShapeEndpoint:
    """Verify the /subway/shape/{id} endpoint returns encoded polylines."""

    @pytest.mark.parametrize("line_id", SUBWAY_LINES_CORE)
    def test_subway_shape_endpoint_returns_200(self, line_id: str):
        """GET /subway/shape/{line} must return 200 with polylines + directions."""
        response = client.get(f"/subway/shape/{line_id}")
        assert response.status_code == 200, f"Subway shape /{line_id} returned {response.status_code}"
        data = response.json()
        assert data["route_id"] == line_id
        assert len(data["polylines"]) > 0, f"Subway shape /{line_id}: empty polylines"
        assert len(data["stops"]) > 0, f"Subway shape /{line_id}: no stops"
        # Direction data must be present
        assert "directions" in data, f"Subway shape /{line_id}: missing directions"
        assert len(data["directions"]) >= 1, f"Subway shape /{line_id}: no direction entries"
        for d in data["directions"]:
            assert "direction_id" in d
            assert "polylines" in d
            assert len(d["polylines"]) > 0, f"Subway {line_id} direction {d['direction_id']}: empty polylines"

    @pytest.mark.parametrize("line_id", SUBWAY_LINES_CORE)
    def test_subway_shape_polylines_are_encoded_strings(self, line_id: str):
        """Polylines must be non-empty Google-encoded strings."""
        data = client.get(f"/subway/shape/{line_id}").json()
        for i, poly in enumerate(data["polylines"]):
            assert isinstance(poly, str), f"Subway {line_id} polyline[{i}] not a string"
            assert len(poly) > 10, f"Subway {line_id} polyline[{i}] too short ({len(poly)} chars)"


class TestSubwayShapeColors:
    """Verify every subway line returns a valid hex color."""

    @pytest.mark.parametrize("line_id", SUBWAY_LINES_CORE)
    def test_subway_line_has_color(self, line_id: str):
        color = get_subway_color(line_id)
        assert color.startswith("#"), f"Subway {line_id} color '{color}' missing #"
        assert len(color) == 7, f"Subway {line_id} color '{color}' wrong length"
        assert color != "#808183", f"Subway {line_id} got fallback grey"


# ===================================================================
# LIRR: Every branch must return track geometry
# ===================================================================

# LIRR GTFS route_ids → branch names
# Note: "11" (Belmont Park) and "12" (City Terminal Zone) are excluded because
# they are seasonal/limited-service branches with no GTFS shape data.
LIRR_BRANCHES = {
    "1": "Babylon",
    "2": "Hempstead",
    "3": "Oyster Bay",
    "4": "Ronkonkoma",
    "5": "Montauk",
    "6": "Long Beach",
    "7": "Far Rockaway",
    "8": "West Hempstead",
    "9": "Port Washington",
    "10": "Port Jefferson",
}


class TestLIRRShapeData:
    """Verify GTFS static data returns polylines for every LIRR branch."""

    @pytest.mark.parametrize("route_id,branch", list(LIRR_BRANCHES.items()))
    def test_lirr_branch_has_shape(self, route_id: str, branch: str):
        """Every LIRR branch must have polyline data."""
        result = get_single_lirr_line(route_id)
        assert result is not None, f"LIRR branch {branch} (route_id={route_id}): no shape data"
        assert len(result["polylines"]) > 0, f"LIRR {branch}: empty polylines"
        total_points = sum(len(p) for p in result["polylines"])
        assert total_points > 2, f"LIRR {branch}: only {total_points} points"

    @pytest.mark.parametrize("route_id,branch", list(LIRR_BRANCHES.items()))
    def test_lirr_branch_has_name_and_color(self, route_id: str, branch: str):
        """Shape data must include a name and color."""
        result = get_single_lirr_line(route_id)
        assert result is not None
        assert result["name"], f"LIRR {branch}: empty name"
        assert result["color_hex"], f"LIRR {branch}: empty color"
        assert result["route_id"].startswith("LIRR_"), f"LIRR {branch}: route_id not prefixed"

    def test_lirr_shapes_all_returns_branches(self):
        """get_all_lirr_lines must return at least 9 major branches."""
        lines = get_all_lirr_lines()
        assert len(lines) >= 9, f"Only {len(lines)} LIRR branches returned"
        for line in lines:
            assert len(line["polylines"]) > 0, f"LIRR {line['name']}: empty polylines"
            assert line["color_hex"], f"LIRR {line['name']}: empty color"


class TestLIRRShapeEndpoint:
    """Verify the /lirr/shape/{id} endpoint."""

    @pytest.mark.parametrize("route_id,branch", list(LIRR_BRANCHES.items()))
    def test_lirr_shape_endpoint_returns_200(self, route_id: str, branch: str):
        """GET /lirr/shape/{id} must return 200 with polylines + directions."""
        response = client.get(f"/lirr/shape/{route_id}")
        assert response.status_code == 200, f"LIRR /{route_id} ({branch}) returned {response.status_code}"
        data = response.json()
        assert len(data["polylines"]) > 0, f"LIRR /{route_id} ({branch}): empty polylines"
        # Direction data must be present for commuter rail
        assert len(data["directions"]) >= 1, f"LIRR /{route_id} ({branch}): no directions"
        for d in data["directions"]:
            assert len(d["polylines"]) > 0, f"LIRR {branch} dir {d['direction_id']}: empty polylines"

    @pytest.mark.parametrize("route_id", list(LIRR_BRANCHES.keys()))
    def test_lirr_shape_accepts_prefixed_id(self, route_id: str):
        """The endpoint must accept both '5' and 'LIRR_5'."""
        r1 = client.get(f"/lirr/shape/{route_id}")
        r2 = client.get(f"/lirr/shape/LIRR_{route_id}")
        assert r1.status_code == 200
        assert r2.status_code == 200
        assert r1.json()["polylines"] == r2.json()["polylines"]

    def test_lirr_shapes_all_endpoint(self):
        """GET /lirr/shapes/all must return all branch overlays."""
        response = client.get("/lirr/shapes/all")
        assert response.status_code == 200
        data = response.json()
        assert "lines" in data
        assert len(data["lines"]) >= 9
        for line in data["lines"]:
            assert line["mode"] == "lirr"
            assert len(line["polylines"]) > 0


# ===================================================================
# MNR: Every line must return track geometry
# ===================================================================

# MNR GTFS route_ids → line names
MNR_LINES = {
    "1": "Hudson",
    "2": "Harlem",
    "3": "New Haven",
    "4": "New Canaan",
    "5": "Danbury",
    "6": "Waterbury",
}


class TestMNRShapeData:
    """Verify GTFS static data returns polylines for every MNR line."""

    @pytest.mark.parametrize("route_id,line_name", list(MNR_LINES.items()))
    def test_mnr_line_has_shape(self, route_id: str, line_name: str):
        """Every MNR line must have polyline data."""
        result = get_single_mnr_line(route_id)
        assert result is not None, f"MNR {line_name} (route_id={route_id}): no shape data"
        assert len(result["polylines"]) > 0, f"MNR {line_name}: empty polylines"
        total_points = sum(len(p) for p in result["polylines"])
        assert total_points > 2, f"MNR {line_name}: only {total_points} points"

    @pytest.mark.parametrize("route_id,line_name", list(MNR_LINES.items()))
    def test_mnr_line_has_name_and_color(self, route_id: str, line_name: str):
        result = get_single_mnr_line(route_id)
        assert result is not None
        assert result["name"], f"MNR {line_name}: empty name"
        assert result["color_hex"], f"MNR {line_name}: empty color"
        assert result["route_id"].startswith("MNR_"), f"MNR {line_name}: route_id not prefixed"

    def test_mnr_shapes_all_returns_lines(self):
        lines = get_all_mnr_lines()
        assert len(lines) >= 3, f"Only {len(lines)} MNR lines returned"
        for line in lines:
            assert len(line["polylines"]) > 0, f"MNR {line['name']}: empty polylines"


class TestMNRShapeEndpoint:
    """Verify the /mnr/shape/{id} endpoint."""

    @pytest.mark.parametrize("route_id,line_name", list(MNR_LINES.items()))
    def test_mnr_shape_endpoint_returns_200(self, route_id: str, line_name: str):
        response = client.get(f"/mnr/shape/{route_id}")
        assert response.status_code == 200, f"MNR /{route_id} ({line_name}) returned {response.status_code}"
        data = response.json()
        assert len(data["polylines"]) > 0, f"MNR /{route_id} ({line_name}): empty polylines"
        # Direction data must be present for commuter rail
        assert len(data["directions"]) >= 1, f"MNR /{route_id} ({line_name}): no directions"
        for d in data["directions"]:
            assert len(d["polylines"]) > 0, f"MNR {line_name} dir {d['direction_id']}: empty polylines"

    @pytest.mark.parametrize("route_id", list(MNR_LINES.keys()))
    def test_mnr_shape_accepts_prefixed_id(self, route_id: str):
        r1 = client.get(f"/mnr/shape/{route_id}")
        r2 = client.get(f"/mnr/shape/MNR_{route_id}")
        assert r1.status_code == 200
        assert r2.status_code == 200
        assert r1.json()["polylines"] == r2.json()["polylines"]

    def test_mnr_shapes_all_endpoint(self):
        response = client.get("/mnr/shapes/all")
        assert response.status_code == 200
        data = response.json()
        assert "lines" in data
        assert len(data["lines"]) >= 3
        for line in data["lines"]:
            assert line["mode"] == "mnr"
            assert len(line["polylines"]) > 0


# ===================================================================
# BUS: Route shape endpoint must return polylines + stops
# ===================================================================


class TestBusRouteShapeEndpoint:
    """Verify bus route shape endpoint returns actual track data."""

    @patch("app.routers.bus.get_route_shape", new_callable=AsyncMock)
    def test_bus_shape_returns_polylines_and_stops(self, mock_shape):
        """When a user taps a bus route, they get the full route line."""
        mock_shape.return_value = RouteShape(
            route_id="MTA NYCT_B63",
            polylines=[
                # Realistic encoded polyline (64 chars)
                "gsqwFn`ubMcAcBcCcDcEcFcGcHcIcJcKcLcMcNcOcPcQcRcScTcUcVcWcXcYcZ",
            ],
            stops=[
                BusStop(id="MTA_308214", name="5 Av / Union St", lat=40.6728, lon=-73.9894),
                BusStop(id="MTA_308215", name="5 Av / 9 St", lat=40.6704, lon=-73.9883),
                BusStop(id="MTA_308216", name="5 Av / 3 St", lat=40.6756, lon=-73.9906),
            ],
        )
        response = client.get("/bus/route-shape/MTA%20NYCT_B63")
        assert response.status_code == 200
        data = response.json()
        assert data["route_id"] == "MTA NYCT_B63"
        assert len(data["polylines"]) > 0, "Bus shape must have polylines"
        assert len(data["stops"]) >= 2, "Bus shape must have stops"
        for poly in data["polylines"]:
            assert len(poly) > 10, "Polyline string too short to be encoded"

    @patch("app.routers.bus.get_route_shape", new_callable=AsyncMock)
    def test_bus_stops_have_valid_coords(self, mock_shape):
        mock_shape.return_value = RouteShape(
            route_id="MTA NYCT_B63",
            polylines=["encodedPoly"],
            stops=[
                BusStop(id="S1", name="Stop 1", lat=40.67, lon=-73.99),
                BusStop(id="S2", name="Stop 2", lat=40.68, lon=-73.98),
            ],
        )
        data = client.get("/bus/route-shape/MTA%20NYCT_B63").json()
        for stop in data["stops"]:
            assert 40.4 < stop["lat"] < 41.0, f"Stop {stop['name']}: lat out of NYC"
            assert -74.3 < stop["lon"] < -73.6, f"Stop {stop['name']}: lon out of NYC"

    @patch("app.routers.bus.get_route_shape", new_callable=AsyncMock)
    def test_bus_shape_empty_returns_gracefully(self, mock_shape):
        """An unknown bus route should still return 200 with empty data."""
        mock_shape.return_value = RouteShape(
            route_id="UNKNOWN", polylines=[], stops=[],
        )
        response = client.get("/bus/route-shape/UNKNOWN")
        assert response.status_code == 200
        data = response.json()
        assert data["polylines"] == []


# ===================================================================
# CROSS-MODE: Tap pipeline dispatches to correct shape endpoint
# ===================================================================


class TestRouteTapDispatching:
    """Verify that clicking a route from /nearby/grouped returns a route_id
    that maps to the CORRECT shape endpoint — no subway ↔ LIRR collision."""

    def test_lirr_route_id_does_not_collide_with_subway(self):
        """LIRR route_id '5' becomes 'LIRR_5' — must NOT hit /subway/shape/5.

        This was the original bug: tapping LIRR Montauk (route 5) fetched
        /subway/shape/5 which matched the 4/5/6 subway line.
        """
        # LIRR_5 hitting the subway endpoint should 404 or return wrong data
        subway_resp = client.get("/subway/shape/LIRR_5")
        assert subway_resp.status_code == 404, (
            "Subway shape endpoint should NOT match 'LIRR_5'"
        )

        # But the LIRR endpoint must return real Montauk data
        lirr_resp = client.get("/lirr/shape/5")
        assert lirr_resp.status_code == 200
        data = lirr_resp.json()
        assert len(data["polylines"]) > 0
        assert "LIRR" in data["route_id"]

    def test_mnr_route_id_does_not_collide_with_subway(self):
        """MNR route_id '1' becomes 'MNR_1' — must NOT hit /subway/shape/1."""
        subway_resp = client.get("/subway/shape/MNR_1")
        assert subway_resp.status_code == 404

        mnr_resp = client.get("/mnr/shape/1")
        assert mnr_resp.status_code == 200
        data = mnr_resp.json()
        assert len(data["polylines"]) > 0

    @pytest.mark.parametrize("route_id", ["5", "1", "2", "3", "4", "6", "7"])
    def test_numeric_ids_resolve_correctly_per_mode(self, route_id: str):
        """Numeric IDs exist in both subway and LIRR/MNR — each mode resolves independently."""
        # Subway side
        subway_resp = client.get(f"/subway/shape/{route_id}")
        assert subway_resp.status_code == 200
        subway_data = subway_resp.json()
        assert subway_data["route_id"] == route_id

        # LIRR side (if the branch exists)
        lirr_resp = client.get(f"/lirr/shape/{route_id}")
        if lirr_resp.status_code == 200:
            lirr_data = lirr_resp.json()
            assert lirr_data["route_id"].startswith("LIRR_")
            # The polylines must be DIFFERENT from the subway version
            assert lirr_data["polylines"] != subway_data["polylines"], (
                f"LIRR shape for route {route_id} should differ from subway shape"
            )


class TestShapeEndpoint404s:
    """Verify that unknown route IDs return 404, not garbage data."""

    def test_subway_shape_404_unknown(self):
        assert client.get("/subway/shape/ZZZ").status_code == 404

    def test_lirr_shape_404_unknown(self):
        assert client.get("/lirr/shape/99").status_code == 404

    def test_mnr_shape_404_unknown(self):
        assert client.get("/mnr/shape/99").status_code == 404


# ===================================================================
# POLYLINE QUALITY: Make sure encoded polylines are decodable
# ===================================================================


def _decode_polyline(encoded: str) -> list[tuple[float, float]]:
    """Decode a Google-encoded polyline string into (lat, lon) pairs."""
    coords: list[tuple[float, float]] = []
    index = 0
    lat = 0
    lng = 0
    while index < len(encoded):
        for is_lng in (False, True):
            shift = 0
            result = 0
            while True:
                b = ord(encoded[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            dlat_or_dlng = ~(result >> 1) if (result & 1) else (result >> 1)
            if is_lng:
                lng += dlat_or_dlng
            else:
                lat += dlat_or_dlng
        coords.append((lat / 1e5, lng / 1e5))
    return coords


class TestPolylineQuality:
    """Verify that encoded polylines decode to real NYC-area coordinates."""

    @pytest.mark.parametrize("line_id", ["A", "L", "1", "7", "G"])
    def test_subway_polyline_decodes_to_nyc(self, line_id: str):
        data = client.get(f"/subway/shape/{line_id}").json()
        for poly_str in data["polylines"]:
            coords = _decode_polyline(poly_str)
            assert len(coords) > 2, f"Subway {line_id}: decoded polyline has < 3 points"
            for lat, lon in coords:
                assert 40.0 < lat < 41.5, f"Subway {line_id}: lat {lat} out of NYC area"
                assert -74.5 < lon < -73.0, f"Subway {line_id}: lon {lon} out of NYC area"

    def test_lirr_polyline_decodes_to_long_island(self):
        data = client.get("/lirr/shape/5").json()  # Montauk
        for poly_str in data["polylines"]:
            coords = _decode_polyline(poly_str)
            assert len(coords) > 2
            for lat, lon in coords:
                assert 40.4 < lat < 41.2, f"LIRR Montauk: lat {lat} outside range"
                assert -74.1 < lon < -71.5, f"LIRR Montauk: lon {lon} outside range"

    def test_mnr_polyline_decodes_to_metro_north_corridor(self):
        data = client.get("/mnr/shape/1").json()  # Hudson
        for poly_str in data["polylines"]:
            coords = _decode_polyline(poly_str)
            assert len(coords) > 2
            for lat, lon in coords:
                assert 40.5 < lat < 42.0, f"MNR Hudson: lat {lat} outside range"
                assert -74.5 < lon < -73.0, f"MNR Hudson: lon {lon} outside range"


# ===================================================================
# SYSTEM MAP: Branch polylines must be preserved on /subway/shapes/all
# ===================================================================


class TestSystemMapBranchPreservation:
    """Verify /subway/shapes/all preserves branching line polylines.

    The system map endpoint must NOT collapse branch polylines (e.g.
    the A train's Far Rockaway, Lefferts Blvd, and Rockaway Park branches)
    into a single trunk line.  Each branch with unique stops should appear
    as a separate polyline.
    """

    def test_system_map_a_train_has_branches(self):
        """A train should have 3 polylines (3 branches) on the system map."""
        data = client.get("/subway/shapes/all").json()
        a_lines = [l for l in data["lines"] if l["route_id"] == "A"]
        assert len(a_lines) == 1, "A train should be in system map"
        poly_count = len(a_lines[0]["polylines"])
        assert poly_count >= 3, (
            f"A train system map should have ≥3 polylines (branches), got {poly_count}"
        )

    @pytest.mark.parametrize("route_id,min_branches", [
        ("A", 3),   # Far Rockaway, Lefferts Blvd, Rockaway Park
        ("N", 3),   # Astoria, Sea Beach, and another
        ("5", 3),   # Dyre Ave, Flatbush, etc.
        ("2", 2),   # Wakefield, New Lots
    ])
    def test_system_map_branching_lines(self, route_id: str, min_branches: int):
        """Branching lines should have multiple polylines on the system map."""
        data = client.get("/subway/shapes/all").json()
        lines = [l for l in data["lines"] if l["route_id"] == route_id]
        assert len(lines) == 1, f"{route_id} train should be in system map"
        poly_count = len(lines[0]["polylines"])
        assert poly_count >= min_branches, (
            f"{route_id} train: expected ≥{min_branches} polylines, got {poly_count}"
        )

    def test_system_map_non_branching_line_has_single_polyline(self):
        """L train has no branches — should have exactly 1 polyline."""
        data = client.get("/subway/shapes/all").json()
        l_lines = [l for l in data["lines"] if l["route_id"] == "L"]
        assert len(l_lines) == 1
        assert len(l_lines[0]["polylines"]) == 1, (
            "L train (no branches) should have exactly 1 polyline"
        )

    def test_system_map_all_lines_have_polylines(self):
        """Every line in the system map response must have ≥1 polyline."""
        data = client.get("/subway/shapes/all").json()
        for line in data["lines"]:
            assert len(line["polylines"]) >= 1, (
                f"System map line {line['route_id']} has no polylines"
            )

    def test_system_map_total_polylines_increased_with_branches(self):
        """Total polyline count should be > number of lines (branches add extras)."""
        data = client.get("/subway/shapes/all").json()
        n_lines = len(data["lines"])
        total_polys = sum(len(l["polylines"]) for l in data["lines"])
        assert total_polys > n_lines, (
            f"System map has {total_polys} polylines for {n_lines} lines — "
            f"expected more due to branches"
        )


# ===================================================================
# NEARBY STATIONS: Server-side proximity filtering
# ===================================================================


class TestNearbyStationsEndpoint:
    """GET /subway/stations/nearby — proximity-filtered station list."""

    def test_nearby_stations_returns_200(self):
        """Endpoint should return 200 with valid coordinates."""
        response = client.get("/subway/stations/nearby?lat=40.758&lon=-73.985&radius=1000")
        assert response.status_code == 200
        data = response.json()
        assert "stations" in data

    def test_nearby_stations_fewer_than_all(self):
        """Nearby endpoint should return fewer stations than the /all endpoint."""
        all_resp = client.get("/subway/stations/all").json()
        nearby_resp = client.get("/subway/stations/nearby?lat=40.758&lon=-73.985&radius=500").json()
        assert len(nearby_resp["stations"]) < len(all_resp["stations"]), (
            "Nearby stations should be a subset of all stations"
        )

    def test_nearby_stations_are_within_radius(self):
        """All returned stations should be within the specified radius."""
        from math import radians, cos, sqrt
        lat, lon, radius = 40.758, -73.985, 1000
        resp = client.get(f"/subway/stations/nearby?lat={lat}&lon={lon}&radius={radius}").json()
        for s in resp["stations"]:
            dlat = (s["lat"] - lat) * 111_000
            dlon = (s["lon"] - lon) * 111_000 * cos(radians(lat))
            dist = sqrt(dlat * dlat + dlon * dlon)
            assert dist <= radius * 1.05, (  # 5% tolerance for float math
                f"Station {s['name']} at distance {dist:.0f}m exceeds radius {radius}m"
            )

    def test_nearby_stations_missing_params(self):
        """Missing lat/lon should return 422."""
        assert client.get("/subway/stations/nearby").status_code == 422

    def test_nearby_stations_default_radius(self):
        """Omitting radius should use the default (1600m)."""
        resp = client.get("/subway/stations/nearby?lat=40.758&lon=-73.985")
        assert resp.status_code == 200


# ===================================================================
# GROUPED ENDPOINT: Mode filter
# ===================================================================


class TestGroupedModeFilter:
    """Verify /nearby/grouped?mode= filters by transit mode."""

    def test_mode_filter_returns_200(self):
        """Each mode filter should return 200."""
        for mode in ("subway", "bus", "lirr", "mnr"):
            resp = client.get(f"/nearby/grouped?lat=40.7&lon=-73.9&mode={mode}")
            assert resp.status_code == 200, f"mode={mode} returned {resp.status_code}"

    def test_mode_filter_restricts_results(self):
        """When mode=subway, only subway results should appear."""
        resp = client.get("/nearby/grouped?lat=40.7&lon=-73.9&mode=subway")
        data = resp.json()
        for group in data:
            assert group["mode"] == "subway", (
                f"Expected mode='subway', got '{group['mode']}' for route {group['route_id']}"
            )

    def test_no_mode_filter_returns_all(self):
        """Without mode filter, all modes should be returned."""
        resp = client.get("/nearby/grouped?lat=40.7&lon=-73.9")
        assert resp.status_code == 200
