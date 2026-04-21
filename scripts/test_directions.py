#!/usr/bin/env python3
"""Test direction output for problem bus routes."""
import httpx, sys

BASE = "http://localhost:8000"

# Two test locations: near M12 (Hudson/Chelsea), and broader midtown
LOCATIONS = [
    ("M12 corridor", 40.7400, -74.0070, 600),
    ("Midtown West", 40.7580, -73.9855, 800),
    ("Upper West Side", 40.7870, -73.9754, 600),
]

TARGET = {"M12", "M11", "M14A", "M15", "M14D", "M20", "M7"}

any_found = False
for label, lat, lon, radius in LOCATIONS:
    resp = httpx.get(f"{BASE}/nearby/grouped", params={"lat": lat, "lon": lon, "radius": radius}, timeout=20)
    if resp.status_code != 200:
        print(f"[{label}] HTTP {resp.status_code}")
        continue

    data = resp.json()
    groups = data if isinstance(data, list) else data.get("groups", [])

    for g in groups:
        display = g.get("display_name", g.get("route_id", "?"))
        if display not in TARGET:
            continue
        dirs = g.get("directions", [])
        any_found = True
        print(f"\n{'='*55}")
        print(f"[{label}] Route: {display}  →  {len(dirs)} direction tab(s)")
        for i, d in enumerate(dirs):
            key = d.get("direction", "?")
            dest = d.get("destination", "")
            arrivals = d.get("arrivals", [])
            real = [a for a in arrivals if a.get("minutes_away", 999) < 900]
            flag = ""
            if key.lower() in ("outbound", "inbound"):
                flag = "  ⚠️  GENERIC PLACEHOLDER"
            print(f"  [{i}] direction='{key}'  destination='{dest}'  arrivals={len(arrivals)}  real={len(real)}{flag}")

if not any_found:
    print("No target routes found near any test location.")
    sys.exit(1)

print("\n✅ Done")
