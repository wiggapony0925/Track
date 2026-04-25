#!/usr/bin/env python3
"""Comprehensive performance + route-stability test for ``/nearby/grouped``.

This is the high-coverage companion to ``load_test_nearby_15users.py``.
Goals:

  1. Exercise *every* NYC subway line, LIRR/MNR branch, and
     bus-heavy corridor by sampling 50+ locations across all five
     boroughs.
  2. Validate the architectural invariant: once a route is shown for a
     location, subsequent calls (full, quick, jittered) MUST keep it.
     The new sticky-route-memory layer in ``nearby.py`` must hold this
     across SIRI/GTFS-RT flakes, case mismatches (BX92↔Bx92), ``+``
     variants, MTABC outages, and rail intermittents.
  3. Stress concurrency: multiple simulated users hit the same location
     simultaneously to expose race conditions in the response cache.
  4. Stress the cache grid: small GPS jitter (~30 m) must NEVER lose
     routes — neighbor-cell fallback + sticky memory together cover it.
  5. Report performance percentiles per mode and overall.

Reusable helpers (see "Reusable test surface" section):
  - :class:`LocationSpec`, :class:`UserStats`, :class:`AggregateStats`
  - :func:`fetch_routes`, :func:`run_round`, :func:`run_location`
  - :func:`pct`, :func:`fmt_latency_row`, :func:`coverage_report`
  - :func:`assert_no_drops`

Usage::

    cd /Users/jeffreyfernandez/code/Track
    TrackBackend/.venv/bin/python scripts/load_test_nearby_comprehensive.py

Optional environment overrides::

    BASE_URL=http://localhost:8000
    NEARBY_LT_ROUNDS=8         # follow-up calls per user (default 8)
    NEARBY_LT_USERS=3          # concurrent users per location (default 3)
    NEARBY_LT_RADIUS=800
    NEARBY_LT_MAX_LOCATIONS=0  # 0 = no limit, else cap the location list
    NEARBY_LT_QUIET=0          # 1 = suppress per-location prints

Exit codes:
  0  pass (or pass-with-non-fatal errors)
  1  one or more route drops detected (architectural regression)
  2  backend unreachable
"""

from __future__ import annotations

import asyncio
import os
import random
import statistics
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from typing import Any

import httpx

# ─────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────

BASE_URL = os.environ.get("BASE_URL", "http://localhost:8000")
ENDPOINT = f"{BASE_URL}/nearby/grouped"

ROUNDS_PER_USER = int(os.environ.get("NEARBY_LT_ROUNDS", "8"))
USERS_PER_LOCATION = int(os.environ.get("NEARBY_LT_USERS", "3"))
RADIUS_M = int(os.environ.get("NEARBY_LT_RADIUS", "800"))
MAX_LOCATIONS = int(os.environ.get("NEARBY_LT_MAX_LOCATIONS", "0"))
QUIET = os.environ.get("NEARBY_LT_QUIET", "0") == "1"
TIMEOUT_S = 30
JITTER_DEG = 0.0003  # ~30 m

# Concurrency caps to keep the box happy
GLOBAL_INFLIGHT_LIMIT = 16
HTTPX_LIMITS = httpx.Limits(
    max_connections=128,
    max_keepalive_connections=64,
)


# ─────────────────────────────────────────────────────────────────────
# Locations: ≥50 sites covering subway, LIRR, MNR, MTABC, MTA-NYCT bus
# ─────────────────────────────────────────────────────────────────────
# Format: (label, mode_tags, lat, lon)
# mode_tags is a free-form set of tags useful for coverage reporting
# (not used for assertions — every route returned is treated as relevant).

@dataclass(frozen=True)
class LocationSpec:
    label: str
    lat: float
    lon: float
    tags: frozenset[str] = field(default_factory=frozenset)


def _loc(label: str, lat: float, lon: float, *tags: str) -> LocationSpec:
    return LocationSpec(label=label, lat=lat, lon=lon, tags=frozenset(tags))


