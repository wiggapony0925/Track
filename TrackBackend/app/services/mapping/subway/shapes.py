"""Loads MTA GTFS static data to provide full subway route polylines
and ordered stop lists. Uses pre-computed shape_stops.json (52 KB)
instead of the raw stop_times.txt (35 MB) for fast lookups.

Data files required in app/data/:
- shapes.txt:       Route geometry points (from GTFS static)
- trips.txt:        Maps route_id → shape_id (from GTFS static)
- shape_stops.json: Pre-computed shape_id → [stop_ids] mapping
- stops.txt:        Stop coordinates and names (loaded via station_lookup)."""

from __future__ import annotations

import csv
import json
from collections import defaultdict
from functools import lru_cache
from math import atan2, cos, radians, sin, sqrt
from pathlib import Path
from typing import NamedTuple

from app.services.mapping.shared.coords import (
    ShapePoint,
)
from app.services.mapping.shared.coords import (
    pack_coords as _pack_coords,
)
from app.services.mapping.shared.coords import (
    shape_passes_quality as _shape_passes_quality,
)
from app.services.mapping.shared.coords import (
    unpack_coords as _unpack_coords,
)
from app.services.transit.station_lookup import get_stop_info
from app.utils.logger import TrackLogger

_DATA_DIR = Path(__file__).resolve().parent.parent.parent / "data"
_SHAPES_PATH = _DATA_DIR / "shapes.txt"
_TRIPS_PATH = _DATA_DIR / "trips.txt"
_SHAPE_STOPS_PATH = _DATA_DIR / "shape_stops.json"
_ROUTES_TXT_PATH = _DATA_DIR / "subway" / "regular_GTFS" / "routes.txt"


class RouteStopEntry(NamedTuple):
    stop_id: str
    name: str
    lat: float
    lon: float
    sequence: int


class DirectionData(NamedTuple):
    """Polylines and stops for one GTFS direction of a route."""

    direction_id: int
    headsign: str
    polylines: list[list[tuple[float, float]]]
    stops: list[RouteStopEntry]


# ---------------------------------------------------------------------------
# Compact shape helpers — store sorted lat/lon as packed single-precision
# floats (4 bytes each → 8 bytes/point) instead of NamedTuple objects
# (~148 bytes/point).  For 347K points this saves ~48 MB.
# (imported from app.services.mapping.shared.coords as _pack_coords / _unpack_coords / _unpack_point_set)


# ---------------------------------------------------------------------------
# Shapes: shape_id → list of (lat, lon) in order
# ---------------------------------------------------------------------------


