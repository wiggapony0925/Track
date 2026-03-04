#
# test_all_endpoints.py
# TrackBackend
#
# Comprehensive test suite for EVERY endpoint in the Track backend.
# Tests cover: models, grouping logic, subway, bus, LIRR, MNR,
# nearby, status, predict, and config endpoints.
#

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.models import (
    AllCommuterRailLinesResponse,
    AllSubwayLinesResponse,
    AllSubwayStationsResponse,
    BusArrival,
    BusRoute,
    BusStop,
    BusVehicle,
    CommuterRailLineOverlay,
    DirectionArrivals,
    ElevatorStatus,
    GroupedNearbyTransit,
    NearbyTransitArrival,
    RouteShape,
    SubwayLineOverlay,
    SubwayStation,
    TrackArrival,
    TransitAlert,
)
from app.routers.nearby import _display_name, _group_arrivals, _soonest_minutes
from app.services.commuter_rail_shapes import (
    get_lirr_route_color,
    get_lirr_route_name,
    get_mnr_route_color,
    get_mnr_route_name,
    get_single_lirr_line,
    get_single_mnr_line,
)

client = TestClient(app)


# ===================================================================
# 1. CONFIG ENDPOINT
# ===================================================================


class TestConfigEndpoint:
    """GET /config — returns app_settings from settings.json."""

    def test_config_returns_200(self):
        response = client.get("/config")
        assert response.status_code == 200

    def test_config_has_required_keys(self):
        data = client.get("/config").json()
        required = [
            "search_radius_meters",
            "refresh_interval_seconds",
            "nearest_metro_fallback_radius_meters",
            "max_nearby_results",
            "max_arrivals_per_feed",
            "nearby_bus_stops_limit",
            "http_timeout_seconds",
            "http_connect_timeout_seconds",
            "http_max_retries",
            "http_retry_delay_seconds",
            "show_ghost_trains",
            "simulation_easing_enabled",
        ]
        for key in required:
            assert key in data, f"Missing key: {key}"

    def test_config_values_are_correct_type(self):
        data = client.get("/config").json()
        assert isinstance(data["search_radius_meters"], int)
        assert isinstance(data["refresh_interval_seconds"], int)
        assert isinstance(data["http_timeout_seconds"], float)
        assert isinstance(data["show_ghost_trains"], bool)


# ===================================================================
# 2. SUBWAY ENDPOINTS
# ===================================================================


class TestSubwayShapesAll:
    """GET /subway/shapes/all — full system map overlay."""

    @patch("app.routers.subway.get_all_subway_lines", return_value=["A", "L"])
    @patch("app.services.subway_shapes._load_route_shapes")
    @patch("app.services.subway_shapes._load_shapes")
    def test_shapes_all_returns_overlays(self, mock_shapes, mock_route_shapes, mock_lines):
        import struct

        mock_route_shapes.return_value = {
            "A": {0: ["shapeA"]},
            "L": {0: ["shapeL"]},
        }

        mock_shapes.return_value = {
            "shapeA": struct.pack("<4f", 40.7, -74.0, 40.71, -74.01),
            "shapeL": struct.pack("<4f", 40.72, -73.95, 40.73, -73.96),
        }

        response = client.get("/subway/shapes/all")
        assert response.status_code == 200
        data = response.json()
        assert "lines" in data
        assert len(data["lines"]) == 2
        route_ids = {l["route_id"] for l in data["lines"]}
        assert route_ids == {"A", "L"}
        for line in data["lines"]:
            assert "color_hex" in line
            assert "polylines" in line
            assert len(line["polylines"]) > 0


class TestSubwayStationsAll:
    """GET /subway/stations/all — all subway station markers."""

    @patch("app.routers.subway.get_all_subway_stations")
    def test_stations_all_returns_stations(self, mock_stations):
        mock_stations.return_value = [
            {"id": "101", "name": "Van Cortlandt Park", "lat": 40.89, "lon": -73.89, "routes": ["1"]},
            {"id": "A27", "name": "59 St-Columbus Circle", "lat": 40.768, "lon": -73.981, "routes": ["A", "C", "B", "D", "1"]},
        ]
        response = client.get("/subway/stations/all")
        assert response.status_code == 200
        data = response.json()
        assert "stations" in data
        assert len(data["stations"]) == 2
        assert data["stations"][0]["name"] == "Van Cortlandt Park"
        assert "routes" in data["stations"][1]


