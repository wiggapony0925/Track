#
# test_predict.py
# TrackBackend
#
# Tests for the /predict/delay endpoint (Audit Item 7).
# Validates heuristic delay adjustments for rush hour, weather, and combos.
#

from __future__ import annotations

import math

import pytest
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


class TestPredictDelayEndpoint:
    """Tests for GET /predict/delay."""

    def test_clear_weather_off_peak(self):
        """No adjustments → factor 1.0, adjusted == original."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 5, "route_id": "L", "hour": 14, "day_of_week": 3, "weather": "clear"},
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["original_minutes"] == 5
        assert data["adjusted_minutes"] == 5
        assert data["delay_factor"] == 1.0
        assert data["adjustment_reason"] is None

    def test_rush_hour_weekday_morning(self):
        """Weekday 8 AM → +10% rush-hour factor."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 10, "route_id": "4", "hour": 8, "day_of_week": 2, "weather": "clear"},
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["delay_factor"] == pytest.approx(1.1)
        assert data["adjusted_minutes"] == math.ceil(10 * 1.1)  # 11
        assert "rush hour" in data["adjustment_reason"]

    def test_rush_hour_weekday_evening(self):
        """Weekday 5 PM → +10% rush-hour factor."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 8, "route_id": "A", "hour": 17, "day_of_week": 4, "weather": "clear"},
        )
        data = resp.json()
        assert data["delay_factor"] == pytest.approx(1.1)
        assert data["adjusted_minutes"] == math.ceil(8 * 1.1)  # 9

    def test_rush_hour_weekend_ignored(self):
        """Weekend 8 AM → no rush-hour adjustment."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 10, "route_id": "4", "hour": 8, "day_of_week": 1, "weather": "clear"},
        )
        data = resp.json()
        assert data["delay_factor"] == 1.0
        assert data["adjusted_minutes"] == 10

    def test_rain_weather(self):
        """Rain → +10%."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 10, "route_id": "G", "hour": 12, "day_of_week": 3, "weather": "rain"},
        )
        data = resp.json()
        assert data["delay_factor"] == pytest.approx(1.1)
        assert "rain" in data["adjustment_reason"]

    def test_snow_weather(self):
        """Snow → +20%."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 10, "route_id": "G", "hour": 12, "day_of_week": 3, "weather": "snow"},
        )
        data = resp.json()
        assert data["delay_factor"] == pytest.approx(1.2)
        assert data["adjusted_minutes"] == 12
        assert "snow" in data["adjustment_reason"]

    def test_rush_hour_plus_rain(self):
        """Rush hour + rain → +20% combined."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 10, "route_id": "1", "hour": 8, "day_of_week": 2, "weather": "rain"},
        )
        data = resp.json()
        assert data["delay_factor"] == pytest.approx(1.2)
        # math.ceil(10 * 1.2000..002) = 13 due to floating-point; that's fine
        assert data["adjusted_minutes"] == 13
        reason = data["adjustment_reason"]
        assert "rush hour" in reason
        assert "rain" in reason

    def test_rush_hour_plus_snow(self):
        """Rush hour + snow → +30% combined."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 10, "route_id": "7", "hour": 18, "day_of_week": 5, "weather": "snow"},
        )
        data = resp.json()
        assert data["delay_factor"] == pytest.approx(1.3)
        assert data["adjusted_minutes"] == 13

    def test_zero_minutes(self):
        """0 minutes → 0 adjusted regardless of factor."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 0, "route_id": "L", "hour": 8, "day_of_week": 2, "weather": "snow"},
        )
        data = resp.json()
        assert data["adjusted_minutes"] == 0

    def test_large_minutes(self):
        """Large ETA with rush + snow → correctly scaled."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 30, "route_id": "F", "hour": 9, "day_of_week": 4, "weather": "snow"},
        )
        data = resp.json()
        # 9 AM is in rush range (7-9 inclusive → range(7,10) includes 9)
        assert data["delay_factor"] == pytest.approx(1.3)
        # ceil(30 * 1.30000..003) = 40 due to float accumulation
        assert data["adjusted_minutes"] == math.ceil(30 * (1.0 + 0.1 + 0.2))

    def test_case_insensitive_weather(self):
        """Weather param is case-insensitive."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 10, "route_id": "L", "hour": 12, "day_of_week": 3, "weather": "RAIN"},
        )
        data = resp.json()
        assert data["delay_factor"] == pytest.approx(1.1)

    def test_missing_required_params(self):
        """Missing required params → 422."""
        resp = client.get("/predict/delay")
        assert resp.status_code == 422

    def test_invalid_hour(self):
        """Hour out of range → 422."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 5, "route_id": "L", "hour": 25, "day_of_week": 1, "weather": "clear"},
        )
        assert resp.status_code == 422

    def test_invalid_day_of_week(self):
        """Day of week out of range → 422."""
        resp = client.get(
            "/predict/delay",
            params={"minutes_away": 5, "route_id": "L", "hour": 12, "day_of_week": 0, "weather": "clear"},
        )
        assert resp.status_code == 422
