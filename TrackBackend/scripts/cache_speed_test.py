#!/usr/bin/env python3
"""
cache_speed_test.py — THE main backend speed & cache test.

Simulates 50 users across all NYC boroughs hitting every API endpoint,
measures cold vs cached response times, tests Venn-diagram cache sharing
between overlapping radii, and outputs a comprehensive results file.

Usage:
    cd TrackBackend
    python scripts/cache_speed_test.py

    # Or from project root:
    .venv/bin/python TrackBackend/scripts/cache_speed_test.py

Output:
    TrackBackend/logs/cache_speed_test_results.txt

Requires the server to be running on http://127.0.0.1:8000
"""

from __future__ import annotations

import asyncio
import json
import random
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import httpx
except ImportError:
    print("ERROR: httpx not installed. Run: pip install httpx")
    sys.exit(1)

# ═══════════════════════════════════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════════════════════════════════

BASE = "http://127.0.0.1:8000"
TIMEOUT = 60.0
NUM_USERS = 50
RADIUS = 800

# 10 locations across NYC — 2 per borough, realistic user positions
LOCATIONS = [
    # Manhattan
    ("Manhattan – Penn Station",       40.7505, -73.9934),
    ("Manhattan – Times Square",       40.7580, -73.9855),
    ("Manhattan – Wall Street",        40.7074, -74.0113),
    # Brooklyn
    ("Brooklyn – Downtown",            40.6892, -73.9857),
    ("Brooklyn – Williamsburg",        40.7081, -73.9571),
    # Queens
    ("Queens – Jackson Heights",       40.7466, -73.8913),
    ("Queens – Flushing",              40.7614, -73.8300),
    # Bronx
    ("Bronx – Yankee Stadium",         40.8296, -73.9262),
    ("Bronx – Fordham",                40.8614, -73.8877),
    # Staten Island
    ("Staten Island – St George",      40.6433, -74.0735),
]

# Known route/stop IDs for targeted endpoint tests
SUBWAY_LINES = ["A", "1", "7", "L", "G", "N", "F", "B"]
BUS_ROUTES = ["MTA NYCT_M15", "MTA NYCT_B44", "MTA NYCT_Q58", "MTABC_BX1"]
BUS_STOP_IDS = ["MTA_305168", "MTA_308209", "MTA_504185"]
LIRR_STATION_IDS = ["LIRR_56", "LIRR_15"]
MNR_STATION_IDS = ["MNR_1", "MNR_48"]

# ═══════════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════════

def _fmt(seconds: float) -> str:
    """Format seconds to a readable string."""
    if seconds < 0.001:
        return f"{seconds*1_000_000:.0f}µs"
    if seconds < 1.0:
        return f"{seconds*1000:.1f}ms"
    return f"{seconds:.3f}s"


def _pct(cached: float, cold: float) -> str:
    if cold <= 0:
        return "N/A"
    ratio = cold / max(cached, 0.0001)
    return f"{ratio:.0f}x faster"


def _stats(times: list[float]) -> dict:
    if not times:
        return {"min": 0, "max": 0, "avg": 0, "median": 0, "p95": 0, "p99": 0}
    s = sorted(times)
    return {
        "min": s[0],
        "max": s[-1],
        "avg": statistics.mean(s),
        "median": statistics.median(s),
        "p95": s[int(len(s) * 0.95)] if len(s) >= 20 else s[-1],
        "p99": s[int(len(s) * 0.99)] if len(s) >= 100 else s[-1],
    }


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.results: list[dict] = []

    def add(self, label: str, time_s: float, status: int, detail: str = ""):
        self.results.append({
            "label": label,
            "time_s": time_s,
            "status": status,
            "detail": detail,
        })


def cache_clear(client: httpx.Client) -> dict:
    """Clear all server-side caches via admin endpoint. Returns counts."""
    try:
        r = client.post(f"{BASE}/admin/cache/clear")
        return r.json() if r.status_code == 200 else {}
    except Exception:
        return {}