class TestSubwayShape:
    """GET /subway/shape/{route_id} — single subway line geometry."""

    @patch("app.routers.subway.get_subway_route_shape")
    def test_shape_returns_polylines_and_stops(self, mock_shape):
        class FakeStop:
            def __init__(self, stop_id, name, lat, lon):
                self.stop_id = stop_id
                self.name = name
                self.lat = lat
                self.lon = lon

        from app.services.subway_shapes import DirectionData

        stops = [FakeStop("L01", "8 Av", 40.74, -74.0), FakeStop("L02", "6 Av", 40.737, -73.997)]
        polylines = [[(40.7, -74.0), (40.71, -74.01)]]
        dir_data = [
            DirectionData(
                direction_id=0,
                headsign="8 Av",
                polylines=polylines,
                stops=stops,
            ),
            DirectionData(
                direction_id=1,
                headsign="Canarsie-Rockaway Pkwy",
                polylines=polylines,
                stops=stops,
            ),
        ]
        mock_shape.return_value = (polylines, stops, dir_data)

        response = client.get("/subway/shape/L")
        assert response.status_code == 200
        data = response.json()
        assert data["route_id"] == "L"
        assert len(data["polylines"]) == 1
        assert len(data["stops"]) == 2
        assert data["stops"][0]["name"] == "8 Av"
        # Verify direction data is present
        assert len(data["directions"]) == 2
        assert data["directions"][0]["direction_id"] == 0
        assert data["directions"][0]["headsign"] == "8 Av"
        assert len(data["directions"][0]["polylines"]) == 1
        assert data["directions"][1]["direction_id"] == 1

    @patch("app.routers.subway.get_subway_route_shape", return_value=None)
    def test_shape_404_for_unknown_line(self, mock_shape):
        response = client.get("/subway/shape/ZZZ")
        assert response.status_code == 404


class TestSubwayArrivals:
    """GET /subway/{line_id} — live arrivals for a line."""

    @patch("app.routers.subway.get_arrivals_for_line", new_callable=AsyncMock)
    def test_arrivals_returns_fresh(self, mock_arrivals):
        import time
        future_ts = int(time.time()) + 300  # 5 min from now
        mock_arrivals.return_value = [
            TrackArrival(
                route_id="L", station="L01", station_name="8 Av",
                direction="S", destination="Canarsie-Rockaway Pkwy",
                minutes_away=5, arrival_ts=future_ts, status="On Time",
            ),
        ]
        response = client.get("/subway/L")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["route_id"] == "L"
        assert data[0]["arrival_ts"] > 0

    @patch("app.routers.subway.resolve_subway_feed_key", return_value=None)
    def test_arrivals_404_for_unknown_line(self, mock_resolve):
        response = client.get("/subway/ZZZ")
        assert response.status_code == 404

    @patch("app.routers.subway.resolve_subway_feed_key", return_value="subway_l")
    @patch("app.routers.subway.get_arrivals_for_line", new_callable=AsyncMock)
    def test_arrivals_graceful_fallback_on_feed_error(self, mock_arrivals, mock_resolve):
        mock_arrivals.side_effect = Exception("Feed timeout")
        response = client.get("/subway/L")
        # Endpoints now return 200 + empty list on error (graceful degradation)
        assert response.status_code == 200
        assert response.json() == []
        assert response.headers.get("X-Track-Degraded") == "subway-arrivals-fallback"


# ===================================================================
# 3. BUS ENDPOINTS
# ===================================================================


class TestBusRoutes:
    """GET /bus/routes — all MTA bus routes."""

    @patch("app.routers.bus.get_routes", new_callable=AsyncMock)
    def test_routes_returns_list(self, mock_routes):
        mock_routes.return_value = [
            BusRoute(id="MTA NYCT_B63", short_name="B63", long_name="Atlantic Av",
                     color="0039A6", description="Brooklyn"),
        ]
        response = client.get("/bus/routes")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["short_name"] == "B63"


class TestBusStops:
    """GET /bus/stops/{route_id} — stops for a bus route."""

    @patch("app.routers.bus.get_stops", new_callable=AsyncMock)
    def test_stops_returns_list(self, mock_stops):
        mock_stops.return_value = [
            BusStop(id="MTA_308214", name="5 Av / Union St", lat=40.67, lon=-73.98),
        ]
        response = client.get("/bus/stops/MTA%20NYCT_B63")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["name"] == "5 Av / Union St"


