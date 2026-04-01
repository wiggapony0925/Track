"""Tests for the /predict/delay endpoint.

These tests validate BEHAVIORAL CONTRACTS, not hard-coded heuristic values:
• Rain/snow → higher factor than clear
• Rush hour → higher factor than off-peak
• Snow → higher factor than rain
• adjusted_minutes >= original_minutes (we never predict faster than MTA)
• New fields (model_source, recency_error_seconds) are present

This approach is correct for an ML endpoint: the exact numbers change as
the model is retrained, but the ordering and constraints must always hold."""

from __future__ import annotations

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def _get(params: dict) -> dict:
    resp = client.get("/predict/delay", params=params)
    assert resp.status_code == 200
    return resp.json()


class TestPredictDelayEndpoint:
    """Tests for GET /predict/delay."""

    def test_response_schema(self):
        """Response contains all required fields with correct types."""
        data = _get(
            {
                "minutes_away": 5,
                "route_id": "L",
                "hour": 14,
                "day_of_week": 3,
                "weather": "clear",
            }
        )
        assert isinstance(data["adjusted_minutes"], int)
        assert isinstance(data["original_minutes"], int)
        assert isinstance(data["delay_factor"], float)
        assert isinstance(data["model_source"], str)
        assert isinstance(data["recency_error_seconds"], float)
        assert data["model_source"] in ("model", "heuristic", "cache")

    def test_clear_weather_off_peak(self):
        """Off-peak clear weather: factor >= 1.0, adjusted >= original."""
        data = _get(
            {
                "minutes_away": 5,
                "route_id": "L",
                "hour": 14,
                "day_of_week": 3,
                "weather": "clear",
            }
        )
        assert data["original_minutes"] == 5
        assert data["adjusted_minutes"] >= data["original_minutes"]
        assert data["delay_factor"] >= 1.0

    def test_rush_hour_increases_factor(self):
        """Weekday rush hour factor > off-peak factor (same route, clear weather)."""
        base = {
            "route_id": "7",
            "weather": "clear",
            "minutes_away": 10,
            "day_of_week": 2,
        }
        off_peak = _get({**base, "hour": 14})["delay_factor"]
        rush = _get({**base, "hour": 8})["delay_factor"]
        assert rush > off_peak, f"Rush ({rush}) should be > off-peak ({off_peak})"

    def test_evening_rush_increases_factor(self):
        """Weekday 5 PM factor > midday 11 AM factor (same route, clear weather)."""
        base = {
            "route_id": "7",
            "weather": "clear",
            "minutes_away": 10,
            "day_of_week": 2,
        }
        midday = _get({**base, "hour": 11})["delay_factor"]
        evening = _get({**base, "hour": 17})["delay_factor"]
        assert (
            evening > midday
        ), f"Evening rush ({evening}) should be > midday ({midday})"

    def test_weekend_rush_lower_than_weekday_rush(self):
        """Weekday 8 AM factor >= weekend 8 AM factor (model learned weekend dip)."""
        base = {"route_id": "4", "weather": "clear", "minutes_away": 10, "hour": 8}
        weekday = _get({**base, "day_of_week": 2})["delay_factor"]
        weekend = _get({**base, "day_of_week": 1})["delay_factor"]
        assert (
            weekday >= weekend
        ), f"Weekday rush ({weekday}) should be >= weekend ({weekend})"

    def test_rain_increases_factor(self):
        """Rain factor > clear factor (same route, off-peak)."""
        base = {"route_id": "G", "hour": 12, "day_of_week": 3, "minutes_away": 10}
        clear = _get({**base, "weather": "clear"})["delay_factor"]
        rain = _get({**base, "weather": "rain"})["delay_factor"]
        assert rain > clear, f"Rain ({rain}) should be > clear ({clear})"

    def test_snow_worse_than_rain(self):
        """Snow factor > rain factor (same route, off-peak)."""
        base = {"route_id": "G", "hour": 12, "day_of_week": 3, "minutes_away": 10}
        rain = _get({**base, "weather": "rain"})["delay_factor"]
        snow = _get({**base, "weather": "snow"})["delay_factor"]
        assert snow > rain, f"Snow ({snow}) should be > rain ({rain})"

    def test_rush_rain_worse_than_rush_clear(self):
        """Rush + rain factor > rush + clear factor."""
        base = {"route_id": "1", "hour": 8, "day_of_week": 2, "minutes_away": 10}
        clear = _get({**base, "weather": "clear"})["delay_factor"]
        rain = _get({**base, "weather": "rain"})["delay_factor"]
        assert rain > clear, f"Rush+rain ({rain}) should be > rush+clear ({clear})"

    def test_rush_snow_worst_combination(self):
        """Rush + snow factor > rush + rain > rush + clear (ordering holds)."""
        base = {"route_id": "7", "hour": 18, "day_of_week": 5, "minutes_away": 10}
        clear = _get({**base, "weather": "clear"})["delay_factor"]
        rain = _get({**base, "weather": "rain"})["delay_factor"]
        snow = _get({**base, "weather": "snow"})["delay_factor"]
        assert (
            snow >= rain >= clear
        ), f"Expected snow({snow}) >= rain({rain}) >= clear({clear})"

    def test_zero_minutes(self):
        """0 minutes → 0 adjusted regardless of factor."""
        data = _get(
            {
                "minutes_away": 0,
                "route_id": "L",
                "hour": 8,
                "day_of_week": 2,
                "weather": "snow",
            }
        )
        assert data["adjusted_minutes"] == 0

    def test_large_minutes_always_scaled_up(self):
        """Large ETA with snow adjustment: adjusted >= original."""
        data = _get(
            {
                "minutes_away": 30,
                "route_id": "F",
                "hour": 9,
                "day_of_week": 4,
                "weather": "snow",
            }
        )
        assert data["adjusted_minutes"] >= data["original_minutes"]
        assert data["delay_factor"] >= 1.0

    def test_case_insensitive_weather(self):
        """RAIN and rain return identical factor."""
        base = {"minutes_away": 10, "route_id": "L", "hour": 12, "day_of_week": 3}
        lower = _get({**base, "weather": "rain"})["delay_factor"]
        upper = _get({**base, "weather": "RAIN"})["delay_factor"]
        assert lower == upper

    def test_stop_id_param_accepted(self):
        """stop_id query param is accepted and doesn't break the response."""
        data = _get(
            {
                "minutes_away": 8,
                "route_id": "7",
                "hour": 8,
                "day_of_week": 2,
                "weather": "rain",
                "stop_id": "702S",
            }
        )
        assert data["adjusted_minutes"] >= data["original_minutes"]

    def test_mode_param_accepted(self):
        """mode=bus is accepted and response is structurally valid."""
        data = _get(
            {
                "minutes_away": 10,
                "route_id": "M15",
                "hour": 8,
                "day_of_week": 2,
                "weather": "clear",
                "mode": "bus",
            }
        )
        assert data["adjusted_minutes"] >= data["original_minutes"]
        assert data["model_source"] in ("model", "heuristic", "cache")

    def test_schedule_deviation_accepted(self):
        """schedule_deviation_s is accepted; late bus (positive deviation) gets model_source ending in _live."""
        data = _get(
            {
                "minutes_away": 8,
                "route_id": "Q10",
                "hour": 8,
                "day_of_week": 2,
                "weather": "clear",
                "mode": "bus",
                "schedule_deviation_s": 180,
            }
        )
        assert data["adjusted_minutes"] >= data["original_minutes"]
        # Live path bypasses cache → source ends with _live
        assert data["model_source"].endswith("_live")

    def test_zero_deviation_uses_cache(self):
        """schedule_deviation_s=0 is treated as absent; cached path is used."""
        data = _get(
            {
                "minutes_away": 5,
                "route_id": "L",
                "hour": 14,
                "day_of_week": 3,
                "weather": "clear",
                "schedule_deviation_s": 0,
            }
        )
        # Zero deviation → contextual cache path, not _live
        assert not data["model_source"].endswith("_live")

    def test_original_minutes_echoed(self):
        """original_minutes always equals the minutes_away input."""
        data = _get(
            {
                "minutes_away": 12,
                "route_id": "A",
                "hour": 10,
                "day_of_week": 3,
                "weather": "clear",
            }
        )
        assert data["original_minutes"] == 12

    # ── Validation (422) tests ─────────────────────────────────────────────

    def test_missing_required_params(self):
        """Missing required params → 422."""
        resp = client.get("/predict/delay")
        assert resp.status_code == 422

    def test_invalid_hour(self):
        """Hour out of range → 422."""
        resp = client.get(
            "/predict/delay",
            params={
                "minutes_away": 5,
                "route_id": "L",
                "hour": 25,
                "day_of_week": 1,
                "weather": "clear",
            },
        )
        assert resp.status_code == 422

    def test_invalid_day_of_week(self):
        """Day of week out of range → 422."""
        resp = client.get(
            "/predict/delay",
            params={
                "minutes_away": 5,
                "route_id": "L",
                "hour": 12,
                "day_of_week": 0,
                "weather": "clear",
            },
        )
        assert resp.status_code == 422