def _cell_jitter(lat: float, lon: float, decimals: int = 3) -> tuple[float, float]:
    """Return a jittered (lat, lon) guaranteed to stay in the same grid cell.

    Computes the cell center, then adds random jitter within ±40% of the
    cell width (±0.0004 for 3 decimals), ensuring no cell-boundary crossing.
    """
    factor = 10 ** decimals
    center_lat = round(lat * factor) / factor
    center_lon = round(lon * factor) / factor
    half_cell = 0.4 / factor  # 40% of cell width — safe margin
    return (
        center_lat + random.uniform(-half_cell, half_cell),
        center_lon + random.uniform(-half_cell, half_cell),
    )


# ═══════════════════════════════════════════════════════════════════════
# TEST SECTIONS
# ═══════════════════════════════════════════════════════════════════════

def timed_get(client: httpx.Client, url: str, params: dict | None = None) -> tuple[float, int, int]:
    """GET with timing. Returns (seconds, status_code, response_bytes)."""
    t0 = time.perf_counter()
    try:
        r = client.get(url, params=params)
        elapsed = time.perf_counter() - t0
        return elapsed, r.status_code, len(r.content)
    except Exception as exc:
        elapsed = time.perf_counter() - t0
        return elapsed, 0, 0


def test_1_endpoint_inventory(c: httpx.Client, out: list[str]):
    """Test every endpoint once — cold call — to verify they all work."""
    # Clear all caches (including startup warmup) for true cold measurement
    cache_clear(c)

    out.append("")
    out.append("=" * 80)
    out.append("TEST 1: ENDPOINT INVENTORY — Every API endpoint, cold call")
    out.append("=" * 80)

    lat, lon = 40.7505, -73.9934  # Penn Station
    endpoints = [
        # (name, path, params)
        ("GET /nearby",                  f"{BASE}/nearby",                  {"lat": lat, "lon": lon, "radius": RADIUS}),
        ("GET /nearby/grouped",          f"{BASE}/nearby/grouped",          {"lat": lat, "lon": lon, "radius": RADIUS}),
        ("GET /nearby/grouped?mode=subway", f"{BASE}/nearby/grouped",      {"lat": lat, "lon": lon, "radius": RADIUS, "mode": "subway"}),
        ("GET /nearby/grouped?mode=bus", f"{BASE}/nearby/grouped",         {"lat": lat, "lon": lon, "radius": RADIUS, "mode": "bus"}),
        ("GET /nearby/grouped?mode=lirr", f"{BASE}/nearby/grouped",       {"lat": lat, "lon": lon, "radius": RADIUS, "mode": "lirr"}),
        ("GET /nearby/grouped?mode=mnr", f"{BASE}/nearby/grouped",        {"lat": lat, "lon": lon, "radius": RADIUS, "mode": "mnr"}),
        ("GET /subway/A",               f"{BASE}/subway/A",                None),
        ("GET /subway/1",               f"{BASE}/subway/1",                None),
        ("GET /subway/7",               f"{BASE}/subway/7",                None),
        ("GET /subway/L",               f"{BASE}/subway/L",                None),
        ("GET /subway/shapes/all",       f"{BASE}/subway/shapes/all",      None),
        ("GET /subway/stations/all",     f"{BASE}/subway/stations/all",    None),
        ("GET /subway/stations/nearby",  f"{BASE}/subway/stations/nearby", {"lat": lat, "lon": lon, "radius": RADIUS}),
        ("GET /subway/shape/A",          f"{BASE}/subway/shape/A",         None),
        ("GET /bus/routes",              f"{BASE}/bus/routes",              None),
        ("GET /bus/nearby",              f"{BASE}/bus/nearby",              {"lat": lat, "lon": lon, "radius": RADIUS}),
        ("GET /bus/stops/MTA NYCT_M15",  f"{BASE}/bus/stops/MTA NYCT_M15", None),
        ("GET /bus/live/MTA_305168",     f"{BASE}/bus/live/MTA_305168",    None),
        ("GET /bus/vehicles/MTA NYCT_M15", f"{BASE}/bus/vehicles/MTA NYCT_M15", None),
        ("GET /bus/route-shape/MTA NYCT_M15", f"{BASE}/bus/route-shape/MTA NYCT_M15", None),
        ("GET /bus/schedule/MTA NYCT_M15", f"{BASE}/bus/schedule/MTA NYCT_M15", None),
        ("GET /lirr",                    f"{BASE}/lirr",                   {"lat": lat, "lon": lon}),
        ("GET /lirr/shapes/all",         f"{BASE}/lirr/shapes/all",        None),
        ("GET /mnr",                     f"{BASE}/mnr",                    {"lat": lat, "lon": lon}),
        ("GET /mnr/shapes/all",          f"{BASE}/mnr/shapes/all",         None),
        ("GET /alerts",                  f"{BASE}/alerts",                  None),
        ("GET /accessibility",           f"{BASE}/accessibility",           None),
        ("GET /predict/delay",           f"{BASE}/predict/delay",           {"minutes_away": 5, "route_id": "A", "hour": 8}),
    ]

    pass_count = 0
    fail_count = 0
    times = []
    for name, url, params in endpoints:
        elapsed, status, nbytes = timed_get(c, url, params)
        ok = 200 <= status < 300
        if ok:
            pass_count += 1
        else:
            fail_count += 1
        times.append(elapsed)
        icon = "✅" if ok else "❌"
        out.append(f"  {icon} {name:<45s} {status:>3d}  {_fmt(elapsed):>10s}  {nbytes:>7,d} bytes")

    out.append(f"\n  Summary: {pass_count} passed, {fail_count} failed, "
               f"total {_fmt(sum(times))}, avg {_fmt(statistics.mean(times))}")
    return pass_count, fail_count


