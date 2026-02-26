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
from functools import lru_cache
from pathlib import Path
from typing import NamedTuple

from app.utils.logger import TrackLogger
from app.utils.shape_utils import (
    ShapePoint,
    pack_coords as _pack_coords,
    unpack_coords as _unpack_coords,
    unpack_point_set as _unpack_point_set,
)

_DATA_DIR = Path(__file__).resolve().parent.parent / "data"

_LIRR_DIR = _DATA_DIR / "lirr" / "gtfslirr"
_MNR_DIR = _DATA_DIR / "metro_north" / "gtfsmnr"


class CommuterRoute(NamedTuple):
    route_id: str
    name: str
    color_hex: str


# ---------------------------------------------------------------------------
# (imported from app.utils.shape_utils as _pack_coords / _unpack_coords / _unpack_point_set)


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
# LIRR
# ---------------------------------------------------------------------------

@lru_cache(maxsize=1)
def _lirr_shapes() -> dict[str, bytes]:
    return _parse_shapes(_LIRR_DIR / "shapes.txt")


@lru_cache(maxsize=1)
def _lirr_routes() -> dict[str, CommuterRoute]:
    return _parse_routes(_LIRR_DIR / "routes.txt")


@lru_cache(maxsize=1)
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
            results.append({
                "route_id": f"LIRR_{route_id}",
                "name": route.name,
                "color_hex": route.color_hex,
                "polylines": polylines,
            })

    TrackLogger.info(f"LIRR shapes: {len(results)} branches loaded")
    return results


# ---------------------------------------------------------------------------
# Metro-North
# ---------------------------------------------------------------------------

@lru_cache(maxsize=1)
def _mnr_shapes() -> dict[str, bytes]:
    return _parse_shapes(_MNR_DIR / "shapes.txt")


@lru_cache(maxsize=1)
def _mnr_routes() -> dict[str, CommuterRoute]:
    return _parse_routes(_MNR_DIR / "routes.txt")


@lru_cache(maxsize=1)
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
            results.append({
                "route_id": f"MNR_{route_id}",
                "name": route.name,
                "color_hex": route.color_hex,
                "polylines": polylines,
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

    Returns: {route_id, name, color_hex, polylines, directions}
    """
    routes = _lirr_routes()
    route = routes.get(route_id)
    if not route:
        return None

    dir_shapes = _lirr_route_shapes_by_dir().get(route_id, {})
    shapes_data = _lirr_shapes()
    headsigns = _lirr_headsigns().get(route_id, {})

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
            directions.append({
                "direction_id": direction_id,
                "headsign": headsigns.get(direction_id, ""),
                "polylines": dir_polys,
            })

    return {
        "route_id": f"LIRR_{route_id}",
        "name": route.name,
        "color_hex": route.color_hex,
        "polylines": polylines,
        "directions": directions,
    }


def get_single_mnr_line(route_id: str) -> dict | None:
    """Return shape data for a single Metro-North line by numeric route_id.

    Returns: {route_id, name, color_hex, polylines, directions}
    """
    routes = _mnr_routes()
    route = routes.get(route_id)
    if not route:
        return None

    dir_shapes = _mnr_route_shapes_by_dir().get(route_id, {})
    shapes_data = _mnr_shapes()
    headsigns = _mnr_headsigns().get(route_id, {})

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
            directions.append({
                "direction_id": direction_id,
                "headsign": headsigns.get(direction_id, ""),
                "polylines": dir_polys,
            })

    return {
        "route_id": f"MNR_{route_id}",
        "name": route.name,
        "color_hex": route.color_hex,
        "polylines": polylines,
        "directions": directions,
    }
