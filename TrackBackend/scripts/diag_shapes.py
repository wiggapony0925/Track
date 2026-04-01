#!/usr/bin/env python3
"""Diagnostic: check A/E train shape-stop assignments for Jamaica area."""

from __future__ import annotations

import csv
import json
from collections import defaultdict

DATA_DIR = "app/data"

# Load shape_stops.json
with open(f"{DATA_DIR}/shape_stops.json") as f:
    shape_stops = json.load(f)

# Load stops.txt for names
stop_names = {}
with open(f"{DATA_DIR}/stops.txt") as f:
    for row in csv.DictReader(f):
        stop_names[row["stop_id"]] = row.get("stop_name", "")

# Load trips.txt to get route -> shape mapping
route_shapes = defaultdict(set)
with open(f"{DATA_DIR}/trips.txt") as f:
    for row in csv.DictReader(f):
        route_shapes[row["route_id"]].add(row["shape_id"])

# Jamaica-area stop prefixes
# Sutphin Blvd = G06, Jamaica-179 = F11/G05, Parsons/Archer = G08, etc.
jamaica_prefixes = ["G05", "G06", "G07", "G08", "G09", "F09", "F11", "F12"]

print("=" * 70)
print("A TRAIN: shape_ids with Jamaica-area stops")
print("=" * 70)
a_shapes = route_shapes.get("A", set())
print(f"Total A train shapes: {len(a_shapes)}")
for sid in sorted(a_shapes):
    stops = shape_stops.get(sid, [])
    jamaica = [
        (s, stop_names.get(s, stop_names.get(s[:-1], "?")))
        for s in stops
        if any(s.startswith(p) for p in jamaica_prefixes)
    ]
    if jamaica:
        print(f"\n  SHAPE {sid} ({len(stops)} stops):")
        print(f"    Jamaica stops: {jamaica}")
        # Show last 15 stops
        last_stops = [
            (s, stop_names.get(s, stop_names.get(s[:-1], "?"))) for s in stops[-15:]
        ]
        print(f"    Last 15 stops: {last_stops}")

print()
print("=" * 70)
print("E TRAIN: shape_ids with Jamaica-area stops")
print("=" * 70)
e_shapes = route_shapes.get("E", set())
print(f"Total E train shapes: {len(e_shapes)}")
for sid in sorted(e_shapes):
    stops = shape_stops.get(sid, [])
    jamaica = [
        (s, stop_names.get(s, stop_names.get(s[:-1], "?")))
        for s in stops
        if any(s.startswith(p) for p in jamaica_prefixes)
    ]
    if jamaica:
        print(f"\n  SHAPE {sid} ({len(stops)} stops):")
        print(f"    Jamaica stops: {jamaica}")
        last_stops = [
            (s, stop_names.get(s, stop_names.get(s[:-1], "?"))) for s in stops[-15:]
        ]
        print(f"    Last 15 stops: {last_stops}")

print()
print("=" * 70)
print("C TRAIN: shape_ids with Jamaica-area stops")
print("=" * 70)
c_shapes = route_shapes.get("C", set())
print(f"Total C train shapes: {len(c_shapes)}")
for sid in sorted(c_shapes):
    stops = shape_stops.get(sid, [])
    jamaica = [
        (s, stop_names.get(s, stop_names.get(s[:-1], "?")))
        for s in stops
        if any(s.startswith(p) for p in jamaica_prefixes)
    ]
    if jamaica:
        print(f"\n  SHAPE {sid} ({len(stops)} stops):")
        print(f"    Jamaica stops: {jamaica}")

print()
print("=" * 70)
print("DEDUP CHECK: What _load_route_shapes() keeps for A (direction 0)")
print("=" * 70)

# Simulate _load_route_shapes dedup logic
trips_by_route_dir = defaultdict(lambda: defaultdict(set))
with open(f"{DATA_DIR}/trips.txt") as f:
    for row in csv.DictReader(f):
        trips_by_route_dir[row["route_id"]][int(row.get("direction_id", "0"))].add(
            row["shape_id"]
        )

for route in ["A", "C", "E"]:
    for direction in sorted(trips_by_route_dir[route].keys()):
        sids = trips_by_route_dir[route][direction]
        sorted_sids = sorted(
            sids, key=lambda s: len(shape_stops.get(s, [])), reverse=True
        )

        final = []
        covered = set()
        for sid in sorted_sids:
            stops = set(shape_stops.get(sid, []))
            unique = stops - covered
            if not final or unique:
                final.append(sid)
                covered.update(stops)

        print(
            f"\n  {route} dir={direction}: {len(sids)} raw shapes -> {len(final)} after dedup"
        )
        for sid in final:
            stops = shape_stops.get(sid, [])
            jamaica = [
                s for s in stops if any(s.startswith(p) for p in jamaica_prefixes)
            ]
            term = stops[-1] if stops else "?"
            term_name = stop_names.get(
                term, stop_names.get(term[:-1] if len(term) > 1 else term, "?")
            )
            print(
                f"    {sid}: {len(stops)} stops, terminal={term}({term_name}), jamaica_stops={jamaica}"
            )

# Check shapes.txt for A train shapes that extend to Jamaica area
print()
print("=" * 70)
print("SHAPES.TXT: Geographic extent of A train shapes")
print("=" * 70)
# Sutphin Blvd-Archer Av = approx lat 40.7005, lon -73.808
# Jamaica-179 = approx lat 40.7128, lon -73.7838
import csv  # noqa: E402

shapes_data = defaultdict(list)
with open(f"{DATA_DIR}/shapes.txt") as f:
    for row in csv.DictReader(f):
        sid = row["shape_id"]
        if sid.startswith(("A..", "E..")):
            lat = float(row["shape_pt_lat"])
            lon = float(row["shape_pt_lon"])
            seq = int(row["shape_pt_sequence"])
            shapes_data[sid].append((seq, lat, lon))

for sid in sorted(shapes_data.keys()):
    pts = sorted(shapes_data[sid])
    # Check if any points are east of -73.82 (Jamaica area)
    east_pts = [(s, la, lo) for s, la, lo in pts if lo > -73.82]
    if east_pts:
        last_pt = pts[-1]
        print(
            f"  {sid}: {len(pts)} pts, reaches lon {max(lo for _,_,lo in pts):.4f} (Jamaica area)"
        )
        print(
            f"    Terminal point: seq={last_pt[0]}, lat={last_pt[1]:.4f}, lon={last_pt[2]:.4f}"
        )
    else:
        last_pt = pts[-1]
        print(
            f"  {sid}: {len(pts)} pts, max_lon={max(lo for _,_,lo in pts):.4f} (NOT Jamaica)"
        )