def test_2_cold_vs_cached(c: httpx.Client, out: list[str]):
    """Hit the same endpoint cold then cached to measure cache speedup."""
    # Clear so cold calls are truly cold (not warmed by Test 1)
    cache_clear(c)

    out.append("")
    out.append("=" * 80)
    out.append("TEST 2: COLD vs CACHED — Response-level cache verification")
    out.append("=" * 80)
    out.append("  Each test: cold fetch → immediate re-fetch (should be cached)")
    out.append("")

    tests = [
        ("/nearby/grouped",          {"lat": 40.6892, "lon": -73.9857, "radius": RADIUS}),
        ("/nearby/grouped?mode=subway", {"lat": 40.7081, "lon": -73.9571, "radius": RADIUS, "mode": "subway"}),
        ("/nearby/grouped?mode=bus", {"lat": 40.7466, "lon": -73.8913, "radius": RADIUS, "mode": "bus"}),
        ("/subway/A",                None),
        ("/subway/1",                None),
        ("/bus/routes",              None),
        ("/bus/live/MTA_305168",     None),
        ("/subway/shapes/all",       None),
        ("/alerts",                  None),
    ]

    total_cold = 0.0
    total_cached = 0.0
    for path, params in tests:
        # Cold
        cold_t, cold_s, _ = timed_get(c, f"{BASE}{path}", params)
        # Cached (immediate)
        cache_t, cache_s, _ = timed_get(c, f"{BASE}{path}", params)
        total_cold += cold_t
        total_cached += cache_t
        speedup = _pct(cache_t, cold_t)
        out.append(f"  {path:<40s}  cold={_fmt(cold_t):>10s}  cached={_fmt(cache_t):>10s}  {speedup}")

    out.append(f"\n  Totals: cold={_fmt(total_cold)}, cached={_fmt(total_cached)}, "
               f"overall {_pct(total_cached, total_cold)}")


