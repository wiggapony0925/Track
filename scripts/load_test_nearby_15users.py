#!/usr/bin/env python3
"""
Load test: 15 concurrent users hammering /nearby/grouped.

Validates BOTH:
  1. Performance under concurrency (p50/p95/p99 latency, throughput).
  2. Route stability — the fix for "Q26 disappears for some users".
     Every route discovered in the location's "ground-truth" run MUST
     appear in every subsequent run for that location. Any drop is a
     regression of the Phase C.5 guarantee.

Usage:
    cd TrackBackend && .venv/bin/python ../scripts/load_test_nearby_15users.py
    # optional: BASE_URL=http://localhost:8000 python ../scripts/...

Each user:
  - Picks a unique NYC location (15 distinct neighborhoods).
  - Does 1 cold ground-truth call (quick=false, no cache).
  - Then 6 mixed calls: alternating quick=false and quick=true,
    with tiny GPS jitter to stress the cache-key/grid logic.
  - Asserts every ground-truth route still appears in each follow-up.

Exits non-zero if any route disappears.
"""

from __future__ import annotations

import asyncio
import os
import random
import statistics
import sys
import time
from collections import defaultdict
from dataclasses import dataclass, field

import httpx

BASE_URL = os.environ.get("BASE_URL", "http://localhost:8000")
ENDPOINT = f"{BASE_URL}/nearby/grouped"

NUM_USERS = 15
ROUNDS_PER_USER = 6  # follow-up calls after ground truth
TIMEOUT_S = 30
RADIUS_M = 800

# 15 distinct NYC locations covering all 5 boroughs + bus-heavy areas.
# Q26 territory is included (Auburndale/Bayside, Queens) to specifically
# regression-test the original bug.
LOCATIONS: list[tuple[str, float, float]] = [
    ("Auburndale (Q26 area)",   40.7600, -73.7900),
    ("Bayside (Q26 east end)",  40.7635, -73.7710),
    ("Flushing Main St",        40.7596, -73.8300),
    ("Jackson Heights",         40.7466, -73.8832),
    ("Astoria (N/W)",           40.7720, -73.9301),
    ("Long Island City",        40.7425, -73.9560),
    ("Williamsburg",            40.7081, -73.9571),
    ("Park Slope",              40.6710, -73.9800),
    ("Bay Ridge",               40.6340, -74.0288),
    ("Coney Island",            40.5749, -73.9817),
    ("South Bronx (Hub)",       40.8176, -73.9209),
    ("Harlem 125th",            40.8116, -73.9465),
    ("Times Square",            40.7580, -73.9855),
    ("Penn Station",            40.7505, -73.9934),
    ("Wall Street",             40.7074, -74.0113),
]
assert len(LOCATIONS) == NUM_USERS


@dataclass
class UserStats:
    label: str
    lat: float
    lon: float
    ground_truth_routes: set[str] = field(default_factory=set)
    latencies_ms: list[float] = field(default_factory=list)
    quick_latencies_ms: list[float] = field(default_factory=list)
    missing_per_call: list[tuple[int, bool, set[str]]] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)


async def fetch_routes(
    client: httpx.AsyncClient, lat: float, lon: float, *, quick: bool
) -> tuple[set[str], float, int]:
    """Return (route_id_set, latency_ms, status_code). Raises on transport error."""
    params = {"lat": f"{lat:.6f}", "lon": f"{lon:.6f}", "radius": RADIUS_M}
    if quick:
        params["quick"] = "true"

    t0 = time.perf_counter()
    r = await client.get(ENDPOINT, params=params, timeout=TIMEOUT_S)
    dt_ms = (time.perf_counter() - t0) * 1000.0

    if r.status_code != 200:
        return set(), dt_ms, r.status_code

    data = r.json()
    if not isinstance(data, list):
        return set(), dt_ms, r.status_code
    routes = {item["route_id"] for item in data if "route_id" in item}
    return routes, dt_ms, 200


async def run_user(client: httpx.AsyncClient, idx: int) -> UserStats:
    label, lat, lon = LOCATIONS[idx]
    stats = UserStats(label=label, lat=lat, lon=lon)

    # ── Step 1: ground-truth call (full, quick=false) ─────────────
    try:
        gt_routes, gt_ms, code = await fetch_routes(client, lat, lon, quick=False)
    except Exception as exc:  # noqa: BLE001
        stats.errors.append(f"ground-truth: {exc!r}")
        return stats

    if code != 200:
        stats.errors.append(f"ground-truth status {code}")
        return stats

    stats.ground_truth_routes = gt_routes
    stats.latencies_ms.append(gt_ms)

    # ── Step 2: follow-ups with jitter and mixed quick mode ───────
    for round_idx in range(ROUNDS_PER_USER):
        # GPS jitter: ±0.0003° (~30 m) — stresses cache-cell rounding.
        jlat = lat + random.uniform(-0.0003, 0.0003)
        jlon = lon + random.uniform(-0.0003, 0.0003)
        quick = round_idx % 2 == 1  # alternate

        try:
            routes, dt_ms, code = await fetch_routes(client, jlat, jlon, quick=quick)
        except Exception as exc:  # noqa: BLE001
            stats.errors.append(f"round{round_idx} ({'quick' if quick else 'full'}): {exc!r}")
            continue

        if code != 200:
            stats.errors.append(f"round{round_idx} status {code}")
            continue

        if quick:
            stats.quick_latencies_ms.append(dt_ms)
        else:
            stats.latencies_ms.append(dt_ms)

        # Route stability check: ground-truth routes must persist.
        # (New routes appearing is fine — that's enrichment.)
        missing = stats.ground_truth_routes - routes
        if missing:
            stats.missing_per_call.append((round_idx, quick, missing))

    return stats


