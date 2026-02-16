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

_DATA_DIR = Path(__file__).resolve().parent.parent / "data"

_LIRR_DIR = _DATA_DIR / "lirr" / "gtfslirr"
_MNR_DIR = _DATA_DIR / "metro_north" / "gtfsmnr"


class ShapePoint(NamedTuple):
    lat: float
    lon: float
    sequence: int


class CommuterRoute(NamedTuple):
    route_id: str
    name: str
    color_hex: str


# ---------------------------------------------------------------------------
# Generic GTFS parsers
# ---------------------------------------------------------------------------

def _parse_shapes(shapes_path: Path) -> dict[str, list[ShapePoint]]:
    """Parse a GTFS shapes.txt into shape_id → sorted list of ShapePoints."""
    shapes: dict[str, list[ShapePoint]] = defaultdict(list)
    if not shapes_path.exists():
        TrackLogger.warning(f"shapes.txt not found: {shapes_path}")
        return dict(shapes)

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
            shapes[shape_id].append(ShapePoint(lat=lat, lon=lon, sequence=seq))

    for pts in shapes.values():
        pts.sort(key=lambda p: p.sequence)

    return dict(shapes)


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


def _parse_route_shapes(trips_path: Path) -> dict[str, set[str]]:
    """Parse trips.txt to map route_id → set of shape_ids."""
    route_shapes: dict[str, set[str]] = defaultdict(set)
    if not trips_path.exists():
        TrackLogger.warning(f"trips.txt not found: {trips_path}")
        return dict(route_shapes)

    with open(trips_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            route_id = row.get("route_id", "").strip().strip('"')
            shape_id = row.get("shape_id", "").strip().strip('"')
            if route_id and shape_id:
                route_shapes[route_id].add(shape_id)

    return dict(route_shapes)


def _parse_route_shapes_by_direction(
    trips_path: Path,
) -> dict[str, dict[int, set[str]]]:
    """Parse trips.txt to map route_id → {direction_id: set of shape_ids}."""
    result: dict[str, dict[int, set[str]]] = defaultdict(lambda: defaultdict(set))
    if not trips_path.exists():
        TrackLogger.warning(f"trips.txt not found: {trips_path}")
        return dict(result)

    with open(trips_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            route_id = row.get("route_id", "").strip().strip('"')
            shape_id = row.get("shape_id", "").strip().strip('"')
            if not route_id or not shape_id:
                continue
            try:
                direction = int(row.get("direction_id", "0").strip().strip('"'))
            except ValueError:
                direction = 0
            result[route_id][direction].add(shape_id)

    return dict(result)


def _parse_direction_headsigns(
    trips_path: Path,
) -> dict[str, dict[int, str]]:
    """Parse trips.txt to get the most common headsign per route/direction.

    Returns: {route_id: {direction_id: headsign}}
    """
    from collections import Counter

    if not trips_path.exists():
        return {}

    counts: dict[str, dict[int, Counter]] = defaultdict(lambda: defaultdict(Counter))

    with open(trips_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            route_id = row.get("route_id", "").strip().strip('"')
            headsign = row.get("trip_headsign", "").strip().strip('"')
            if not route_id or not headsign:
                continue
            # Skip bus-like headsigns (contain "(Bus)")
            if "(Bus)" in headsign:
                continue
            try:
                direction = int(row.get("direction_id", "0").strip().strip('"'))
            except ValueError:
                direction = 0
            counts[route_id][direction][headsign] += 1

    result: dict[str, dict[int, str]] = {}
    for route_id, dir_map in counts.items():
        result[route_id] = {}
        for direction, counter in dir_map.items():
            result[route_id][direction] = counter.most_common(1)[0][0]
    return result


def _deduplicate_shapes(
    shape_ids: set[str],
    shapes_data: dict[str, list[ShapePoint]],
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
        pts = shapes_data[sid]
        point_set = {(round(p.lat, 5), round(p.lon, 5)) for p in pts}

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
def _lirr_shapes() -> dict[str, list[ShapePoint]]:
    return _parse_shapes(_LIRR_DIR / "shapes.txt")


@lru_cache(maxsize=1)
def _lirr_routes() -> dict[str, CommuterRoute]:
    return _parse_routes(_LIRR_DIR / "routes.txt")


@lru_cache(maxsize=1)
def _lirr_route_shapes() -> dict[str, set[str]]:
    return _parse_route_shapes(_LIRR_DIR / "trips.txt")


@lru_cache(maxsize=1)
def _lirr_route_shapes_by_dir() -> dict[str, dict[int, set[str]]]:
    return _parse_route_shapes_by_direction(_LIRR_DIR / "trips.txt")


@lru_cache(maxsize=1)
def _lirr_headsigns() -> dict[str, dict[int, str]]:
    return _parse_direction_headsigns(_LIRR_DIR / "trips.txt")


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
            pts = shapes_data.get(sid, [])
            if pts:
                polylines.append([(p.lat, p.lon) for p in pts])

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
def _mnr_shapes() -> dict[str, list[ShapePoint]]:
    return _parse_shapes(_MNR_DIR / "shapes.txt")


@lru_cache(maxsize=1)
def _mnr_routes() -> dict[str, CommuterRoute]:
    return _parse_routes(_MNR_DIR / "routes.txt")


@lru_cache(maxsize=1)
def _mnr_route_shapes() -> dict[str, set[str]]:
    return _parse_route_shapes(_MNR_DIR / "trips.txt")


@lru_cache(maxsize=1)
def _mnr_route_shapes_by_dir() -> dict[str, dict[int, set[str]]]:
    return _parse_route_shapes_by_direction(_MNR_DIR / "trips.txt")


@lru_cache(maxsize=1)
def _mnr_headsigns() -> dict[str, dict[int, str]]:
    return _parse_direction_headsigns(_MNR_DIR / "trips.txt")


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
            pts = shapes_data.get(sid, [])
            if pts:
                polylines.append([(p.lat, p.lon) for p in pts])

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
        pts = shapes_data.get(sid, [])
        if pts:
            polylines.append([(p.lat, p.lon) for p in pts])

    if not polylines:
        return None

    # Build per-direction data
    directions: list[dict] = []
    for direction_id in sorted(dir_shapes.keys()):
        dir_sids = _deduplicate_shapes(dir_shapes[direction_id], shapes_data)
        dir_polys: list[list[tuple[float, float]]] = []
        for sid in dir_sids:
            pts = shapes_data.get(sid, [])
            if pts:
                dir_polys.append([(p.lat, p.lon) for p in pts])
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
        pts = shapes_data.get(sid, [])
        if pts:
            polylines.append([(p.lat, p.lon) for p in pts])

    if not polylines:
        return None

    # Build per-direction data
    directions: list[dict] = []
    for direction_id in sorted(dir_shapes.keys()):
        dir_sids = _deduplicate_shapes(dir_shapes[direction_id], shapes_data)
        dir_polys: list[list[tuple[float, float]]] = []
        for sid in dir_sids:
            pts = shapes_data.get(sid, [])
            if pts:
                dir_polys.append([(p.lat, p.lon) for p in pts])
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
