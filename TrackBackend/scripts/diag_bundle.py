#!/usr/bin/env python3
"""Check subway_bundle.json for A/E branch data."""

from __future__ import annotations

import json
import math


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


SUTPHIN_LAT = 40.7005
SUTPHIN_LON = -73.8080

with open("Track/Data/subway_bundle.json") as f:
    b = json.load(f)

routes = b.get("routes", {})
print("Bundle version:", b.get("version"))

for route_id in ["A", "C", "E"]:
    branches = routes.get(route_id, [])
    if not branches:
        print(f"{route_id}: MISSING from bundle")
        continue

    # Check if v2 (list of lists of dicts) or v1 (list of dicts)
    if isinstance(branches[0], list):
        print(f"\n{route_id}: {len(branches)} branches (v2 format)")
        for i, branch in enumerate(branches):
            # Find closest point to Sutphin
            min_dist = float("inf")
            for pt in branch:
                lat = pt["lat"] if isinstance(pt, dict) else pt[0]
                lon = pt["lon"] if isinstance(pt, dict) else pt[1]
                d = haversine_m(lat, lon, SUTPHIN_LAT, SUTPHIN_LON)
                if d < min_dist:
                    min_dist = d
            last = branch[-1] if branch else "?"
            print(
                f"  branch {i}: {len(branch)} pts, min_dist_sutphin={min_dist:.0f}m, terminal={last}"
            )
    else:
        print(f"\n{route_id}: {len(branches)} pts (v1 format)")
        min_dist = float("inf")
        for pt in branches:
            lat = pt["lat"] if isinstance(pt, dict) else pt[0]
            lon = pt["lon"] if isinstance(pt, dict) else pt[1]
            d = haversine_m(lat, lon, SUTPHIN_LAT, SUTPHIN_LON)
            if d < min_dist:
                min_dist = d
        print(f"  min_dist_sutphin={min_dist:.0f}m")
