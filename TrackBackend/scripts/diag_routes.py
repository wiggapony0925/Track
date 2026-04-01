from __future__ import annotations

import json

with open("Track/Data/subway_bundle.json") as f:
    data = json.load(f)

routes = data["routes"]

for r in ["A", "C", "E"]:
    branches = routes.get(r, [])
    print(f"=== Route {r} ({len(branches)} branch(es)) ===")
    for i, branch in enumerate(branches):
        if isinstance(branch, dict):
            stops = branch.get("stops", [])
            coords = branch.get("coordinates", branch.get("shape", []))
            print(f"  Branch {i}: stops={len(stops)}, coords={len(coords)}")
            print(f"    keys: {list(branch.keys())}")
            for s in stops[-5:]:
                if isinstance(s, dict):
                    print(f'    Stop: {s.get("name","?")} ({s.get("id","?")})')
                else:
                    print(f"    Stop: {s}")
        elif isinstance(branch, list):
            print(f"  Branch {i}: list of {len(branch)} items")
            if len(branch) > 0 and isinstance(branch[0], dict):
                print(f"    First item keys: {list(branch[0].keys())}")
            elif len(branch) > 0 and isinstance(branch[0], list):
                print(
                    f"    Looks like coordinate arrays, first has {len(branch[0])} items"
                )
    print()

# Check where A route data goes geographically
# Sutphin Blvd area is around lat 40.700-40.710, lon -73.800 to -73.815
print("=== Checking if A train polylines pass near Sutphin (lat~40.70, lon~-73.81) ===")
for r in ["A", "C", "E"]:
    branches = routes.get(r, [])
    for i, branch in enumerate(branches):
        if isinstance(branch, list):
            for j, segment in enumerate(branch):
                if isinstance(segment, list):
                    for pt in segment:
                        if isinstance(pt, list) and len(pt) >= 2:
                            lat, lon = pt[0], pt[1]
                            if 40.695 < lat < 40.715 and -73.820 < lon < -73.795:
                                print(
                                    f"  Route {r} branch {i} seg {j}: lat={lat}, lon={lon} NEAR SUTPHIN"
                                )
                                break
        elif isinstance(branch, dict):
            coords = branch.get("coordinates", branch.get("shape", []))
            if isinstance(coords, list):
                for j, pt in enumerate(coords):
                    if isinstance(pt, list) and len(pt) >= 2:
                        lat, lon = pt[0], pt[1]
                        if 40.695 < lat < 40.715 and -73.820 < lon < -73.795:
                            print(
                                f"  Route {r} branch {i}: coord {j}: lat={lat}, lon={lon} NEAR SUTPHIN"
                            )
                            break
                    elif isinstance(pt, dict):
                        lat = pt.get("lat", pt.get("latitude", 0))
                        lon = pt.get("lon", pt.get("longitude", 0))
                        if 40.695 < lat < 40.715 and -73.820 < lon < -73.795:
                            print(
                                f"  Route {r} branch {i}: coord {j}: lat={lat}, lon={lon} NEAR SUTPHIN"
                            )
                            break
