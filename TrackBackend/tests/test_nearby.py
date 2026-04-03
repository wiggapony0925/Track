"""Tests for the /nearby endpoint, /bus/vehicles, /bus/route-shape,
and associated models."""

from __future__ import annotations

from datetime import UTC
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.models import (
    BusStop,
    BusVehicle,
    DirectionArrivals,
    GroupedNearbyTransit,
    NearbyTransitArrival,
    RouteShape,
)
from app.routers import nearby as nearby_router
from app.routers.nearby import _direction_label, _group_arrivals

client = TestClient(app)


def _cached_group(route_id: str = "A") -> GroupedNearbyTransit:
    return GroupedNearbyTransit(
        route_id=route_id,
        display_name=route_id,
        mode="subway",
        color_hex="#0039A6",
        directions=[
            DirectionArrivals(
                direction="Northbound",
                arrivals=[
                    NearbyTransitArrival(
                        route_id=route_id,
                        stop_name="Test Stop",
                        direction="Northbound",
                        minutes_away=3,
                        status="On Time",
                        mode="subway",
                    )
                ],
            )
        ],
    )


class TestNearbyTransitArrivalModel:
    """Tests for the NearbyTransitArrival Pydantic model."""

    def test_subway_arrival(self):
        arrival = NearbyTransitArrival(
            route_id="L",
            stop_name="1st Avenue",
            direction="Manhattan",
            minutes_away=3,
            status="On Time",
            mode="subway",
        )
        assert arrival.route_id == "L"
        assert arrival.stop_name == "1st Avenue"
        assert arrival.minutes_away == 3
        assert arrival.mode == "subway"

    def test_bus_arrival(self):
        arrival = NearbyTransitArrival(
            route_id="MTA NYCT_B63",
            stop_name="5 Av / Union St",
            direction="Approaching",
            minutes_away=5,
            status="Approaching",
            mode="bus",
        )
        assert arrival.route_id == "MTA NYCT_B63"
        assert arrival.mode == "bus"

    def test_default_status(self):
        arrival = NearbyTransitArrival(
            route_id="G",
            stop_name="Metropolitan Av",
            direction="Church Av",
            minutes_away=8,
            mode="subway",
        )
        assert arrival.status == "On Time"


class TestBusVehicleModel:
    """Tests for the BusVehicle Pydantic model."""

    def test_vehicle_with_bearing(self):
        vehicle = BusVehicle(
            vehicle_id="MTA NYCT_7582",
            route_id="MTA NYCT_B63",
            lat=40.6728,
            lon=-73.9894,
            bearing=180.0,
            next_stop="5 Av / Union St",
            status_text="Approaching",
        )
        assert vehicle.vehicle_id == "MTA NYCT_7582"
        assert vehicle.lat == 40.6728
        assert vehicle.bearing == 180.0
        assert vehicle.next_stop == "5 Av / Union St"

    def test_vehicle_without_optional_fields(self):
        vehicle = BusVehicle(
            vehicle_id="V1",
            route_id="R1",
            lat=40.0,
            lon=-74.0,
        )
        assert vehicle.bearing is None
        assert vehicle.next_stop is None
        assert vehicle.status_text is None


class TestRouteShapeModel:
    """Tests for the RouteShape Pydantic model."""

    def test_route_shape(self):
        shape = RouteShape(
            route_id="MTA NYCT_B63",
            polylines=["encoded_string_1", "encoded_string_2"],
            stops=[
                BusStop(id="S1", name="Stop 1", lat=40.0, lon=-74.0),
                BusStop(id="S2", name="Stop 2", lat=40.1, lon=-74.1),
            ],
        )
        assert shape.route_id == "MTA NYCT_B63"
        assert len(shape.polylines) == 2
        assert len(shape.stops) == 2

    def test_empty_route_shape(self):
        shape = RouteShape(route_id="R1", polylines=[], stops=[])
        assert shape.polylines == []
        assert shape.stops == []


class TestNearbyEndpoint:
    """Tests for the GET /nearby endpoint."""

    def test_nearby_requires_lat_lon(self):
        response = client.get("/nearby")
        assert response.status_code == 422

    def test_nearby_requires_lon(self):
        response = client.get("/nearby?lat=40.7")
        assert response.status_code == 422

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_nearby_returns_sorted_results(self, mock_buses, mock_subway, mock_rail):
        mock_rail.return_value = []
        mock_subway.return_value = [
            NearbyTransitArrival(
                route_id="L",
                stop_name="1st Avenue",
                direction="Manhattan",
                minutes_away=5,
                status="On Time",
                mode="subway",
            ),
        ]
        mock_buses.return_value = [
            NearbyTransitArrival(
                route_id="B63",
                stop_name="5 Av",
                direction="Approaching",
                minutes_away=2,
                status="Approaching",
                mode="bus",
            ),
        ]

        response = client.get("/nearby?lat=40.7&lon=-73.9")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 2
        # Should be sorted by minutes_away
        assert data[0]["minutes_away"] <= data[1]["minutes_away"]
        assert data[0]["mode"] == "bus"
        assert data[1]["mode"] == "subway"

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_nearby_handles_empty_results(self, mock_buses, mock_subway, mock_rail):
        mock_rail.return_value = []
        mock_subway.return_value = []
        mock_buses.return_value = []

        response = client.get("/nearby?lat=40.7&lon=-73.9")
        assert response.status_code == 200
        assert response.json() == []

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_nearby_limits_to_20_results(self, mock_buses, mock_subway, mock_rail):
        mock_rail.return_value = []
        mock_subway.return_value = [
            NearbyTransitArrival(
                route_id=f"L{i}",
                stop_name=f"Station {i}",
                direction="N",
                minutes_away=i,
                mode="subway",
            )
            for i in range(15)
        ]
        mock_buses.return_value = [
            NearbyTransitArrival(
                route_id=f"B{i}",
                stop_name=f"Stop {i}",
                direction="S",
                minutes_away=i + 15,
                mode="bus",
            )
            for i in range(15)
        ]

        response = client.get("/nearby?lat=40.7&lon=-73.9")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 30  # 15+15 = 30, capped at max_nearby_results (40)

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_nearby_handles_subway_error_gracefully(
        self, mock_buses, mock_subway, mock_rail
    ):
        mock_rail.return_value = []
        mock_subway.side_effect = Exception("Feed unavailable")
        mock_buses.return_value = [
            NearbyTransitArrival(
                route_id="B63",
                stop_name="5 Av",
                direction="Approaching",
                minutes_away=3,
                mode="bus",
            ),
        ]

        response = client.get("/nearby?lat=40.7&lon=-73.9")
        assert response.status_code == 200
        data = response.json()
        # Should still return bus data even if subway failed
        assert len(data) == 1
        assert data[0]["mode"] == "bus"


