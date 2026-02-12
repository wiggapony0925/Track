#
# test_settings.py
# TrackBackend
#
# Tests that settings.json values are properly wired into the backend
# configuration and that the /config endpoint returns all app_settings.
#

from __future__ import annotations

import json
from pathlib import Path

from fastapi.testclient import TestClient

from app.config import get_settings
from app.main import app

client = TestClient(app)


class TestSettingsLoaded:
    """Tests that settings.json is loaded correctly."""

    def test_search_radius_meters(self):
        settings = get_settings()
        assert settings.app_settings.search_radius_meters == 800

    def test_refresh_interval_seconds(self):
        settings = get_settings()
        assert settings.app_settings.refresh_interval_seconds == 30

    def test_nearest_metro_fallback_radius(self):
        settings = get_settings()
        assert settings.app_settings.nearest_metro_fallback_radius_meters == 5000

    def test_max_nearby_results(self):
        settings = get_settings()
        assert settings.app_settings.max_nearby_results == 20

    def test_max_arrivals_per_feed(self):
        settings = get_settings()
        assert settings.app_settings.max_arrivals_per_feed == 10

    def test_nearby_bus_stops_limit(self):
        settings = get_settings()
        assert settings.app_settings.nearby_bus_stops_limit == 3

    def test_http_timeout_seconds(self):
        settings = get_settings()
        assert settings.app_settings.http_timeout_seconds == 15.0

    def test_http_connect_timeout_seconds(self):
        settings = get_settings()
        assert settings.app_settings.http_connect_timeout_seconds == 10.0

    def test_show_ghost_trains(self):
        settings = get_settings()
        assert settings.app_settings.show_ghost_trains is False

    def test_http_max_retries(self):
        settings = get_settings()
        assert settings.app_settings.http_max_retries == 2

    def test_http_retry_delay_seconds(self):
        settings = get_settings()
        assert settings.app_settings.http_retry_delay_seconds == 1.0


class TestConfigEndpoint:
    """Tests that the /config endpoint exposes all app_settings."""

    def test_config_returns_all_settings(self):
        response = client.get("/config")
        assert response.status_code == 200
        data = response.json()
        assert data["search_radius_meters"] == 800
        assert data["refresh_interval_seconds"] == 30
        assert data["nearest_metro_fallback_radius_meters"] == 5000
        assert data["max_nearby_results"] == 20
        assert data["max_arrivals_per_feed"] == 10
        assert data["nearby_bus_stops_limit"] == 3
        assert data["http_timeout_seconds"] == 15.0
        assert data["http_connect_timeout_seconds"] == 10.0
        assert data["http_max_retries"] == 2
        assert data["http_retry_delay_seconds"] == 1.0
        assert data["show_ghost_trains"] is False

    def test_config_matches_settings_json(self):
        """Verify the /config response matches what's in settings.json."""
        settings_path = Path(__file__).resolve().parent.parent / "settings.json"
        raw = json.loads(settings_path.read_text(encoding="utf-8"))
        expected = raw["app_settings"]

        response = client.get("/config")
        assert response.status_code == 200
        data = response.json()

        for key, value in expected.items():
            assert data[key] == value, f"Mismatch for key {key}: {data.get(key)} != {value}"


class TestSettingsJsonStructure:
    """Tests that settings.json has the expected structure."""

    def test_settings_json_has_all_sections(self):
        settings_path = Path(__file__).resolve().parent.parent / "settings.json"
        raw = json.loads(settings_path.read_text(encoding="utf-8"))
        assert "app_settings" in raw
        assert "api_keys" in raw
        assert "urls" in raw

    def test_urls_has_all_required_feeds(self):
        settings = get_settings()
        assert settings.urls.subway_ace
        assert settings.urls.subway_g
        assert settings.urls.subway_nqrw
        assert settings.urls.subway_123456
        assert settings.urls.subway_bdfm
        assert settings.urls.subway_jz
        assert settings.urls.subway_l
        assert settings.urls.subway_si
        assert settings.urls.lirr
        assert settings.urls.alerts_json
        assert settings.urls.elevators_json

    def test_bus_endpoints_exist(self):
        settings = get_settings()
        eps = settings.urls.bus_endpoints
        assert eps is not None
        assert eps.vehicle_monitoring
        assert eps.stop_monitoring
        assert eps.routes_for_agency
        assert eps.stops_for_route
        assert eps.stops_near_location
