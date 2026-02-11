#
# test_nearby.py
# TrackBackend
#
# Tests for the /nearby endpoint, /bus/vehicles, /bus/route-shape,
# and associated models.
#

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.models import BusStop, BusVehicle, NearbyTransitArrival, RouteShape, TrackArrival

client = TestClient(app)


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

    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_nearby_returns_sorted_results(self, mock_buses, mock_subway):
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

    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_nearby_handles_empty_results(self, mock_buses, mock_subway):
        mock_subway.return_value = []
        mock_buses.return_value = []

        response = client.get("/nearby?lat=40.7&lon=-73.9")
        assert response.status_code == 200
        assert response.json() == []

    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_nearby_limits_to_20_results(self, mock_buses, mock_subway):
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
        assert len(data) == 20

    @patch("app.routers.nearby._fetch_nearby_subway", new_callable=AsyncMock)
    @patch("app.routers.nearby._fetch_nearby_buses", new_callable=AsyncMock)
    def test_nearby_handles_subway_error_gracefully(self, mock_buses, mock_subway):
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