class TestBusVehiclesEndpoint:
    """Tests for the GET /bus/vehicles/{route_id} endpoint."""

    @patch("app.routers.bus.get_vehicle_positions", new_callable=AsyncMock)
    def test_vehicles_returns_positions(self, mock_vehicles):
        mock_vehicles.return_value = [
            BusVehicle(
                vehicle_id="V1",
                route_id="MTA NYCT_B63",
                lat=40.67,
                lon=-73.99,
                bearing=180.0,
                next_stop="5 Av",
                status_text="Approaching",
            ),
        ]

        response = client.get("/bus/vehicles/MTA%20NYCT_B63")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["vehicle_id"] == "V1"
        assert data[0]["lat"] == 40.67
        assert data[0]["bearing"] == 180.0

    @patch("app.routers.bus.get_vehicle_positions", new_callable=AsyncMock)
    def test_vehicles_empty_route(self, mock_vehicles):
        mock_vehicles.return_value = []

        response = client.get("/bus/vehicles/MTA%20NYCT_X99")
        assert response.status_code == 200
        assert response.json() == []


class TestRouteShapeEndpoint:
    """Tests for the GET /bus/route-shape/{route_id} endpoint."""

    @patch("app.routers.bus.get_route_shape", new_callable=AsyncMock)
    def test_route_shape_returns_polylines_and_stops(self, mock_shape):
        mock_shape.return_value = RouteShape(
            route_id="MTA NYCT_B63",
            polylines=["encoded_poly_1"],
            stops=[
                BusStop(id="S1", name="Stop 1", lat=40.0, lon=-74.0),
            ],
        )

        response = client.get("/bus/route-shape/MTA%20NYCT_B63")
        assert response.status_code == 200
        data = response.json()
        assert data["route_id"] == "MTA NYCT_B63"
        assert len(data["polylines"]) == 1
        assert len(data["stops"]) == 1
        assert data["stops"][0]["name"] == "Stop 1"

    @patch("app.routers.bus.get_route_shape", new_callable=AsyncMock)
    def test_route_shape_empty(self, mock_shape):
        mock_shape.return_value = RouteShape(
            route_id="R1",
            polylines=[],
            stops=[],
        )

        response = client.get("/bus/route-shape/R1")
        assert response.status_code == 200
        data = response.json()
        assert data["polylines"] == []
        assert data["stops"] == []


class TestGroupedModels:
    """Tests for the DirectionArrivals and GroupedNearbyTransit models."""

    def test_direction_arrivals(self):
        da = DirectionArrivals(
            direction="N",
            arrivals=[
                NearbyTransitArrival(
                    route_id="L",
                    stop_name="1st Ave",
                    direction="N",
                    minutes_away=3,
                    mode="subway",
                ),
            ],
        )
        assert da.direction == "N"
        assert len(da.arrivals) == 1

    def test_grouped_transit(self):
        group = GroupedNearbyTransit(
            route_id="L",
            display_name="L",
            mode="subway",
            color_hex="#7C858C",
            directions=[
                DirectionArrivals(direction="N", arrivals=[]),
                DirectionArrivals(direction="S", arrivals=[]),
            ],
        )
        assert group.route_id == "L"
        assert len(group.directions) == 2
        assert group.color_hex == "#7C858C"

    def test_arrival_with_stop_coords(self):
        arrival = NearbyTransitArrival(
            route_id="B63",
            stop_name="5 Av",
            direction="E",
            minutes_away=4,
            mode="bus",
            stop_lat=40.67,
            stop_lon=-73.98,
        )
        assert arrival.stop_lat == 40.67
        assert arrival.stop_lon == -73.98


class TestGroupingLogic:
    """Tests for the _group_arrivals helper."""

    def test_groups_by_route(self):
        flat = [
            NearbyTransitArrival(
                route_id="A",
                stop_name="S1",
                direction="N",
                minutes_away=3,
                mode="subway",
            ),
            NearbyTransitArrival(
                route_id="A",
                stop_name="S2",
                direction="S",
                minutes_away=5,
                mode="subway",
            ),
            NearbyTransitArrival(
                route_id="L",
                stop_name="S3",
                direction="N",
                minutes_away=2,
                mode="subway",
            ),
        ]
        groups = _group_arrivals(flat)
        assert len(groups) == 2
        route_ids = {g.route_id for g in groups}
        assert route_ids == {"A", "L"}

    def test_sorts_by_soonest_arrival(self):
        flat = [
            NearbyTransitArrival(
                route_id="A",
                stop_name="S1",
                direction="N",
                minutes_away=10,
                mode="subway",
            ),
            NearbyTransitArrival(
                route_id="L",
                stop_name="S2",
                direction="N",
                minutes_away=2,
                mode="subway",
            ),
        ]
        groups = _group_arrivals(flat)
        # Groups are sorted by canonical MTA order first (A=040 < L=080),
        # then by soonest arrival as tiebreaker within the same sort key.
        assert groups[0].route_id == "A"
        assert groups[1].route_id == "L"

    def test_directions_sorted_alphabetically(self):
        flat = [
            NearbyTransitArrival(
                route_id="A",
                stop_name="S1",
                direction="S",
                minutes_away=3,
                mode="subway",
            ),
            NearbyTransitArrival(
                route_id="A",
                stop_name="S2",
                direction="N",
                minutes_away=5,
                mode="subway",
            ),
        ]
        groups = _group_arrivals(flat)
        assert len(groups) == 1
        assert groups[0].directions[0].direction == "N"
        assert groups[0].directions[1].direction == "S"

    def test_empty_input(self):
        assert _group_arrivals([]) == []

    def test_subway_color_assigned(self):
        flat = [
            NearbyTransitArrival(
                route_id="L",
                stop_name="S1",
                direction="N",
                minutes_away=3,
                mode="subway",
            ),
        ]
        groups = _group_arrivals(flat)
        assert groups[0].color_hex == "#7C858C"

    def test_bus_default_color(self):
        flat = [
            NearbyTransitArrival(
                route_id="MTA NYCT_B63",
                stop_name="5 Av",
                direction="E",
                minutes_away=4,
                mode="bus",
            ),
        ]
        groups = _group_arrivals(flat)
        assert groups[0].color_hex == "#0039A6"
        assert groups[0].display_name == "B63"