class TestBusNearby:
    """GET /bus/nearby — bus stops near a GPS coordinate."""

    @patch("app.routers.bus.get_nearby_stops", new_callable=AsyncMock)
    def test_nearby_returns_stops(self, mock_nearby):
        mock_nearby.return_value = [
            BusStop(id="S1", name="Stop A", lat=40.67, lon=-73.98, direction="SW"),
        ]
        response = client.get("/bus/nearby?lat=40.67&lon=-73.98")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1

    def test_nearby_requires_lat_lon(self):
        response = client.get("/bus/nearby")
        assert response.status_code == 422


class TestBusLive:
    """GET /bus/live/{stop_id} — real-time arrivals at a stop."""

    @patch("app.routers.bus.get_realtime_arrivals", new_callable=AsyncMock)
    def test_live_returns_arrivals(self, mock_live):
        from datetime import timedelta
        mock_live.return_value = [
            BusArrival(
                route_id="MTA NYCT_B63", vehicle_id="V1", stop_id="S1",
                status_text="Approaching", status="Live",
                expected_arrival=datetime.now(timezone.utc) + timedelta(minutes=10),
            ),
        ]
        response = client.get("/bus/live/MTA_308214")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["status"] == "Live"


class TestBusVehicles:
    """GET /bus/vehicles/{route_id} — live vehicle positions."""

    @patch("app.routers.bus.get_vehicle_positions", new_callable=AsyncMock)
    def test_vehicles_returns_positions(self, mock_vehicles):
        mock_vehicles.return_value = [
            BusVehicle(vehicle_id="V1", route_id="B63", lat=40.67, lon=-73.99, bearing=180.0),
        ]
        response = client.get("/bus/vehicles/MTA%20NYCT_B63")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["bearing"] == 180.0

    @patch("app.routers.bus.get_vehicle_positions", new_callable=AsyncMock)
    def test_vehicles_empty(self, mock_vehicles):
        mock_vehicles.return_value = []
        response = client.get("/bus/vehicles/MTA%20NYCT_X99")
        assert response.status_code == 200
        assert response.json() == []


class TestBusRouteShape:
    """GET /bus/route-shape/{route_id} — route geometry and stops."""

    @patch("app.routers.bus.get_route_shape", new_callable=AsyncMock)
    def test_route_shape_returns_data(self, mock_shape):
        mock_shape.return_value = RouteShape(
            route_id="MTA NYCT_B63",
            polylines=["encoded_poly"],
            stops=[BusStop(id="S1", name="Stop 1", lat=40.0, lon=-74.0)],
        )
        response = client.get("/bus/route-shape/MTA%20NYCT_B63")
        assert response.status_code == 200
        data = response.json()
        assert data["route_id"] == "MTA NYCT_B63"
        assert len(data["polylines"]) == 1
        assert len(data["stops"]) == 1


# ===================================================================
# 4. LIRR ENDPOINTS
# ===================================================================


class TestLIRRShapesAll:
    """GET /lirr/shapes/all — all LIRR branch polylines."""

    @patch("app.routers.lirr.get_all_lirr_lines")
    def test_shapes_all_returns_overlays(self, mock_lines):
        mock_lines.return_value = [
            {
                "route_id": "LIRR_5",
                "name": "Montauk Branch",
                "color_hex": "#006EC7",
                "polylines": [[(40.7, -73.9), (40.8, -73.8)]],
            },
        ]
        response = client.get("/lirr/shapes/all")
        assert response.status_code == 200
        data = response.json()
        assert "lines" in data
        assert len(data["lines"]) == 1
        assert data["lines"][0]["name"] == "Montauk Branch"
        assert data["lines"][0]["mode"] == "lirr"


class TestLIRRShape:
    """GET /lirr/shape/{route_id} — single LIRR branch polyline."""

    @patch("app.routers.lirr.get_single_lirr_line")
    def test_shape_returns_data(self, mock_line):
        mock_line.return_value = {
            "route_id": "LIRR_5",
            "name": "Montauk Branch",
            "color_hex": "006EC7",
            "polylines": [[(40.7, -73.9), (40.8, -73.8)]],
        }
        response = client.get("/lirr/shape/5")
        assert response.status_code == 200
        data = response.json()
        assert data["route_id"] == "LIRR_5"
        assert len(data["polylines"]) == 1
        assert data["stops"] == []  # commuter rail returns empty stops

    @patch("app.routers.lirr.get_single_lirr_line")
    def test_shape_accepts_prefixed_id(self, mock_line):
        mock_line.return_value = {
            "route_id": "LIRR_9",
            "name": "Port Washington Branch",
            "color_hex": "C60C30",
            "polylines": [[(40.7, -73.9), (40.8, -73.8)]],
        }
        response = client.get("/lirr/shape/LIRR_9")
        assert response.status_code == 200
        data = response.json()
        assert data["route_id"] == "LIRR_9"

    @patch("app.routers.lirr.get_single_lirr_line", return_value=None)
    def test_shape_404_for_unknown_branch(self, mock_line):
        response = client.get("/lirr/shape/99")
        assert response.status_code == 404


