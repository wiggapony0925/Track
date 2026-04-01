#!/usr/bin/env python3
"""Diagnostic: Check for overlapping same-colour polylines in the system map output."""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import asyncio
from collections import defaultdict

from app.routers.subway import subway_shapes_all
from app.utils.polyline_utils import decode_polyline

# Same trunk groups as server/client
TRUNK_GROUPS = [
    ["1", "2", "3"],
    ["4", "5", "6", "6X"],
    ["7", "7X"],
    ["A", "C", "E"],
    ["B", "D", "F", "FX", "M"],
    ["G"],
    ["J", "Z"],
    ["L"],
    ["N", "Q", "R", "W"],
    ["S"],
    ["SI"],
]

ROUTE_TO_TRUNK = {}
for gi, group in enumerate(TRUNK_GROUPS):
    for rid in group:
        ROUTE_TO_TRUNK[rid] = gi


async def main():
    response = await subway_shapes_all()

    # Group polylines by trunk colour
    trunk_polylines: dict[int, list[tuple[str, list[tuple[float, float]]]]] = (
        defaultdict(list)
    )

    for overlay in response.lines:
        tid = ROUTE_TO_TRUNK.get(overlay.route_id, -1)
        for enc in overlay.polylines:
            decoded = decode_polyline(enc)
            if len(decoded) >= 2:
                trunk_polylines[tid].append((overlay.route_id, decoded))

    print("=" * 70)
    print("SYSTEM MAP OVERLAP DIAGNOSTIC")
    print("=" * 70)

    # For each trunk group, check how many polylines there are and how much they overlap
    cell_size = 0.0005  # ~55m at NYC

    for gi, group in enumerate(TRUNK_GROUPS):
        polys = trunk_polylines.get(gi, [])
        if not polys:
            continue

        routes_seen = {p[0] for p in polys}
        total_pts = sum(len(p[1]) for p in polys)

        # Check overlap between polylines in this group
        # Build grid per polyline
        grids = []
        for route_id, coords in polys:
            grid = set()
            for lat, lon in coords:
                cx, cy = int(lat / cell_size), int(lon / cell_size)
                grid.add((cx, cy))
            grids.append((route_id, grid, len(coords)))

        overlap_pairs = []
        for i in range(len(grids)):
            for j in range(i + 1, len(grids)):
                r1, g1, _n1 = grids[i]
                r2, g2, _n2 = grids[j]
                shared = len(g1 & g2)
                ratio1 = shared / max(1, len(g1))
                ratio2 = shared / max(1, len(g2))
                if shared > 5:  # more than 5 cells overlap
                    overlap_pairs.append((r1, r2, shared, ratio1, ratio2))

        label = "/".join(group)
        print(
            f"\n{label}: {len(polys)} polylines from routes {sorted(routes_seen)}, {total_pts} total points"
        )

        if overlap_pairs:
            print(f"  ⚠️  {len(overlap_pairs)} overlapping polyline pairs:")
            for r1, r2, shared, rat1, rat2 in sorted(
                overlap_pairs, key=lambda x: -x[2]
            ):
                print(
                    f"    {r1} ↔ {r2}: {shared} shared cells ({rat1:.0%} of {r1}, {rat2:.0%} of {r2})"
                )
        else:
            print("  ✅ No significant overlap")

    # Check direction-1 extras (raw GTFS, no offset)
    print("\n" + "=" * 70)
    print("DIRECTION-1 EXTRAS (added AFTER pipeline — NO offset)")
    print("=" * 70)

    # We can check by comparing the total polyline count per route with
    # what direction-0 would produce
    for overlay in response.lines:
        count = len(overlay.polylines)
        if count > 3:  # routes with many polylines likely have dir-1 extras
            print(f"  {overlay.route_id}: {count} polylines (may include dir-1 extras)")


asyncio.run(main())