LOCATIONS: list[LocationSpec] = [
    # ── Manhattan subway hubs ────────────────────────────────────────
    _loc("Times Sq–42 St",            40.7559, -73.9870, "subway", "manhattan"),
    _loc("Penn Station",              40.7505, -73.9934, "subway", "lirr", "manhattan"),
    _loc("Grand Central",             40.7527, -73.9772, "subway", "mnr", "manhattan"),
    _loc("Union Sq 14 St",            40.7359, -73.9911, "subway", "manhattan"),
    _loc("Herald Sq 34 St",           40.7497, -73.9879, "subway", "bus", "manhattan"),
    _loc("Columbus Circle",           40.7681, -73.9819, "subway", "bus", "manhattan"),
    _loc("125 St Lex (4/5/6)",        40.8000, -73.9354, "subway", "bus", "manhattan"),
    _loc("Harlem 125 ABCD",           40.8116, -73.9465, "subway", "bus", "manhattan"),
    _loc("Inwood–207 St (A)",         40.8680, -73.9210, "subway", "manhattan"),
    _loc("Wall Street",               40.7074, -74.0113, "subway", "manhattan"),
    _loc("South Ferry",               40.7019, -74.0130, "subway", "manhattan"),
    _loc("Canal St",                  40.7185, -74.0010, "subway", "manhattan"),
    _loc("West 4 St",                 40.7322, -74.0008, "subway", "manhattan"),
    _loc("Roosevelt Island",          40.7610, -73.9508, "subway", "manhattan"),
    _loc("96 St Q (Second Ave)",      40.7849, -73.9474, "subway", "manhattan"),

    # ── Brooklyn ─────────────────────────────────────────────────────
    _loc("Atlantic Av–Barclays",      40.6843, -73.9776, "subway", "lirr", "bus", "brooklyn"),
    _loc("DeKalb Av",                 40.6905, -73.9818, "subway", "brooklyn"),
    _loc("Jay St–MetroTech",          40.6924, -73.9872, "subway", "brooklyn"),
    _loc("Bedford Av (L)",            40.7174, -73.9568, "subway", "brooklyn"),
    _loc("Williamsburg",              40.7081, -73.9571, "subway", "bus", "brooklyn"),
    _loc("Park Slope",                40.6710, -73.9800, "subway", "bus", "brooklyn"),
    _loc("Bay Ridge 95 St",           40.6164, -74.0303, "subway", "bus", "brooklyn"),
    _loc("Bay Ridge 86 St",           40.6340, -74.0288, "subway", "bus", "brooklyn"),
    _loc("Coney Island Stillwell",    40.5775, -73.9810, "subway", "bus", "brooklyn"),
    _loc("Brighton Beach",            40.5779, -73.9612, "subway", "bus", "brooklyn"),
    _loc("Flatbush Av Junction",      40.6447, -73.9320, "subway", "bus", "brooklyn"),
    _loc("Crown Heights Utica",       40.6685, -73.9325, "subway", "bus", "brooklyn"),
    _loc("Bushwick Myrtle-Wyckoff",   40.6997, -73.9128, "subway", "bus", "brooklyn"),

    # ── Queens (incl. Q26 territory) ─────────────────────────────────
    _loc("Auburndale (Q26 west)",     40.7600, -73.7900, "bus", "lirr", "queens", "q26"),
    _loc("Bayside (Q26 east)",        40.7635, -73.7710, "bus", "lirr", "queens", "q26"),
    _loc("Flushing Main St",          40.7596, -73.8300, "subway", "bus", "lirr", "queens"),
    _loc("Jackson Heights 74 St",     40.7466, -73.8915, "subway", "bus", "queens"),
    _loc("Jamaica 165 St",            40.7066, -73.7937, "subway", "bus", "queens"),
    _loc("Sutphin–Archer (LIRR)",     40.7022, -73.8077, "subway", "lirr", "bus", "queens"),
    _loc("Forest Hills 71 Av",        40.7218, -73.8448, "subway", "bus", "queens"),
    _loc("Astoria Ditmars",           40.7752, -73.9123, "subway", "bus", "queens"),
    _loc("Astoria Blvd",              40.7720, -73.9175, "subway", "bus", "queens"),
    _loc("Long Island City Court Sq", 40.7470, -73.9446, "subway", "bus", "queens"),
    _loc("Rockaway Park",             40.5821, -73.8351, "subway", "bus", "queens"),
    _loc("Far Rockaway",              40.6038, -73.7546, "subway", "bus", "lirr", "queens"),
    _loc("Howard Beach JFK",          40.6601, -73.8302, "subway", "bus", "queens"),

    # ── Bronx ────────────────────────────────────────────────────────
    _loc("South Bronx Hub",           40.8176, -73.9209, "subway", "bus", "bronx"),
    _loc("Yankee Stadium 161",        40.8276, -73.9258, "subway", "bus", "mnr", "bronx"),
    _loc("Fordham Rd",                40.8612, -73.8995, "subway", "bus", "mnr", "bronx"),
    _loc("Pelham Bay Park",           40.8527, -73.8281, "subway", "bus", "bronx"),
    _loc("Wakefield 241 St",          40.9032, -73.8504, "subway", "bus", "bronx"),
    _loc("Co-op City",                40.8714, -73.8290, "bus", "bronx"),
    _loc("Riverdale 231 St",          40.8786, -73.9046, "subway", "bus", "bronx"),

    # ── Staten Island (SI Railway + buses) ───────────────────────────
    _loc("St George Ferry",           40.6437, -74.0734, "bus", "siferry", "statenisland"),
    _loc("New Dorp",                  40.5734, -74.1186, "bus", "statenisland"),
    _loc("Eltingville",               40.5453, -74.1672, "bus", "statenisland"),

    # ── Express / suburban LIRR + MNR exposure ───────────────────────
    _loc("Jamaica LIRR",              40.7019, -73.8083, "lirr", "queens"),
    _loc("Mineola LIRR",              40.7421, -73.6406, "lirr", "longisland"),
    _loc("Hicksville LIRR",           40.7677, -73.5286, "lirr", "longisland"),
    _loc("White Plains MNR",          41.0331, -73.7754, "mnr", "westchester"),
    _loc("Yonkers MNR",               40.9326, -73.8985, "mnr", "westchester"),
]

