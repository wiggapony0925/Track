#
# test_nearby.py
# TrackBackend
#
# Tests for the /nearby endpoint and NearbyTransitArrival model.
#

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.models import NearbyTransitArrival, TrackArrival

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