def test_3_venn_diagram_cache_sharing(c: httpx.Client, out: list[str]):
    """Simulate users in overlapping radii — the Venn diagram test.

    Three users near Times Square:
      User A: center point (cold)
      User B: same ~111m grid cell (response cache hit)
      User C: adjacent grid cell, overlapping radius (per-stop cache hit)
      User D: far away Brooklyn (completely cold)
    """
    # Clear so User A is truly cold
    cache_clear(c)

    out.append("")
    out.append("=" * 80)
    out.append("TEST 3: VENN DIAGRAM — Overlapping radius cache sharing")
    out.append("=" * 80)
    out.append("  User A = cold fetch, User B = same grid cell, User C = adjacent cell,")
    out.append("  User D = completely different area (Brooklyn)")
    out.append("")

    # Pick a center and compute grid cells
    center_lat, center_lon = 40.7582, -73.9852
    f = 1000  # 3 decimal places

    # User B: same cell (tiny offset)
    b_lat = center_lat + 0.0001
    b_lon = center_lon + 0.0001

    # User C: adjacent cell (~150m away)
    c_lat = center_lat + 0.002
    c_lon = center_lon + 0.002

    # User D: Brooklyn
    d_lat, d_lon = 40.6892, -73.9857

    out.append(f"  User A: ({center_lat}, {center_lon}) → cell ({round(center_lat*f)/f}, {round(center_lon*f)/f})")
    out.append(f"  User B: ({b_lat}, {b_lon}) → cell ({round(b_lat*f)/f}, {round(b_lon*f)/f})")
    out.append(f"  User C: ({c_lat}, {c_lon}) → cell ({round(c_lat*f)/f}, {round(c_lon*f)/f})")
    out.append(f"  User D: ({d_lat}, {d_lon}) → cell ({round(d_lat*f)/f}, {round(d_lon*f)/f})")
    out.append("")

    params_a = {"lat": center_lat, "lon": center_lon, "radius": RADIUS}
    params_b = {"lat": b_lat, "lon": b_lon, "radius": RADIUS}
    params_c = {"lat": c_lat, "lon": c_lon, "radius": RADIUS}
    params_d = {"lat": d_lat, "lon": d_lon, "radius": RADIUS}

    t_a, s_a, _ = timed_get(c, f"{BASE}/nearby/grouped", params_a)
    t_b, s_b, _ = timed_get(c, f"{BASE}/nearby/grouped", params_b)
    t_c, s_c, _ = timed_get(c, f"{BASE}/nearby/grouped", params_c)
    t_d, s_d, _ = timed_get(c, f"{BASE}/nearby/grouped", params_d)

    out.append(f"  User A (cold):             {_fmt(t_a):>10s}  [{s_a}]")
    out.append(f"  User B (same cell):        {_fmt(t_b):>10s}  [{s_b}]  {_pct(t_b, t_a)}")
    out.append(f"  User C (adjacent cell):    {_fmt(t_c):>10s}  [{s_c}]  {_pct(t_c, t_a)} (per-stop sharing)")
    out.append(f"  User D (Brooklyn, cold):   {_fmt(t_d):>10s}  [{s_d}]")


def test_4_fifty_users_simulation(c: httpx.Client, out: list[str]):
    """Simulate 50 users across NYC hitting /nearby/grouped.

    - First 10 are cold (one per location, primes the caches)
    - Next 40 are within the same grid cells (should be near-instant)
    This simulates realistic traffic: most users cluster around transit hubs.
    """
    # Clear so cold calls are genuinely cold
    cache_clear(c)

    out.append("")
    out.append("=" * 80)
    out.append("TEST 4: 50-USER SIMULATION — /nearby/grouped across NYC")
    out.append("=" * 80)
    out.append(f"  {len(LOCATIONS)} locations × 1 cold + 4 cached = {NUM_USERS} requests")
    out.append("")

    cold_times: list[float] = []
    cached_times: list[float] = []
    all_times: list[float] = []
    errors = 0

    for loc_name, lat, lon in LOCATIONS:
        # Cold call — first user at this location
        params = {"lat": lat, "lon": lon, "radius": RADIUS}
        t, s, _ = timed_get(c, f"{BASE}/nearby/grouped", params)
        cold_times.append(t)
        all_times.append(t)
        if s != 200:
            errors += 1
        status_str = f"[{s}]" if s == 200 else f"[{s} ⚠️]"
        out.append(f"  🧊 COLD  {loc_name:<35s} {_fmt(t):>10s} {status_str}")

        # 4 cached calls — users in same grid cell with safe jitter
        for i in range(4):
            jitter_lat, jitter_lon = _cell_jitter(lat, lon)
            params_j = {"lat": jitter_lat, "lon": jitter_lon, "radius": RADIUS}
            t2, s2, _ = timed_get(c, f"{BASE}/nearby/grouped", params_j)
            cached_times.append(t2)
            all_times.append(t2)
            if s2 != 200:
                errors += 1

    cold_stats = _stats(cold_times)
    cached_stats = _stats(cached_times)
    all_stats = _stats(all_times)

    out.append("")
    out.append(f"  ┌──────────────────────────────────────────────────────────────┐")
    out.append(f"  │  50-User Results                                            │")
    out.append(f"  ├──────────────┬────────────┬────────────┬────────────────────┤")
    out.append(f"  │              │  Cold (10) │ Cached (40)│   All (50)         │")
    out.append(f"  ├──────────────┼────────────┼────────────┼────────────────────┤")
    out.append(f"  │ Min          │ {_fmt(cold_stats['min']):>10s} │ {_fmt(cached_stats['min']):>10s} │ {_fmt(all_stats['min']):>18s} │")
    out.append(f"  │ Max          │ {_fmt(cold_stats['max']):>10s} │ {_fmt(cached_stats['max']):>10s} │ {_fmt(all_stats['max']):>18s} │")
    out.append(f"  │ Avg          │ {_fmt(cold_stats['avg']):>10s} │ {_fmt(cached_stats['avg']):>10s} │ {_fmt(all_stats['avg']):>18s} │")
    out.append(f"  │ Median       │ {_fmt(cold_stats['median']):>10s} │ {_fmt(cached_stats['median']):>10s} │ {_fmt(all_stats['median']):>18s} │")
    out.append(f"  │ P95          │ {_fmt(cold_stats['p95']):>10s} │ {_fmt(cached_stats['p95']):>10s} │ {_fmt(all_stats['p95']):>18s} │")
    out.append(f"  │ Total        │ {_fmt(sum(cold_times)):>10s} │ {_fmt(sum(cached_times)):>10s} │ {_fmt(sum(all_times)):>18s} │")
    out.append(f"  │ Errors       │ {'—':>10s} │ {'—':>10s} │ {errors:>18d} │")
    out.append(f"  └──────────────┴────────────┴────────────┴────────────────────┘")
    out.append(f"  Cache speedup: cold avg {_fmt(cold_stats['avg'])} → cached avg {_fmt(cached_stats['avg'])} = {_pct(cached_stats['avg'], cold_stats['avg'])}")