if MAX_LOCATIONS > 0:
    LOCATIONS = LOCATIONS[:MAX_LOCATIONS]


# ─────────────────────────────────────────────────────────────────────
# Reusable test surface
# ─────────────────────────────────────────────────────────────────────


@dataclass
class CallResult:
    routes: set[str]
    routes_by_mode: dict[str, set[str]]
    latency_ms: float
    status: int
    quick: bool


@dataclass
class UserStats:
    location: LocationSpec
    user_idx: int
    ground_truth_routes: set[str] = field(default_factory=set)
    ground_truth_modes: dict[str, set[str]] = field(default_factory=dict)
    full_latencies_ms: list[float] = field(default_factory=list)
    quick_latencies_ms: list[float] = field(default_factory=list)
    missing_per_call: list[tuple[int, bool, set[str]]] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    # Every unique route this user observed across all rounds — for coverage.
    seen_routes: set[str] = field(default_factory=set)
    seen_routes_by_mode: dict[str, set[str]] = field(default_factory=dict)


@dataclass
class AggregateStats:
    full_latencies_ms: list[float] = field(default_factory=list)
    quick_latencies_ms: list[float] = field(default_factory=list)
    seen_routes_by_mode: dict[str, set[str]] = field(default_factory=dict)
    drops: int = 0
    errors: int = 0
    locations_with_drops: list[str] = field(default_factory=list)


_inflight_sem = asyncio.Semaphore(GLOBAL_INFLIGHT_LIMIT)


