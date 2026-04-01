#!/usr/bin/env python3
"""Check the processed stations response for JSON issues."""

from __future__ import annotations

import json
import math

from app.services.mapping.corridor_pipeline import get_processed_stops

stops = get_processed_stops()
print(f"Total stops: {len(stops)}")

nan_count = 0
inf_count = 0
for s in stops:
    for p in s.get("positions", []):
        lat = p.get("lat", 0)
        lon = p.get("lon", 0)
        if math.isnan(lat) or math.isnan(lon):
            nan_count += 1
            print(f"  NaN: station={s['station_id']}, route={p['route_id']}")
        if math.isinf(lat) or math.isinf(lon):
            inf_count += 1
            print(f"  Inf: station={s['station_id']}, route={p['route_id']}")

print(f"NaN: {nan_count}, Inf: {inf_count}")

payload = {"stations": stops}
raw = json.dumps(payload)
if "NaN" in raw:
    print("WARNING: NaN in JSON!")
if "Infinity" in raw:
    print("WARNING: Infinity in JSON!")
print(f"JSON size: {len(raw)} bytes")

if stops:
    print("\nSample:")
    print(json.dumps(stops[0], indent=2))

# Check all keys match expected schema
expected_keys = {"station_id", "name", "is_transfer", "positions"}
pos_keys = {"route_id", "lat", "lon"}
for s in stops:
    extra = set(s.keys()) - expected_keys
    missing = expected_keys - set(s.keys())
    if extra or missing:
        print(f"Station {s.get('station_id')}: extra={extra}, missing={missing}")
        break
    for p in s.get("positions", []):
        pextra = set(p.keys()) - pos_keys
        pmissing = pos_keys - set(p.keys())
        if pextra or pmissing:
            print(f"Position: extra={pextra}, missing={pmissing}")
            break
else:
    print("\nAll stations match expected schema.")
