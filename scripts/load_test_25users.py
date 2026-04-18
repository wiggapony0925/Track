#!/usr/bin/env python3
"""
Load test: Simulates 25 concurrent users hitting /engine/go.

Each "user" sends a trip request with a realistic NYC origin/destination pair,
waits for the response, then sends another (simulating real usage patterns).
Runs 3 rounds per user = 75 total requests across 25 concurrent sessions.

Targets: local backend at http://localhost:8000/engine/go
"""

import asyncio
import json
import time
import statistics
import httpx

BASE_URL = "http://localhost:8000"
ENGINE_GO = f"{BASE_URL}/engine/go"
ENGINE_DIRECT = "http://localhost:8081/go"  # direct to C++ for comparison

NUM_USERS = 25
ROUNDS_PER_USER = 3
TIMEOUT_S = 45

# Realistic NYC origin/destination pairs covering diverse boroughs
# Format: (label, lat, lon)
LOCATIONS = [
    ("Penn Station", 40.7505, -73.9934),
    ("Grand Central", 40.7527, -73.9772),
    ("Times Square", 40.7580, -73.9855),
    ("Union Square", 40.7359, -73.9911),
    ("Brooklyn Heights", 40.6960, -73.9936),
    ("Williamsburg", 40.7081, -73.9571),
    ("Astoria", 40.7720, -73.9301),
    ("Flushing", 40.7614, -73.8300),
    ("College Point", 40.7863, -73.8456),
    ("Jackson Heights", 40.7466, -73.8832),
    ("Coney Island", 40.5749, -73.9817),
    ("Park Slope", 40.6710, -73.9800),
    ("Upper East Side", 40.7736, -73.9566),
    ("Upper West Side", 40.7870, -73.9754),
    ("Harlem", 40.8116, -73.9465),
    ("South Bronx", 40.8176, -73.9209),
    ("Downtown Brooklyn", 40.6928, -73.9903),
    ("Long Island City", 40.7425, -73.9560),
    ("Bushwick", 40.6944, -73.9213),
    ("Forest Hills", 40.7185, -73.8450),
    ("Bay Ridge", 40.6340, -74.0288),
    ("Midtown East", 40.7549, -73.9723),
    ("Wall Street", 40.7074, -74.0113),
    ("East Village", 40.7265, -73.9815),
    ("Prospect Park", 40.6602, -73.9690),
    ("Jamaica", 40.7024, -73.7899),
    ("Flatbush", 40.6410, -73.9590),
    ("Bedford-Stuy", 40.6872, -73.9418),
    ("Sunnyside", 40.7433, -73.9163),
    ("Washington Heights", 40.8400, -73.9390),
]

now_ts = int(time.time())

# Compute service day fields (same as backend's _service_day_context)
from datetime import datetime, timezone, timedelta, time as time_value
NY_TZ = timezone(timedelta(hours=-4))  # EDT
now_ny = datetime.fromtimestamp(now_ts, tz=NY_TZ)
service_date = now_ny.date()
service_day_yyyymmdd = int(service_date.strftime("%Y%m%d"))
service_weekday = service_date.weekday()
midnight_ny = datetime.combine(service_date, time_value.min, tzinfo=NY_TZ)
service_day_midnight_ts = int(midnight_ny.timestamp())

def make_payload(origin_idx: int, dest_idx: int) -> dict:
    o = LOCATIONS[origin_idx % len(LOCATIONS)]
    d = LOCATIONS[dest_idx % len(LOCATIONS)]
    return {
        "origin": {"label": o[0], "lat": o[1], "lon": o[2]},
        "destination": {"label": d[0], "lat": d[1], "lon": d[2]},
        "depart_at_ts": now_ts,
        "query_ts": now_ts,
        "service_day_yyyymmdd": service_day_yyyymmdd,
        "service_weekday": service_weekday,
        "service_day_midnight_ts": service_day_midnight_ts,
        "max_transfers": 2,
        "max_origin_walk_m": 1200,
        "max_destination_walk_m": 1200,
        "max_transfer_walk_m": 800,
        "search_window_minutes": 180,
        "num_itineraries": 4,
        "modes": ["subway", "bus"],
        "now_ts": now_ts,
        "record_recent": False,
    }


