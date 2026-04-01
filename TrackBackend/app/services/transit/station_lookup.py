"""Loads MTA GTFS stops.txt (Subway, LIRR, Metro-North) and provides fast
lookups from stop_id → (lat, lon, name) and spatial proximity queries.

Performance: get_nearby_stop_ids() uses a bounding-box pre-filter O(1)
before haversine O(k) where k << n total stops."""

from __future__ import annotations

import csv
from functools import lru_cache
from pathlib import Path
from typing import NamedTuple

from app.utils.geo_utils import bounding_box_degrees, haversine_m
from app.utils.logger import TrackLogger

_DATA_DIR = Path(__file__).resolve().parent.parent.parent / "data"


class StopInfo(NamedTuple):
    stop_id: str
    name: str
    lat: float
    lon: float
    agency: str = "subway"


@lru_cache(maxsize=1)
def _load_stops() -> dict[str, StopInfo]:
    """Parse all available stops.txt into a dict keyed by stop_id.

    LIRR and MNR share numeric stop_ids (e.g. both have stop_id "1"),
    so we store them under both the namespaced key ("lirr:1", "mnr:1")
    AND the raw key.  Lookups for rail agencies use ``get_stop_info``
    with the optional *agency* hint to resolve collisions.  For subway
    the raw stop_id is unique and never collides.
    """
    stops: dict[str, StopInfo] = {}

    # Files to load: (Path, Agency Name)
    stop_files = [
        (_DATA_DIR / "stops.txt", "subway"),
        (_DATA_DIR / "lirr/gtfslirr/stops.txt", "lirr"),
        (_DATA_DIR / "metro_north/gtfsmnr/stops.txt", "mnr"),
    ]

    for path, agency in stop_files:
        if not path.exists():
            TrackLogger.warning(f"stops.txt not found: {path}", tag="DATA")
            continue

        count_before = len(stops)
        with open(path, encoding="utf-8") as f:
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

                info = StopInfo(
                    stop_id=stop_id,
                    name=row.get("stop_name", "Unknown"),
                    lat=lat,
                    lon=lon,
                    agency=agency,
                )

                # Always store under namespaced key for agency-specific lookups
                if agency in ("lirr", "mnr"):
                    stops[f"{agency}:{stop_id}"] = info

                # Also store under raw key (last writer wins for collisions,
                # but namespaced keys are used for agency-specific lookups)
                stops[stop_id] = info

        TrackLogger.data(
            f"Loaded {len(stops) - count_before} stops from {agency} ({path.name})"
        )

    TrackLogger.data(f"Station lookup ready: {len(stops)} total stop entries")
    return stops


# ------------------------------------------------------------------
# Point lookups — O(1) dict access
# ------------------------------------------------------------------


def get_stop_info(stop_id: str, agency: str | None = None) -> StopInfo | None:
    """Look up a single stop by its GTFS stop_id (e.g. 'L12N' or '231').

    When *agency* is ``"lirr"`` or ``"mnr"``, tries the namespaced key first
    (``"lirr:231"``) so that LIRR and MNR stops with the same numeric ID
    resolve to the correct station.
    """
    stops = _load_stops()
    if agency in ("lirr", "mnr"):
        info = stops.get(f"{agency}:{stop_id}")
        if info is not None:
            return info
    return stops.get(stop_id)


def get_stop_name(stop_id: str, agency: str | None = None) -> str:
    """Return the human-readable station name for a stop_id, or the raw ID if unknown."""
    info = get_stop_info(stop_id, agency=agency)
    return info.name if info else stop_id


# ------------------------------------------------------------------
# Spatial queries — bounding-box pre-filter + haversine refinement
# ------------------------------------------------------------------


def is_stop_nearby(
    stop_id: str,
    lat: float,
    lon: float,
    radius_m: float,
    agency: str | None = None,
) -> bool:
    """Return True if the stop_id is within radius_m meters of (lat, lon)."""
    info = get_stop_info(stop_id, agency=agency)
    if info is None:
        return False
    return haversine_m(lat, lon, info.lat, info.lon) <= radius_m


def get_nearby_stop_ids(
    lat: float,
    lon: float,
    radius_m: float,
    agency: str | None = None,
) -> set[str]:
    """Return the set of stop_ids within radius_m meters of (lat, lon).

    **Algorithm:** O(n) scan with a cheap bounding-box pre-filter that rejects
    ~95% of stops before the expensive haversine call.  The bbox check is a
    simple float comparison — much faster than trig for the majority of stops
    that are far away.

    Returns **raw** stop_ids (not namespaced) so they can be matched
    directly against GTFS-RT feed entities.
    """
    # Pre-compute bounding box in degrees for fast rejection
    lat_delta, lon_delta = bounding_box_degrees(radius_m)
    lat_min, lat_max = lat - lat_delta, lat + lat_delta
    lon_min, lon_max = lon - lon_delta, lon + lon_delta

    nearby: set[str] = set()
    for key, info in _load_stops().items():
        # --- Agency filtering ---
        if agency in ("lirr", "mnr"):
            if not key.startswith(f"{agency}:"):
                continue
        elif agency:
            if ":" in key:
                continue
            if info.agency != agency:
                continue
        else:
            # No filter — skip namespaced keys to avoid double-counting
            if ":" in key:
                continue

        # --- Bounding-box pre-filter (O(1) per stop, rejects ~95%) ---
        if info.lat < lat_min or info.lat > lat_max:
            continue
        if info.lon < lon_min or info.lon > lon_max:
            continue

        # --- Precise haversine (only for candidates inside the bbox) ---
        if haversine_m(lat, lon, info.lat, info.lon) <= radius_m:
            nearby.add(info.stop_id)

    return nearby