class TestLIRRArrivals:
    """GET /lirr — upcoming LIRR arrivals."""

    @patch("app.routers.lirr.fetch_rail_arrivals", new_callable=AsyncMock)
    def test_arrivals_returns_fresh(self, mock_arrivals):
        import time
        future_ts = int(time.time()) + 600
        mock_arrivals.return_value = [
            TrackArrival(
                route_id="5", station="LI_BPORT", station_name="Bridgehampton",
                direction="W", destination="Penn Station",
                minutes_away=10, arrival_ts=future_ts,
            ),
        ]
        response = client.get("/lirr")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["route_id"] == "5"

    @patch("app.routers.lirr.fetch_rail_arrivals", new_callable=AsyncMock)
    def test_arrivals_graceful_fallback_on_error(self, mock_arrivals):
        mock_arrivals.side_effect = Exception("LIRR feed timeout")
        response = client.get("/lirr")
        # Endpoints now return 200 + empty list on error (graceful degradation)
        assert response.status_code == 200
        assert response.json() == []
        assert response.headers.get("X-Track-Degraded") == "lirr-arrivals-fallback"


# ===================================================================
# 5. MNR ENDPOINTS
# ===================================================================


class TestMNRShapesAll:
    """GET /mnr/shapes/all — all Metro-North line polylines."""

    @patch("app.routers.mnr.get_all_mnr_lines")
    def test_shapes_all_returns_overlays(self, mock_lines):
        mock_lines.return_value = [
            {
                "route_id": "MNR_1",
                "name": "Hudson Line",
                "color_hex": "009B3A",
                "polylines": [[(40.9, -73.9), (41.0, -73.8)]],
            },
        ]
        response = client.get("/mnr/shapes/all")
        assert response.status_code == 200
        data = response.json()
        assert "lines" in data
        assert len(data["lines"]) == 1
        assert data["lines"][0]["name"] == "Hudson Line"
        assert data["lines"][0]["mode"] == "mnr"


class TestMNRShape:
    """GET /mnr/shape/{route_id} — single Metro-North line polyline."""

    @patch("app.routers.mnr.get_single_mnr_line")
    def test_shape_returns_data(self, mock_line):
        mock_line.return_value = {
            "route_id": "MNR_1",
            "name": "Hudson Line",
            "color_hex": "009B3A",
            "polylines": [[(40.9, -73.9), (41.0, -73.8)]],
        }
        response = client.get("/mnr/shape/1")
        assert response.status_code == 200
        data = response.json()
        assert data["route_id"] == "MNR_1"
        assert len(data["polylines"]) == 1

    @patch("app.routers.mnr.get_single_mnr_line")
    def test_shape_accepts_prefixed_id(self, mock_line):
        mock_line.return_value = {
            "route_id": "MNR_3",
            "name": "New Haven Line",
            "color_hex": "E00034",
            "polylines": [[(41.1, -73.2)]],
        }
        response = client.get("/mnr/shape/MNR_3")
        assert response.status_code == 200

    @patch("app.routers.mnr.get_single_mnr_line", return_value=None)
    def test_shape_404_for_unknown_line(self, mock_line):
        response = client.get("/mnr/shape/99")
        assert response.status_code == 404


