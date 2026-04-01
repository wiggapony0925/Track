#!/usr/bin/env python3
"""Measure shapes/all response size and timing."""

from __future__ import annotations

import gzip
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.routers.subway import _build_shapes_all_sync

t0 = time.perf_counter()
resp = _build_shapes_all_sync()
t1 = time.perf_counter()
print("Build time: %.1fs" % (t1 - t0))

t2 = time.perf_counter()
data = resp.model_dump(mode="json")
json_str = json.dumps(data)
t3 = time.perf_counter()
print(f"Serialize time: {t3 - t2:.2f}s")
print(f"JSON size: {len(json_str)} bytes ({len(json_str) / 1024 / 1024:.1f} MB)")

t4 = time.perf_counter()
compressed = gzip.compress(json_str.encode(), compresslevel=6)
t5 = time.perf_counter()
print("Gzip time: %.2fs" % (t5 - t4))
print(f"Gzip size: {len(compressed)} bytes ({len(compressed) / 1024:.0f} KB)")
print("Compression ratio: %.1fx" % (len(json_str) / len(compressed)))

print(f"lines: {len(data['lines'])}")
print(f"trunk_polylines: {len(data.get('trunk_polylines', []))}")
total_polys = sum(len(entry["polylines"]) for entry in data["lines"])
print(f"total per-route polylines: {total_polys}")