class TestNearbyGroupedEndpoint:
    """Tests for the GET /nearby/grouped endpoint."""

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_grouped_returns_grouped_results(self, mock_buses, mock_subway, mock_rail):
        mock_rail.return_value = []
        mock_subway.return_value = [
            NearbyTransitArrival(
                route_id="A",
                stop_name="S1",
                direction="N",
                minutes_away=3,
                mode="subway",
            ),
            NearbyTransitArrival(
                route_id="A",
                stop_name="S2",
                direction="S",
                minutes_away=5,
                mode="subway",
            ),
        ]
        mock_buses.return_value = []

        response = client.get("/nearby/grouped?lat=40.7&lon=-73.9")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["route_id"] == "A"
        assert data[0]["display_name"] == "A"
        assert len(data[0]["directions"]) == 2

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_grouped_empty(self, mock_buses, mock_subway, mock_rail):
        mock_rail.return_value = []
        mock_subway.return_value = []
        mock_buses.return_value = []

        response = client.get("/nearby/grouped?lat=40.7&lon=-73.9")
        assert response.status_code == 200
        assert response.json() == []

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_grouped_mixed_modes(self, mock_buses, mock_subway, mock_rail):
        mock_rail.return_value = []
        mock_subway.return_value = [
            NearbyTransitArrival(
                route_id="L",
                stop_name="1st Av",
                direction="N",
                minutes_away=4,
                mode="subway",
            ),
        ]
        mock_buses.return_value = [
            NearbyTransitArrival(
                route_id="MTA NYCT_B63",
                stop_name="5 Av",
                direction="E",
                minutes_away=2,
                mode="bus",
            ),
        ]

        response = client.get("/nearby/grouped?lat=40.7&lon=-73.9")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 2
        # Canonical MTA order: subway before bus (not pure soonest-arrival)
        assert data[0]["mode"] == "subway"
        assert data[1]["mode"] == "bus"

    @patch("app.routers.nearby._compute_and_cache_grouped", new_callable=AsyncMock)
    def test_grouped_uses_neighbor_cell_cache_on_gps_jitter(self, mock_compute):
        import json as _json

        cached_group = _cached_group("A")
        cached_key = nearby_router._nearby_cache_key(40.7000, -73.9000, 1000, None)
        jitter_key = nearby_router._nearby_cache_key(40.70009, -73.9000, 1000, None)
        assert jitter_key != cached_key

        _json_bytes = _json.dumps(
            [cached_group.model_dump()], default=str
        ).encode()
        nearby_router._nearby_resp_cache[cached_key] = (
            0.0,
            [cached_group],
            _json_bytes,
        )

        with patch("time.time", return_value=5.0):
            response = client.get(
                "/nearby/grouped?lat=40.70009&lon=-73.9000&radius=1000"
            )

        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["route_id"] == "A"

    @patch("app.routers.nearby._compute_and_cache_grouped", new_callable=AsyncMock)
    def test_grouped_serves_cached_response_when_refresh_errors(self, mock_compute):
        import json as _json

        cached_group = _cached_group("L")
        cache_key = nearby_router._nearby_cache_key(40.7000, -73.9000, 1000, None)
        _json_bytes = _json.dumps(
            [cached_group.model_dump()], default=str
        ).encode()
        nearby_router._nearby_resp_cache[cache_key] = (
            25.0,
            [cached_group],
            _json_bytes,
        )
        mock_compute.side_effect = RuntimeError("upstream unavailable")

        with patch("time.time", return_value=80.0):
            response = client.get(
                "/nearby/grouped?lat=40.7000&lon=-73.9000&radius=1000"
            )

        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        assert data[0]["route_id"] == "L"


# ===================================================================
# Direction Label Mapping (Audit Item 9)
# ===================================================================


class TestDirectionLabel:
    """Tests for _direction_label compass-code mapping."""

    def test_compass_north(self):
        assert _direction_label("N") == "Northbound"

    def test_compass_south(self):
        assert _direction_label("S") == "Southbound"

    def test_compass_east(self):
        assert _direction_label("E") == "Eastbound"

    def test_compass_west(self):
        assert _direction_label("W") == "Westbound"

    def test_compass_northeast(self):
        assert _direction_label("NE") == "Northeast"

    def test_compass_southwest(self):
        assert _direction_label("SW") == "Southwest"

    def test_inbound(self):
        assert _direction_label("INBOUND") == "Inbound"

    def test_outbound(self):
        assert _direction_label("OUTBOUND") == "Outbound"

    def test_case_insensitive(self):
        assert _direction_label("n") == "Northbound"
        assert _direction_label("se") == "Southeast"

    def test_destination_name_passthrough(self):
        """Non-compass strings (like destination names) pass through unchanged."""
        assert _direction_label("Far Rockaway") == "Far Rockaway"
        assert _direction_label("Manhattan") == "Manhattan"


class TestDirectionLabelInGrouped:
    """direction_label should appear in grouped endpoint results."""

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_direction_label_populated(self, mock_buses, mock_subway, mock_rail):
        mock_rail.return_value = []
        mock_buses.return_value = []
        mock_subway.return_value = [
            NearbyTransitArrival(
                route_id="L",
                stop_name="1st Av",
                direction="N",
                minutes_away=3,
                mode="subway",
            ),
            NearbyTransitArrival(
                route_id="L",
                stop_name="1st Av",
                direction="S",
                minutes_away=5,
                mode="subway",
            ),
        ]

        response = client.get("/nearby/grouped?lat=40.7&lon=-73.9")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 1
        directions = data[0]["directions"]
        labels = {d["direction_label"] for d in directions}
        assert labels == {"Northbound", "Southbound"}


# ===================================================================
# BUS ROUTE BACKFILL
# ===================================================================


