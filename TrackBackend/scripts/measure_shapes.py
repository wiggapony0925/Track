#!/usr/bin/env python3
"""Measure shapes/all response size and timing."""
import time, json, gzip, sys, os
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
print("Serialize time: %.2fs" % (t3 - t2))
print("JSON size: %d bytes (%.1f MB)" % (len(json_str), len(json_str) / 1024 / 1024))

t4 = time.perf_counter()
compressed = gzip.compress(json_str.encode(), compresslevel=6)
t5 = time.perf_counter()
print("Gzip time: %.2fs" % (t5 - t4))
print("Gzip size: %d bytes (%.0f KB)" % (len(compressed), len(compressed) / 1024))
print("Compression ratio: %.1fx" % (len(json_str) / len(compressed)))

print("lines: %d" % len(data["lines"]))
print("trunk_polylines: %d" % len(data.get("trunk_polylines", [])))
total_polys = sum(len(l["polylines"]) for l in data["lines"])
print("total per-route polylines: %d" % total_polys)