def test_5_fifty_users_all_endpoints(c: httpx.Client, out: list[str]):
    """Simulate 50 users hitting a MIX of endpoints — realistic traffic pattern.

    Distribution (roughly what a real app session does):
      - 40% /nearby/grouped (main screen)
      - 15% /subway/{line}  (tapped into a route)
      - 15% /bus/live/{stop} (tapped into bus stop)
      - 10% /bus/vehicles/{route} (map view)
      - 5%  /subway/shapes/all (app launch)
      - 5%  /alerts (status tab)
      - 5%  /bus/routes (bus tab)
      - 5%  /predict/delay (arrival card)
    """
    out.append("")
    out.append("=" * 80)
    out.append("TEST 5: 50-USER MIXED TRAFFIC — Realistic endpoint distribution")
    out.append("=" * 80)

    random.seed(42)  # Reproducible

    # Build 50 requests with realistic distribution
    requests: list[tuple[str, str, dict | None]] = []

    # 20 × /nearby/grouped (40%)
    for _ in range(20):
        loc = random.choice(LOCATIONS)
        lat = loc[1] + random.uniform(-0.001, 0.001)
        lon = loc[2] + random.uniform(-0.001, 0.001)
        requests.append(("nearby/grouped", f"{BASE}/nearby/grouped", {"lat": lat, "lon": lon, "radius": RADIUS}))

    # 8 × /subway/{line} (15%)
    for _ in range(8):
        line = random.choice(SUBWAY_LINES)
        requests.append((f"subway/{line}", f"{BASE}/subway/{line}", None))

    # 7 × /bus/live/{stop} (15%)
    for _ in range(7):
        stop = random.choice(BUS_STOP_IDS)
        requests.append((f"bus/live/{stop}", f"{BASE}/bus/live/{stop}", None))

    # 5 × /bus/vehicles/{route} (10%)
    for _ in range(5):
        route = random.choice(BUS_ROUTES)
        requests.append((f"bus/vehicles", f"{BASE}/bus/vehicles/{route}", None))

    # 3 × /subway/shapes/all (app launch)
    for _ in range(3):
        requests.append(("subway/shapes/all", f"{BASE}/subway/shapes/all", None))

    # 3 × /alerts
    for _ in range(3):
        requests.append(("alerts", f"{BASE}/alerts", None))

    # 2 × /bus/routes
    for _ in range(2):
        requests.append(("bus/routes", f"{BASE}/bus/routes", None))

    # 2 × /predict/delay
    for _ in range(2):
        requests.append(("predict/delay", f"{BASE}/predict/delay",
                         {"minutes_away": random.randint(1, 15), "route_id": random.choice(SUBWAY_LINES), "hour": random.randint(6, 22)}))

    random.shuffle(requests)

    # Run them sequentially (simulates serial user sessions)
    by_endpoint: dict[str, list[float]] = {}
    errors = 0
    total_time = 0.0

    for label, url, params in requests:
        t, s, _ = timed_get(c, url, params)
        total_time += t
        if s != 200:
            errors += 1
        bucket = label.split("/")[0] if "/" in label else label
        by_endpoint.setdefault(bucket, []).append(t)

    out.append(f"  50 requests, {errors} errors, total wall time: {_fmt(total_time)}")
    out.append("")
    out.append(f"  {'Endpoint':<25s} {'Count':>5s} {'Avg':>10s} {'Min':>10s} {'Max':>10s} {'Total':>10s}")
    out.append(f"  {'─'*25} {'─'*5} {'─'*10} {'─'*10} {'─'*10} {'─'*10}")

    for ep in sorted(by_endpoint):
        times = by_endpoint[ep]
        st = _stats(times)
        out.append(f"  {ep:<25s} {len(times):>5d} {_fmt(st['avg']):>10s} {_fmt(st['min']):>10s} {_fmt(st['max']):>10s} {_fmt(sum(times)):>10s}")


