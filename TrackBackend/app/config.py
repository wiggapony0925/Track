#
# config.py
# TrackBackend
#
# Loads settings.json and exposes typed configuration via Pydantic.
#

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

from pydantic import BaseModel

from app.utils.transit_utils import resolve_subway_feed_key

_SETTINGS_PATH = Path(__file__).resolve().parent.parent / "settings.json"


class AppSettings(BaseModel):
    search_radius_meters: int = 800  # Radius (meters) to search for nearby stops
    refresh_interval_seconds: int = 30  # How often to fetch fresh data from MTA
    nearest_metro_fallback_radius_meters: int = 5000  # Fallback radius if nothing found nearby
    max_nearby_results: int = 20  # Max results to return in /nearby endpoint
    max_arrivals_per_feed: int = 10  # Limit arrivals processed per GTFS feed
    nearby_bus_stops_limit: int = 3  # Limit bus stops in nearby results
    http_timeout_seconds: float = 15.0  # Timeout for MTA HTTP requests
    http_connect_timeout_seconds: float = 10.0  # Connect timeout for MTA HTTP requests
    http_max_retries: int = 2  # Max retries for failed MTA requests
    http_retry_delay_seconds: float = 1.0  # Delay between retries
    show_ghost_trains: bool = False  # If True, show trains with projected positions even if data is missing
    simulation_easing_enabled: bool = True  # If True, clients should use physics-based interpolation
    # Note: Supabase credentials should be set via environment variables:
    # SUPABASE_URL, SUPABASE_SERVICE_KEY


class ApiKeys(BaseModel):
    mta_api_key: str = ""
    mta_bus_key: str = ""


class BusEndpoints(BaseModel):
    vehicle_monitoring: str
    stop_monitoring: str
    routes_for_agency: str
    stops_for_route: str
    stops_near_location: str


class Urls(BaseModel):
    subway_ace: str
    subway_g: str
    subway_nqrw: str
    subway_123456: str
    subway_bdfm: str
    subway_jz: str
    subway_l: str
    subway_si: str
    lirr: str
    metro_north: str
    alerts_json: str
    bus_alerts_json: str = ""
    lirr_alerts_json: str = ""
    mnr_alerts_json: str = ""
    elevators_json: str
    bus_siri_base: str = ""
    bus_oba_base: str = ""
    bus_endpoints: BusEndpoints | None = None


class Settings(BaseModel):
    app_settings: AppSettings
    api_keys: ApiKeys
    urls: Urls


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Read and parse *settings.json* once, then cache the result."""
    raw: dict[str, Any] = json.loads(_SETTINGS_PATH.read_text(encoding="utf-8"))
    return Settings(**raw)


def get_feed_url(line_id: str) -> str | None:
    """Return the MTA feed URL for the given subway line, or *None*."""
    settings = get_settings()
    key = resolve_subway_feed_key(line_id)
    if key is None:
        return None
    urls_dict = settings.urls.model_dump()
    return urls_dict.get(key)
