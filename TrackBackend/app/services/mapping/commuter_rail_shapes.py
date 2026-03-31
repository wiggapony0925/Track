#
# commuter_rail_shapes.py
# TrackBackend
#
# Loads MTA GTFS static data to provide LIRR and Metro-North route polylines.
# Mirrors subway_shapes.py but for commuter rail feeds.
#
# Data files:
#   - app/data/lirr/gtfslirr/shapes.txt, routes.txt, trips.txt
#   - app/data/metro_north/gtfsmnr/shapes.txt, routes.txt, trips.txt
#

from __future__ import annotations

import csv
from collections import defaultdict
from pathlib import Path
from typing import NamedTuple

from app.utils.logger import TrackLogger
from app.services.mapping.shape_utils import (
    ShapePoint,
    pack_coords as _pack_coords,
    unpack_coords as _unpack_coords,
    unpack_point_set as _unpack_point_set,
)

_DATA_DIR = Path(__file__).resolve().parent.parent.parent / "data"


# ---------------------------------------------------------------------------
# Cache decorator that skips caching empty results.  When GTFS files are
# missing (e.g. Render disk wipe), the underlying parsers return {} or
# ({}, {}, {}).  Standard @lru_cache would permanently cache that empty
# result, making the server blind to data appearing later.  This decorator
# only stores the first *non-empty* result and retries on subsequent calls
# until the data is actually available.
# ---------------------------------------------------------------------------

def _cache_nonempty(fn):
    """Like ``@lru_cache(maxsize=1)`` but only caches non-empty results.

    "Empty" is defined as a falsy value *or* a tuple whose first element is
    falsy (handles the ``_parse_trips_combined`` return of ``({}, {}, {})``,
    which is truthy as a tuple but semantically empty).

    Exposes a ``.cache_clear()`` method for compatibility with
    ``_clear_gtfs_caches()`` in ``gtfs_refresh.py``.
    """
    _sentinel = object()
    _cached = _sentinel

    def wrapper():
        nonlocal _cached
        if _cached is not _sentinel:
            return _cached
        result = fn()
        # Determine if the result is "populated"
        is_populated = bool(result)
        if is_populated and isinstance(result, tuple) and len(result) > 0:
            is_populated = bool(result[0])
        if is_populated:
            _cached = result
        return result

    def cache_clear():
        nonlocal _cached
        _cached = _sentinel

    wrapper.cache_clear = cache_clear
    wrapper.__name__ = fn.__name__
    wrapper.__qualname__ = fn.__qualname__
    return wrapper

_LIRR_DIR = _DATA_DIR / "lirr" / "gtfslirr"
_MNR_DIR = _DATA_DIR / "metro_north" / "gtfsmnr"


class CommuterRoute(NamedTuple):
    route_id: str
    name: str
    color_hex: str


class CommuterStop(NamedTuple):
    """A commuter rail stop with name + coordinates, resolved from stops.txt."""
    stop_id: str
    name: str
    lat: float
    lon: float


# ---------------------------------------------------------------------------
# (imported from app.services.mapping.shape_utils as _pack_coords / _unpack_coords / _unpack_point_set)


# ---------------------------------------------------------------------------
# Generic GTFS parsers
# ---------------------------------------------------------------------------

