#
# subway_shapes.py
# TrackBackend
#
# Loads MTA GTFS static data to provide full subway route polylines
# and ordered stop lists. Uses pre-computed shape_stops.json (52 KB)
# instead of the raw stop_times.txt (35 MB) for fast lookups.
#
# Data files required in app/data/:
#   - shapes.txt:       Route geometry points (from GTFS static)
#   - trips.txt:        Maps route_id → shape_id (from GTFS static)
#   - shape_stops.json: Pre-computed shape_id → [stop_ids] mapping
#   - stops.txt:        Stop coordinates and names (loaded via station_lookup)
#

from __future__ import annotations

import csv
import json
from collections import defaultdict
from functools import lru_cache
from pathlib import Path
from typing import NamedTuple

from app.services.station_lookup import get_stop_info

_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_SHAPES_PATH = _DATA_DIR / "shapes.txt"
_TRIPS_PATH = _DATA_DIR / "trips.txt"
_SHAPE_STOPS_PATH = _DATA_DIR / "shape_stops.json"


class ShapePoint(NamedTuple):
    lat: float
    lon: float
    sequence: int


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
# Shapes: shape_id → list of (lat, lon) in order
# ---------------------------------------------------------------------------

@lru_cache(maxsize=1)
def _load_shapes() -> dict[str, list[ShapePoint]]:
    """Parse shapes.txt into a dict of shape_id → sorted list of ShapePoints."""
    shapes: dict[str, list[ShapePoint]] = defaultdict(list)
    if not _SHAPES_PATH.exists():
        return dict(shapes)

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
            except (ValueError, KeyError):
                continue
            shapes[shape_id].append(ShapePoint(lat=lat, lon=lon, sequence=seq))

    # Sort each shape's points by sequence
    for pts in shapes.values():
        pts.sort(key=lambda p: p.sequence)

    return dict(shapes)


# ---------------------------------------------------------------------------
# Trips: route_id → {direction_id: shape_id}
# ---------------------------------------------------------------------------

@lru_cache(maxsize=1)
def _load_route_shapes() -> dict[str, dict[int, list[str]]]:
    """Parse trips.txt to map route_id → {direction_id: [shape_ids]}.

    Collects unique shape_ids per route/direction to support branching lines
    (e.g., the A train's Far Rockaway and Lefferts branches).
    """
    # Collect ALL unique shape_ids per route/direction
    all_shapes: dict[str, dict[int, set[str]]] = defaultdict(lambda: defaultdict(set))
    if not _TRIPS_PATH.exists():
        return {}

    with open(_TRIPS_PATH, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            route_id = row.get("route_id", "").strip()
            shape_id = row.get("shape_id", "").strip()
            if not route_id or not shape_id:
                continue
            try:
                direction = int(row.get("direction_id", "0"))
            except ValueError:
                direction = 0
            all_shapes[route_id][direction].add(shape_id)

    # Two-pass dedup: keep the longest shape for each corridor, then add
    # any shape that contributes at least one unique stop (i.e. a branch).
    # This preserves Lefferts Blvd, Rockaway Park, and similar branches
    # that share a trunk with the main line but diverge at a junction.
    shape_stops_map = _load_shape_stops()
    result: dict[str, dict[int, list[str]]] = {}

    for route_id, dir_map in all_shapes.items():
        result[route_id] = {}
        for direction, shape_ids in dir_map.items():
            # Sort by stop count descending so the longest variant wins
            sorted_sids = sorted(
                list(shape_ids),
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
    """Parse trips.txt to find the most common headsign per route/direction.

    Returns: {route_id: {direction_id: headsign_str}}
    """
    if not _TRIPS_PATH.exists():
        return {}

    from collections import Counter
    counts: dict[str, dict[int, Counter]] = defaultdict(lambda: defaultdict(Counter))

    with open(_TRIPS_PATH, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            route_id = row.get("route_id", "").strip()
            headsign = row.get("trip_headsign", "").strip()
            if not route_id or not headsign:
                continue
            try:
                direction = int(row.get("direction_id", "0"))
            except ValueError:
                direction = 0
            counts[route_id][direction][headsign] += 1

    result: dict[str, dict[int, str]] = {}
    for route_id, dir_map in counts.items():
        result[route_id] = {}
        for direction, counter in dir_map.items():
            result[route_id][direction] = counter.most_common(1)[0][0]
    return result


def _get_stops_for_shape(shape_id: str) -> list[RouteStopEntry]:
    """Return the ordered stop list for a shape_id, with resolved names/coords."""
    shape_stops = _load_shape_stops()
    stop_ids = shape_stops.get(shape_id, [])
    if not stop_ids:
        return []

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
        entries.append(RouteStopEntry(
            stop_id=stop_id,
            name=info.name,
            lat=info.lat,
            lon=info.lon,
            sequence=seq,
        ))

    return entries


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def get_subway_route_shape(
    route_id: str,
) -> tuple[list[list[tuple[float, float]]], list[RouteStopEntry], list[DirectionData]] | None:
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
            shape_points = shapes_data.get(shape_id)
            if shape_points:
                coords = [(p.lat, p.lon) for p in shape_points]
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
            direction_data.append(DirectionData(
                direction_id=direction_id,
                headsign=headsigns.get(direction_id, ""),
                polylines=dir_polylines,
                stops=dir_stops,
            ))

    if not polylines:
        return None

    # Final sort of stops by sequence is not perfectly valid across branches, 
    # but the client usually just needs the collection of stops served.
    return polylines, all_stops, direction_data


def get_all_subway_stations() -> list[dict]:
    """Return all unique stations with the lines that serve them.

    Groups stops by parent ID (e.g. '120N' and '120S' -> '120') so that
    Transfer/Express stations show up as a single dot with all lines.
    """
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
        s["routes"] = sorted(list(s["routes"]))
        results.append(s)

    return results
