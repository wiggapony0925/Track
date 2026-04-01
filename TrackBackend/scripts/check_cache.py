#!/usr/bin/env python3
"""Check if backend shapes cache has precision-5 (stale) or precision-6 (current) polylines."""

from __future__ import annotations

import json
import os
import time

path = os.path.join(
    os.path.dirname(__file__), "..", "app", "data", "_cache_shapes_all.json"
)
path = os.path.abspath(path)

if not os.path.exists(path):
    print("No backend cache file found — will be rebuilt on next request.")
    exit()

stat = os.stat(path)
print(f"Cache file: {path}")
print(f"Cache size: {stat.st_size / 1024:.0f} KB")
age_hours = (time.time() - stat.st_mtime) / 3600
print(f"Cache age:  {age_hours:.1f} hours")

with open(path) as f:
    data = json.load(f)

lines = data.get("lines", [])
if not lines:
    print("No lines in cache!")
    exit()

poly = lines[0]["shapes"][0]["polyline"]
line_name = lines[0].get("name", "unknown")

# Decode first coordinate pair
i, lat, lng = 0, 0, 0
for coord_idx in range(2):
    shift, result = 0, 0
    while True:
        b = ord(poly[i]) - 63
        i += 1
        result |= (b & 0x1F) << shift
        shift += 5
        if b < 0x20:
            break
    val = ~(result >> 1) if (result & 1) else (result >> 1)
    if coord_idx == 0:
        lat = val
    else:
        lng = val

c6 = (lat / 1e6, lng / 1e6)
c5 = (lat / 1e5, lng / 1e5)

print(f"\nFirst line: {line_name}")
print(f"Raw integer values: lat={lat}, lng={lng}")
print(f"As precision-6: ({c6[0]:.6f}, {c6[1]:.6f})")
print(f"As precision-5: ({c5[0]:.5f}, {c5[1]:.5f})")

if 39 < c6[0] < 42 and -75 < c6[1] < -72:
    print("\n✅ Cache contains PRECISION-6 polylines (current v9)")
elif 39 < c5[0] < 42 and -75 < c5[1] < -72:
    print(
        "\n❌ Cache contains PRECISION-5 polylines (STALE! Delete and restart backend)"
    )
    print(f"   rm '{path}'")
else:
    print("\n⚠️  Could not determine precision (coordinates don't look like NYC)")