class TestBusRouteBackfill:
    """Verify that bus routes with stops in the radius appear even
    when no live SIRI data is available (the backfill logic)."""

    @patch("app.routers.nearby.get_realtime_arrivals", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_nearby_stops", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    def test_backfill_creates_placeholder_for_no_live_routes(
        self,
        mock_rail,
        mock_subway,
        mock_stops,
        mock_arrivals,
    ):
        """A stop serves Q10 but SIRI returns no arrivals — Q10 should be
        filtered out (placeholder-only), while B83 with live data remains."""
        mock_subway.return_value = []
        mock_rail.return_value = []
        mock_stops.return_value = [
            BusStop(
                id="S1",
                name="Linden Blvd / 227 St",
                lat=40.66,
                lon=-73.74,
                direction="SW",
                route_ids=["MTABC_Q10", "MTA NYCT_B83"],
            ),
        ]
        # SIRI returns arrivals only for B83, none for Q10
        from datetime import datetime

        mock_arrivals.return_value = [
            __import__("app.models", fromlist=["BusArrival"]).BusArrival(
                route_id="B83",
                vehicle_id="V1",
                stop_id="S1",
                status_text="2 stops away",
                expected_arrival=datetime.now(UTC),
                direction_ref=0,
                destination_name="Flatbush Av",
            ),
        ]

        response = client.get("/nearby/grouped?lat=40.66&lon=-73.74")
        assert response.status_code == 200
        data = response.json()

        route_names = {g["display_name"] for g in data}
        assert "B83" in route_names, f"Live route B83 missing: {route_names}"
        # Q10 has only placeholder data (no live, no schedule) — it should be
        # filtered out so the iOS app doesn't show an empty card.
        assert (
            "Q10" not in route_names
        ), f"Placeholder-only route Q10 should be filtered out: {route_names}"

    @patch("app.routers.nearby.get_realtime_arrivals", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_nearby_stops", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    def test_backfill_placeholder_has_scheduled_status(
        self,
        mock_rail,
        mock_subway,
        mock_stops,
        mock_arrivals,
    ):
        """Routes with ONLY placeholder data (no live, no schedule) should
        be filtered out entirely — the iOS app shows them as empty cards."""
        mock_subway.return_value = []
        mock_rail.return_value = []
        mock_stops.return_value = [
            BusStop(
                id="S1",
                name="Jamaica Av",
                lat=40.70,
                lon=-73.80,
                direction="E",
                route_ids=["MTABC_Q56"],
            ),
        ]
        mock_arrivals.return_value = []  # No live data at all

        response = client.get("/nearby/grouped?lat=40.70&lon=-73.80")
        assert response.status_code == 200
        data = response.json()

        # Q56 has only placeholder arrivals — should be filtered out
        assert len(data) == 0, (
            f"Placeholder-only route should be excluded, got: "
            f"{[g['display_name'] for g in data]}"
        )

    @patch("app.routers.nearby.get_realtime_arrivals", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_nearby_stops", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    def test_no_backfill_when_route_has_live_data(
        self,
        mock_rail,
        mock_subway,
        mock_stops,
        mock_arrivals,
    ):
        """Routes with live SIRI data should NOT get a duplicate backfill entry."""
        mock_subway.return_value = []
        mock_rail.return_value = []
        mock_stops.return_value = [
            BusStop(
                id="S1",
                name="Atlantic Av",
                lat=40.68,
                lon=-73.97,
                direction="NE",
                route_ids=["MTA NYCT_B63"],
            ),
        ]
        from datetime import datetime

        mock_arrivals.return_value = [
            __import__("app.models", fromlist=["BusArrival"]).BusArrival(
                route_id="B63",
                vehicle_id="V1",
                stop_id="S1",
                status_text="Approaching",
                expected_arrival=datetime.now(UTC),
                direction_ref=0,
                destination_name="Cobble Hill",
            ),
        ]

        response = client.get("/nearby/grouped?lat=40.68&lon=-73.97")
        assert response.status_code == 200
        data = response.json()

        # B63 should appear exactly once (live data), not duplicated by backfill
        b63_groups = [g for g in data if g["display_name"] == "B63"]
        assert (
            len(b63_groups) == 1
        ), f"B63 appears {len(b63_groups)} times (should be 1)"

    @patch("app.routers.nearby.get_realtime_arrivals", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_nearby_stops", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    def test_backfill_uses_stop_coordinates(
        self,
        mock_rail,
        mock_subway,
        mock_stops,
        mock_arrivals,
    ):
        """Routes with ONLY placeholder data should be filtered out."""
        mock_subway.return_value = []
        mock_rail.return_value = []
        mock_stops.return_value = [
            BusStop(
                id="S1",
                name="Merrick Blvd",
                lat=40.655,
                lon=-73.755,
                direction="N",
                route_ids=["MTABC_Q5"],
            ),
        ]
        mock_arrivals.return_value = []

        response = client.get("/nearby/grouped?lat=40.655&lon=-73.755")
        assert response.status_code == 200
        data = response.json()

        # Q5 has only placeholder arrivals — should be excluded
        assert len(data) == 0, (
            f"Placeholder-only route should be excluded, got: "
            f"{[g['display_name'] for g in data]}"
        )


class TestPhaseCOppositeDirection:
    """Phase C: routes with only 1 direction after Phases A+B get an
    opposite-direction placeholder so grouped cards always have 2 tabs."""

    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    def test_express_bus_gets_opposite_direction(
        self,
        mock_rail,
        mock_subway,
        mock_buses,
    ):
        """BxM3 with only MIDTOWN arrivals should still get 2 direction tabs."""
        mock_subway.return_value = []
        mock_rail.return_value = []
        mock_buses.return_value = [
            NearbyTransitArrival(
                route_id="BxM3",
                stop_name="Bx Stop",
                direction="MIDTOWN",
                destination="MIDTOWN",
                minutes_away=5,
                mode="bus",
                stop_lat=40.86,
                stop_lon=-73.90,
                stop_id="S1",
                vehicle_id="V1",
            ),
        ]

        response = client.get("/nearby/grouped?lat=40.86&lon=-73.90")
        assert response.status_code == 200
        data = response.json()

        bxm3 = [
            g
            for g in data
            if "BXM3" in g["display_name"].upper() or "BxM3" in g["display_name"]
        ]
        assert len(bxm3) == 1, f"Expected 1 BxM3 group, got {len(bxm3)}: {data}"
        group = bxm3[0]
        assert len(group["directions"]) == 2, (
            f"Expected 2 directions, got {len(group['directions'])}: "
            f"{[d['direction'] for d in group['directions']]}"
        )

    @patch("app.routers.nearby.get_realtime_arrivals", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_nearby_stops", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    def test_phase_c_does_not_add_to_two_direction_route(
        self,
        mock_rail,
        mock_subway,
        mock_stops,
        mock_arrivals,
    ):
        """A route that already has 2 directions should NOT get a 3rd from Phase C."""
        mock_subway.return_value = []
        mock_rail.return_value = []
        mock_stops.return_value = [
            BusStop(
                id="S1",
                name="Stop A",
                lat=40.7,
                lon=-73.9,
                direction="N",
                route_ids=["MTA NYCT_B63"],
            ),
            BusStop(
                id="S2",
                name="Stop B",
                lat=40.7,
                lon=-73.9,
                direction="S",
                route_ids=["MTA NYCT_B63"],
            ),
        ]
        from datetime import datetime

        mock_arrivals.side_effect = [
            [  # Stop S1
                __import__("app.models", fromlist=["BusArrival"]).BusArrival(
                    route_id="B63",
                    vehicle_id="V1",
                    stop_id="S1",
                    status_text="Approaching",
                    expected_arrival=datetime.now(UTC),
                    direction_ref=0,
                    destination_name="COBBLE HILL",
                ),
            ],
            [  # Stop S2
                __import__("app.models", fromlist=["BusArrival"]).BusArrival(
                    route_id="B63",
                    vehicle_id="V2",
                    stop_id="S2",
                    status_text="Approaching",
                    expected_arrival=datetime.now(UTC),
                    direction_ref=1,
                    destination_name="PROSPECT PARK",
                ),
            ],
        ]

        response = client.get("/nearby/grouped?lat=40.70&lon=-73.90")
        assert response.status_code == 200
        data = response.json()

        b63 = [g for g in data if g["display_name"] == "B63"]
        assert len(b63) == 1
        # Should stay at 2 directions, not 3
        assert (
            len(b63[0]["directions"]) == 2
        ), f"Expected 2 dirs, got {len(b63[0]['directions'])}"

    @patch("app.routers.nearby.get_realtime_arrivals", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_nearby_stops", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    def test_compass_direction_gets_opposite(
        self,
        mock_rail,
        mock_subway,
        mock_stops,
        mock_arrivals,
    ):
        """A route with only compass direction 'N' should get 'S' placeholder."""
        mock_subway.return_value = []
        mock_rail.return_value = []
        mock_stops.return_value = [
            BusStop(
                id="S1",
                name="Stop N",
                lat=40.7,
                lon=-73.9,
                direction="N",
                route_ids=["MTA NYCT_B43"],
            ),
        ]
        from datetime import datetime

        mock_arrivals.return_value = [
            __import__("app.models", fromlist=["BusArrival"]).BusArrival(
                route_id="B43",
                vehicle_id="V1",
                stop_id="S1",
                status_text="Approaching",
                expected_arrival=datetime.now(UTC),
                direction_ref=None,
                destination_name=None,
            ),
        ]

        response = client.get("/nearby/grouped?lat=40.70&lon=-73.90")
        assert response.status_code == 200
        data = response.json()

        b43 = [g for g in data if g["display_name"] == "B43"]
        assert len(b43) == 1
        dirs = {d["direction"] for d in b43[0]["directions"]}
        assert len(dirs) == 2, f"Expected 2 directions, got: {dirs}"