def pct(xs: list[float], p: float) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    k = max(0, min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1)))))
    return s[k]


async def main() -> int:
    print(f"=== /nearby/grouped load test: {NUM_USERS} concurrent users ===")
    print(f"Endpoint: {ENDPOINT}")
    print(f"Rounds/user: {ROUNDS_PER_USER}  Total calls: ~{NUM_USERS * (ROUNDS_PER_USER + 1)}")
    print()

    # Health check
    async with httpx.AsyncClient() as client:
        try:
            r = await client.get(f"{BASE_URL}/health", timeout=5)
            print(f"Health: {r.status_code}")
        except Exception as exc:  # noqa: BLE001
            print(f"❌ Backend unreachable at {BASE_URL}: {exc}")
            return 2

    limits = httpx.Limits(max_connections=64, max_keepalive_connections=32)
    t0 = time.perf_counter()
    async with httpx.AsyncClient(limits=limits) as client:
        results = await asyncio.gather(*(run_user(client, i) for i in range(NUM_USERS)))
    wall_ms = (time.perf_counter() - t0) * 1000.0

    # ── Aggregate stats ───────────────────────────────────────────
    all_full = [ms for s in results for ms in s.latencies_ms]
    all_quick = [ms for s in results for ms in s.quick_latencies_ms]
    total_calls = sum(len(s.latencies_ms) + len(s.quick_latencies_ms) for s in results)

    print()
    print("─" * 78)
    print(f"Wall clock: {wall_ms:.0f} ms   Total calls: {total_calls}   "
          f"Throughput: {total_calls / (wall_ms / 1000):.1f} req/s")
    print("─" * 78)

    def _row(name: str, xs: list[float]) -> None:
        if not xs:
            print(f"  {name:<14} (no samples)")
            return
        print(f"  {name:<14} n={len(xs):>3}  "
              f"p50={pct(xs, 50):>7.0f}  p95={pct(xs, 95):>7.0f}  "
              f"p99={pct(xs, 99):>7.0f}  max={max(xs):>7.0f}  "
              f"mean={statistics.mean(xs):>7.0f} ms")

    print("Latency (ms):")
    _row("full mode",  all_full)
    _row("quick mode", all_quick)
    print()

    # ── Per-user breakdown ───────────────────────────────────────
    print("Per-user route discovery:")
    print(f"  {'#':<3} {'location':<28} {'routes':>6} {'p95(ms)':>9} {'errs':>5} stability")
    any_drop = False
    error_count = 0
    for i, s in enumerate(results):
        all_lat = s.latencies_ms + s.quick_latencies_ms
        p95 = pct(all_lat, 95)
        err_n = len(s.errors)
        error_count += err_n
        if s.missing_per_call:
            any_drop = True
            stab = "❌ DROPPED"
        elif err_n:
            stab = "⚠️  errors"
        else:
            stab = "✅"
        print(f"  {i:<3} {s.label:<28} {len(s.ground_truth_routes):>6} "
              f"{p95:>9.0f} {err_n:>5} {stab}")

    # ── Drop diagnostics ─────────────────────────────────────────
    if any_drop:
        print()
        print("❌ ROUTE STABILITY VIOLATIONS:")
        for s in results:
            if not s.missing_per_call:
                continue
            print(f"\n  {s.label} ({s.lat:.4f},{s.lon:.4f})")
            print(f"    ground-truth: {sorted(s.ground_truth_routes)}")
            for round_idx, quick, missing in s.missing_per_call:
                tag = "quick" if quick else "full"
                print(f"    round {round_idx} ({tag}): MISSING {sorted(missing)}")

    # ── Error diagnostics ────────────────────────────────────────
    if error_count:
        print()
        print(f"⚠️  Errors ({error_count}):")
        for s in results:
            for e in s.errors:
                print(f"  [{s.label}] {e}")

    # ── Q26 specific check ───────────────────────────────────────
    print()
    print("Q26 regression check:")
    q26_users = [s for s in results if "Q26" in s.label or "Auburndale" in s.label or "Bayside" in s.label]
    for s in q26_users:
        has_q26 = any(r.upper() == "Q26" for r in s.ground_truth_routes)
        marker = "✅" if has_q26 else "❌"
        print(f"  {marker} {s.label}: Q26 {'present' if has_q26 else 'MISSING'} "
              f"(found {len(s.ground_truth_routes)} routes)")

    print()
    if any_drop:
        print("RESULT: ❌ FAIL — route drops detected")
        return 1
    if error_count:
        print("RESULT: ⚠️  PASS-WITH-ERRORS")
        return 0
    print("RESULT: ✅ PASS — all routes stable across all rounds")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
