#!/usr/bin/env python3
"""Simulate the exact iOS app cold launch: 4 parallel API calls."""
import httpx
import time
import concurrent.futures
import sys

BASE = "http://127.0.0.1:8000"
LAT, LON, RAD = 40.7505, -73.9934, 8047

CALLS = [
    ("/nearby",         {"lat": LAT, "lon": LON, "radius": RAD}),
    ("/nearby/grouped", {"lat": LAT, "lon": LON, "radius": RAD}),
    ("/bus/nearby",     {"lat": LAT, "lon": LON, "radius": RAD}),
    ("/alerts",         None),
]

OUT_FILE = "/tmp/launch_sim_out.txt"
lines = []

def log(msg):
    print(msg, flush=True)
    lines.append(msg)


def fetch(args):
    path, params = args
    c = httpx.Client(timeout=60)
    t0 = time.perf_counter()
    r = c.get(f"{BASE}{path}", params=params)
    t = time.perf_counter() - t0
    c.close()
    return path, t, r.status_code, len(r.content)


def run_batch(label):
    t_start = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
        results = list(ex.map(fetch, CALLS))
    wall = time.perf_counter() - t_start

    log(f"\n=== {label} ===")
    for path, t, status, nbytes in sorted(results, key=lambda x: -x[1]):
        bstr = f"{nbytes:>10,} bytes" if nbytes else ""
        log(f"  {path:<20s} {t:.3f}s  [{status}]  {bstr}")
    bottleneck = max(results, key=lambda x: x[1])
    log(f"\n  Wall time (parallel): {wall:.3f}s")
    log(f"  Bottleneck:           {bottleneck[1]:.3f}s  ({bottleneck[0]})")
    return wall, results


# Clear caches first
log("Clearing all caches...")
r = httpx.post(f"{BASE}/admin/cache/clear")
log(f"  {r.json()}")

wall_cold, _ = run_batch("COLD APP LAUNCH (4 parallel, radius=8047)")
wall_cached, _ = run_batch("CACHED (same calls, 2nd launch)")

log(f"\n{'='*60}")
log(f"  Cold launch backend time:   {wall_cold:.3f}s")
log(f"  Cached launch backend time: {wall_cached:.3f}s")
log(f"  Speedup:                    {wall_cold/max(wall_cached,0.001):.0f}x")
log(f"\n  Your measured app launch: 4.008s")
log(f"  Backend portion (cold):   ~{wall_cold:.1f}s")
log(f"  iOS overhead (est):       ~{max(0, 4.008 - wall_cold):.1f}s")
log(f"    (auth resolve, GPS wait, SwiftUI render, JSON decode)")

with open(OUT_FILE, "w") as f:
    f.write("\n".join(lines) + "\n")
log(f"\nSaved to {OUT_FILE}")