class TestMNRArrivals:
    """GET /mnr — upcoming Metro-North arrivals."""

    @patch("app.routers.mnr.fetch_rail_arrivals", new_callable=AsyncMock)
    def test_arrivals_returns_fresh(self, mock_arrivals):
        import time
        future_ts = int(time.time()) + 600
        mock_arrivals.return_value = [
            TrackArrival(
                route_id="1", station="MNR_GCT", station_name="Grand Central",
                direction="N", destination="Poughkeepsie",
                minutes_away=8, arrival_ts=future_ts,
            ),
        ]
        response = client.get("/mnr")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["destination"] == "Poughkeepsie"

    @patch("app.routers.mnr.fetch_rail_arrivals", new_callable=AsyncMock)
    def test_arrivals_graceful_fallback_on_error(self, mock_arrivals):
        mock_arrivals.side_effect = Exception("MNR feed timeout")
        response = client.get("/mnr")
        # Endpoints now return 200 + empty list on error (graceful degradation)
        assert response.status_code == 200
        assert response.json() == []
        assert response.headers.get("X-Track-Degraded") == "mnr-arrivals-fallback"


# ===================================================================
# 6. NEARBY ENDPOINTS
# ===================================================================


class TestNearbyFlat:
    """GET /nearby — flat list of nearby arrivals sorted by minutes_away."""

    def test_requires_lat_lon(self):
        assert client.get("/nearby").status_code == 422
        assert client.get("/nearby?lat=40.7").status_code == 422

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_returns_sorted_by_minutes(self, mock_bus, mock_sub, mock_rail):
        mock_rail.return_value = []
        mock_sub.return_value = [
            NearbyTransitArrival(route_id="L", stop_name="1st Ave", direction="N",
                                 minutes_away=5, mode="subway"),
        ]
        mock_bus.return_value = [
            NearbyTransitArrival(route_id="B63", stop_name="5 Av", direction="E",
                                 minutes_away=2, mode="bus"),
        ]
        data = client.get("/nearby?lat=40.7&lon=-73.9").json()
        assert data[0]["minutes_away"] <= data[1]["minutes_away"]

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_includes_lirr_and_mnr(self, mock_bus, mock_sub, mock_rail):
        # _fetch_nearby_rail is called twice (lirr, mnr) — return data only once
        mock_rail.side_effect = [
            [NearbyTransitArrival(route_id="LIRR_5", stop_name="Jamaica",
                                  direction="W", minutes_away=7, mode="lirr")],
            [],  # MNR returns nothing
        ]
        mock_sub.return_value = []
        mock_bus.return_value = []
        data = client.get("/nearby?lat=40.7&lon=-73.9").json()
        assert len(data) == 1
        assert data[0]["route_id"] == "LIRR_5"
        assert data[0]["mode"] == "lirr"

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_handles_all_feeds_failing(self, mock_bus, mock_sub, mock_rail):
        mock_rail.side_effect = [Exception("LIRR down"), Exception("MNR down")]
        mock_sub.side_effect = Exception("Subway down")
        mock_bus.side_effect = Exception("Bus down")
        response = client.get("/nearby?lat=40.7&lon=-73.9")
        assert response.status_code == 200
        assert response.json() == []


