#!/usr/bin/env python3
"""Analyze which polyline segments are missing from the shapes/all response."""
import sys
sys.path.insert(0, "/Users/jeffreyfernandez/code/Track/TrackBackend")

from app.services.mapping.subway_shapes import _load_route_shapes, _load_shape_stops, _load_shapes, _unpack_coords
from app.services.mapping.corridor_pipeline import TRUNK_GROUPS, ROUTE_TO_TRUNK

route_shapes = _load_route_shapes()
shape_stops = _load_shape_stops()
shapes_data = _load_shapes()
skip_variants = {"6X", "7X", "FX", "FS", "GS", "SR"}

print("=== Skipped variants ===")
for v in sorted(skip_variants):
    if v in route_shapes:
        dirs = route_shapes[v]
        for d, sids in dirs.items():
            for sid in sids:
                stops = shape_stops.get(sid, [])
                buf = shapes_data.get(sid)
                pts = len(_unpack_coords(buf)) if buf else 0
                print(f"  {v} dir-{d} shape {sid}: {len(stops)} stops, {pts} points")

print()
print("=== Routes with shapes per direction ===")
for route_id in sorted(route_shapes.keys()):
    if route_id in skip_variants:
        continue
    dirs = route_shapes[route_id]
    parts = []
    for d in sorted(dirs.keys()):
        parts.append(f"dir-{d}: {len(dirs[d])} shapes")
    print(f"  {route_id}: {', '.join(parts)}")

print()
print("=== Dir-1 shapes with unique stations ===")
for route_id in sorted(route_shapes.keys()):
    if route_id in skip_variants:
        continue
    dirs = route_shapes[route_id]
    primary_dir = 0 if 0 in dirs else min(dirs.keys())
    other_dir = 1 - primary_dir
    if other_dir not in dirs:
        continue

    covered = set()
    for sid in dirs[primary_dir]:
        for s in shape_stops.get(sid, []):
            covered.add(s[:-1] if s and s[-1] in "NS" else s)

    for sid in dirs[other_dir]:
        raw_stops = shape_stops.get(sid, [])
        other_stations = {s[:-1] if s and s[-1] in "NS" else s for s in raw_stops}
        unique = other_stations - covered
        status = "KEPT" if len(unique) >= 2 else "DROPPED" if unique else "no-unique"
        if unique:
            print(f"  {route_id} dir-{other_dir} shape {sid}: {len(unique)} unique → {status}: {sorted(unique)[:5]}")

print()
print("=== Trunk group coverage ===")
for trunk_name, routes in TRUNK_GROUPS.items():
    included = [r for r in routes if r not in skip_variants]
    skipped = [r for r in routes if r in skip_variants]
    if skipped:
        print(f"  {trunk_name}: included={included}, SKIPPED={skipped}")
