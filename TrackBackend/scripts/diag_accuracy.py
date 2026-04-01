#!/usr/bin/env python3
"""Accuracy audit: compare pipeline output to GTFS stop positions."""

from __future__ import annotations

import csv
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.models import SubwayLineOverlay
from app.services.mapping.corridor_pipeline import apply_topological_offsets
from app.services.mapping.subway_shapes import (
    _load_route_shapes,
    _load_shape_stops,
    _load_shapes,
    _unpack_coords,
    get_stops_for_route,
)
from app.utils.polyline_utils import decode_polyline, encode_polyline
from app.utils.transit_utils import get_all_subway_lines, get_subway_color

DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "app", "data")


def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (
        math.sin(dlat / 2) ** 2
        + math.cos(math.radians(lat1))
        * math.cos(math.radians(lat2))
        * math.sin(dlon / 2) ** 2
    )
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _station_id(sid):
    return sid[:-1] if sid and sid[-1] in ("N", "S") else sid


# Build full pipeline (matching subway.py)
skip_variants = {"6X", "7X", "FX", "FS", "GS", "SR"}
lines = [ln for ln in get_all_subway_lines() if ln not in skip_variants]
route_shapes = _load_route_shapes()
shapes_data = _load_shapes()
shape_stops_map = _load_shape_stops()

overlays = []
dir1_extras = []

for line in lines:
    direction_shapes = route_shapes.get(line)
    if not direction_shapes:
        continue
    primary_dir = 0 if 0 in direction_shapes else min(direction_shapes.keys())
    shape_ids = direction_shapes[primary_dir]
    polylines_raw = []
    for sid in shape_ids:
        buf = shapes_data.get(sid)
        if buf:
            polylines_raw.append(_unpack_coords(buf))
    if not polylines_raw:
        continue
    encoded = [encode_polyline(c) for c in polylines_raw]
    overlays.append(
        SubwayLineOverlay(
            route_id=line, color_hex=get_subway_color(line), polylines=encoded
        )
    )

    covered_stations = set()
    for sid in shape_ids:
        covered_stations.update(_station_id(s) for s in shape_stops_map.get(sid, []))
    other_dir = 1 - primary_dir
    if other_dir in direction_shapes:
        for sid in direction_shapes[other_dir]:
            other_stations = {_station_id(s) for s in shape_stops_map.get(sid, [])}
            unique = other_stations - covered_stations
            if len(unique) >= 2:
                dir1_extras.append((line, sid))
                covered_stations.update(other_stations)

# Run pipeline
overlays = apply_topological_offsets(overlays)

# Append dir-1 extras
overlay_map = {o.route_id: o for o in overlays}
for line, sid in dir1_extras:
    buf = shapes_data.get(sid)
    if not buf:
        continue
    raw = list(reversed(_unpack_coords(buf)))
    overlay_map[line].polylines.append(encode_polyline(raw))

# Decode final output
pipeline_coords = {}
for ov in overlays:
    pipeline_coords[ov.route_id] = [decode_polyline(e) for e in ov.polylines]

# Load stop positions
stops_file = os.path.join(DATA_DIR, "stops.txt")
stop_pos = {}
with open(stops_file) as f:
    for row in csv.DictReader(f):
        stop_pos[row["stop_id"]] = (
            float(row["stop_lat"]),
            float(row["stop_lon"]),
            row.get("stop_name", ""),
        )

# Also load raw GTFS shapes for comparison
raw_all_coords = {}
for line in lines:
    direction_shapes = route_shapes.get(line, {})
    all_pts = []
    for _dir_id, sids in direction_shapes.items():
        for sid in sids:
            buf = shapes_data.get(sid)
            if buf:
                all_pts.extend(_unpack_coords(buf))
    raw_all_coords[line] = all_pts

# Measure every stop
all_dists = []
per_route = {}
gap_stops = []

for route_id in sorted(pipeline_coords.keys()):
    polys = pipeline_coords[route_id]
    stops = get_stops_for_route(route_id)
    parent_stops = set()
    for s in stops:
        parent_stops.add(s)
        if s.endswith(("N", "S")):
            parent_stops.add(s[:-1])

    route_dists = []
    for sid in sorted(parent_stops):
        if sid not in stop_pos:
            continue
        slat, slon, sname = stop_pos[sid]

        best = float("inf")
        for poly in polys:
            for plat, plon in poly:
                d = haversine_m(slat, slon, plat, plon)
                if d < best:
                    best = d
                if d < 5:
                    break
            if best < 5:
                break
        all_dists.append(best)
        route_dists.append(best)

        if best > 30:
            # Check raw GTFS distance
            raw_pts = raw_all_coords.get(route_id, [])
            best_raw = float("inf")
            for rlat, rlon in raw_pts:
                d = haversine_m(slat, slon, rlat, rlon)
                if d < best_raw:
                    best_raw = d
                if d < 5:
                    break
            if best_raw > 80:
                cause = "GTFS_GAP"
            elif best > best_raw * 3:
                cause = "PIPELINE_BUG"
            else:
                cause = "OFFSET"
            gap_stops.append((route_id, best, best_raw, cause, sid, sname))

    if route_dists:
        per_route[route_id] = sorted(route_dists)

# Statistics
all_dists.sort()
n = len(all_dists)


def percentile(data, p):
    k = int(p / 100 * (len(data) - 1))
    return data[k]


print("=" * 70)
print("ACCURACY REPORT — RAW GTFS PRESERVED PIPELINE")
print("=" * 70)
print(f"Total route-stop pairs measured: {n}")
print("")
print("Overall statistics:")
print(f"  Average:  {sum(all_dists)/n:7.1f} m")
print(f"  Median:   {percentile(all_dists, 50):7.1f} m")
print(f"  P90:      {percentile(all_dists, 90):7.1f} m")
print(f"  P95:      {percentile(all_dists, 95):7.1f} m")
print(f"  P99:      {percentile(all_dists, 99):7.1f} m")
print(f"  Max:      {max(all_dists):7.1f} m")
print("")
print("Coverage thresholds:")
for t in [5, 10, 20, 30, 50]:
    cnt = sum(1 for d in all_dists if d <= t)
    pct = cnt / n * 100
    print(f"  ≤ {t:2d} m: {pct:6.1f}% ({cnt}/{n})")

print("\nPer-route worst-case (max distance):")
for route_id in sorted(per_route.keys()):
    dists = per_route[route_id]
    mx = max(dists)
    avg = sum(dists) / len(dists)
    cnt = len(dists)
    status = "OK" if mx <= 30 else ("WARN" if mx <= 50 else "BAD")
    print(
        f"  {route_id:>3s}: avg={avg:5.1f}m  max={mx:5.1f}m  stops={cnt:3d}  [{status}]"
    )

if gap_stops:
    print(f"\nStops >30m ({len(gap_stops)}):")
    for route_id, pipe_d, raw_d, cause, sid, sname in sorted(
        gap_stops, key=lambda x: -x[1]
    ):
        print(
            f"  {route_id:>3s} {pipe_d:6.1f}m (raw={raw_d:5.1f}m) {cause:>12s}  {sid:>6s}  {sname}"
        )
else:
    print(f"\nNo stops >30m! All {n} route-stop pairs within 30m.")

# Per-line polyline counts
print("\nPer-line polyline counts:")
total_polys = 0
for ov in sorted(overlays, key=lambda o: o.route_id):
    total_polys += len(ov.polylines)
    print(f"  {ov.route_id:>3s}: {len(ov.polylines)} polylines")
print(f"  Total: {total_polys}")
