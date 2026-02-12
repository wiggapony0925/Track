#
# station_lookup.py
# TrackBackend
#
# Loads MTA GTFS stops.txt and provides a fast lookup from stop_id → (lat, lon, name).
# Used to filter subway arrivals by proximity to the user's location.
#

from __future__ import annotations

import csv
import math
from functools import lru_cache
from pathlib import Path
from typing import NamedTuple

_STOPS_PATH = Path(__file__).resolve().parent.parent / "data" / "stops.txt"


class StopInfo(NamedTuple):
    stop_id: str
    name: str
    lat: float
    lon: float


@lru_cache(maxsize=1)
def _load_stops() -> dict[str, StopInfo]:
    """Parse stops.txt into a dict keyed by stop_id."""
    stops: dict[str, StopInfo] = {}
    if not _STOPS_PATH.exists():
        return stops

    with open(_STOPS_PATH, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            stop_id = row.get("stop_id", "").strip()
            if not stop_id:
                continue
            try:
                lat = float(row.get("stop_lat", "0"))
                lon = float(row.get("stop_lon", "0"))
            except ValueError:
                continue
            stops[stop_id] = StopInfo(
                stop_id=stop_id,
                name=row.get("stop_name", "Unknown"),
                lat=lat,
                lon=lon,
            )

    return stops


def get_stop_info(stop_id: str) -> StopInfo | None:
    """Look up a single stop by its GTFS stop_id (e.g. 'L12N')."""
    return _load_stops().get(stop_id)


def get_stop_name(stop_id: str) -> str:
    """Return the human-readable station name for a stop_id, or the raw ID if unknown."""
    info = get_stop_info(stop_id)
    return info.name if info else stop_id


def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Haversine distance between two lat/lon points, in meters."""
    R = 6_371_000  # Earth radius in meters
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def is_stop_nearby(stop_id: str, lat: float, lon: float, radius_m: float) -> bool:
    """Return True if the stop_id is within radius_m meters of (lat, lon)."""
    info = get_stop_info(stop_id)
    if info is None:
        return False
    return _haversine_m(lat, lon, info.lat, info.lon) <= radius_m


def get_nearby_stop_ids(lat: float, lon: float, radius_m: float) -> set[str]:
    """Return the set of stop_ids within radius_m meters of (lat, lon).

    Only returns parent stops and directional stops (N/S suffixed)
    that are within the radius.
    """
    nearby: set[str] = set()
    for stop_id, info in _load_stops().items():
        if _haversine_m(lat, lon, info.lat, info.lon) <= radius_m:
            nearby.add(stop_id)
    return nearby