@lru_cache(maxsize=1)
def _load_shapes() -> dict[str, bytes]:
    """Parse shapes.txt into a dict of shape_id → packed bytes (8 bytes/point).

    Points are sorted by sequence and then stored as compact float32 pairs.
    Use ``_unpack_coords(buf)`` to convert back to [(lat, lon), ...].
    """
    raw: dict[str, list[ShapePoint]] = defaultdict(list)
    if not _SHAPES_PATH.exists():
        return {}

    with open(_SHAPES_PATH, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            shape_id = row.get("shape_id", "").strip()
            if not shape_id:
                continue
            try:
                lat = float(row["shape_pt_lat"])
                lon = float(row["shape_pt_lon"])
                seq = int(row["shape_pt_sequence"])
            except (ValueError, KeyError) as exc:
                TrackLogger.debug(
                    f"Skipping malformed shape row {shape_id}: {exc}", tag="DATA"
                )
                continue
            raw[shape_id].append(ShapePoint(lat=lat, lon=lon, sequence=seq))

    # Sort each shape's points by sequence, then pack to compact bytes.
    # Discard any shape that contains a (0, 0) placeholder point or an
    # implausibly large segment — both indicate corrupt MTA GTFS data.
    result: dict[str, bytes] = {}
    for shape_id, pts in raw.items():
        pts.sort(key=lambda p: p.sequence)
        if not _shape_passes_quality(shape_id, pts):
            TrackLogger.warning(
                f"[DATA] Skipping corrupt shape {shape_id}", tag="DATA"
            )
            continue
        result[shape_id] = _pack_coords(pts)

    return result


# ---------------------------------------------------------------------------
# Trips: route_id → {direction_id: shape_id}  +  direction headsigns
# Parsed in a SINGLE pass to avoid reading trips.txt twice (~20K rows).
# ---------------------------------------------------------------------------


@lru_cache(maxsize=1)
def _parse_trips() -> tuple[
    dict[str, dict[int, set[str]]],  # route_shapes_raw
    dict[str, dict[int, str]],  # headsigns
]:
    """Single-pass parse of trips.txt returning both route-shape mapping and headsigns."""
    from collections import Counter

    route_shapes_raw: dict[str, dict[int, set[str]]] = defaultdict(
        lambda: defaultdict(set)
    )
    headsign_counts: dict[str, dict[int, Counter]] = defaultdict(
        lambda: defaultdict(Counter)
    )

    if not _TRIPS_PATH.exists():
        return {}, {}

    with open(_TRIPS_PATH, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            route_id = row.get("route_id", "").strip()
            shape_id = row.get("shape_id", "").strip()
            headsign = row.get("trip_headsign", "").strip()
            try:
                direction = int(row.get("direction_id", "0"))
            except ValueError as exc:
                TrackLogger.debug(
                    f"Bad direction_id for route {route_id}, defaulting to 0: {exc}",
                    tag="DATA",
                )
                direction = 0

            if route_id and shape_id:
                route_shapes_raw[route_id][direction].add(shape_id)
            if route_id and headsign:
                headsign_counts[route_id][direction][headsign] += 1

    # Resolve headsigns to most-common per direction
    headsigns: dict[str, dict[int, str]] = {}
    for route_id, dir_map in headsign_counts.items():
        headsigns[route_id] = {
            d: counter.most_common(1)[0][0] for d, counter in dir_map.items()
        }

    return dict(route_shapes_raw), headsigns


@lru_cache(maxsize=1)
def _load_route_shapes() -> dict[str, dict[int, list[str]]]:
    """Map route_id → {direction_id: [shape_ids]} with branch deduplication."""
    all_shapes, _ = _parse_trips()
    if not all_shapes:
        return {}

    shape_stops_map = _load_shape_stops()
    result: dict[str, dict[int, list[str]]] = {}

    for route_id, dir_map in all_shapes.items():
        result[route_id] = {}
        for direction, shape_ids in dir_map.items():
            # Sort by stop count descending so the longest variant wins
            sorted_sids = sorted(
                shape_ids,
                key=lambda sid: len(shape_stops_map.get(sid, [])),
                reverse=True,
            )

            final_sids: list[str] = []
            covered_stops: set[str] = set()

            for sid in sorted_sids:
                stops = set(shape_stops_map.get(sid, []))
                if not stops:
                    continue

                unique_stops = stops - covered_stops

                if not final_sids:
                    # Always keep the longest shape as the baseline
                    final_sids.append(sid)
                    covered_stops.update(stops)
                elif unique_stops:
                    # This shape serves at least one stop not yet covered
                    # → it's a real branch (e.g. Lefferts Blvd, Rockaway Park)
                    final_sids.append(sid)
                    covered_stops.update(stops)
                # else: pure subset of already-kept shapes → skip

            result[route_id][direction] = final_sids

    return result


# ---------------------------------------------------------------------------
# Shape stops: shape_id → [stop_ids] (pre-computed, 52 KB)
# ---------------------------------------------------------------------------


@lru_cache(maxsize=1)
def _load_shape_stops() -> dict[str, list[str]]:
    """Load the pre-computed shape_id → [stop_ids] mapping."""
    if not _SHAPE_STOPS_PATH.exists():
        return {}
    with open(_SHAPE_STOPS_PATH, encoding="utf-8") as f:
        return json.load(f)


@lru_cache(maxsize=1)
def _load_direction_headsigns() -> dict[str, dict[int, str]]:
    """Return the most common headsign per route/direction (from shared trips parse)."""
    _, headsigns = _parse_trips()
    return headsigns


@lru_cache(maxsize=512)
def _get_stops_for_shape(shape_id: str) -> tuple[RouteStopEntry, ...]:
    """Return the ordered stop list for a shape_id, with resolved names/coords."""
    shape_stops = _load_shape_stops()
    stop_ids = shape_stops.get(shape_id, [])
    if not stop_ids:
        return ()

    entries: list[RouteStopEntry] = []
    seen_names: set[str] = set()

    for seq, stop_id in enumerate(stop_ids):
        info = get_stop_info(stop_id)
        if info is None:
            continue
        # Deduplicate by station name (N/S versions of same station share a name)
        if info.name in seen_names:
            continue
        seen_names.add(info.name)
        entries.append(
            RouteStopEntry(
                stop_id=stop_id,
                name=info.name,
                lat=info.lat,
                lon=info.lon,
                sequence=seq,
            )
        )

    return tuple(entries)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def get_subway_route_shape(
    route_id: str,
) -> (
    tuple[list[list[tuple[float, float]]], list[RouteStopEntry], list[DirectionData]]
    | None
):
    """Return the full route geometry and ordered stops for a subway line.

    Returns:
        (all_polylines, all_stops, direction_data_list)
        - all_polylines / all_stops: merged across both directions (backwards compat)
        - direction_data_list: per-direction split with polylines, stops, headsign
    """
    route_shapes = _load_route_shapes()
    direction_shapes = route_shapes.get(route_id)
    if not direction_shapes:
        return None

    shapes_data = _load_shapes()
    headsigns = _load_direction_headsigns().get(route_id, {})

    polylines: list[list[tuple[float, float]]] = []
    all_stops: list[RouteStopEntry] = []
    seen_stop_ids: set[str] = set()
    direction_data: list[DirectionData] = []

    for direction_id, shape_ids in sorted(direction_shapes.items()):
        dir_polylines: list[list[tuple[float, float]]] = []
        dir_stops: list[RouteStopEntry] = []
        dir_seen: set[str] = set()

        for shape_id in shape_ids:
            shape_buf = shapes_data.get(shape_id)
            if shape_buf:
                coords = _unpack_coords(shape_buf)
                polylines.append(coords)
                dir_polylines.append(coords)

            # Collect unique stops from all shapes to ensure branches are covered
            current_shape_stops = _get_stops_for_shape(shape_id)
            for stop in current_shape_stops:
                if stop.stop_id not in seen_stop_ids:
                    all_stops.append(stop)
                    seen_stop_ids.add(stop.stop_id)
                if stop.stop_id not in dir_seen:
                    dir_stops.append(stop)
                    dir_seen.add(stop.stop_id)

        if dir_polylines:
            direction_data.append(
                DirectionData(
                    direction_id=direction_id,
                    headsign=headsigns.get(direction_id, ""),
                    polylines=dir_polylines,
                    stops=dir_stops,
                )
            )

    if not polylines:
        return None

    # Final sort of stops by sequence is not perfectly valid across branches,
    # but the client usually just needs the collection of stops served.
    return polylines, all_stops, direction_data


# ---------------------------------------------------------------------------
# Express / Local service type detection
# ---------------------------------------------------------------------------


@lru_cache(maxsize=1)
def _load_service_types() -> dict[str, str]:
    """Parse routes.txt to classify each route as express, local, mixed, or None.

    Reads the ``route_long_name`` column from the GTFS static routes.txt.
    Examples:
      - "Lexington Avenue Express" → "express"
      - "8 Avenue Local"           → "local"
      - "Queens Blvd Express/6 Av Local" → "mixed"
      - "Brooklyn-Queens Crosstown" → (omitted)
    """
    if not _ROUTES_TXT_PATH.exists():
        return {}

    result: dict[str, str] = {}
    with open(_ROUTES_TXT_PATH, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            route_id = row.get("route_id", "").strip()
            long_name = row.get("route_long_name", "").lower()
            if not route_id:
                continue

            has_express = "express" in long_name
            has_local = "local" in long_name

            if has_express and has_local:
                result[route_id] = "mixed"
            elif has_express:
                result[route_id] = "express"
            elif has_local:
                result[route_id] = "local"
            # else: shuttles, crosstown, SIR — no label

    return result


def get_stops_for_route(route_id: str) -> set[str]:
    """Return all stop_ids served by a subway route (both directions, all branches).

    Uses the pre-computed ``shape_stops.json`` + ``trips.txt`` mapping so it's
    fast (no database queries).  Returns platform-level IDs (e.g. ``"701N"``,
    ``"701S"``) which can be looked up via ``get_stop_info``.
    """
    route_shapes = _load_route_shapes()
    shape_stops = _load_shape_stops()
    all_stops: set[str] = set()
    if route_id not in route_shapes:
        return all_stops
    for _dir_id, shape_ids in route_shapes[route_id].items():
        for sid in shape_ids:
            all_stops.update(shape_stops.get(sid, []))
    return all_stops


def get_subway_service_type(route_id: str) -> str | None:
    """Return 'express', 'local', 'mixed', or None for a subway route_id."""
    return _load_service_types().get(route_id)


_all_stations_cache: list[dict] | None = None


def get_all_subway_stations() -> list[dict]:
    """Return all unique stations with the lines that serve them.

    Groups stops by parent ID (e.g. '120N' and '120S' -> '120') so that
    Transfer/Express stations show up as a single dot with all lines.

    Result is cached in-memory after first computation — station data
    only changes when GTFS is refreshed (every 24h).
    """
    global _all_stations_cache
    if _all_stations_cache is not None:
        return _all_stations_cache

    route_shapes = _load_route_shapes()

    # Map parent_id -> {name, lat, lon, routes: set}
    stations: dict[str, dict] = {}

    for route_id, directions in route_shapes.items():
        # Only process unique shapes per route to avoid double counting,
        # BUT some stops might only be on one side. Better to process all.
        visited_shapes = set()
        for shape_ids in directions.values():
            for shape_id in shape_ids:
                if shape_id in visited_shapes:
                    continue
                visited_shapes.add(shape_id)

                stops = _get_stops_for_shape(shape_id)
                for stop in stops:
                    # Convert child ID (L06N) to parent ID (L06)
                    # Standard MTA IDs are 3 chars + N/S. Some are different.
                    # If it ends in N or S and len > 1, strip it.
                    parent_id = stop.stop_id
                    if len(parent_id) > 1 and parent_id[-1] in "NS":
                        parent_id = parent_id[:-1]

                    if parent_id not in stations:
                        stations[parent_id] = {
                            "id": parent_id,
                            # Use the stop name (e.g. "8 Av")
                            "name": stop.name,
                            "lat": stop.lat,
                            "lon": stop.lon,
                            "routes": set(),
                        }

                    stations[parent_id]["routes"].add(route_id)

    # Convert to list
    results = []
    for s in stations.values():
        # Sort routes: 1,2,3,A,C,E...
        s["routes"] = sorted(s["routes"])
        results.append(s)

    _all_stations_cache = results
    return results


# ── Transfer enrichment ─────────────────────────────────────────────
# Populates route_ids on shape stops so the iOS client can display
# accurate transfer badges without relying on client-side heuristics.

_station_name_index: dict[str, list[dict]] | None = None


def _haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Return distance in metres between two WGS-84 points."""
    R = 6_371_000
    dlat = radians(lat2 - lat1)
    dlon = radians(lon2 - lon1)
    a = (
        sin(dlat / 2) ** 2
        + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ** 2
    )
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))


def _get_station_name_index() -> tuple[dict[str, list[dict]], list[dict]]:
    """Build (name_lookup, all_stations) from the subway station cache."""
    global _station_name_index
    all_stations = get_all_subway_stations()
    if _station_name_index is None:
        idx: dict[str, list[dict]] = {}
        for s in all_stations:
            key = s["name"].lower().strip()
            idx.setdefault(key, []).append(s)
        _station_name_index = idx
    return _station_name_index, all_stations


def enrich_stops_with_transfers(
    stops: list,
    current_route: str,
    proximity_m: float = 200.0,
    name_match_m: float = 500.0,
) -> list:
    """Populate ``route_ids`` on each BusStop with transfer routes.

    Two match strategies:

    1. **Name match** — stations sharing the *exact same* display name
       within *name_match_m* metres (default 500 m).  The generous
       radius handles sprawling complexes like Grand Central where
       platforms of different services sit 200-300 m apart.  Numbered
       streets that repeat across boroughs (e.g. ``111 St``) are always
       10+ km apart so 500 m is perfectly safe.

    2. **Proximity match** — any station within *proximity_m* metres
       regardless of name (default 200 m).  Catches transfer complexes
       with different names (74 St-Broadway ↔ Jackson Hts-Roosevelt Av).

    Operates in-place and returns the same list for convenience.
    """
    name_lookup, all_stations = _get_station_name_index()
    _EXPRESS = {"6": "6X", "7": "7X", "F": "FX"}
    _BASE = {v: k for k, v in _EXPRESS.items()}

    for stop in stops:
        transfer_routes: set[str] = set()
        stop_key = stop.name.lower().strip()
        matched_ids: set[str] = set()

        # 1. Name match — same name within 500 m (large station complexes)
        for s in name_lookup.get(stop_key, []):
            if _haversine(stop.lat, stop.lon, s["lat"], s["lon"]) <= name_match_m:
                matched_ids.add(s["id"])
                transfer_routes.update(s["routes"])

        # 2. Proximity match — different-name transfers within 200 m
        for s in all_stations:
            if s["id"] in matched_ids:
                continue
            if _haversine(stop.lat, stop.lon, s["lat"], s["lon"]) <= proximity_m:
                transfer_routes.update(s["routes"])

        # Remove current route and its express/local twin
        transfer_routes.discard(current_route)
        if current_route in _EXPRESS:
            transfer_routes.discard(_EXPRESS[current_route])
        if current_route in _BASE:
            transfer_routes.discard(_BASE[current_route])

        if transfer_routes:
            stop.route_ids = sorted(transfer_routes)

    return stops