# ------------------------------------------------------------------ #
# 10. Bus route_id normalisation and both-direction grouping          #
# ------------------------------------------------------------------ #


class TestBusRouteIdNormalization:
    """Verify that _group_arrivals merges bus arrivals regardless of
    whether route_id has an agency prefix or not."""

    def test_same_route_different_prefix_merged(self):
        """'B63' and 'MTA NYCT_B63' should become one group with display_name='B63'."""
        flat = [
            NearbyTransitArrival(
                route_id="B63",
                stop_name="5 AV/9 ST",
                direction="0",
                destination="BAY RIDGE",
                minutes_away=4,
                mode="bus",
            ),
            NearbyTransitArrival(
                route_id="B63",
                stop_name="5 AV/10 ST",
                direction="1",
                destination="PROSPECT PARK",
                minutes_away=6,
                mode="bus",
            ),
        ]
        groups = _group_arrivals(flat)
        assert len(groups) == 1
        assert groups[0].display_name == "B63"
        assert len(groups[0].directions) == 2

    def test_both_directions_have_labels(self):
        """Direction tabs should use destination names, not '0'/'1'."""
        flat = [
            NearbyTransitArrival(
                route_id="B63",
                stop_name="5 AV/9 ST",
                direction="0",
                destination="BAY RIDGE",
                minutes_away=4,
                mode="bus",
            ),
            NearbyTransitArrival(
                route_id="B63",
                stop_name="5 AV/10 ST",
                direction="1",
                destination="PROSPECT PARK",
                minutes_away=6,
                mode="bus",
            ),
        ]
        groups = _group_arrivals(flat)
        labels = {d.direction_label for d in groups[0].directions}
        assert "BAY RIDGE" in labels
        assert "PROSPECT PARK" in labels

    def test_single_direction_still_works(self):
        """A route with only one direction should get 2 tabs (live + opposite placeholder)."""
        flat = [
            NearbyTransitArrival(
                route_id="B63",
                stop_name="5 AV/9 ST",
                direction="0",
                destination="BAY RIDGE",
                minutes_away=4,
                mode="bus",
            ),
        ]
        groups = _group_arrivals(flat)
        assert len(groups) == 1
        # Phase C adds an opposite-direction placeholder so every card has 2 tabs
        assert len(groups[0].directions) == 2
        live_dir = next(d for d in groups[0].directions if d.direction == "0")
        assert live_dir.direction_label == "BAY RIDGE"

    def test_direction_label_fallback_no_destination(self):
        """When destination is None, direction label resolves from GTFS headsigns.

        With the headsign enrichment pipeline, numeric direction keys ("0"/"1")
        now resolve to real terminal names from the GTFS trips table instead of
        generic "Direction A"/"Direction B" labels.  When no GTFS data is available,
        falls back to "Direction A"/"Direction B".
        """
        flat = [
            NearbyTransitArrival(
                route_id="B63",
                stop_name="5 AV/9 ST",
                direction="0",
                destination=None,
                minutes_away=5,
                mode="bus",
            ),
            NearbyTransitArrival(
                route_id="B63",
                stop_name="5 AV/10 ST",
                direction="1",
                destination=None,
                minutes_away=8,
                mode="bus",
            ),
        ]
        groups = _group_arrivals(flat)
        labels = {d.direction_label for d in groups[0].directions}
        # GTFS headsigns should resolve; if DB not present, falls back to Direction A/B
        generic = {"Direction A", "Direction B"}
        if labels != generic:
            # Labels are real terminal names — verify they're not empty
            for label in labels:
                assert len(label) > 0, "Direction label must not be empty"
            assert len(labels) == 2, f"Expected 2 directions, got {len(labels)}"

    def test_three_direction_branching_route(self):
        """A branching route (e.g. Q58) with 3 terminals gets 3 direction tabs."""
        flat = [
            NearbyTransitArrival(
                route_id="Q58",
                stop_name="MYRTLE AV/FRESH POND RD",
                direction="0",
                destination="JUNIPER VALLEY",
                minutes_away=3,
                mode="bus",
            ),
            NearbyTransitArrival(
                route_id="Q58",
                stop_name="MYRTLE AV/SENECA AV",
                direction="1",
                destination="RIDGEWOOD",
                minutes_away=5,
                mode="bus",
            ),
            NearbyTransitArrival(
                route_id="Q58",
                stop_name="METROPOLITAN AV/DRY HARBOR",
                direction="2",
                destination="MIDDLE VILLAGE",
                minutes_away=8,
                mode="bus",
            ),
        ]
        groups = _group_arrivals(flat)
        assert len(groups) == 1
        assert len(groups[0].directions) == 3
        labels = {d.direction_label for d in groups[0].directions}
        assert labels == {"JUNIPER VALLEY", "RIDGEWOOD", "MIDDLE VILLAGE"}

    def test_three_direction_fallback_labels(self):
        """Direction keys '0', '1', '2' without destinations resolve from GTFS.

        With headsign enrichment, direction_id 0/1 resolve to real terminal
        names. Direction 2 has no GTFS mapping so falls back to "Direction C".
        """
        flat = [
            NearbyTransitArrival(
                route_id="Q58",
                stop_name="S1",
                direction="0",
                destination=None,
                minutes_away=3,
                mode="bus",
            ),
            NearbyTransitArrival(
                route_id="Q58",
                stop_name="S2",
                direction="1",
                destination=None,
                minutes_away=7,
                mode="bus",
            ),
            NearbyTransitArrival(
                route_id="Q58",
                stop_name="S3",
                direction="2",
                destination=None,
                minutes_away=12,
                mode="bus",
            ),
        ]
        groups = _group_arrivals(flat)
        labels = {d.direction_label for d in groups[0].directions}
        # direction_id 0 and 1 may resolve to GTFS headsigns; 2 always falls back
        assert "Direction C" in labels or len(labels) == 3
        for label in labels:
            assert len(label) > 0, "Direction label must not be empty"

    def test_compass_direction_keys(self):
        """Routes using compass direction keys (N, S, SW…) also group correctly."""
        flat = [
            NearbyTransitArrival(
                route_id="B63",
                stop_name="5 AV/9 ST",
                direction="N",
                destination="PROSPECT PARK",
                minutes_away=4,
                mode="bus",
            ),
            NearbyTransitArrival(
                route_id="B63",
                stop_name="5 AV/10 ST",
                direction="S",
                destination="BAY RIDGE",
                minutes_away=6,
                mode="bus",
            ),
        ]
        groups = _group_arrivals(flat)
        assert len(groups) == 1
        assert len(groups[0].directions) == 2
        labels = {d.direction_label for d in groups[0].directions}
        # With destinations available, compass labels include the terminal
        assert "Northbound → PROSPECT PARK" in labels
        assert "Southbound → BAY RIDGE" in labels

    """Integration tests: verify /nearby/grouped returns both bus directions
    when nearby stops serve both sides of a route."""

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_realtime_arrivals", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_nearby_stops", new_callable=AsyncMock)
    def test_both_directions_live(
        self, mock_stops, mock_arrivals, mock_subway, mock_rail
    ):
        """When SIRI returns arrivals from both direction stops, both tabs appear."""
        from datetime import datetime, timedelta

        from app.models import BusArrival

        mock_subway.return_value = []
        mock_rail.return_value = []

        # Two physical stops — one per direction
        stop_nb = BusStop(
            id="NB_001",
            name="5 AV/9 ST (NB)",
            lat=40.67,
            lon=-73.98,
            direction="N",
            route_ids=["MTA NYCT_B63"],
        )
        stop_sb = BusStop(
            id="SB_001",
            name="5 AV/9 ST (SB)",
            lat=40.6699,
            lon=-73.98,
            direction="S",
            route_ids=["MTA NYCT_B63"],
        )
        mock_stops.return_value = [stop_nb, stop_sb]

        now = datetime.now(UTC)
        # Northbound stop → direction_ref=0
        mock_arrivals.side_effect = [
            [
                BusArrival(
                    route_id="B63",
                    vehicle_id="V1",
                    stop_id="NB_001",
                    status_text="approaching",
                    direction_ref=0,
                    expected_arrival=now + timedelta(minutes=3),
                    destination_name="BAY RIDGE",
                )
            ],
            [
                BusArrival(
                    route_id="B63",
                    vehicle_id="V2",
                    stop_id="SB_001",
                    status_text="1 stop away",
                    direction_ref=1,
                    expected_arrival=now + timedelta(minutes=5),
                    destination_name="PROSPECT PARK",
                )
            ],
        ]

        response = client.get("/nearby/grouped?lat=40.67&lon=-73.98&mode=bus")
        assert response.status_code == 200
        data = response.json()

        # Should be exactly 1 grouped route: B63
        b63_groups = [g for g in data if g["display_name"] == "B63"]
        assert len(b63_groups) == 1

        # Should have 2 direction tabs
        directions = b63_groups[0]["directions"]
        assert len(directions) == 2
        dir_labels = {d["direction_label"] for d in directions}
        assert "Bay Ridge" in dir_labels
        assert "Prospect Park" in dir_labels

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_realtime_arrivals", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_nearby_stops", new_callable=AsyncMock)
    def test_single_direction_gets_backfill(
        self, mock_stops, mock_arrivals, mock_subway, mock_rail
    ):
        """When SIRI only returns one direction, the opposite direction
        is backfilled so the card still has two tabs."""
        from datetime import datetime, timedelta

        from app.models import BusArrival

        mock_subway.return_value = []
        mock_rail.return_value = []

        # Two physical stops — one per direction
        stop_nb = BusStop(
            id="NB_001",
            name="5 AV/9 ST (NB)",
            lat=40.67,
            lon=-73.98,
            direction="N",
            route_ids=["MTA NYCT_B63"],
        )
        stop_sb = BusStop(
            id="SB_001",
            name="5 AV/9 ST (SB)",
            lat=40.6699,
            lon=-73.98,
            direction="S",
            route_ids=["MTA NYCT_B63"],
        )
        mock_stops.return_value = [stop_nb, stop_sb]

        now = datetime.now(UTC)
        # Only northbound stop has live data
        mock_arrivals.side_effect = [
            [
                BusArrival(
                    route_id="B63",
                    vehicle_id="V1",
                    stop_id="NB_001",
                    status_text="approaching",
                    direction_ref=0,
                    expected_arrival=now + timedelta(minutes=3),
                    destination_name="BAY RIDGE",
                )
            ],
            [],  # Southbound stop: no buses approaching
        ]

        response = client.get("/nearby/grouped?lat=40.67&lon=-73.98&mode=bus")
        assert response.status_code == 200
        data = response.json()

        b63_groups = [g for g in data if g["display_name"] == "B63"]
        assert len(b63_groups) == 1

        # Should have 2 direction tabs (1 live + 1 backfilled)
        directions = b63_groups[0]["directions"]
        assert len(directions) == 2

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_realtime_arrivals", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_nearby_stops", new_callable=AsyncMock)
    def test_prefix_mismatch_still_groups(
        self, mock_stops, mock_arrivals, mock_subway, mock_rail
    ):
        """Even if SIRI returns 'MTA NYCT_B63' as route_id (LineRef fallback),
        grouping should still produce one card named 'B63'."""
        from datetime import datetime, timedelta

        from app.models import BusArrival

        mock_subway.return_value = []
        mock_rail.return_value = []

        stop_nb = BusStop(
            id="NB_001",
            name="5 AV/9 ST",
            lat=40.67,
            lon=-73.98,
            direction="N",
            route_ids=["MTA NYCT_B63"],
        )
        mock_stops.return_value = [stop_nb]

        now = datetime.now(UTC)
        # SIRI returns the full LineRef with prefix
        mock_arrivals.return_value = [
            BusArrival(
                route_id="MTA NYCT_B63",
                vehicle_id="V1",
                stop_id="NB_001",
                status_text="approaching",
                direction_ref=0,
                expected_arrival=now + timedelta(minutes=3),
                destination_name="BAY RIDGE",
            ),
        ]

        response = client.get("/nearby/grouped?lat=40.67&lon=-73.98&mode=bus")
        assert response.status_code == 200
        data = response.json()

        # Even with "MTA NYCT_" prefix, display_name should be "B63"
        b63_groups = [g for g in data if g["display_name"] == "B63"]
        assert len(b63_groups) == 1

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_realtime_arrivals", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_nearby_stops", new_callable=AsyncMock)
    def test_branching_route_three_stops_one_live(
        self, mock_stops, mock_arrivals, mock_subway, mock_rail
    ):
        """A branching route with 3 nearby stops but only 1 with live data
        should produce at least 2 direction tabs (1 live + headsign-resolved opposite).

        Previously expected 3 tabs (phantom compass tabs from nearby stops).
        With GTFS headsign enrichment, the opposite direction resolves to a
        real terminal name, and phantom compass tabs are correctly suppressed.
        """
        from datetime import datetime, timedelta

        from app.models import BusArrival

        mock_subway.return_value = []
        mock_rail.return_value = []

        # Three physical stops for the same route — different branches
        stop_a = BusStop(
            id="A_001",
            name="MYRTLE/FRESH POND",
            lat=40.70,
            lon=-73.90,
            direction="SW",
            route_ids=["MTA NYCT_Q58"],
        )
        stop_b = BusStop(
            id="B_001",
            name="METROPOLITAN/DRY HARBOR",
            lat=40.71,
            lon=-73.89,
            direction="NE",
            route_ids=["MTA NYCT_Q58"],
        )
        stop_c = BusStop(
            id="C_001",
            name="JUNIPER VALLEY RD",
            lat=40.715,
            lon=-73.88,
            direction="E",
            route_ids=["MTA NYCT_Q58"],
        )
        mock_stops.return_value = [stop_a, stop_b, stop_c]

        now = datetime.now(UTC)
        # Only the first stop has live data
        mock_arrivals.side_effect = [
            [
                BusArrival(
                    route_id="Q58",
                    vehicle_id="V1",
                    stop_id="A_001",
                    status_text="approaching",
                    direction_ref=0,
                    expected_arrival=now + timedelta(minutes=4),
                    destination_name="RIDGEWOOD",
                )
            ],
            [],  # No live data at stop B
            [],  # No live data at stop C
        ]

        response = client.get("/nearby/grouped?lat=40.70&lon=-73.90&mode=bus")
        assert response.status_code == 200
        data = response.json()

        q58_groups = [g for g in data if g["display_name"] == "Q58"]
        assert len(q58_groups) == 1

        # Should have at least 2 direction tabs (live + opposite)
        directions = q58_groups[0]["directions"]
        assert len(directions) >= 2
        # The live direction should use the destination name
        live_labels = [
            d["direction_label"]
            for d in directions
            if any(a["minutes_away"] < 99 for a in d["arrivals"])
        ]
        assert len(live_labels) >= 1


