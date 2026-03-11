#!/usr/bin/env python3
"""Check physical separation of all detected corridor pairs.

For each vertex where corridor offsets are applied, measure the actual
distance to the neighboring trunk.  This tells us what the "real shared
track" threshold should be.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from app.services.mapping.corridor_pipeline import (
    _group_and_merge_trunks,
    _local_direction,
    _direction_at_distance,
    TRUNK_GROUPS,
    ROUTE_TO_TRUNK,
    CORRIDOR_DETECT_DIST,
    CORRIDOR_ALIGN_MIN,
    _to_meters,
    _to_wgs84,
)
from app.utils.polyline_utils import encode_polyline
from app.services.mapping.subway_shapes import _load_route_shapes, _load_shapes, _unpack_coords
from app.utils.transit_utils import get_all_subway_lines
from app.models import SubwayLineOverlay
from shapely.geometry import Point
from shapely import STRtree
from collections import namedtuple, defaultdict

# Build overlays
skip = {"6X", "7X", "FX", "FS", "GS", "SR"}
lines = [l for l in get_all_subway_lines() if l not in skip]
rs = _load_route_shapes(); sd = _load_shapes()
overlays = []
for l in lines:
    ds = rs.get(l)
    if not ds: continue
    d0 = 0 if 0 in ds else min(ds.keys())
    raws = [_unpack_coords(sd[s]) for s in ds[d0] if s in sd]
    if raws:
        overlays.append(SubwayLineOverlay(
            route_id=l, color_hex="",
            polylines=[encode_polyline(r) for r in raws],
        ))

trunk_paths = _group_and_merge_trunks(overlays)

# Build spatial index
Info = namedtuple("Info", ["trunk_idx", "path_idx", "path"])
all_infos = []
all_geoms = []
for ti, paths in trunk_paths.items():
    for pi, p in enumerate(paths):
        all_infos.append(Info(ti, pi, p))
        all_geoms.append(p)
tree = STRtree(all_geoms)

# For all vertices of all trunk paths, collect distance to nearest
# detected corridor partner
pair_distances = defaultdict(list)  # (trunk_a, trunk_b) -> [distances]

for ti, paths in trunk_paths.items():
    for pi, path in enumerate(paths):
        coords = list(path.coords)
        for i in range(0, len(coords), 3):  # sample every 3rd vertex
            x, y = coords[i]
            pt = Point(x, y)
            dir_i = _local_direction(coords, i)

            candidates = tree.query(pt.buffer(CORRIDOR_DETECT_DIST))
            for ci in candidates:
                info = all_infos[ci]
                if info.trunk_idx == ti:
                    continue
                dist = info.path.distance(pt)
                if dist >= CORRIDOR_DETECT_DIST:
                    continue
                proj = info.path.project(pt)
                dir_j = _direction_at_distance(info.path, proj)
                dot = abs(dir_i[0] * dir_j[0] + dir_i[1] * dir_j[1])
                if dot >= CORRIDOR_ALIGN_MIN:
                    pair = (min(ti, info.trunk_idx), max(ti, info.trunk_idx))
                    pair_distances[pair].append(dist)

print("=" * 80)
print("CORRIDOR PAIR DISTANCE DISTRIBUTION")
print("=" * 80)
print(f"{'Pair':30s} {'Count':>6s} {'Min':>6s} {'P10':>6s} {'Med':>6s} {'P90':>6s} {'Max':>6s}")
print("-" * 80)

for pair, dists in sorted(pair_distances.items()):
    dists.sort()
    n = len(dists)
    name_a = ",".join(TRUNK_GROUPS[pair[0]])
    name_b = ",".join(TRUNK_GROUPS[pair[1]])
    label = f"T{pair[0]}({name_a}) ↔ T{pair[1]}({name_b})"

    p10 = dists[n // 10] if n >= 10 else dists[0]
    med = dists[n // 2]
    p90 = dists[9 * n // 10] if n >= 10 else dists[-1]

    flag = " ← FALSE?" if min(dists) > 15 else ""
    print(f"  {label:38s} {n:5d} {dists[0]:5.1f}m {p10:5.1f}m {med:5.1f}m {p90:5.1f}m {dists[-1]:5.1f}m{flag}")

print("\n" + "=" * 80)
print("INTERPRETATION")
print("=" * 80)
print("Pairs with min distance > 15m are likely FALSE corridor detections")
print("(parallel streets, not shared track)")
print("True shared corridors typically have min distance < 10m")
