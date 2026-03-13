#!/usr/bin/env python3
"""Check offline bundle polylines for A/C/E near Sutphin."""
import json
import math

SUTPHIN_LAT = 40.7005
SUTPHIN_LON = -73.808

with open("Track/Data/subway_bundle.json") as f:
    data = json.load(f)

routes = data.get("routes", {})
print("Routes type:", type(routes).__name__)
if isinstance(routes, dict):
    print("Available route IDs:", sorted(routes.keys()))

for route_id in ["A", "C", "E"]:
    route_data = routes.get(route_id)
    if route_data is None:
        print(f"{route_id}: NOT IN BUNDLE")
        continue

    # Detect format
    if isinstance(route_data, list) and route_data:
        first = route_data[0]
        if isinstance(first, list):
            # v2: list of branches, each branch is list of {lat, lon}
            total_pts = sum(len(b) for b in route_data)
            min_dist = float("inf")
            for branch in route_data:
                for pt in branch:
                    lat = pt["lat"]
                    lon = pt["lon"]
                    dlat = (lat - SUTPHIN_LAT) * 111000
                    dlon = (lon - SUTPHIN_LON) * 111000 * math.cos(math.radians(SUTPHIN_LAT))
                    d = math.sqrt(dlat * dlat + dlon * dlon)
                    if d < min_dist:
                        min_dist = d
            print(f"{route_id}: v2 | {len(route_data)} branches | {total_pts} pts | closest={min_dist:.0f}m")
        elif isinstance(first, dict):
            # v1: single list of {lat, lon}
            min_dist = float("inf")
            for pt in route_data:
                lat = pt["lat"]
                lon = pt["lon"]
                dlat = (lat - SUTPHIN_LAT) * 111000
                dlon = (lon - SUTPHIN_LON) * 111000 * math.cos(math.radians(SUTPHIN_LAT))
                d = math.sqrt(dlat * dlat + dlon * dlon)
                if d < min_dist:
                    min_dist = d
            print(f"{route_id}: v1 | {len(route_data)} pts | closest={min_dist:.0f}m")
        else:
            print(f"{route_id}: unknown element type {type(first)}")
    else:
        print(f"{route_id}: empty or unknown format")

print()
for stop in data.get("stops", []):
    if "Sutphin" in stop.get("name", ""):
        print(f"Stop: {stop}")