class TestNearbyGrouped:
    """GET /nearby/grouped — arrivals grouped by route."""

    def test_requires_lat_lon(self):
        assert client.get("/nearby/grouped").status_code == 422

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_groups_by_route(self, mock_bus, mock_sub, mock_rail):
        mock_rail.return_value = []
        mock_sub.return_value = [
            NearbyTransitArrival(route_id="A", stop_name="S1", direction="N",
                                 minutes_away=3, mode="subway"),
            NearbyTransitArrival(route_id="A", stop_name="S2", direction="S",
                                 minutes_away=5, mode="subway"),
        ]
        mock_bus.return_value = []
        data = client.get("/nearby/grouped?lat=40.7&lon=-73.9").json()
        assert len(data) == 1
        assert data[0]["route_id"] == "A"
        assert len(data[0]["directions"]) == 2

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_grouped_lirr_has_prefixed_id_and_name(self, mock_bus, mock_sub, mock_rail):
        mock_rail.side_effect = [
            [NearbyTransitArrival(route_id="LIRR_5", stop_name="Jamaica",
                                  direction="W", minutes_away=7, mode="lirr")],
            [],  # MNR returns nothing
        ]
        mock_sub.return_value = []
        mock_bus.return_value = []
        data = client.get("/nearby/grouped?lat=40.7&lon=-73.9").json()
        assert len(data) == 1
        assert data[0]["route_id"] == "LIRR_5"
        assert data[0]["mode"] == "lirr"
        # display_name should be the branch name, not "5"
        assert data[0]["display_name"] != "5"
        assert "Branch" in data[0]["display_name"] or "Service" in data[0]["display_name"]

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_grouped_mnr_has_prefixed_id_and_name(self, mock_bus, mock_sub, mock_rail):
        mock_rail.side_effect = [
            [],  # LIRR returns nothing
            [NearbyTransitArrival(route_id="MNR_1", stop_name="Grand Central",
                                  direction="N", minutes_away=4, mode="mnr")],
        ]
        mock_sub.return_value = []
        mock_bus.return_value = []
        data = client.get("/nearby/grouped?lat=40.7&lon=-73.9").json()
        assert len(data) == 1
        assert data[0]["route_id"] == "MNR_1"
        assert data[0]["mode"] == "mnr"
        # display_name should be the resolved line name, not "1"
        assert data[0]["display_name"] != "1"

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_grouped_all_modes_together(self, mock_bus, mock_sub, mock_rail):
        """All 4 modes appear together, sorted by soonest arrival."""
        mock_sub.return_value = [
            NearbyTransitArrival(route_id="L", stop_name="1st Ave", direction="N",
                                 minutes_away=5, mode="subway"),
        ]
        mock_bus.return_value = [
            NearbyTransitArrival(route_id="MTA NYCT_B63", stop_name="5 Av",
                                 direction="E", minutes_away=2, mode="bus"),
        ]
        mock_rail.side_effect = [
            [NearbyTransitArrival(route_id="LIRR_9", stop_name="Jamaica",
                                  direction="W", minutes_away=10, mode="lirr")],
            [],  # MNR returns nothing
        ]
        data = client.get("/nearby/grouped?lat=40.7&lon=-73.9").json()
        assert len(data) == 3
        modes = {g["mode"] for g in data}
        assert modes == {"bus", "subway", "lirr"}
        # Canonical MTA order: subway first, then LIRR, then bus
        assert data[0]["mode"] == "subway"
        assert data[1]["mode"] == "lirr"
        assert data[2]["mode"] == "bus"


# ===================================================================
# 7. STATUS ENDPOINTS
# ===================================================================


class TestAlerts:
    """GET /alerts — critical service alerts."""

    @patch("app.routers.status.get_alerts", new_callable=AsyncMock)
    def test_alerts_returns_list(self, mock_alerts):
        mock_alerts.return_value = [
            TransitAlert(
                route_id="A",
                title="Service Change",
                description="A trains running local",
                severity="MODERATE",
            ),
        ]
        response = client.get("/alerts")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["title"] == "Service Change"

    @patch("app.routers.status.get_alerts", new_callable=AsyncMock)
    def test_alerts_empty(self, mock_alerts):
        mock_alerts.return_value = []
        response = client.get("/alerts")
        assert response.status_code == 200
        assert response.json() == []

    @patch("app.routers.status.get_alerts", new_callable=AsyncMock)
    def test_alerts_502_on_error(self, mock_alerts):
        mock_alerts.side_effect = Exception("Alert feed down")
        response = client.get("/alerts")
        assert response.status_code == 502


class TestAccessibility:
    """GET /accessibility — broken elevators/escalators."""

    @patch("app.routers.status.get_broken_elevators", new_callable=AsyncMock)
    def test_accessibility_returns_list(self, mock_elevators):
        mock_elevators.return_value = [
            ElevatorStatus(
                station="Penn Station",
                equipment_type="Elevator",
                description="Out of service",
                outage_since="2026-02-15",
            ),
        ]
        response = client.get("/accessibility")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["station"] == "Penn Station"

    @patch("app.routers.status.get_broken_elevators", new_callable=AsyncMock)
    def test_accessibility_502_on_error(self, mock_elevators):
        mock_elevators.side_effect = Exception("Elevator feed down")
        response = client.get("/accessibility")
        assert response.status_code == 502


# ===================================================================
# 8. DISPLAY NAME / GROUPING LOGIC (UNIT TESTS)
# ===================================================================


class TestDisplayName:
    """Unit tests for _display_name helper."""

    def test_strips_mta_nyct_prefix(self):
        assert _display_name("MTA NYCT_B63") == "B63"
        # SBS routes: M15+ maps to canonical "M15-SBS" via CANONICAL_BUS_DISPLAY
        assert _display_name("MTA NYCT_M15+") == "M15-SBS"

    def test_strips_mtabc_prefix(self):
        assert _display_name("MTABC_Q112") == "Q112"
        assert _display_name("MTABC_QM1") == "QM1"
        assert _display_name("MTABC_Q58") == "Q58"

    def test_strips_mta_bus_prefix(self):
        assert _display_name("MTA BUS_Q10") == "Q10"

    def test_resolves_lirr_prefix(self):
        name = _display_name("LIRR_5")
        assert name != "5"  # Should be a real branch name
        assert "Montauk" in name or "Branch" in name

    def test_resolves_mnr_prefix(self):
        name = _display_name("MNR_1")
        assert name != "1"
        assert "Hudson" in name or "Line" in name

    def test_passthrough_for_subway(self):
        assert _display_name("L") == "L"
        assert _display_name("A") == "A"