def _parse_shapes(shapes_path: Path) -> dict[str, bytes]:
    """Parse a GTFS shapes.txt into shape_id → packed bytes (8 bytes/point)."""
    raw: dict[str, list[ShapePoint]] = defaultdict(list)
    if not shapes_path.exists():
        TrackLogger.warning(f"shapes.txt not found: {shapes_path}")
        return {}

    with open(shapes_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            shape_id = row.get("shape_id", "").strip().strip('"')
            if not shape_id:
                continue
            try:
                lat = float(row["shape_pt_lat"].strip('"'))
                lon = float(row["shape_pt_lon"].strip('"'))
                seq = int(row["shape_pt_sequence"].strip('"'))
            except (ValueError, KeyError):
                continue
            raw[shape_id].append(ShapePoint(lat=lat, lon=lon, sequence=seq))

    result: dict[str, bytes] = {}
    for shape_id, pts in raw.items():
        pts.sort(key=lambda p: p.sequence)
        result[shape_id] = _pack_coords(pts)

    return result


def _parse_routes(routes_path: Path) -> dict[str, CommuterRoute]:
    """Parse a GTFS routes.txt into route_id → CommuterRoute."""
    routes: dict[str, CommuterRoute] = {}
    if not routes_path.exists():
        TrackLogger.warning(f"routes.txt not found: {routes_path}")
        return routes

    with open(routes_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            route_id = row.get("route_id", "").strip().strip('"')
            name = row.get("route_long_name", "").strip().strip('"')
            color = row.get("route_color", "4D5357").strip().strip('"')
            if route_id:
                routes[route_id] = CommuterRoute(
                    route_id=route_id,
                    name=name,
                    color_hex=color,
                )

    return routes


def _parse_trips_combined(
    trips_path: Path,
) -> tuple[
    dict[str, set[str]],               # route_shapes: route_id → {shape_ids}
    dict[str, dict[int, set[str]]],    # route_shapes_by_dir: route_id → {dir: {shape_ids}}
    dict[str, dict[int, str]],         # headsigns: route_id → {dir: headsign}
]:
    """Single-pass parse of trips.txt returning all three data structures.

    Replaces _parse_route_shapes, _parse_route_shapes_by_direction, and
    _parse_direction_headsigns to avoid reading the file 3 times.
    """
    from collections import Counter

    route_shapes: dict[str, set[str]] = defaultdict(set)
    by_dir: dict[str, dict[int, set[str]]] = defaultdict(lambda: defaultdict(set))
    headsign_counts: dict[str, dict[int, Counter]] = defaultdict(lambda: defaultdict(Counter))

    if not trips_path.exists():
        TrackLogger.warning(f"trips.txt not found: {trips_path}")
        return {}, {}, {}

    with open(trips_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            route_id = row.get("route_id", "").strip().strip('"')
            shape_id = row.get("shape_id", "").strip().strip('"')
            headsign = row.get("trip_headsign", "").strip().strip('"')
            try:
                direction = int(row.get("direction_id", "0").strip().strip('"'))
            except ValueError:
                direction = 0

            if route_id and shape_id:
                route_shapes[route_id].add(shape_id)
                by_dir[route_id][direction].add(shape_id)
            if route_id and headsign and "(Bus)" not in headsign:
                headsign_counts[route_id][direction][headsign] += 1

    headsigns: dict[str, dict[int, str]] = {}
    for rid, dm in headsign_counts.items():
        headsigns[rid] = {d: c.most_common(1)[0][0] for d, c in dm.items()}

    return dict(route_shapes), dict(by_dir), headsigns


def _deduplicate_shapes(
    shape_ids: set[str],
    shapes_data: dict[str, bytes],
) -> list[str]:
    """Keep only the longest / most unique shape per route to reduce duplication.

    Many trips share the same shape. Among those that differ, we keep only
    shapes that are *not* a geographic subset of a longer one.
    """
    # Sort by number of points descending (longest first)
    candidates = sorted(
        [sid for sid in shape_ids if sid in shapes_data],
        key=lambda sid: len(shapes_data[sid]),
        reverse=True,
    )

    final: list[str] = []
    kept_point_sets: list[set[tuple[float, float]]] = []

    for sid in candidates:
        buf = shapes_data[sid]
        point_set = _unpack_point_set(buf)

        # If >80% of this shape's points already exist in a kept shape, skip
        is_subset = False
        for existing in kept_point_sets:
            overlap = len(point_set & existing)
            if overlap / max(len(point_set), 1) > 0.80:
                is_subset = True
                break

        if not is_subset:
            final.append(sid)
            kept_point_sets.append(point_set)

    return final


# ---------------------------------------------------------------------------
# Stop parsing: stops.txt + stop_times.txt + trips.txt → shape_id → [stops]
# ---------------------------------------------------------------------------

def _parse_stops_file(stops_path: Path) -> dict[str, CommuterStop]:
    """Parse GTFS stops.txt into stop_id → CommuterStop."""
    stops: dict[str, CommuterStop] = {}
    if not stops_path.exists():
        TrackLogger.warning(f"stops.txt not found: {stops_path}")
        return stops

    with open(stops_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            stop_id = row.get("stop_id", "").strip().strip('"')
            name = row.get("stop_name", "").strip().strip('"')
            try:
                lat = float(row["stop_lat"].strip('"'))
                lon = float(row["stop_lon"].strip('"'))
            except (ValueError, KeyError):
                continue
            if stop_id:
                stops[stop_id] = CommuterStop(
                    stop_id=stop_id, name=name, lat=lat, lon=lon,
                )
    return stops


def _build_shape_stop_map(
    stop_times_path: Path,
    trips_path: Path,
) -> dict[str, list[str]]:
    """Build shape_id → ordered list of stop_ids from GTFS stop_times + trips.

    Algorithm:
    1. Parse trips.txt to get trip_id → shape_id mapping.
    2. Parse stop_times.txt grouped by trip_id, picking one representative
       trip per shape_id (the one with the most stops).
    3. Return shape_id → [stop_ids in stop_sequence order].
    """
    # Step 1: trip_id → shape_id
    trip_to_shape: dict[str, str] = {}
    if trips_path.exists():
        with open(trips_path, encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                tid = row.get("trip_id", "").strip().strip('"')
                sid = row.get("shape_id", "").strip().strip('"')
                if tid and sid:
                    trip_to_shape[tid] = sid

    if not trip_to_shape:
        return {}

    # Step 2: Parse stop_times.txt grouped by trip_id
    trip_stops: dict[str, list[tuple[int, str]]] = defaultdict(list)
    if stop_times_path.exists():
        with open(stop_times_path, encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                tid = row.get("trip_id", "").strip().strip('"')
                stop_id = row.get("stop_id", "").strip().strip('"')
                try:
                    seq = int(row.get("stop_sequence", "0").strip().strip('"'))
                except ValueError:
                    seq = 0
                if tid and stop_id:
                    trip_stops[tid].append((seq, stop_id))

    # Step 3: Pick best trip per shape (most stops)
    shape_best: dict[str, list[str]] = {}
    for tid, stops in trip_stops.items():
        sid = trip_to_shape.get(tid)
        if not sid:
            continue
        ordered = [s[1] for s in sorted(stops, key=lambda x: x[0])]
        if sid not in shape_best or len(ordered) > len(shape_best[sid]):
            shape_best[sid] = ordered

    return shape_best


@_cache_nonempty
def _lirr_stops() -> dict[str, CommuterStop]:
    return _parse_stops_file(_LIRR_DIR / "stops.txt")


@_cache_nonempty
def _lirr_shape_stop_map() -> dict[str, list[str]]:
    return _build_shape_stop_map(_LIRR_DIR / "stop_times.txt", _LIRR_DIR / "trips.txt")


@_cache_nonempty
def _mnr_stops() -> dict[str, CommuterStop]:
    return _parse_stops_file(_MNR_DIR / "stops.txt")


@_cache_nonempty
def _mnr_shape_stop_map() -> dict[str, list[str]]:
    return _build_shape_stop_map(_MNR_DIR / "stop_times.txt", _MNR_DIR / "trips.txt")


def _resolve_stops_for_shapes(
    shape_ids: list[str],
    shape_stop_map: dict[str, list[str]],
    stops_data: dict[str, CommuterStop],
) -> list[CommuterStop]:
    """Collect unique stops across multiple shapes, preserving order."""
    seen: set[str] = set()
    result: list[CommuterStop] = []
    for sid in shape_ids:
        for stop_id in shape_stop_map.get(sid, []):
            if stop_id in seen:
                continue
            stop = stops_data.get(stop_id)
            if stop:
                result.append(stop)
                seen.add(stop_id)
    return result


# ---------------------------------------------------------------------------
# LIRR
# ---------------------------------------------------------------------------

@_cache_nonempty
def _lirr_shapes() -> dict[str, bytes]:
    return _parse_shapes(_LIRR_DIR / "shapes.txt")


@_cache_nonempty
def _lirr_routes() -> dict[str, CommuterRoute]:
    return _parse_routes(_LIRR_DIR / "routes.txt")


@_cache_nonempty
def _lirr_trips() -> tuple[dict[str, set[str]], dict[str, dict[int, set[str]]], dict[str, dict[int, str]]]:
    return _parse_trips_combined(_LIRR_DIR / "trips.txt")


def _lirr_route_shapes() -> dict[str, set[str]]:
    return _lirr_trips()[0]


def _lirr_route_shapes_by_dir() -> dict[str, dict[int, set[str]]]:
    return _lirr_trips()[1]


def _lirr_headsigns() -> dict[str, dict[int, str]]:
    return _lirr_trips()[2]


def get_all_lirr_lines() -> list[dict]:
    """Return polylines for all LIRR branches.

    Returns a list of dicts:
        {route_id, name, color_hex, polylines: [[(lat, lon), ...]]}
    """
    routes = _lirr_routes()
    route_shapes = _lirr_route_shapes()
    shapes_data = _lirr_shapes()

    results: list[dict] = []
    for route_id, route in routes.items():
        raw_shape_ids = route_shapes.get(route_id, set())
        if not raw_shape_ids:
            continue

        unique_sids = _deduplicate_shapes(raw_shape_ids, shapes_data)
        polylines: list[list[tuple[float, float]]] = []
        for sid in unique_sids:
            buf = shapes_data.get(sid, b"")
            if buf:
                polylines.append(_unpack_coords(buf))

        if polylines:
            all_stops = _resolve_stops_for_shapes(unique_sids, _lirr_shape_stop_map(), _lirr_stops())
            results.append({
                "route_id": f"LIRR_{route_id}",
                "name": route.name,
                "color_hex": route.color_hex,
                "polylines": polylines,
                "stops": all_stops,
            })

    TrackLogger.info(f"LIRR shapes: {len(results)} branches loaded")
    return results


# ---------------------------------------------------------------------------
# Metro-North
# ---------------------------------------------------------------------------

@_cache_nonempty
def _mnr_shapes() -> dict[str, bytes]:
    return _parse_shapes(_MNR_DIR / "shapes.txt")


@_cache_nonempty
def _mnr_routes() -> dict[str, CommuterRoute]:
    return _parse_routes(_MNR_DIR / "routes.txt")


@_cache_nonempty
def _mnr_trips() -> tuple[dict[str, set[str]], dict[str, dict[int, set[str]]], dict[str, dict[int, str]]]:
    return _parse_trips_combined(_MNR_DIR / "trips.txt")


def _mnr_route_shapes() -> dict[str, set[str]]:
    return _mnr_trips()[0]


def _mnr_route_shapes_by_dir() -> dict[str, dict[int, set[str]]]:
    return _mnr_trips()[1]


def _mnr_headsigns() -> dict[str, dict[int, str]]:
    return _mnr_trips()[2]


def get_all_mnr_lines() -> list[dict]:
    """Return polylines for all Metro-North branches.

    Returns a list of dicts:
        {route_id, name, color_hex, polylines: [[(lat, lon), ...]]}
    """
    routes = _mnr_routes()
    route_shapes = _mnr_route_shapes()
    shapes_data = _mnr_shapes()

    results: list[dict] = []
    for route_id, route in routes.items():
        raw_shape_ids = route_shapes.get(route_id, set())
        if not raw_shape_ids:
            continue

        unique_sids = _deduplicate_shapes(raw_shape_ids, shapes_data)
        polylines: list[list[tuple[float, float]]] = []
        for sid in unique_sids:
            buf = shapes_data.get(sid, b"")
            if buf:
                polylines.append(_unpack_coords(buf))

        if polylines:
            all_stops = _resolve_stops_for_shapes(unique_sids, _mnr_shape_stop_map(), _mnr_stops())
            results.append({
                "route_id": f"MNR_{route_id}",
                "name": route.name,
                "color_hex": route.color_hex,
                "polylines": polylines,
                "stops": all_stops,
            })

    TrackLogger.info(f"MNR shapes: {len(results)} branches loaded")
    return results


# ---------------------------------------------------------------------------
# Route name lookups (for nearby endpoint display names)
# ---------------------------------------------------------------------------

def get_lirr_route_name(route_id: str) -> str:
    """Return the human-readable LIRR branch name for a numeric route_id.

    Falls back to the raw route_id if not found.
    """
    routes = _lirr_routes()
    route = routes.get(route_id)
    return route.name if route else route_id


def get_mnr_route_name(route_id: str) -> str:
    """Return the human-readable Metro-North line name for a numeric route_id.

    Falls back to the raw route_id if not found.
    """
    routes = _mnr_routes()
    route = routes.get(route_id)
    return route.name if route else route_id


def get_lirr_route_color(route_id: str) -> str:
    """Return the hex color for a LIRR route_id. Falls back to grey."""
    routes = _lirr_routes()
    route = routes.get(route_id)
    return f"#{route.color_hex}" if route else "#4D5357"


def get_mnr_route_color(route_id: str) -> str:
    """Return the hex color for a Metro-North route_id. Falls back to grey."""
    routes = _mnr_routes()
    route = routes.get(route_id)
    return f"#{route.color_hex}" if route else "#4D5357"


# ---------------------------------------------------------------------------
# Single-branch shape lookup (for route detail view)
# ---------------------------------------------------------------------------

def get_single_lirr_line(route_id: str) -> dict | None:
    """Return shape data for a single LIRR branch by numeric route_id.

    Returns: {route_id, name, color_hex, polylines, stops, directions}
    """
    routes = _lirr_routes()
    route = routes.get(route_id)
    if not route:
        return None

    dir_shapes = _lirr_route_shapes_by_dir().get(route_id, {})
    shapes_data = _lirr_shapes()
    headsigns = _lirr_headsigns().get(route_id, {})
    shape_stop_map = _lirr_shape_stop_map()
    stops_data = _lirr_stops()

    # Also fall back to the flat map for overall polylines
    route_shapes = _lirr_route_shapes()
    raw_shape_ids = route_shapes.get(route_id, set())
    if not raw_shape_ids:
        return None

    unique_sids = _deduplicate_shapes(raw_shape_ids, shapes_data)
    polylines: list[list[tuple[float, float]]] = []
    for sid in unique_sids:
        buf = shapes_data.get(sid, b"")
        if buf:
            polylines.append(_unpack_coords(buf))

    if not polylines:
        return None

    # Resolve stops for the overall route
    all_stops = _resolve_stops_for_shapes(unique_sids, shape_stop_map, stops_data)

    # Build per-direction data
    directions: list[dict] = []
    for direction_id in sorted(dir_shapes.keys()):
        dir_sids = _deduplicate_shapes(dir_shapes[direction_id], shapes_data)
        dir_polys: list[list[tuple[float, float]]] = []
        for sid in dir_sids:
            buf = shapes_data.get(sid, b"")
            if buf:
                dir_polys.append(_unpack_coords(buf))
        if dir_polys:
            dir_stops = _resolve_stops_for_shapes(dir_sids, shape_stop_map, stops_data)
            directions.append({
                "direction_id": direction_id,
                "headsign": headsigns.get(direction_id, ""),
                "polylines": dir_polys,
                "stops": dir_stops,
            })

    return {
        "route_id": f"LIRR_{route_id}",
        "name": route.name,
        "color_hex": route.color_hex,
        "polylines": polylines,
        "stops": all_stops,
        "directions": directions,
    }


def get_single_mnr_line(route_id: str) -> dict | None:
    """Return shape data for a single Metro-North line by numeric route_id.

    Returns: {route_id, name, color_hex, polylines, stops, directions}
    """
    routes = _mnr_routes()
    route = routes.get(route_id)
    if not route:
        return None

    dir_shapes = _mnr_route_shapes_by_dir().get(route_id, {})
    shapes_data = _mnr_shapes()
    headsigns = _mnr_headsigns().get(route_id, {})
    shape_stop_map = _mnr_shape_stop_map()
    stops_data = _mnr_stops()

    route_shapes = _mnr_route_shapes()
    raw_shape_ids = route_shapes.get(route_id, set())
    if not raw_shape_ids:
        return None

    unique_sids = _deduplicate_shapes(raw_shape_ids, shapes_data)
    polylines: list[list[tuple[float, float]]] = []
    for sid in unique_sids:
        buf = shapes_data.get(sid, b"")
        if buf:
            polylines.append(_unpack_coords(buf))

    if not polylines:
        return None

    # Resolve stops for the overall route
    all_stops = _resolve_stops_for_shapes(unique_sids, shape_stop_map, stops_data)

    # Build per-direction data
    directions: list[dict] = []
    for direction_id in sorted(dir_shapes.keys()):
        dir_sids = _deduplicate_shapes(dir_shapes[direction_id], shapes_data)
        dir_polys: list[list[tuple[float, float]]] = []
        for sid in dir_sids:
            buf = shapes_data.get(sid, b"")
            if buf:
                dir_polys.append(_unpack_coords(buf))
        if dir_polys:
            dir_stops = _resolve_stops_for_shapes(dir_sids, shape_stop_map, stops_data)
            directions.append({
                "direction_id": direction_id,
                "headsign": headsigns.get(direction_id, ""),
                "polylines": dir_polys,
                "stops": dir_stops,
            })

    return {
        "route_id": f"MNR_{route_id}",
        "name": route.name,
        "color_hex": route.color_hex,
        "polylines": polylines,
        "stops": all_stops,
        "directions": directions,
    }
