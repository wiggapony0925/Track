#!/usr/bin/env python3
"""Broad scan: check ALL bus route groups from /nearby/grouped for 'Outbound'/'Inbound' direction tabs."""
import httpx

BASE = "http://localhost:8000"

# Check multiple locations to get good coverage
LOCATIONS = [
    ("Hudson/Chelsea", 40.7400, -74.0070, 800),
    ("Midtown West", 40.7580, -73.9855, 800),
    ("Upper West", 40.7870, -73.9754, 800),
    ("Astoria", 40.7726, -73.9299, 800),
    ("Flushing", 40.7590, -73.8303, 800),
    ("Bronx Hub", 40.8173, -73.9244, 800),
    ("Flatbush", 40.6501, -73.9496, 800),
]

generic_keys = {"outbound", "inbound"}
found_generic = []
total_groups = 0
total_dirs = 0

for label, lat, lon, radius in LOCATIONS:
    try:
        resp = httpx.get(f"{BASE}/nearby/grouped", params={"lat": lat, "lon": lon, "radius": radius}, timeout=20)
    except Exception as e:
        print(f"[{label}] ERROR: {e}")
        continue

    if resp.status_code != 200:
        print(f"[{label}] HTTP {resp.status_code}")
        continue

    data = resp.json()
    groups = data if isinstance(data, list) else data.get("groups", [])

    for g in groups:
        mode = g.get("mode", "")
        if mode != "bus":
            continue
        total_groups += 1
        display = g.get("display_name", g.get("route_id", "?"))
        for d in g.get("directions", []):
            total_dirs += 1
            key = d.get("direction", "")
            if key.lower() in generic_keys:
                real = [a for a in d.get("arrivals", []) if a.get("minutes_away", 999) < 900]
                found_generic.append({
                    "location": label,
                    "route": display,
                    "direction": key,
                    "arrivals": len(d.get("arrivals", [])),
                    "real": len(real),
                })

print(f"\nScanned {total_groups} bus groups, {total_dirs} direction tabs across {len(LOCATIONS)} locations")

if found_generic:
    print(f"\n⚠️  Found {len(found_generic)} generic placeholder direction(s):")
    for item in found_generic:
        print(f"  [{item['location']}] {item['route']}: '{item['direction']}' — {item['real']} real / {item['arrivals']} total arrivals")
else:
    print("\n✅ Zero 'Outbound'/'Inbound' generic direction tabs found across all bus routes!")