class TestGroupArrivals:
    """Unit tests for _group_arrivals helper."""

    def test_groups_by_route_id(self):
        flat = [
            NearbyTransitArrival(route_id="A", stop_name="S1", direction="N",
                                 minutes_away=3, mode="subway"),
            NearbyTransitArrival(route_id="A", stop_name="S2", direction="S",
                                 minutes_away=5, mode="subway"),
            NearbyTransitArrival(route_id="L", stop_name="S3", direction="N",
                                 minutes_away=2, mode="subway"),
        ]
        groups = _group_arrivals(flat)
        assert len(groups) == 2

    def test_subway_gets_color(self):
        flat = [
            NearbyTransitArrival(route_id="L", stop_name="S1", direction="N",
                                 minutes_away=3, mode="subway"),
        ]
        groups = _group_arrivals(flat)
        assert groups[0].color_hex == "#A7A9AC"

    def test_bus_gets_default_color(self):
        flat = [
            NearbyTransitArrival(route_id="MTA NYCT_B63", stop_name="5 Av",
                                 direction="E", minutes_away=4, mode="bus"),
        ]
        groups = _group_arrivals(flat)
        assert groups[0].color_hex == "#0039A6"

    def test_lirr_gets_branch_color(self):
        flat = [
            NearbyTransitArrival(route_id="LIRR_9", stop_name="Jamaica",
                                 direction="W", minutes_away=7, mode="lirr"),
        ]
        groups = _group_arrivals(flat)
        assert groups[0].color_hex is not None
        assert groups[0].color_hex != "#4D5357"  # Should not be fallback grey

    def test_mnr_gets_line_color(self):
        flat = [
            NearbyTransitArrival(route_id="MNR_1", stop_name="Grand Central",
                                 direction="N", minutes_away=4, mode="mnr"),
        ]
        groups = _group_arrivals(flat)
        assert groups[0].color_hex is not None
        assert groups[0].color_hex != "#4D5357"

    def test_sorted_by_soonest(self):
        flat = [
            NearbyTransitArrival(route_id="A", stop_name="S1", direction="N",
                                 minutes_away=10, mode="subway"),
            NearbyTransitArrival(route_id="L", stop_name="S2", direction="N",
                                 minutes_away=2, mode="subway"),
        ]
        groups = _group_arrivals(flat)
        # Groups are sorted by canonical MTA order first (A=040 < L=080),
        # then by soonest arrival as tiebreaker within the same sort key.
        assert groups[0].route_id == "A"
        assert groups[1].route_id == "L"

    def test_empty_input(self):
        assert _group_arrivals([]) == []


class TestSoonestMinutes:
    """Unit tests for _soonest_minutes helper."""

    def test_returns_min_across_directions(self):
        group = GroupedNearbyTransit(
            route_id="A", display_name="A", mode="subway",
            directions=[
                DirectionArrivals(direction="N", arrivals=[
                    NearbyTransitArrival(route_id="A", stop_name="S1", direction="N",
                                         minutes_away=8, mode="subway"),
                ]),
                DirectionArrivals(direction="S", arrivals=[
                    NearbyTransitArrival(route_id="A", stop_name="S2", direction="S",
                                         minutes_away=3, mode="subway"),
                ]),
            ],
        )
        assert _soonest_minutes(group) == 3

    def test_returns_999_for_empty(self):
        group = GroupedNearbyTransit(
            route_id="X", display_name="X", mode="subway",
            directions=[],
        )
        assert _soonest_minutes(group) == 999


# ===================================================================
# 11. COMMUTER RAIL NAME / COLOR LOOKUPS
# ===================================================================


