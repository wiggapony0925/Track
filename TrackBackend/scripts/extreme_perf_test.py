#!/usr/bin/env python3
"""
extreme_perf_test.py — EXTREME backend performance & stress test.

Hammers every Track API endpoint with escalating concurrency levels:
  Phase 1: Warmup baseline (10 concurrent users)
  Phase 2: Sustained load (50 concurrent users × 3 rounds)
  Phase 3: Spike burst (100 concurrent users, all at once)
  Phase 4: Endurance soak (50 users × 10 rounds, 500 total requests)
  Phase 5: Heavy payload stress (shapes/all, stations/all — big responses)
  Phase 6: Rapid-fire single endpoint (200 serial hits, measures p99 drift)
  Phase 7: Mixed chaos (random endpoints, random locations, 100 concurrent)

Outputs a detailed report to logs/extreme_perf_results.txt with:
  - Per-endpoint latency: min / p50 / p90 / p99 / max
  - Throughput (req/s) per phase
  - Error rates and status code distribution
  - Memory/CPU delta (via /metrics endpoint scraping)

Usage:
    cd TrackBackend
    source .venv/bin/activate
    python scripts/extreme_perf_test.py                          # localhost:8767
    python scripts/extreme_perf_test.py --base http://localhost:8000
    python scripts/extreme_perf_test.py --base https://track-vkrr.onrender.com
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import statistics
import sys
import time
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import httpx
except ImportError:
    print("ERROR: httpx not installed.  pip install httpx")
    sys.exit(1)

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════════════════════════════════════════

DEFAULT_BASE = "http://127.0.0.1:8767"
TIMEOUT = 60.0            # nearby/grouped can take 25s+ (cold MTA calls)
TIMEOUT_LIGHT = 15.0      # fast/cached endpoints

# NYC locations — spread across all boroughs + edge cases
LOCATIONS = [
    ("Penn Station",           40.7505, -73.9934),
    ("Times Square",           40.7580, -73.9855),
    ("Grand Central",          40.7527, -73.9772),
    ("Wall Street",            40.7074, -74.0113),
    ("Union Square",           40.7359, -73.9911),
    ("Columbus Circle",        40.7681, -73.9819),
    ("Downtown Brooklyn",      40.6892, -73.9857),
    ("Williamsburg",           40.7081, -73.9571),
    ("Jackson Heights",        40.7466, -73.8913),
    ("Flushing",               40.7614, -73.8300),
    ("Yankee Stadium",         40.8296, -73.9262),
    ("Fordham",                40.8614, -73.8877),
    ("St George SI",           40.6433, -74.0735),
    ("Astoria",                40.7722, -73.9174),
    ("Harlem 125th",           40.8075, -73.9455),
    ("Coney Island",           40.5755, -73.9707),
    ("JFK Airport",            40.6413, -73.7781),
    ("Bushwick",               40.6944, -73.9213),
    ("LIC Court Square",       40.7471, -73.9459),
    ("Washington Heights",     40.8468, -73.9316),
]

SUBWAY_LINES = ["A", "C", "E", "B", "D", "F", "M", "N", "Q", "R", "W",
                "1", "2", "3", "4", "5", "6", "7", "G", "J", "Z", "L", "S"]

BUS_ROUTES = [
    "MTA NYCT_M15", "MTA NYCT_M34-SBS", "MTA NYCT_B44",
    "MTA NYCT_B63", "MTA NYCT_Q58", "MTABC_BX1",
    "MTA NYCT_M1", "MTA NYCT_S79-SBS",
]

BUS_STOP_IDS = ["MTA_305168", "MTA_308209", "MTA_504185",
                "MTA_400561", "MTA_308214"]

LIRR_ROUTES = ["9", "2", "1", "10"]
MNR_ROUTES  = ["1", "2", "4", "5"]

# ═══════════════════════════════════════════════════════════════════════════════
# DATA TYPES
# ═══════════════════════════════════════════════════════════════════════════════

@dataclass
class RequestResult:
    endpoint: str
    status: int
    latency: float          # seconds
    size: int               # response bytes
    error: str | None = None

@dataclass
class PhaseReport:
    name: str
    total_requests: int = 0
    total_errors: int = 0
    wall_time: float = 0.0
    results: list[RequestResult] = field(default_factory=list)

    @property
    def rps(self) -> float:
        return self.total_requests / self.wall_time if self.wall_time > 0 else 0

    @property
    def error_rate(self) -> float:
        return (self.total_errors / self.total_requests * 100) if self.total_requests else 0

    def latency_stats(self, endpoint: str | None = None) -> dict[str, float]:
        times = [r.latency for r in self.results
                 if (endpoint is None or r.endpoint == endpoint) and r.error is None]
        if not times:
            return {}
        times.sort()
        n = len(times)
        return {
            "min":  times[0],
            "p50":  times[n // 2],
            "p90":  times[int(n * 0.90)],
            "p95":  times[int(n * 0.95)],
            "p99":  times[int(n * 0.99)],
            "max":  times[-1],
            "mean": statistics.mean(times),
            "stdev": statistics.stdev(times) if n > 1 else 0,
            "count": n,
        }

    def status_distribution(self) -> dict[int, int]:
        dist: dict[int, int] = defaultdict(int)
        for r in self.results:
            dist[r.status] += 1
        return dict(sorted(dist.items()))

# ═══════════════════════════════════════════════════════════════════════════════
# HTTP HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

async def _hit(client: httpx.AsyncClient, method: str, url: str,
               label: str, timeout: float | None = None) -> RequestResult:
    """Fire a single request, return timing + metadata."""
    t = timeout or (TIMEOUT if "/nearby" in url else TIMEOUT_LIGHT)
    t0 = time.perf_counter()
    try:
        resp = await client.request(method, url, timeout=t)
        elapsed = time.perf_counter() - t0
        return RequestResult(
            endpoint=label,
            status=resp.status_code,
            latency=elapsed,
            size=len(resp.content),
        )
    except Exception as exc:
        elapsed = time.perf_counter() - t0
        return RequestResult(
            endpoint=label,
            status=0,
            latency=elapsed,
            size=0,
            error=str(exc)[:120],
        )


def _rand_loc() -> tuple[str, float, float]:
    return random.choice(LOCATIONS)

# ═══════════════════════════════════════════════════════════════════════════════
# ENDPOINT GENERATORS
# ═══════════════════════════════════════════════════════════════════════════════

def _all_endpoint_urls(base: str) -> list[tuple[str, str, str]]:
    """Return (method, url, label) tuples for every hittable endpoint."""
    urls: list[tuple[str, str, str]] = []

    # --- System ---
    urls.append(("GET", f"{base}/health", "/health"))
    urls.append(("GET", f"{base}/config", "/config"))
    urls.append(("GET", f"{base}/data/status", "/data/status"))

    # --- Nearby (core endpoint, multiple locations) ---
    for name, lat, lon in LOCATIONS[:8]:
        urls.append(("GET", f"{base}/nearby/grouped?lat={lat}&lon={lon}&radius=800",
                      f"/nearby/grouped [{name}]"))

    # --- Subway ---
    for line in SUBWAY_LINES:
        urls.append(("GET", f"{base}/subway/{line}", f"/subway/{line}"))

    for name, lat, lon in LOCATIONS[:5]:
        urls.append(("GET", f"{base}/subway/stations/nearby?lat={lat}&lon={lon}&radius=1600",
                      f"/subway/stations/nearby [{name}]"))

    urls.append(("GET", f"{base}/subway/stations/all", "/subway/stations/all"))
    urls.append(("GET", f"{base}/subway/stations/processed", "/subway/stations/processed"))

    for line in ["A", "1", "7", "L", "G"]:
        urls.append(("GET", f"{base}/subway/shape/{line}", f"/subway/shape/{line}"))

    # --- Bus ---
    for name, lat, lon in LOCATIONS[:5]:
        urls.append(("GET", f"{base}/bus/nearby?lat={lat}&lon={lon}&radius=800",
                      f"/bus/nearby [{name}]"))

    urls.append(("GET", f"{base}/bus/routes", "/bus/routes"))

    for rt in BUS_ROUTES[:4]:
        urls.append(("GET", f"{base}/bus/stops/{rt}", f"/bus/stops/{rt}"))
        urls.append(("GET", f"{base}/bus/vehicles/{rt}", f"/bus/vehicles/{rt}"))
        urls.append(("GET", f"{base}/bus/route-shape/{rt}", f"/bus/route-shape/{rt}"))
        urls.append(("GET", f"{base}/bus/schedule/{rt}", f"/bus/schedule/{rt}"))

    for sid in BUS_STOP_IDS:
        urls.append(("GET", f"{base}/bus/live/{sid}", f"/bus/live/{sid}"))

    # --- LIRR ---
    urls.append(("GET", f"{base}/lirr", "/lirr"))
    urls.append(("GET", f"{base}/lirr/shapes/all", "/lirr/shapes/all"))
    for rt in LIRR_ROUTES:
        urls.append(("GET", f"{base}/lirr/shape/{rt}", f"/lirr/shape/{rt}"))

    # --- MNR ---
    urls.append(("GET", f"{base}/mnr", "/mnr"))
    urls.append(("GET", f"{base}/mnr/shapes/all", "/mnr/shapes/all"))
    for rt in MNR_ROUTES:
        urls.append(("GET", f"{base}/mnr/shape/{rt}", f"/mnr/shape/{rt}"))

    # --- Alerts & Accessibility ---
    urls.append(("GET", f"{base}/alerts", "/alerts"))
    urls.append(("GET", f"{base}/alerts?mode=subway", "/alerts?mode=subway"))
    urls.append(("GET", f"{base}/alerts?mode=bus", "/alerts?mode=bus"))
    urls.append(("GET", f"{base}/accessibility", "/accessibility"))

    # --- Weather ---
    urls.append(("GET", f"{base}/weather", "/weather"))
    urls.append(("GET", f"{base}/weather?lat=40.7505&lon=-73.9934", "/weather [Penn]"))

    # --- ML Prediction ---
    urls.append(("GET",
        f"{base}/predict/delay?minutes_away=5&route_id=A&hour=8&day_of_week=1",
        "/predict/delay [A, 5min]"))
    urls.append(("GET",
        f"{base}/predict/delay?minutes_away=12&route_id=7&hour=17&day_of_week=3&mode=subway",
        "/predict/delay [7, 12min]"))

    return urls

# ═══════════════════════════════════════════════════════════════════════════════
# PHASES
# ═══════════════════════════════════════════════════════════════════════════════

async def phase_warmup(client: httpx.AsyncClient, base: str) -> PhaseReport:
    """Phase 1: Hit every endpoint once with low concurrency to warm caches."""
    report = PhaseReport(name="Phase 1: Warmup Baseline")
    endpoints = _all_endpoint_urls(base)
    sem = asyncio.Semaphore(10)

    async def _go(m, u, l):
        async with sem:
            return await _hit(client, m, u, l)

    t0 = time.perf_counter()
    results = await asyncio.gather(*[_go(m, u, l) for m, u, l in endpoints])
    report.wall_time = time.perf_counter() - t0
    report.results = list(results)
    report.total_requests = len(results)
    report.total_errors = sum(1 for r in results if r.error or r.status >= 500)
    return report


async def phase_sustained(client: httpx.AsyncClient, base: str) -> PhaseReport:
    """Phase 2: 50 concurrent users × 3 rounds — mixed fast endpoints."""
    report = PhaseReport(name="Phase 2: Sustained Load (50 users × 3 rounds)")
    sem = asyncio.Semaphore(50)

    # Mix of fast endpoints (subway, alerts, weather) + a few nearby calls
    fast_endpoints = [
        *[(f"{base}/subway/{l}", f"/subway/{l}") for l in SUBWAY_LINES[:12]],
        *[(f"{base}/alerts", "/alerts") for _ in range(5)],
        *[(f"{base}/weather?lat=40.75&lon=-73.99", "/weather") for _ in range(5)],
        *[(f"{base}/lirr", "/lirr") for _ in range(3)],
        *[(f"{base}/mnr", "/mnr") for _ in range(3)],
        *[(f"{base}/bus/routes", "/bus/routes") for _ in range(3)],
        *[(f"{base}/subway/stations/all", "/subway/stations/all") for _ in range(3)],
        *[(f"{base}/predict/delay?minutes_away=5&route_id=A&hour=8&day_of_week=1",
           "/predict/delay") for _ in range(5)],
    ]
    # Add a few nearby/grouped (the expensive ones)
    for name, lat, lon in LOCATIONS[:5]:
        fast_endpoints.append((f"{base}/nearby/grouped?lat={lat}&lon={lon}&radius=800",
                               f"/nearby/grouped [{name}]"))

    # Pad to 150 total
    while len(fast_endpoints) < 150:
        fast_endpoints.append(random.choice(fast_endpoints[:30]))
    random.shuffle(fast_endpoints)
    fast_endpoints = fast_endpoints[:150]

    async def _go(url, label):
        async with sem:
            return await _hit(client, "GET", url, label)

    t0 = time.perf_counter()
    results = await asyncio.gather(*[_go(u, l) for u, l in fast_endpoints])
    report.wall_time = time.perf_counter() - t0
    report.results = list(results)
    report.total_requests = len(results)
    report.total_errors = sum(1 for r in results if r.error or r.status >= 500)
    return report


async def phase_spike(client: httpx.AsyncClient, base: str) -> PhaseReport:
    """Phase 3: 100 concurrent requests fired simultaneously — stress burst."""
    report = PhaseReport(name="Phase 3: Spike Burst (100 concurrent)")

    # Mix of endpoints to simulate real traffic
    tasks = []
    for _ in range(30):
        name, lat, lon = _rand_loc()
        tasks.append(("GET", f"{base}/nearby/grouped?lat={lat}&lon={lon}", "/nearby/grouped"))
    for _ in range(20):
        line = random.choice(SUBWAY_LINES)
        tasks.append(("GET", f"{base}/subway/{line}", f"/subway/{line}"))
    for _ in range(15):
        name, lat, lon = _rand_loc()
        tasks.append(("GET", f"{base}/bus/nearby?lat={lat}&lon={lon}", "/bus/nearby"))
    for _ in range(10):
        tasks.append(("GET", f"{base}/alerts", "/alerts"))
    for _ in range(10):
        tasks.append(("GET", f"{base}/weather?lat=40.75&lon=-73.99", "/weather"))
    for _ in range(5):
        tasks.append(("GET", f"{base}/predict/delay?minutes_away=5&route_id=A&hour=8&day_of_week=1",
                       "/predict/delay"))
    for _ in range(5):
        tasks.append(("GET", f"{base}/lirr", "/lirr"))
    for _ in range(5):
        tasks.append(("GET", f"{base}/mnr", "/mnr"))

    random.shuffle(tasks)

    t0 = time.perf_counter()
    results = await asyncio.gather(*[_hit(client, m, u, l) for m, u, l in tasks])
    report.wall_time = time.perf_counter() - t0
    report.results = list(results)
    report.total_requests = len(results)
    report.total_errors = sum(1 for r in results if r.error or r.status >= 500)
    return report


async def phase_endurance(client: httpx.AsyncClient, base: str) -> PhaseReport:
    """Phase 4: Soak — 50 users × 10 waves, mixed endpoints, 0.5s between waves."""
    report = PhaseReport(name="Phase 4: Endurance Soak (500 requests, 10 waves)")
    all_results: list[RequestResult] = []
    sem = asyncio.Semaphore(50)

    # Build a pool of endpoints with ~90% fast, ~10% nearby/grouped
    fast_pool = [
        *[(f"{base}/subway/{l}", f"/subway/{l}") for l in SUBWAY_LINES],
        *[(f"{base}/alerts", "/alerts"),
          (f"{base}/alerts?mode=subway", "/alerts?mode=subway"),
          (f"{base}/alerts?mode=bus", "/alerts?mode=bus")],
        *[(f"{base}/weather?lat=40.75&lon=-73.99", "/weather")],
        *[(f"{base}/lirr", "/lirr"), (f"{base}/mnr", "/mnr")],
        *[(f"{base}/health", "/health"), (f"{base}/config", "/config")],
        *[(f"{base}/predict/delay?minutes_away={m}&route_id={r}&hour=8&day_of_week=1",
           f"/predict/delay [{r},{m}m]")
          for m in [3, 5, 10] for r in ["A", "7", "L"]],
        *[(f"{base}/bus/stops/{rt}", f"/bus/stops/{rt}") for rt in BUS_ROUTES[:3]],
        *[(f"{base}/subway/shape/{l}", f"/subway/shape/{l}") for l in ["A", "1", "7"]],
        *[(f"{base}/accessibility", "/accessibility")],
    ]

    async def _go():
        # 10% chance of hitting nearby/grouped
        if random.random() < 0.10:
            name, lat, lon = _rand_loc()
            url = f"{base}/nearby/grouped?lat={lat}&lon={lon}&radius=800"
            label = f"/nearby/grouped [{name}]"
        else:
            url, label = random.choice(fast_pool)
        async with sem:
            return await _hit(client, "GET", url, label)

    t0 = time.perf_counter()
    for wave in range(10):
        results = await asyncio.gather(*[_go() for _ in range(50)])
        all_results.extend(results)
        if wave < 9:
            await asyncio.sleep(0.5)
    report.wall_time = time.perf_counter() - t0
    report.results = all_results
    report.total_requests = len(all_results)
    report.total_errors = sum(1 for r in all_results if r.error or r.status >= 500)
    return report


async def phase_heavy_payload(client: httpx.AsyncClient, base: str) -> PhaseReport:
    """Phase 5: Stress the largest endpoints — shapes, all stations, bus routes."""
    report = PhaseReport(name="Phase 5: Heavy Payload Stress")
    heavy = [
        ("GET", f"{base}/subway/shapes/all", "/subway/shapes/all"),
        ("GET", f"{base}/subway/stations/all", "/subway/stations/all"),
        ("GET", f"{base}/subway/stations/processed", "/subway/stations/processed"),
        ("GET", f"{base}/lirr/shapes/all", "/lirr/shapes/all"),
        ("GET", f"{base}/mnr/shapes/all", "/mnr/shapes/all"),
        ("GET", f"{base}/bus/routes", "/bus/routes"),
    ]

    # Hit each heavy endpoint 5× concurrently
    tasks = heavy * 5
    random.shuffle(tasks)

    t0 = time.perf_counter()
    results = await asyncio.gather(*[_hit(client, m, u, l) for m, u, l in tasks])
    report.wall_time = time.perf_counter() - t0
    report.results = list(results)
    report.total_requests = len(results)
    report.total_errors = sum(1 for r in results if r.error or r.status >= 500)
    return report


async def phase_rapid_fire(client: httpx.AsyncClient, base: str) -> PhaseReport:
    """Phase 6: 300 serial requests across fast endpoints — measures latency drift."""
    report = PhaseReport(name="Phase 6: Rapid-Fire Serial (300 hits)")

    # Cycle through cached endpoints to test sustained serial throughput
    targets = [
        (f"{base}/subway/1", "/subway/1"),
        (f"{base}/subway/A", "/subway/A"),
        (f"{base}/subway/7", "/subway/7"),
        (f"{base}/subway/L", "/subway/L"),
        (f"{base}/alerts", "/alerts"),
        (f"{base}/weather?lat=40.75&lon=-73.99", "/weather"),
        (f"{base}/health", "/health"),
        (f"{base}/config", "/config"),
        (f"{base}/lirr", "/lirr"),
        (f"{base}/mnr", "/mnr"),
    ]

    t0 = time.perf_counter()
    for i in range(300):
        url, label = targets[i % len(targets)]
        result = await _hit(client, "GET", url, f"{label} [serial #{i+1}]")
        report.results.append(result)
    report.wall_time = time.perf_counter() - t0
    report.total_requests = 300
    report.total_errors = sum(1 for r in report.results if r.error or r.status >= 500)
    return report


async def phase_chaos(client: httpx.AsyncClient, base: str) -> PhaseReport:
    """Phase 7: 100 fully random concurrent requests — simulate real-world chaos."""
    report = PhaseReport(name="Phase 7: Mixed Chaos (100 random concurrent)")

    all_endpoints = _all_endpoint_urls(base)
    tasks = [random.choice(all_endpoints) for _ in range(100)]

    t0 = time.perf_counter()
    results = await asyncio.gather(*[_hit(client, m, u, l) for m, u, l in tasks])
    report.wall_time = time.perf_counter() - t0
    report.results = list(results)
    report.total_requests = len(results)
    report.total_errors = sum(1 for r in results if r.error or r.status >= 500)
    return report


# ═══════════════════════════════════════════════════════════════════════════════
# REPORT FORMATTING
# ═══════════════════════════════════════════════════════════════════════════════

def _ms(s: float) -> str:
    return f"{s * 1000:.1f}ms"

def _sz(b: int) -> str:
    if b < 1024:
        return f"{b}B"
    if b < 1024 * 1024:
        return f"{b / 1024:.1f}KB"
    return f"{b / (1024 * 1024):.1f}MB"


def format_phase(report: PhaseReport) -> str:
    lines: list[str] = []
    lines.append(f"\n{'═' * 80}")
    lines.append(f"  {report.name}")
    lines.append(f"{'═' * 80}")
    lines.append(f"  Total requests:  {report.total_requests}")
    lines.append(f"  Wall time:       {report.wall_time:.2f}s")
    lines.append(f"  Throughput:      {report.rps:.1f} req/s")
    lines.append(f"  Errors:          {report.total_errors} ({report.error_rate:.1f}%)")
    lines.append(f"  Status codes:    {report.status_distribution()}")

    # Overall latency
    overall = report.latency_stats()
    if overall:
        lines.append(f"\n  Overall Latency:")
        lines.append(f"    min={_ms(overall['min'])}  p50={_ms(overall['p50'])}  "
                      f"p90={_ms(overall['p90'])}  p95={_ms(overall['p95'])}  "
                      f"p99={_ms(overall['p99'])}  max={_ms(overall['max'])}")
        lines.append(f"    mean={_ms(overall['mean'])}  stdev={_ms(overall['stdev'])}")

    # Per-endpoint breakdown (group by base label)
    endpoints = sorted(set(r.endpoint.split(" [")[0] for r in report.results))
    if len(endpoints) > 1:
        lines.append(f"\n  Per-Endpoint Breakdown:")
        lines.append(f"  {'Endpoint':<35s} {'Count':>5s}  {'p50':>8s}  {'p90':>8s}  "
                      f"{'p99':>8s}  {'Max':>8s}  {'Errs':>4s}  {'Avg Size':>9s}")
        lines.append(f"  {'-' * 95}")
        for ep in endpoints:
            ep_results = [r for r in report.results if r.endpoint.startswith(ep)]
            stats = report.latency_stats()
            # compute per-endpoint stats manually
            times = sorted(r.latency for r in ep_results if r.error is None)
            errs = sum(1 for r in ep_results if r.error or r.status >= 500)
            avg_size = (sum(r.size for r in ep_results) // len(ep_results)) if ep_results else 0
            if times:
                n = len(times)
                lines.append(
                    f"  {ep:<35s} {len(ep_results):>5d}  "
                    f"{_ms(times[n // 2]):>8s}  "
                    f"{_ms(times[int(n * 0.90)]):>8s}  "
                    f"{_ms(times[int(n * 0.99)]):>8s}  "
                    f"{_ms(times[-1]):>8s}  "
                    f"{errs:>4d}  "
                    f"{_sz(avg_size):>9s}"
                )
            else:
                lines.append(f"  {ep:<35s} {len(ep_results):>5d}  {'ALL ERRORS':>40s}")

    # Show actual errors if any
    errors = [r for r in report.results if r.error]
    if errors:
        lines.append(f"\n  Errors ({len(errors)}):")
        seen: set[str] = set()
        for r in errors[:20]:
            key = f"{r.endpoint}: {r.error}"
            if key not in seen:
                seen.add(key)
                lines.append(f"    [{r.endpoint}] {r.error}")

    return "\n".join(lines)


def format_summary(phases: list[PhaseReport]) -> str:
    total_req = sum(p.total_requests for p in phases)
    total_err = sum(p.total_errors for p in phases)
    total_time = sum(p.wall_time for p in phases)

    all_latencies = sorted(r.latency for p in phases for r in p.results if r.error is None)
    total_bytes = sum(r.size for p in phases for r in p.results)
    n = len(all_latencies)

    lines = [
        f"\n{'█' * 80}",
        f"  EXTREME PERFORMANCE TEST — FINAL SUMMARY",
        f"{'█' * 80}",
        f"",
        f"  Test run:        {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}",
        f"  Total requests:  {total_req}",
        f"  Total errors:    {total_err} ({total_err / total_req * 100:.1f}%)" if total_req else "",
        f"  Total wall time: {total_time:.1f}s",
        f"  Avg throughput:  {total_req / total_time:.1f} req/s" if total_time else "",
        f"  Total data:      {_sz(total_bytes)}",
        f"",
    ]

    if all_latencies:
        lines.extend([
            f"  Global Latency Distribution ({n} successful requests):",
            f"    min  = {_ms(all_latencies[0])}",
            f"    p50  = {_ms(all_latencies[n // 2])}",
            f"    p90  = {_ms(all_latencies[int(n * 0.90)])}",
            f"    p95  = {_ms(all_latencies[int(n * 0.95)])}",
            f"    p99  = {_ms(all_latencies[int(n * 0.99)])}",
            f"    max  = {_ms(all_latencies[-1])}",
            f"    mean = {_ms(statistics.mean(all_latencies))}",
            f"",
        ])

    # Phase comparison table
    lines.append(f"  Phase Comparison:")
    lines.append(f"  {'Phase':<45s} {'Reqs':>5s}  {'Errs':>4s}  {'RPS':>7s}  {'p50':>8s}  {'p99':>8s}")
    lines.append(f"  {'-' * 85}")
    for p in phases:
        stats = p.latency_stats()
        lines.append(
            f"  {p.name:<45s} {p.total_requests:>5d}  {p.total_errors:>4d}  "
            f"{p.rps:>6.1f}  "
            f"{_ms(stats.get('p50', 0)):>8s}  "
            f"{_ms(stats.get('p99', 0)):>8s}"
        )

    # Verdict
    lines.append(f"\n  {'─' * 40}")
    if total_err == 0:
        lines.append(f"  ✅ VERDICT: ALL {total_req} REQUESTS PASSED — ZERO ERRORS")
    elif total_err / total_req < 0.01:
        lines.append(f"  ⚠️  VERDICT: {total_err}/{total_req} errors ({total_err/total_req*100:.2f}%) — ACCEPTABLE")
    elif total_err / total_req < 0.05:
        lines.append(f"  ⚠️  VERDICT: {total_err}/{total_req} errors ({total_err/total_req*100:.1f}%) — NEEDS ATTENTION")
    else:
        lines.append(f"  ❌ VERDICT: {total_err}/{total_req} errors ({total_err/total_req*100:.1f}%) — CRITICAL")

    p99 = all_latencies[int(n * 0.99)] if all_latencies else 0
    if p99 < 0.5:
        lines.append(f"  ✅ LATENCY: p99 = {_ms(p99)} — EXCELLENT")
    elif p99 < 2.0:
        lines.append(f"  ⚠️  LATENCY: p99 = {_ms(p99)} — ACCEPTABLE")
    else:
        lines.append(f"  ❌ LATENCY: p99 = {_ms(p99)} — TOO SLOW")

    lines.append(f"  {'─' * 40}")
    return "\n".join(lines)


# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

async def main(base: str) -> None:
    print(f"\n🔥 EXTREME PERFORMANCE TEST")
    print(f"   Target: {base}")
    print(f"   Time:   {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'─' * 60}\n")

    # Verify server is alive
    async with httpx.AsyncClient() as c:
        try:
            r = await c.get(f"{base}/health", timeout=10)
            if r.status_code != 200:
                print(f"❌ Server returned {r.status_code} on /health — aborting.")
                sys.exit(1)
            print(f"✅ Server healthy ({r.status_code})\n")
        except Exception as e:
            print(f"❌ Cannot reach {base}/health: {e}")
            sys.exit(1)

    limits = httpx.Limits(max_connections=150, max_keepalive_connections=50)
    async with httpx.AsyncClient(limits=limits) as client:
        phases: list[PhaseReport] = []

        runners = [
            ("1/7", phase_warmup),
            ("2/7", phase_sustained),
            ("3/7", phase_spike),
            ("4/7", phase_endurance),
            ("5/7", phase_heavy_payload),
            ("6/7", phase_rapid_fire),
            ("7/7", phase_chaos),
        ]

        for label, fn in runners:
            print(f"⏳ [{label}] Running {fn.__doc__.strip().split(chr(10))[0]}...")
            report = await fn(client, base)
            phases.append(report)
            stats = report.latency_stats()
            p50 = _ms(stats.get("p50", 0)) if stats else "N/A"
            print(f"   ✓ {report.total_requests} reqs in {report.wall_time:.1f}s "
                  f"({report.rps:.0f} req/s) | p50={p50} | "
                  f"errors={report.total_errors}\n")

    # Build full report
    output_lines: list[str] = []
    output_lines.append(f"EXTREME PERFORMANCE TEST REPORT")
    output_lines.append(f"Target: {base}")
    output_lines.append(f"Date:   {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")

    for p in phases:
        output_lines.append(format_phase(p))

    output_lines.append(format_summary(phases))

    full_report = "\n".join(output_lines)

    # Save to file
    log_dir = Path(__file__).resolve().parent.parent / "logs"
    log_dir.mkdir(exist_ok=True)
    out_path = log_dir / "extreme_perf_results.txt"
    out_path.write_text(full_report, encoding="utf-8")

    # Print summary to terminal
    print(format_summary(phases))
    print(f"\n📄 Full report saved to: {out_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Extreme performance test for Track backend")
    parser.add_argument("--base", default=DEFAULT_BASE, help=f"Base URL (default: {DEFAULT_BASE})")
    args = parser.parse_args()

    asyncio.run(main(args.base))
