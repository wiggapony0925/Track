#!/usr/bin/env python3
"""Quick diagnostic: check all routes have 2+ direction tabs."""

from __future__ import annotations

import json
import ssl
import urllib.request

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

locations = {
    "Midtown": (40.75308, -73.99945),
    "Brooklyn": (40.68508, -73.97745),
    "Flushing": (40.75868, -73.83045),
}

base = "https://track-vkrr.onrender.com/nearby/grouped"

for name, (lat, lon) in locations.items():
    url = f"{base}?lat={lat}&lon={lon}"
    try:
        with urllib.request.urlopen(url, timeout=120, context=ctx) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        print(f"{name}: ERROR {e}")
        continue

    single = [r for r in data if len(r["directions"]) < 2]
    buses = sum(1 for r in data if r["mode"] == "bus")
    trains = sum(1 for r in data if r["mode"] != "bus")
    print(
        f"{name}: {len(data)} routes ({buses} bus, {trains} train) | single-dir: {len(single)}"
    )
    for r in single:
        dirs = [d["direction"] for d in r["directions"]]
        print(f"  {r['mode']} {r['display_name']}: {dirs}")

    if not single:
        print("  ALL routes have 2+ directions!")