class TestLIRRRouteLookups:
    """Tests for LIRR route name and color resolution."""

    def test_known_lirr_names(self):
        # Route 5 = Montauk Branch
        name = get_lirr_route_name("5")
        assert "Montauk" in name
        # Route 9 = Port Washington Branch
        name = get_lirr_route_name("9")
        assert "Port Washington" in name

    def test_unknown_lirr_name_falls_back(self):
        name = get_lirr_route_name("999")
        assert name == "999"

    def test_lirr_color_is_hex(self):
        color = get_lirr_route_color("5")
        assert color.startswith("#")
        assert len(color) == 7

    def test_unknown_lirr_color_falls_back_to_grey(self):
        color = get_lirr_route_color("999")
        assert color == "#4D5357"


class TestMNRRouteLookups:
    """Tests for Metro-North route name and color resolution."""

    def test_known_mnr_names(self):
        name = get_mnr_route_name("1")
        assert "Hudson" in name
        name = get_mnr_route_name("2")
        assert "Harlem" in name
        name = get_mnr_route_name("3")
        assert "New Haven" in name

    def test_unknown_mnr_name_falls_back(self):
        name = get_mnr_route_name("999")
        assert name == "999"

    def test_mnr_color_is_hex(self):
        color = get_mnr_route_color("1")
        assert color.startswith("#")
        assert len(color) == 7

    def test_unknown_mnr_color_falls_back_to_grey(self):
        color = get_mnr_route_color("999")
        assert color == "#4D5357"


class TestSingleLineLookups:
    """Tests for get_single_lirr_line / get_single_mnr_line."""

    def test_single_lirr_line_returns_dict(self):
        result = get_single_lirr_line("9")  # Port Washington
        if result is not None:
            # If GTFS data is loaded
            assert result["route_id"] == "LIRR_9"
            assert "polylines" in result
            assert isinstance(result["polylines"], list)

    def test_single_lirr_line_unknown_returns_none(self):
        assert get_single_lirr_line("999") is None

    def test_single_mnr_line_returns_dict(self):
        result = get_single_mnr_line("1")  # Hudson
        if result is not None:
            assert result["route_id"] == "MNR_1"
            assert "polylines" in result

    def test_single_mnr_line_unknown_returns_none(self):
        assert get_single_mnr_line("999") is None


# ===================================================================
# 12. MODEL VALIDATION
# ===================================================================


class TestModels:
    """Pydantic model validation tests."""

    def test_nearby_arrival_requires_mode(self):
        a = NearbyTransitArrival(
            route_id="L", stop_name="S1", direction="N",
            minutes_away=3, mode="subway",
        )
        assert a.mode == "subway"

    def test_nearby_arrival_lirr_mode(self):
        a = NearbyTransitArrival(
            route_id="LIRR_5", stop_name="Jamaica", direction="W",
            minutes_away=7, mode="lirr",
        )
        assert a.mode == "lirr"

    def test_nearby_arrival_mnr_mode(self):
        a = NearbyTransitArrival(
            route_id="MNR_1", stop_name="GCT", direction="N",
            minutes_away=4, mode="mnr",
        )
        assert a.mode == "mnr"

    def test_grouped_transit_model(self):
        g = GroupedNearbyTransit(
            route_id="LIRR_5",
            display_name="Montauk Branch",
            mode="lirr",
            color_hex="#006EC7",
            directions=[
                DirectionArrivals(direction="W", arrivals=[]),
            ],
        )
        assert g.route_id == "LIRR_5"
        assert g.display_name == "Montauk Branch"

    def test_commuter_rail_overlay_model(self):
        overlay = CommuterRailLineOverlay(
            route_id="LIRR_9",
            name="Port Washington Branch",
            color_hex="#C60C30",
            polylines=["encoded"],
            mode="lirr",
        )
        assert overlay.mode == "lirr"

    def test_route_shape_empty_stops(self):
        shape = RouteShape(route_id="LIRR_5", polylines=["poly1"], stops=[])
        assert shape.stops == []

    def test_track_arrival_optional_fields(self):
        a = TrackArrival(
            station="L01", direction="S", minutes_away=5,
        )
        assert a.route_id == ""
        assert a.station_name == ""
        assert a.destination is None
        assert a.trip_id is None

    def test_bus_vehicle_optional_fields(self):
        v = BusVehicle(vehicle_id="V1", route_id="R1", lat=40.0, lon=-74.0)
        assert v.bearing is None
        assert v.next_stop is None
        assert v.status_text is None

    def test_elevator_status_optional_outage(self):
        e = ElevatorStatus(
            station="Penn Station",
            equipment_type="Elevator",
            description="Out of service",
        )
        assert e.outage_since is None
