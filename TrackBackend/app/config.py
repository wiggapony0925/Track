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

_SETTINGS_PATH = Path(__file__).resolve().parent.parent / "settings.json"


class AppSettings(BaseModel):
    search_radius_meters: int = 500
    refresh_interval_seconds: int = 30
    show_ghost_trains: bool = False


class ApiKeys(BaseModel):
    mta_api_key: str = "YOUR_KEY_HERE"
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
    alerts_json: str
    elevators_json: str
    bus_siri_base: str = ""
    bus_oba_base: str = ""
    bus_endpoints: BusEndpoints | None = None


class Settings(BaseModel):
    app_settings: AppSettings
    api_keys: ApiKeys
    urls: Urls


# Mapping from a single-letter (or multi-letter) line ID to the settings.json
# URL key so we can look up the correct GTFS-Realtime feed.
LINE_TO_URL_KEY: dict[str, str] = {
    "A": "subway_ace",
    "C": "subway_ace",
    "E": "subway_ace",
    "G": "subway_g",
    "N": "subway_nqrw",
    "Q": "subway_nqrw",
    "R": "subway_nqrw",
    "W": "subway_nqrw",
    "1": "subway_123456",
    "2": "subway_123456",
    "3": "subway_123456",
    "4": "subway_123456",
    "5": "subway_123456",
    "6": "subway_123456",
    "B": "subway_bdfm",
    "D": "subway_bdfm",
    "F": "subway_bdfm",
    "M": "subway_bdfm",
    "J": "subway_jz",
    "Z": "subway_jz",
    "L": "subway_l",
    "SI": "subway_si",
}


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Read and parse *settings.json* once, then cache the result."""
    raw: dict[str, Any] = json.loads(_SETTINGS_PATH.read_text(encoding="utf-8"))
    return Settings(**raw)


def get_feed_url(line_id: str) -> str | None:
    """Return the MTA feed URL for the given subway line, or *None*."""
    settings = get_settings()
    key = LINE_TO_URL_KEY.get(line_id.upper())
    if key is None:
        return None
    urls_dict = settings.urls.model_dump()
    return urls_dict.get(key)
