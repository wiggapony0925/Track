#!/usr/bin/env python3
"""Diagnose which 7-train vertices still get offset and WHERE they are."""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.chdir(os.path.join(os.path.dirname(__file__), ".."))

from shapely.geometry import Point  # noqa: E402

from app.models import SubwayLineOverlay  # noqa: E402
from app.services.mapping.corridor_pipeline import (  # noqa: E402
    CORRIDOR_ALIGN_MIN,
    CORRIDOR_DETECT_DIST,
    TRUNK_GROUPS,
    _compute_corridor_offsets,
    _group_and_merge_trunks,
    _to_wgs84,
)
from app.services.mapping.subway_shapes import (  # noqa: E402
    _load_route_shapes,
    _load_shapes,
    _unpack_coords,
)
from app.utils.polyline_utils import encode_polyline  # noqa: E402
from app.utils.transit_utils import get_all_subway_lines  # noqa: E402

print("=== Pipeline constants ===")
print(f"CORRIDOR_DETECT_DIST = {CORRIDOR_DETECT_DIST}")
print(f"CORRIDOR_ALIGN_MIN   = {CORRIDOR_ALIGN_MIN}")

skip = {"6X", "7X", "FX", "FS", "GS", "SR"}
lines = [ln for ln in get_all_subway_lines() if ln not in skip]
rs = _load_route_shapes()
sd = _load_shapes()
ov = []
for ln in lines:
    ds = rs.get(ln)
    if not ds:
        continue
    d0 = 0 if 0 in ds else min(ds.keys())
    raws = [_unpack_coords(sd[s]) for s in ds[d0] if s in sd]
    if raws:
        ov.append(
            SubwayLineOverlay(
                route_id=ln, color_hex="", polylines=[encode_polyline(r) for r in raws]
            )
        )

tp = _group_and_merge_trunks(ov)
offs = _compute_corridor_offsets(tp)

# Trunk 2 = 7 train
trunk_id = 2
trunk_name = ",".join(TRUNK_GROUPS[trunk_id]) if trunk_id < len(TRUNK_GROUPS) else "?"
print(f"\n=== Trunk {trunk_id} ({trunk_name}) ===")

for seg_idx in sorted(offs.get(trunk_id, {}).keys()):
    pv = offs[trunk_id][seg_idx]
    coords = list(tp[trunk_id][seg_idx].coords)
    path = tp[trunk_id][seg_idx]
    n_total = len(pv)
    n_offset = sum(1 for o in pv if abs(o) > 0.5)

    print(
        f"\nSegment {seg_idx}: {n_total} vertices, {n_offset} offset ({100*n_offset/n_total:.1f}%)"
    )

    if n_offset == 0:
        print("  No offsets - CLEAN")
        continue

    # Show offset vertices
    print(f"  {'Vtx':>5} {'Dist(km)':>9} {'Lat':>10} {'Lon':>11} {'Offset(m)':>10}")
    for i, o in enumerate(pv):
        if abs(o) > 0.5:
            x, y = coords[i]
            lon, lat = _to_wgs84.transform(x, y)
            d = path.project(Point(x, y)) / 1000
            print(f"  {i:5d} {d:9.2f} {lat:10.5f} {lon:11.5f} {o:+10.1f}")

    # Summary
    offset_vals = [o for o in pv if abs(o) > 0.5]
    print(f"\n  Max |offset|: {max(abs(o) for o in offset_vals):.1f}m")
    print(f"  Avg |offset|: {sum(abs(o) for o in offset_vals)/len(offset_vals):.1f}m")

    # Show geographic extent of offsets
    offset_lats = []
    for i, o in enumerate(pv):
        if abs(o) > 0.5:
            x, y = coords[i]
            lon, lat = _to_wgs84.transform(x, y)
            offset_lats.append((lat, lon))
    if offset_lats:
        min_lat = min(ll[0] for ll in offset_lats)
        max_lat = max(ll[0] for ll in offset_lats)
        min_lon = min(ll[1] for ll in offset_lats)
        max_lon = max(ll[1] for ll in offset_lats)
        print(
            f"  Geographic extent: ({min_lat:.5f},{min_lon:.5f}) to ({max_lat:.5f},{max_lon:.5f})"
        )

# Also check: is 74th St area offset?
print("\n=== Checking 74th St / Jackson Hts area ===")
JACKSON_HTS_LAT = 40.7468
JACKSON_HTS_LON = -73.8914
for seg_idx in sorted(offs.get(trunk_id, {}).keys()):
    pv = offs[trunk_id][seg_idx]
    coords = list(tp[trunk_id][seg_idx].coords)
    for i, o in enumerate(pv):
        x, y = coords[i]
        lon, lat = _to_wgs84.transform(x, y)
        if abs(lat - JACKSON_HTS_LAT) < 0.002 and abs(lon - JACKSON_HTS_LON) < 0.005:
            print(f"  v{i} ({lat:.5f},{lon:.5f}) offset={o:+.1f}m")

print("\nDone.")
