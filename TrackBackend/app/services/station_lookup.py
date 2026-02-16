#
# station_lookup.py
# TrackBackend
#
# Loads MTA GTFS stops.txt (Subway, LIRR, Metro-North) and provides a fast 
# lookup from stop_id → (lat, lon, name).
#

from __future__ import annotations

import csv
import math
from functools import lru_cache
from pathlib import Path
from typing import NamedTuple

_DATA_DIR = Path(__file__).resolve().parent.parent / "data"

class StopInfo(NamedTuple):
    stop_id: str
    name: str
    lat: float
    lon: float
    agency: str = "subway"

@lru_cache(maxsize=1)
def _load_stops() -> dict[str, StopInfo]:
    """Parse all available stops.txt into a dict keyed by stop_id."""
    stops: dict[str, StopInfo] = {}
    
    # Files to look for: (Path, Agency Name)
    stop_files = [
        (_DATA_DIR / "stops.txt", "subway"),
        (_DATA_DIR / "lirr/gtfslirr/stops.txt", "lirr"),
        (_DATA_DIR / "metro_north/gtfsmnr/stops.txt", "mnr")
    ]

    for path, agency in stop_files:
        if not path.exists():
            continue

        with open(path, encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                stop_id = row.get("stop_id", "").strip()
                if not stop_id:
                    continue
                
                # Check for location_type to prefer parent stations in Subway
                # but for Rail we often want everything as they are usually flat.
                
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
                    agency=agency
                )

    return stops


def get_stop_info(stop_id: str) -> StopInfo | None:
    """Look up a single stop by its GTFS stop_id (e.g. 'L12N' or '231')."""
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


def get_nearby_stop_ids(lat: float, lon: float, radius_m: float, agency: str | None = None) -> set[str]:
    """Return the set of stop_ids within radius_m meters of (lat, lon)."""
    nearby: set[str] = set()
    for stop_id, info in _load_stops().items():
        if agency and info.agency != agency:
            continue
        if _haversine_m(lat, lon, info.lat, info.lon) <= radius_m:
            nearby.add(stop_id)
    return nearby