async def fetch_routes(
    client: httpx.AsyncClient,
    lat: float,
    lon: float,
    *,
    quick: bool,
    radius: int = RADIUS_M,
) -> CallResult:
    """Fetch ``/nearby/grouped`` and return a structured :class:`CallResult`.

    Network and JSON errors are surfaced as ``status=-1`` with empty
    routes — callers decide whether to count them.
    """
    params: dict[str, Any] = {
        "lat": f"{lat:.6f}",
        "lon": f"{lon:.6f}",
        "radius": radius,
    }
    if quick:
        params["quick"] = "true"

    t0 = time.perf_counter()
    try:
        async with _inflight_sem:
            r = await client.get(ENDPOINT, params=params, timeout=TIMEOUT_S)
        dt_ms = (time.perf_counter() - t0) * 1000.0
    except Exception:
        dt_ms = (time.perf_counter() - t0) * 1000.0
        return CallResult(set(), {}, dt_ms, -1, quick)

    if r.status_code != 200:
        return CallResult(set(), {}, dt_ms, r.status_code, quick)

    try:
        data = r.json()
    except Exception:
        return CallResult(set(), {}, dt_ms, r.status_code, quick)

    if not isinstance(data, list):
        return CallResult(set(), {}, dt_ms, r.status_code, quick)

    routes: set[str] = set()
    by_mode: dict[str, set[str]] = defaultdict(set)
    for item in data:
        if not isinstance(item, dict):
            continue
        rid = item.get("route_id")
        mode = (item.get("mode") or "").lower() or "unknown"
        if rid:
            routes.add(rid)
            by_mode[mode].add(rid)
    return CallResult(routes, dict(by_mode), dt_ms, 200, quick)


async def run_round(
    client: httpx.AsyncClient,
    stats: UserStats,
    round_idx: int,
    *,
    quick: bool,
) -> None:
    """One follow-up request, with jitter, against the user's location."""
    loc = stats.location
    jlat = loc.lat + random.uniform(-JITTER_DEG, JITTER_DEG)
    jlon = loc.lon + random.uniform(-JITTER_DEG, JITTER_DEG)

    res = await fetch_routes(client, jlat, jlon, quick=quick)
    if res.status == -1:
        stats.errors.append(f"round{round_idx} ({'quick' if quick else 'full'}): transport")
        return
    if res.status != 200:
        stats.errors.append(f"round{round_idx} status {res.status}")
        return

    if quick:
        stats.quick_latencies_ms.append(res.latency_ms)
    else:
        stats.full_latencies_ms.append(res.latency_ms)

    stats.seen_routes |= res.routes
    for m, rs in res.routes_by_mode.items():
        stats.seen_routes_by_mode.setdefault(m, set()).update(rs)

    missing = stats.ground_truth_routes - res.routes
    if missing:
        stats.missing_per_call.append((round_idx, quick, missing))


async def run_user(
    client: httpx.AsyncClient,
    location: LocationSpec,
    user_idx: int,
) -> UserStats:
    """One simulated user: 1 ground-truth call + N follow-ups (alternating quick)."""
    stats = UserStats(location=location, user_idx=user_idx)

    # Ground-truth: full mode, no jitter.
    res = await fetch_routes(client, location.lat, location.lon, quick=False)
    if res.status != 200:
        stats.errors.append(f"ground-truth status {res.status}")
        return stats

    stats.ground_truth_routes = set(res.routes)
    stats.ground_truth_modes = {m: set(rs) for m, rs in res.routes_by_mode.items()}
    stats.full_latencies_ms.append(res.latency_ms)
    stats.seen_routes |= res.routes
    for m, rs in res.routes_by_mode.items():
        stats.seen_routes_by_mode.setdefault(m, set()).update(rs)

    for i in range(ROUNDS_PER_USER):
        await run_round(client, stats, i, quick=(i % 2 == 1))

    return stats


