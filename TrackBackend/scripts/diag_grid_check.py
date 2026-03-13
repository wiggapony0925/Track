#!/usr/bin/env python3
"""Simulate the iOS client's routesNear grid check for A/C/E near Sutphin."""
import math
from app.services.mapping.subway_shapes import (
    _load_route_shapes, _load_shapes, _unpack_coords,
)

SUTPHIN_LAT = 40.7005
SUTPHIN_LON = -73.808
ROUTE_GRID_CELL = 0.002  # Must match iOS MapSystemViewModel


def route_grid_key(lat: float, lon: float) -> int:
    lat_cell = int(math.floor(lat / ROUTE_GRID_CELL))
    lon_cell = int(math.floor(lon / ROUTE_GRID_CELL))
    return lat_cell * 10_000_000 + lon_cell


def routes_near(lat: float, lon: float, per_route_grid: dict) -> list:
    lat_cell = int(math.floor(lat / ROUTE_GRID_CELL))
    lon_cell = int(math.floor(lon / ROUTE_GRID_CELL))
    nearby = []
    for route_id, grid in per_route_grid.items():
        found = False
        for dl in range(-1, 2):
            for dn in range(-1, 2):
                key = (lat_cell + dl) * 10_000_000 + (lon_cell + dn)
                if key in grid:
                    found = True
                    break
            if found:
                break
        if found:
            nearby.append(route_id)
    return nearby


def main():
    route_shapes = _load_route_shapes()
    shapes_data = _load_shapes()

    # Build raw polylines per route (pre-corridor-pipeline)
    route_polylines: dict[str, list] = {}
    for line in ["A", "C", "E"]:
        direction_shapes = route_shapes.get(line)
        if not direction_shapes:
            continue
        primary_dir = 0 if 0 in direction_shapes else min(direction_shapes.keys())
        shape_ids = direction_shapes[primary_dir]
        polylines_raw = []
        for shape_id in shape_ids:
            shape_buf = shapes_data.get(shape_id)
            if shape_buf:
                raw = _unpack_coords(shape_buf)
                polylines_raw.append(raw)
        route_polylines[line] = polylines_raw

    # Build per-route spatial grids (same logic as iOS client)
    per_route_grid: dict[str, set] = {}
    for route_id, branches in route_polylines.items():
        grid = set()
        for branch in branches:
            for lat, lon in branch:
                grid.add(route_grid_key(lat, lon))
        per_route_grid[route_id] = grid
        total_pts = sum(len(b) for b in branches)
        print(f"{route_id}: {len(grid)} grid cells, {len(branches)} branches, {total_pts} pts")

    # Check routesNear for Sutphin
    print(f"\nSutphin coords: ({SUTPHIN_LAT}, {SUTPHIN_LON})")
    lat_cell = int(math.floor(SUTPHIN_LAT / ROUTE_GRID_CELL))
    lon_cell = int(math.floor(SUTPHIN_LON / ROUTE_GRID_CELL))
    print(f"Grid cell: lat={lat_cell}, lon={lon_cell}")

    nearby = routes_near(SUTPHIN_LAT, SUTPHIN_LON, per_route_grid)
    print(f"routesNear result: {nearby}")
    if not nearby:
        print(">>> FALLBACK TRIGGERED: would show full group ['A', 'C', 'E']")

    # Closest approach per route
    print()
    for route_id in ["A", "C", "E"]:
        min_dist = float("inf")
        closest = None
        for branch in route_polylines[route_id]:
            for lat, lon in branch:
                dlat = (lat - SUTPHIN_LAT) * 111000
                dlon = (lon - SUTPHIN_LON) * 111000 * math.cos(math.radians(SUTPHIN_LAT))
                d = math.sqrt(dlat * dlat + dlon * dlon)
                if d < min_dist:
                    min_dist = d
                    closest = (lat, lon)
        print(f"{route_id}: closest approach = {min_dist:.0f}m at ({closest[0]:.5f}, {closest[1]:.5f})")

    # Now simulate AFTER corridor pipeline — check what the server actually returns
    print("\n" + "=" * 60)
    print("After corridor pipeline (actual server output):")
    print("=" * 60)

    from app.services.mapping.corridor_pipeline import apply_topological_offsets
    from app.models import SubwayLineOverlay
    from app.utils.transit_utils import get_subway_color
    from app.utils.polyline_utils import encode_polyline as _encode_polyline

    overlays = []
    for line in ["A", "C", "E"]:
        encoded = [_encode_polyline(coords) for coords in route_polylines[line]]
        color = get_subway_color(line)
        overlays.append(SubwayLineOverlay(
            route_id=line,
            color_hex=color,
            polylines=encoded,
        ))

    result_overlays = apply_topological_offsets(overlays)

    # Rebuild grids from pipeline output
    from app.utils.polyline_utils import decode_polyline as _decode_polyline
    per_route_grid_post = {}
    for overlay in result_overlays:
        grid = set()
        total_pts = 0
        for enc in overlay.polylines:
            coords = _decode_polyline(enc)
            total_pts += len(coords)
            for lat, lon in coords:
                grid.add(route_grid_key(lat, lon))
        per_route_grid_post[overlay.route_id] = grid
        print(f"{overlay.route_id}: {len(grid)} grid cells, {len(overlay.polylines)} polylines, {total_pts} pts")

    nearby_post = routes_near(SUTPHIN_LAT, SUTPHIN_LON, per_route_grid_post)
    print(f"\nroutesNear (post-pipeline): {nearby_post}")
    if not nearby_post:
        print(">>> FALLBACK TRIGGERED: would show full group ['A', 'C', 'E']")

    # Per-route closest approach after pipeline
    for overlay in result_overlays:
        min_dist = float("inf")
        for enc in overlay.polylines:
            coords = _decode_polyline(enc)
            for lat, lon in coords:
                dlat = (lat - SUTPHIN_LAT) * 111000
                dlon = (lon - SUTPHIN_LON) * 111000 * math.cos(math.radians(SUTPHIN_LAT))
                d = math.sqrt(dlat * dlat + dlon * dlon)
                if d < min_dist:
                    min_dist = d
        print(f"{overlay.route_id}: closest approach (post-pipeline) = {min_dist:.0f}m")


if __name__ == "__main__":
    main()