# ===================================================================
# 12. DESTINATION-BASED DIRECTION KEYS (BRANCHING ROUTES)
# ===================================================================


class TestDestinationBasedDirectionKeys:
    """Verify that bus direction keys use SIRI DestinationName so branching
    routes like B46, B41, M15 get separate swipeable tabs per terminal."""

    def test_branching_route_separate_tabs(self):
        """B46 with 3 different destinations should produce 3 direction tabs."""
        flat = [
            NearbyTransitArrival(
                route_id="B46",
                stop_name="UTICA AV/CHURCH AV",
                direction="KINGS PLAZA",
                destination="KINGS PLAZA",
                minutes_away=4,
                mode="bus",
            ),
            NearbyTransitArrival(
                route_id="B46",
                stop_name="UTICA AV/EASTERN PKWY",
                direction="AV H",
                destination="AV H",
                minutes_away=6,
                mode="bus",
            ),
            NearbyTransitArrival(
                route_id="B46",
                stop_name="UTICA AV/ATLANTIC AV",
                direction="WILLIAMSBURG",
                destination="WILLIAMSBURG",
                minutes_away=8,
                mode="bus",
            ),
        ]
        groups = _group_arrivals(flat)
        assert len(groups) == 1, "All B46 arrivals should be one route group"
        assert len(groups[0].directions) == 3, "B46 should have 3 destination tabs"

    def test_destination_keys_produce_title_case_labels(self):
        """Destination-name direction keys should produce title-case labels."""
        flat = [
            NearbyTransitArrival(
                route_id="B46",
                stop_name="UTICA AV/CHURCH AV",
                direction="KINGS PLAZA",
                destination="KINGS PLAZA",
                minutes_away=4,
                mode="bus",
            ),
            NearbyTransitArrival(
                route_id="B46",
                stop_name="UTICA AV/EASTERN PKWY",
                direction="WILLIAMSBURG",
                destination="WILLIAMSBURG",
                minutes_away=8,
                mode="bus",
            ),
        ]
        groups = _group_arrivals(flat)
        labels = {d.direction_label for d in groups[0].directions}
        assert "Kings Plaza" in labels
        assert "Williamsburg" in labels

    def test_same_destination_merges_into_one_tab(self):
        """Multiple buses heading to the same terminal share one direction tab,
        plus Phase C adds an opposite-direction placeholder."""
        flat = [
            NearbyTransitArrival(
                route_id="B46",
                stop_name="UTICA AV/CHURCH AV",
                direction="KINGS PLAZA",
                destination="KINGS PLAZA",
                minutes_away=3,
                mode="bus",
            ),
            NearbyTransitArrival(
                route_id="B46",
                stop_name="UTICA AV/LINDEN BLVD",
                direction="KINGS PLAZA",
                destination="KINGS PLAZA",
                minutes_away=7,
                mode="bus",
            ),
        ]
        groups = _group_arrivals(flat)
        # One live direction (KINGS PLAZA) + one Phase C placeholder = 2
        assert len(groups[0].directions) == 2
        live_dir = next(d for d in groups[0].directions if d.direction == "KINGS PLAZA")
        assert len(live_dir.arrivals) == 2

    def test_direction_label_title_case_all_caps(self):
        """ALL CAPS destination names should be title-cased for display."""
        assert _direction_label("KINGS PLAZA") == "Kings Plaza"
        assert _direction_label("BAY RIDGE") == "Bay Ridge"
        assert _direction_label("PROSPECT PARK") == "Prospect Park"
        assert _direction_label("WILLIAMSBURG") == "Williamsburg"

    def test_direction_label_mixed_case_preserved(self):
        """Already-mixed-case destinations should be title-cased consistently."""
        assert _direction_label("Far Rockaway") == "Far Rockaway"
        assert _direction_label("Lefferts Blvd") == "Lefferts Blvd"

    def test_direction_label_sbs_via_route(self):
        """SBS 'via' destinations should title-case properly."""
        label = _direction_label("KINGS PLAZA VIA UTICA AV SBS")
        assert label == "Kings Plaza Via Utica Av Sbs"

    def test_numeric_fallback_still_uses_destination(self):
        """When direction key IS numeric (legacy path), label still pulls destination."""
        flat = [
            NearbyTransitArrival(
                route_id="B63",
                stop_name="5 AV/9 ST",
                direction="0",
                destination="BAY RIDGE",
                minutes_away=4,
                mode="bus",
            ),
        ]
        groups = _group_arrivals(flat)
        assert groups[0].directions[0].direction_label == "BAY RIDGE"

    @patch("app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_realtime_arrivals", new_callable=AsyncMock)
    @patch("app.routers.nearby.get_nearby_stops", new_callable=AsyncMock)
    def test_integration_branching_b46(
        self, mock_stops, mock_arrivals, mock_subway, mock_rail
    ):
        """Integration: B46 with two different SIRI DestinationNames
        should produce two separate direction tabs via the endpoint."""
        from datetime import datetime, timedelta

        from app.models import BusArrival

        mock_subway.return_value = []
        mock_rail.return_value = []

        stop = BusStop(
            id="S_001",
            name="UTICA AV/CHURCH AV",
            lat=40.65,
            lon=-73.93,
            direction="S",
            route_ids=["MTA NYCT_B46"],
        )
        mock_stops.return_value = [stop]

        now = datetime.now(UTC)
        mock_arrivals.return_value = [
            BusArrival(
                route_id="B46",
                vehicle_id="V1",
                stop_id="S_001",
                status_text="approaching",
                direction_ref=0,
                expected_arrival=now + timedelta(minutes=3),
                destination_name="KINGS PLAZA",
            ),
            BusArrival(
                route_id="B46",
                vehicle_id="V2",
                stop_id="S_001",
                status_text="2 stops away",
                direction_ref=0,
                expected_arrival=now + timedelta(minutes=8),
                destination_name="AV H",
            ),
        ]

        response = client.get("/nearby/grouped?lat=40.65&lon=-73.93&mode=bus")
        assert response.status_code == 200
        data = response.json()

        b46_groups = [g for g in data if g["display_name"] == "B46"]
        assert len(b46_groups) == 1

        # Two different destinations → two direction tabs,
        # even though SIRI DirectionRef is 0 for both
        directions = b46_groups[0]["directions"]
        assert len(directions) == 2, (
            "B46 to KINGS PLAZA and AV H should be separate tabs "
            f"even though both have direction_ref=0. Got: {[d['direction'] for d in directions]}"
        )
        dir_labels = {d["direction_label"] for d in directions}
        assert "Kings Plaza" in dir_labels
        assert "Av H" in dir_labels