def test_6_static_endpoint_speed(c: httpx.Client, out: list[str]):
    """Test static/semi-static endpoints that should be fast after first call."""
    # Clear caches so we measure true cold → cached transition
    cache_clear(c)

    out.append("")
    out.append("=" * 80)
    out.append("TEST 6: STATIC DATA ENDPOINTS — Should be near-instant after first call")
    out.append("=" * 80)

    static_endpoints = [
        ("subway/shapes/all",     f"{BASE}/subway/shapes/all",     None),
        ("subway/stations/all",   f"{BASE}/subway/stations/all",   None),
        ("subway/shape/A",        f"{BASE}/subway/shape/A",        None),
        ("subway/shape/7",        f"{BASE}/subway/shape/7",        None),
        ("lirr/shapes/all",       f"{BASE}/lirr/shapes/all",       None),
        ("mnr/shapes/all",        f"{BASE}/mnr/shapes/all",        None),
        ("bus/routes",            f"{BASE}/bus/routes",             None),
        ("bus/stops/MTA NYCT_M15", f"{BASE}/bus/stops/MTA NYCT_M15", None),
        ("bus/route-shape/MTA NYCT_M15", f"{BASE}/bus/route-shape/MTA NYCT_M15", None),
    ]

    out.append(f"\n  {'Endpoint':<35s} {'Cold':>10s} {'2nd call':>10s} {'3rd call':>10s} {'Speedup':>12s}")
    out.append(f"  {'─'*35} {'─'*10} {'─'*10} {'─'*10} {'─'*12}")

    for name, url, params in static_endpoints:
        t1, _, _ = timed_get(c, url, params)
        t2, _, _ = timed_get(c, url, params)
        t3, _, _ = timed_get(c, url, params)
        speedup = _pct(t2, t1)
        out.append(f"  {name:<35s} {_fmt(t1):>10s} {_fmt(t2):>10s} {_fmt(t3):>10s} {speedup:>12s}")


def test_7_bus_live_per_stop_sharing(c: httpx.Client, out: list[str]):
    """Test that per-stop SIRI arrivals cache is shared across users.

    When User A requests arrivals for stop X, User B requesting the same
    stop gets the cached result — this is the Venn diagram overlap layer.
    """
    # Clear so first call is genuinely cold
    cache_clear(c)

    out.append("")
    out.append("=" * 80)
    out.append("TEST 7: PER-STOP ARRIVAL CACHE — Shared across all users")
    out.append("=" * 80)
    out.append("  Same stop_id requested by different 'users' (serial requests)")
    out.append("")

    for stop_id in BUS_STOP_IDS:
        t1, s1, _ = timed_get(c, f"{BASE}/bus/live/{stop_id}")
        t2, s2, _ = timed_get(c, f"{BASE}/bus/live/{stop_id}")
        t3, s3, _ = timed_get(c, f"{BASE}/bus/live/{stop_id}")
        out.append(f"  {stop_id:<20s}  1st={_fmt(t1):>10s}  2nd={_fmt(t2):>10s}  3rd={_fmt(t3):>10s}  {_pct(t2, t1)}")


