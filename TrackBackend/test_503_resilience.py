#!/usr/bin/env python3
"""
Local 503 resilience test suite.

Tests 4 scenarios against the local backend + engine:
  1. Happy path — engine is up, /engine/go returns 200
  2. Engine down — kill engine, /engine/go retries + returns 503 with clear error
  3. Half-open recovery — engine is restarted, circuit breaker detects it via /health
  4. Rapid-fire under downtime — 5 concurrent requests while engine is down

Usage:
  cd TrackBackend
  source .venv/bin/activate
  TRACK_ENGINE_URL=http://localhost:8092 python test_503_resilience.py
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import httpx

BACKEND_URL = os.environ.get("BACKEND_URL", "http://127.0.0.1:8000")
ENGINE_PORT = int(os.environ.get("ENGINE_PORT", "8092"))
ENGINE_DB = os.environ.get(
    "TRACK_ENGINE_SCHEDULE_DB",
    os.path.join(os.path.dirname(__file__), "app", "data", "transit_schedule.db"),
)

# Penn Station → Times Square (always has service)
GO_PAYLOAD = {
    "origin": {"label": "Penn Station", "lat": 40.7506, "lon": -73.9935},
    "destination": {"label": "Times Square", "lat": 40.7580, "lon": -73.9855},
    "max_transfers": 2,
    "max_origin_walk_m": 1400,
    "max_destination_walk_m": 1200,
    "max_transfer_walk_m": 350,
    "search_window_minutes": 180,
    "num_itineraries": 4,
    "modes": ["subway", "bus"],
    "record_recent": False,
    "now_ts": int(time.time()),
}


def green(s: str) -> str: return f"\033[92m{s}\033[0m"
def red(s: str) -> str:   return f"\033[91m{s}\033[0m"
def yellow(s: str) -> str: return f"\033[93m{s}\033[0m"
def bold(s: str) -> str:  return f"\033[1m{s}\033[0m"


def start_engine() -> subprocess.Popen:
    """Start a local TrackEngine on ENGINE_PORT."""
    # Find the binary
    bin_path = os.path.join(
        os.path.dirname(__file__), "..", "TrackEngine", "build", "bin", "trackengine"
    )
    if not os.path.isfile(bin_path):
        print(red(f"Engine binary not found at {bin_path}"))
        sys.exit(1)

    env = os.environ.copy()
    env["TRACK_ENGINE_PORT"] = str(ENGINE_PORT)
    env["TRACK_ENGINE_SCHEDULE_DB"] = ENGINE_DB

    proc = subprocess.Popen(
        [bin_path],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    # Wait for it to be ready
    for _ in range(30):
        try:
            r = httpx.get(f"http://localhost:{ENGINE_PORT}/health", timeout=1.0)
            if r.status_code == 200:
                return proc
        except Exception:
            pass
        time.sleep(0.5)
    print(red("Engine failed to start within 15s"))
    proc.kill()
    sys.exit(1)


def kill_engine(proc: subprocess.Popen):
    """Kill the engine process."""
    try:
        proc.send_signal(signal.SIGKILL)
        proc.wait(timeout=5)
    except Exception:
        pass


def engine_is_up() -> bool:
    try:
        r = httpx.get(f"http://localhost:{ENGINE_PORT}/health", timeout=2.0)
        return r.status_code == 200
    except Exception:
        return False


def post_go(timeout: float = 20.0) -> httpx.Response:
    """POST /engine/go against the backend."""
    return httpx.post(
        f"{BACKEND_URL}/engine/go",
        json=GO_PAYLOAD,
        timeout=timeout,
    )


def reset_circuit_breaker():
    """Reset the circuit breaker by making a health call to the backend."""
    # Make a health call to ensure the backend is up
    try:
        httpx.get(f"{BACKEND_URL}/health", timeout=5.0)
    except Exception:
        pass


# ─────────────────────────────── TESTS ───────────────────────────────

passed = 0
failed = 0
total = 0


def report(name: str, ok: bool, detail: str = ""):
    global passed, failed, total
    total += 1
    if ok:
        passed += 1
        print(f"  {green('✓')} {name}" + (f"  ({detail})" if detail else ""))
    else:
        failed += 1
        print(f"  {red('✗')} {name}" + (f"  ({detail})" if detail else ""))


def test_1_happy_path(engine_proc):
    """Engine is up → /engine/go returns 200 with trips."""
    print(f"\n{bold('Test 1: Happy path (engine up)')}")

    t0 = time.time()
    resp = post_go()
    elapsed = time.time() - t0

    report(
        "Status 200",
        resp.status_code == 200,
        f"got {resp.status_code}",
    )

    if resp.status_code == 200:
        data = resp.json()
        has_trip = data.get("primary_trip") is not None
        report("Has primary_trip", has_trip)
        n_alts = len(data.get("alternatives", []))
        report("Has alternatives", n_alts > 0, f"{n_alts} alternatives")
    else:
        report("Has primary_trip", False, f"skipped (got {resp.status_code})")

    report(f"Response time < 15s", elapsed < 15, f"{elapsed:.1f}s")


def test_2_engine_down():
    """Engine is down → /engine/go retries and eventually returns 503."""
    print(f"\n{bold('Test 2: Engine down → 503 with retry')}")

    # Verify engine is actually down
    report("Engine confirmed down", not engine_is_up())

    t0 = time.time()
    resp = post_go(timeout=45.0)
    elapsed = time.time() - t0

    report(
        "Status 503",
        resp.status_code == 503,
        f"got {resp.status_code}",
    )

    if resp.status_code == 503:
        detail = resp.json().get("detail", "")
        has_connect = "connect" in detail.lower() or "timed out" in detail.lower()
        report(
            "Error mentions connect/timeout",
            has_connect,
            f"detail: {detail[:100]}",
        )
        has_attempts = "3 attempts" in detail
        report("Retried 3 times", has_attempts, f"detail: {detail[:100]}")

    # Should take ~8s (3 attempts * ~2s connect timeout + 1s + 2s backoff)
    # but less than 20s
    report(
        f"Response time 3-25s (retry backoff)",
        3 < elapsed < 25,
        f"{elapsed:.1f}s",
    )


def test_3_circuit_breaker_blocks():
    """Right after test 2, circuit breaker should block immediately."""
    print(f"\n{bold('Test 3: Circuit breaker fast-fail with health probe')}")

    # Engine is still down, circuit should be open
    t0 = time.time()
    resp = post_go(timeout=30.0)
    elapsed = time.time() - t0

    report("Status 503", resp.status_code == 503, f"got {resp.status_code}")

    if resp.status_code == 503:
        detail = resp.json().get("detail", "")
        is_circuit = "circuit open" in detail.lower() or "connect" in detail.lower()
        report("Circuit open or fast connect fail", is_circuit, detail[:120])

    # With health probe, should be fast (probe timeout 3s + fail)
    report(
        "Fast response (< 8s, circuit or quick fail)",
        elapsed < 8,
        f"{elapsed:.1f}s",
    )


def test_4_half_open_recovery(engine_proc):
    """Engine restarts → half-open circuit detects recovery via /health probe."""
    print(f"\n{bold('Test 4: Half-open recovery (engine restarted)')}")

    report("Engine confirmed up", engine_is_up())

    # The circuit was tripped in test 2/3, but with half-open behavior
    # the health probe should succeed and let the request through
    t0 = time.time()
    resp = post_go(timeout=30.0)
    elapsed = time.time() - t0

    report("Status 200", resp.status_code == 200, f"got {resp.status_code}")

    if resp.status_code == 200:
        data = resp.json()
        has_trip = data.get("primary_trip") is not None
        report("Has primary_trip", has_trip)

    report(f"Response time < 15s", elapsed < 15, f"{elapsed:.1f}s")


def test_5_rapid_fire_down():
    """5 concurrent requests while engine is down → all should 503, no hangs."""
    print(f"\n{bold('Test 5: Rapid-fire 5 requests while engine down')}")

    report("Engine confirmed down", not engine_is_up())

    results: list[tuple[int, float]] = []

    def fire():
        t0 = time.time()
        r = post_go(timeout=45.0)
        return r.status_code, time.time() - t0

    t0_all = time.time()
    with ThreadPoolExecutor(max_workers=5) as pool:
        futures = [pool.submit(fire) for _ in range(5)]
        for f in as_completed(futures):
            results.append(f.result())
    total_elapsed = time.time() - t0_all

    all_503 = all(code == 503 for code, _ in results)
    report("All 5 returned 503", all_503, str([c for c, _ in results]))

    # Should NOT take 5x serial time — circuit breaker should batch-fast-fail
    report(
        f"Total < 35s (not 5x serial)",
        total_elapsed < 35,
        f"{total_elapsed:.1f}s",
    )

    max_single = max(t for _, t in results)
    report(
        f"Slowest single < 25s",
        max_single < 25,
        f"{max_single:.1f}s",
    )


# ─────────────────────────────── MAIN ───────────────────────────────

def main():
    print(bold("=" * 60))
    print(bold("  TrackEngine 503 Resilience Test Suite"))
    print(bold("=" * 60))
    print(f"  Backend:  {BACKEND_URL}")
    print(f"  Engine:   localhost:{ENGINE_PORT}")
    print(f"  DB:       {ENGINE_DB}")

    # Check backend is running
    try:
        r = httpx.get(f"{BACKEND_URL}/health", timeout=5.0)
        if r.status_code != 200:
            print(red(f"\nBackend not healthy: {r.status_code}"))
            sys.exit(1)
        print(f"  Backend:  {green('healthy')}\n")
    except Exception as e:
        print(red(f"\nBackend unreachable at {BACKEND_URL}: {e}"))
        print(yellow("Start it with: cd TrackBackend && TRACK_ENGINE_URL=http://localhost:8092 python run.py"))
        sys.exit(1)

    # ── Phase 1: Engine up ──
    # Kill any existing engine first
    os.system(f"pkill -9 -f 'trackengine.*{ENGINE_PORT}' 2>/dev/null")
    time.sleep(1)

    print(yellow("Starting engine..."))
    engine_proc = start_engine()
    print(green(f"Engine running (pid={engine_proc.pid})"))

    test_1_happy_path(engine_proc)

    # ── Phase 2: Kill engine ──
    print(yellow("\nKilling engine..."))
    kill_engine(engine_proc)
    time.sleep(1)
    assert not engine_is_up(), "Engine should be dead"
    print(green("Engine killed"))

    test_2_engine_down()
    test_3_circuit_breaker_blocks()

    # ── Phase 3: Restart engine ──
    print(yellow("\nRestarting engine..."))
    engine_proc = start_engine()
    print(green(f"Engine restarted (pid={engine_proc.pid})"))

    test_4_half_open_recovery(engine_proc)

    # ── Phase 4: Kill again for rapid-fire test ──
    print(yellow("\nKilling engine for rapid-fire test..."))
    kill_engine(engine_proc)
    time.sleep(1)

    # Wait for circuit to reset (cooldown = 10s)
    print(yellow("Waiting 11s for circuit cooldown..."))
    time.sleep(11)

    test_5_rapid_fire_down()

    # ── Cleanup ──
    print(yellow("\nRestarting engine for future use..."))
    engine_proc = start_engine()
    print(green(f"Engine restored (pid={engine_proc.pid})\n"))

    # ── Summary ──
    print(bold("=" * 60))
    if failed == 0:
        print(green(f"  ALL {passed}/{total} CHECKS PASSED"))
    else:
        print(red(f"  {failed}/{total} CHECKS FAILED"))
    print(bold("=" * 60))

    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    main()