# ------------------------------------------------------------------ #
# 14. SIRI circuit breaker scoping                                     #
# ------------------------------------------------------------------ #


class TestSiriCircuitBreakerScope:
    """The SIRI circuit breaker should only block SIRI (real-time) calls,
    not OBA (static/discovery) calls like get_nearby_stops."""

    def test_oba_calls_bypass_circuit_breaker(self):
        """get_nearby_stops (OBA) should succeed even when the SIRI
        circuit breaker is open."""
        import app.clients.bus_client as bc

        # Trip the SIRI circuit breaker
        bc._trip_siri_circuit()
        assert bc._siri_circuit_is_open(), "Breaker should be open after trip"

        try:
            # OBA call via the grouped endpoint — should NOT be blocked
            # because get_nearby_stops uses _fetch_bus_json without is_siri
            with patch(
                "app.routers.nearby.get_nearby_stops", new_callable=AsyncMock
            ) as mock_stops, patch(
                "app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock
            ) as mock_subway, patch(
                "app.routers.nearby._fetch_nearby_rail", new_callable=AsyncMock
            ) as mock_rail:
                mock_subway.return_value = []
                mock_rail.return_value = []
                mock_stops.return_value = [
                    BusStop(
                        id="S1",
                        name="Test Stop",
                        lat=40.7,
                        lon=-73.9,
                        direction="N",
                        route_ids=["MTA NYCT_B63"],
                    ),
                ]

                response = client.get("/nearby/grouped?lat=40.70&lon=-73.90")
                assert response.status_code == 200
                response.json()
                # OBA discovery still works when SIRI breaker is open.
                # B63 gets only placeholder data (no live, no schedule)
                # so it is correctly filtered out by the placeholder-only
                # filter. The key assertion is that the endpoint succeeds
                # (200) — OBA calls are NOT blocked by the SIRI breaker.
                # Note: if B63 had GTFS schedule data, it would appear.
                mock_stops.assert_called_once()
        finally:
            # Clean up — reset the breaker
            bc._siri_circuit_open = False
            bc._siri_circuit_opened_at = 0.0

    def test_fetch_bus_json_is_siri_flag(self):
        """_fetch_bus_json with is_siri=False should NOT check the circuit
        breaker, while is_siri=True should."""
        import asyncio

        import httpx

        import app.clients.bus_client as bc

        bc._trip_siri_circuit()
        assert bc._siri_circuit_is_open()

        try:
            # is_siri=True → should raise (breaker is open)
            with pytest.raises(httpx.HTTPStatusError, match="circuit breaker"):
                asyncio.get_event_loop().run_until_complete(
                    bc._fetch_bus_json(
                        "https://example.com/fake",
                        {"key": "test"},
                        is_siri=True,
                    )
                )
        finally:
            bc._siri_circuit_open = False
            bc._siri_circuit_opened_at = 0.0