def test_8_subway_feed_sharing(c: httpx.Client, out: list[str]):
    """Test that subway GTFS-RT feeds (9 total) are shared globally.

    The A train feed serves data for A, C, and E lines. Requesting /subway/A
    primes the cache, then /subway/C should be nearly free.
    """
    # Clear MTA feed cache so first line per feed is truly cold
    cache_clear(c)

    out.append("")
    out.append("=" * 80)
    out.append("TEST 8: SUBWAY FEED SHARING — 9 feeds serve all lines globally")
    out.append("=" * 80)
    out.append("  Lines sharing the same feed should benefit from cache priming")
    out.append("")

    # Feed groups: lines that share the same protobuf feed
    feed_groups = [
        ("ACE feed",   ["A", "C", "E"]),
        ("BDFM feed",  ["B", "D", "F", "M"]),
        ("NQRW feed",  ["N", "Q", "R", "W"]),
        ("1-6 feed",   ["1", "2", "3", "4", "5", "6"]),
        ("G feed",     ["G"]),
        ("L feed",     ["L"]),
        ("JZ feed",    ["J", "Z"]),
        ("7 feed",     ["7"]),
        ("SI feed",    ["SI"]),
    ]

    for feed_name, lines in feed_groups:
        times = []
        for line in lines:
            t, s, _ = timed_get(c, f"{BASE}/subway/{line}")
            times.append((line, t, s))
        first_line, first_t, first_s = times[0]
        result_parts = [f"{ln}={_fmt(t)}" for ln, t, _ in times]
        out.append(f"  {feed_name:<12s}: {' → '.join(result_parts)}")


def test_9_mode_filter_speed(c: httpx.Client, out: list[str]):
    """Test /nearby/grouped with mode filter vs unfiltered.

    Filtered requests (mode=subway) should be faster because they skip
    bus/rail feeds entirely.
    """
    out.append("")
    out.append("=" * 80)
    out.append("TEST 9: MODE FILTER OPTIMIZATION — Filtered vs unfiltered")
    out.append("=" * 80)

    lat, lon = 40.7580, -73.9855  # Times Square
    # Use unique coordinates to avoid response cache hits from earlier tests
    lat2, lon2 = 40.7345, -73.9912

    modes = [None, "subway", "bus", "lirr", "mnr"]
    out.append(f"\n  {'Mode':<20s} {'Time':>10s}")
    out.append(f"  {'─'*20} {'─'*10}")

    for mode in modes:
        params = {"lat": lat2, "lon": lon2, "radius": RADIUS}
        if mode:
            params["mode"] = mode
        t, s, _ = timed_get(c, f"{BASE}/nearby/grouped", params)
        label = mode or "all (unfiltered)"
        out.append(f"  {label:<20s} {_fmt(t):>10s}  [{s}]")


# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════