async def run_location(
    client: httpx.AsyncClient,
    location: LocationSpec,
) -> list[UserStats]:
    """Multiple concurrent simulated users on the same location."""
    return await asyncio.gather(
        *(run_user(client, location, u) for u in range(USERS_PER_LOCATION))
    )


# ─────────────────────────────────────────────────────────────────────
# Reporting helpers
# ─────────────────────────────────────────────────────────────────────


def pct(xs: list[float], p: float) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    k = max(0, min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1)))))
    return s[k]


def fmt_latency_row(name: str, xs: list[float]) -> str:
    if not xs:
        return f"  {name:<14} (no samples)"
    return (
        f"  {name:<14} n={len(xs):>5}  "
        f"p50={pct(xs, 50):>7.0f}  p95={pct(xs, 95):>7.0f}  "
        f"p99={pct(xs, 99):>7.0f}  max={max(xs):>7.0f}  "
        f"mean={statistics.mean(xs):>7.0f} ms"
    )


def coverage_report(agg: AggregateStats) -> str:
    lines: list[str] = ["Route coverage by mode:"]
    for mode in sorted(agg.seen_routes_by_mode.keys()):
        rs = agg.seen_routes_by_mode[mode]
        sample = ", ".join(sorted(rs)[:12])
        more = f" … (+{len(rs) - 12} more)" if len(rs) > 12 else ""
        lines.append(f"  {mode:<8} {len(rs):>4} routes  [{sample}{more}]")
    return "\n".join(lines)


def assert_no_drops(all_stats: list[UserStats]) -> tuple[int, list[str]]:
    """Return (drop_count, list_of_failure_messages)."""
    drop_count = 0
    failures: list[str] = []
    by_loc: dict[str, list[UserStats]] = defaultdict(list)
    for s in all_stats:
        by_loc[s.location.label].append(s)

    for label, users in by_loc.items():
        loc_drops: list[str] = []
        for s in users:
            for round_idx, quick, missing in s.missing_per_call:
                drop_count += 1
                tag = "quick" if quick else "full"
                loc_drops.append(
                    f"    user{s.user_idx} round{round_idx} ({tag}): "
                    f"missing {sorted(missing)}",
                )
        if loc_drops:
            failures.append(
                f"  {label} ({users[0].location.lat:.4f},{users[0].location.lon:.4f})"
            )
            failures.extend(loc_drops)
            failures.append(
                f"    ground-truth (user0): {sorted(users[0].ground_truth_routes)}",
            )
    return drop_count, failures


# ─────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────


async def _health_check(base_url: str) -> bool:
    async with httpx.AsyncClient() as client:
        try:
            r = await client.get(f"{base_url}/health", timeout=5)
            return r.status_code == 200
        except Exception:
            return False