async def user_session(
    user_id: int,
    client: httpx.AsyncClient,
    results: list,
    target: str = "backend",
):
    url = ENGINE_GO if target == "backend" else ENGINE_DIRECT
    for r in range(ROUNDS_PER_USER):
        origin_idx = (user_id * ROUNDS_PER_USER + r) % len(LOCATIONS)
        dest_idx = (origin_idx + user_id + 3) % len(LOCATIONS)
        if origin_idx == dest_idx:
            dest_idx = (dest_idx + 1) % len(LOCATIONS)

        payload = make_payload(origin_idx, dest_idx)
        start = time.monotonic()
        try:
            resp = await client.post(url, json=payload, timeout=TIMEOUT_S)
            elapsed_ms = (time.monotonic() - start) * 1000
            status = resp.status_code
            trip_count = 0
            if status == 200:
                data = resp.json()
                if target == "backend":
                    primary = 1 if data.get("primary_trip") else 0
                    alts = len(data.get("alternatives", []))
                    trip_count = primary + alts
                else:
                    primary = 1 if data.get("primary_trip") else 0
                    alts = len(data.get("alternatives", []))
                    trip_count = primary + alts
            results.append({
                "user": user_id,
                "round": r,
                "status": status,
                "ms": elapsed_ms,
                "trips": trip_count,
                "origin": LOCATIONS[origin_idx][0],
                "dest": LOCATIONS[dest_idx][0],
            })
        except Exception as e:
            elapsed_ms = (time.monotonic() - start) * 1000
            results.append({
                "user": user_id,
                "round": r,
                "status": 0,
                "ms": elapsed_ms,
                "trips": 0,
                "origin": LOCATIONS[origin_idx][0],
                "dest": LOCATIONS[dest_idx][0],
                "error": str(e),
            })
        # Small jitter between rounds (simulates user reading results)
        await asyncio.sleep(0.1 + (user_id % 5) * 0.05)


async def run_load_test(target: str = "backend"):
    label = "Backend (Python → C++)" if target == "backend" else "Engine (C++ direct)"
    print(f"\n{'='*60}")
    print(f"  LOAD TEST: {label}")
    print(f"  {NUM_USERS} concurrent users × {ROUNDS_PER_USER} rounds = {NUM_USERS * ROUNDS_PER_USER} requests")
    print(f"{'='*60}\n")

    results = []
    async with httpx.AsyncClient() as client:
        wall_start = time.monotonic()
        tasks = [
            user_session(uid, client, results, target)
            for uid in range(NUM_USERS)
        ]
        await asyncio.gather(*tasks)
        wall_time = time.monotonic() - wall_start

    # ── Analysis ──
    successes = [r for r in results if r["status"] == 200]
    failures = [r for r in results if r["status"] != 200]
    latencies = [r["ms"] for r in successes]
    trip_counts = [r["trips"] for r in successes]

    print(f"  Wall time:       {wall_time:.1f}s")
    print(f"  Total requests:  {len(results)}")
    print(f"  Successes:       {len(successes)} ({len(successes)/len(results)*100:.0f}%)")
    print(f"  Failures:        {len(failures)}")
    if failures:
        for f in failures[:5]:
            err = f.get("error", f"HTTP {f['status']}")
            print(f"    ⚠ User {f['user']} R{f['round']}: {f['origin']}→{f['dest']} — {err}")

    if latencies:
        print(f"\n  Latency (ms):")
        print(f"    Min:           {min(latencies):.0f}")
        print(f"    Median (p50):  {statistics.median(latencies):.0f}")
        print(f"    p90:           {sorted(latencies)[int(len(latencies)*0.9)]:.0f}")
        print(f"    p95:           {sorted(latencies)[int(len(latencies)*0.95)]:.0f}")
        print(f"    p99:           {sorted(latencies)[min(int(len(latencies)*0.99), len(latencies)-1)]:.0f}")
        print(f"    Max:           {max(latencies):.0f}")
        print(f"    Mean:          {statistics.mean(latencies):.0f}")
        if len(latencies) > 1:
            print(f"    Stdev:         {statistics.stdev(latencies):.0f}")

    if trip_counts:
        empty = sum(1 for t in trip_counts if t == 0)
        print(f"\n  Trip results:")
        print(f"    Mean trips:    {statistics.mean(trip_counts):.1f}")
        print(f"    Empty (0):     {empty}/{len(successes)} ({empty/len(successes)*100:.0f}%)")

    throughput = len(results) / wall_time if wall_time > 0 else 0
    print(f"\n  Throughput:      {throughput:.1f} req/s")

    # Show slowest 5
    slowest = sorted(results, key=lambda r: r["ms"], reverse=True)[:5]
    print(f"\n  Slowest 5 requests:")
    for s in slowest:
        status_str = f"HTTP {s['status']}" if s['status'] != 200 else f"{s['trips']} trips"
        print(f"    {s['ms']:>7.0f}ms  {s['origin']:>20s} → {s['dest']:<20s}  [{status_str}]")

    return results


async def main():
    # Phase 1: Warm up with a single request
    print("Warming up...")
    async with httpx.AsyncClient() as client:
        payload = make_payload(0, 5)
        try:
            resp = await client.post(ENGINE_GO, json=payload, timeout=30)
            print(f"  Warmup: HTTP {resp.status_code} ({len(resp.content)} bytes)")
        except Exception as e:
            print(f"  Warmup failed: {e}")
            return

    # Phase 2: Direct C++ engine test (bypasses Python overhead)
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.get("http://localhost:8081/health", timeout=3)
            if resp.status_code == 200:
                await run_load_test("engine")
    except Exception:
        print("  (Skipping direct engine test — not reachable)")

    # Phase 3: Full-stack backend test
    await run_load_test("backend")


if __name__ == "__main__":
    asyncio.run(main())