def main():
    # Check server is up
    try:
        r = httpx.get(f"{BASE}/alerts", timeout=5.0)
        if r.status_code != 200:
            print(f"⚠️  Server returned {r.status_code} — continuing anyway")
    except httpx.ConnectError:
        print(f"❌ Cannot connect to {BASE} — is the server running?")
        print("   Start it with: cd TrackBackend && python run.py")
        sys.exit(1)

    print(f"🚀 Track Backend Cache & Speed Test")
    print(f"   Server: {BASE}")
    print(f"   Users simulated: {NUM_USERS}")
    print(f"   Locations: {len(LOCATIONS)} across NYC")
    print()

    out: list[str] = []
    out.append("╔══════════════════════════════════════════════════════════════════════════════╗")
    out.append("║             TRACK BACKEND — CACHE & SPEED TEST RESULTS                     ║")
    out.append("╚══════════════════════════════════════════════════════════════════════════════╝")
    out.append("")
    now = datetime.now(timezone.utc)
    out.append(f"  Date:     {now.strftime('%Y-%m-%d %H:%M:%S UTC')}")
    out.append(f"  Server:   {BASE}")
    out.append(f"  Users:    {NUM_USERS}")
    out.append(f"  Radius:   {RADIUS}m")
    out.append(f"  Locations: {len(LOCATIONS)} ({', '.join(l[0].split(' – ')[0] for l in LOCATIONS[:5])}...)")

    client = httpx.Client(timeout=TIMEOUT)
    overall_start = time.perf_counter()

    # Verify cache-clear endpoint is available
    try:
        cr = client.post(f"{BASE}/admin/cache/clear")
        if cr.status_code == 200:
            print(f"   Cache-clear endpoint: available ✅")
        else:
            print(f"   Cache-clear endpoint: {cr.status_code} (tests may show warm caches)")
    except Exception:
        print(f"   Cache-clear endpoint: unavailable (upgrade server for accurate cold tests)")

    try:
        # Run all tests
        print("  [1/9] Endpoint inventory...")
        passed, failed = test_1_endpoint_inventory(client, out)
        print(f"         {passed} passed, {failed} failed")

        print("  [2/9] Cold vs cached...")
        test_2_cold_vs_cached(client, out)
        print("         Done")

        print("  [3/9] Venn diagram overlap...")
        test_3_venn_diagram_cache_sharing(client, out)
        print("         Done")

        print("  [4/9] 50-user simulation (/nearby/grouped)...")
        test_4_fifty_users_simulation(client, out)
        print("         Done")

        print("  [5/9] 50-user mixed traffic...")
        test_5_fifty_users_all_endpoints(client, out)
        print("         Done")

        print("  [6/9] Static endpoint speed...")
        test_6_static_endpoint_speed(client, out)
        print("         Done")

        print("  [7/9] Per-stop arrival sharing...")
        test_7_bus_live_per_stop_sharing(client, out)
        print("         Done")

        print("  [8/9] Subway feed sharing...")
        test_8_subway_feed_sharing(client, out)
        print("         Done")

        print("  [9/9] Mode filter optimization...")
        test_9_mode_filter_speed(client, out)
        print("         Done")

    finally:
        client.close()

    overall_elapsed = time.perf_counter() - overall_start

    # Final summary
    out.append("")
    out.append("=" * 80)
    out.append("OVERALL SUMMARY")
    out.append("=" * 80)
    out.append(f"  Total test time:  {_fmt(overall_elapsed)}")
    out.append(f"  All 9 test suites completed.")
    out.append("")
    out.append("  Cache Architecture (all in-memory Python dicts):")
    out.append("  ┌────────────────────────────────────────────────────────────┐")
    out.append("  │ L1  Response cache    /nearby/grouped by GPS grid cell    │")
    out.append("  │ L2  Per-stop arrivals SIRI arrivals by stop_id            │")
    out.append("  │ L3  Subway feeds      9 GTFS-RT feeds by URL             │")
    out.append("  │ L4  Static data       Routes, stops, shapes by route_id  │")
    out.append("  └────────────────────────────────────────────────────────────┘")
    out.append("")
    out.append("  Venn Diagram Sharing:")
    out.append("  • Same cell (~111m): L1 response cache HIT → 0.003-0.005s")
    out.append("  • Adjacent cell:     L1 MISS, L2 per-stop HITs → partial savings")
    out.append("  • Same city:         L3 subway feeds always shared (9 URLs global)")
    out.append("  • Static data:       L4 shapes/stops/routes cached for hours")
    out.append("")

    # Write to file
    results_path = Path(__file__).resolve().parent.parent / "logs" / "cache_speed_test_results.txt"
    results_path.parent.mkdir(parents=True, exist_ok=True)
    results_path.write_text("\n".join(out) + "\n", encoding="utf-8")

    print()
    print(f"✅ All tests complete in {_fmt(overall_elapsed)}")
    print(f"📄 Results saved to: {results_path}")
    print()
    # Also print the full report to stdout
    print("\n".join(out))


if __name__ == "__main__":
    main()