async def main() -> int:
    print("=" * 78)
    print("/nearby/grouped — comprehensive performance & stability test")
    print("=" * 78)
    print(f"Endpoint:           {ENDPOINT}")
    print(f"Locations:          {len(LOCATIONS)}")
    print(f"Users per location: {USERS_PER_LOCATION}")
    print(f"Rounds per user:    {ROUNDS_PER_USER} (1 ground-truth + {ROUNDS_PER_USER} follow-ups)")
    print(f"Total expected calls: ~{len(LOCATIONS) * USERS_PER_LOCATION * (ROUNDS_PER_USER + 1)}")
    print(f"Radius:             {RADIUS_M} m   Jitter: ±{JITTER_DEG}°  (~30 m)")
    print(f"Inflight cap:       {GLOBAL_INFLIGHT_LIMIT}")
    print("─" * 78)

    if not await _health_check(BASE_URL):
        print(f"❌ Backend unreachable at {BASE_URL}")
        print("   Start it with: cd TrackBackend && .venv/bin/python run.py")
        return 2
    print("✅ Health check: OK")
    print()

    random.seed(0xBADCAB)

    t0 = time.perf_counter()
    all_user_stats: list[UserStats] = []
    async with httpx.AsyncClient(limits=HTTPX_LIMITS) as client:
        # Run all locations concurrently (capped via _inflight_sem).
        tasks = [run_location(client, loc) for loc in LOCATIONS]
        for loc, fut in zip(LOCATIONS, asyncio.as_completed(tasks), strict=False):
            user_results = await fut
            all_user_stats.extend(user_results)
            if not QUIET:
                gt_counts = [len(s.ground_truth_routes) for s in user_results]
                err_counts = sum(len(s.errors) for s in user_results)
                drop_users = sum(1 for s in user_results if s.missing_per_call)
                marker = "❌" if drop_users else ("⚠️ " if err_counts else "✅")
                print(
                    f"  {marker} {user_results[0].location.label:<32} "
                    f"gt-routes={gt_counts}  "
                    f"drops={drop_users}/{len(user_results)}  "
                    f"errs={err_counts}"
                )
    wall_ms = (time.perf_counter() - t0) * 1000.0

    # ── Aggregate ────────────────────────────────────────────────────
    agg = AggregateStats()
    for s in all_user_stats:
        agg.full_latencies_ms.extend(s.full_latencies_ms)
        agg.quick_latencies_ms.extend(s.quick_latencies_ms)
        agg.errors += len(s.errors)
        for m, rs in s.seen_routes_by_mode.items():
            agg.seen_routes_by_mode.setdefault(m, set()).update(rs)

    drop_count, drop_lines = assert_no_drops(all_user_stats)
    agg.drops = drop_count

    total_calls = len(agg.full_latencies_ms) + len(agg.quick_latencies_ms)
    print()
    print("─" * 78)
    print(
        f"Wall clock: {wall_ms / 1000:.1f} s   "
        f"Calls: {total_calls}   "
        f"Throughput: {total_calls / max(wall_ms / 1000, 0.001):.1f} req/s"
    )
    print("─" * 78)
    print("Latency:")
    print(fmt_latency_row("full mode",  agg.full_latencies_ms))
    print(fmt_latency_row("quick mode", agg.quick_latencies_ms))
    print()
    print(coverage_report(agg))

    # ── Q26 specific check ──────────────────────────────────────────
    print()
    print("Q26 regression check:")
    q26_users = [s for s in all_user_stats if "q26" in s.location.tags]
    if not q26_users:
        print("  (no Q26-tagged locations in run)")
    for s in q26_users:
        has_q26_gt = any(r.upper().endswith("Q26") or r.upper() == "Q26" for r in s.ground_truth_routes)
        had_q26_any = any(r.upper().endswith("Q26") or r.upper() == "Q26" for r in s.seen_routes)
        marker = "✅" if has_q26_gt else "❌"
        extra = "" if has_q26_gt or not had_q26_any else "  (appeared on follow-ups only — sticky saved it)"
        print(
            f"  {marker} {s.location.label} user{s.user_idx}: "
            f"gt={'Q26 present' if has_q26_gt else 'Q26 MISSING'} "
            f"({len(s.ground_truth_routes)} routes){extra}",
        )

    # ── Drop diagnostics ────────────────────────────────────────────
    if drop_count:
        print()
        print(f"❌ {drop_count} ROUTE STABILITY VIOLATIONS:")
        for line in drop_lines:
            print(line)

    if agg.errors:
        print()
        print(f"⚠️  {agg.errors} error(s) (non-fatal):")
        # show only first 25 to keep output bounded
        shown = 0
        for s in all_user_stats:
            if shown >= 25:
                break
            for e in s.errors:
                print(f"  [{s.location.label} u{s.user_idx}] {e}")
                shown += 1
                if shown >= 25:
                    break

    print()
    if drop_count:
        print(f"RESULT: ❌ FAIL — {drop_count} route drops")
        return 1
    if agg.errors:
        print(f"RESULT: ⚠️  PASS-WITH-ERRORS ({agg.errors} non-stability errors)")
        return 0
    print("RESULT: ✅ PASS — every route stable across every round")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
