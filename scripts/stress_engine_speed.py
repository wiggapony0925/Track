#!/usr/bin/env python3
"""Engine-focused speed test for /metromind/chat → plan_route.

Hammers production with trip-planning prompts ONLY, measuring how fast
the chatbot routes "user → LLM → plan_route → TrackEngine → reply".

For every turn we capture:
* total latency (ms)
* time-to-first-token (ms) — how fast does the user see *something*?
* time-to-first-tool-result (ms) — when the engine card appears
* number of plan_route calls (>1 = model retried/refined)
* whether the engine returned itineraries

Then we print p50/p90/p95/p99/max plus a histogram of buckets and the
slowest 5 trips by name.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import time
from dataclasses import dataclass, field

import httpx

DEFAULT_BASE = "https://track-vkrr.onrender.com"

# Fixed origin (Times Square) so we measure engine perf, not GPS variance.
ORIGIN_LAT, ORIGIN_LON = 40.7580, -73.9855

# Diverse trip prompts — covers short rides, airports, cross-borough,
# fuzzy-name resolution, and accessibility. All real NYC pairs.
TRIPS: list[str] = [
    "how do i get from times square to grand central",
    "trip from times square to penn station",
    "plan from times square to union square",
    "fastest from times square to brooklyn bridge",
    "times square to wall street",
    "how do i get from times square to dumbo",
    "times square to williamsburg",
    "times square to bushwick",
    "times square to atlantic terminal",
    "times square to coney island",
    "how do i get to jfk from times square",
    "times square to laguardia",
    "times square to newark airport",
    "times square to flushing",
    "times square to astoria",
    "times square to forest hills",
    "times square to jamaica center",
    "times square to harlem",
    "times square to washington heights",
    "times square to inwood",
    "times square to yankee stadium",
    "times square to bronx zoo",
    "times square to upper east side",
    "times square to upper west side",
    "times square to columbia university",
    "times square to nyu washington square",
    "times square to chelsea market",
    "times square to high line",
    "times square to met museum",
    "times square to lincoln center",
    "times square to world trade center",
    "times square to south street seaport",
    "times square to roosevelt island",
    "times square to long island city",
    "times square to greenpoint",
    "times square to park slope",
    "times square to prospect park",
    "times square to bedford avenue",
    "times square to barclays center",
    "times square to ridgewood",
    "trip from grand central to brooklyn",
    "fastest way from penn station to jfk",
    "how do i get from union square to harlem",
    "wall street to times square",
    "brooklyn bridge to flushing",
    "dumbo to laguardia",
    "williamsburg to grand central",
    "bushwick to upper east side",
    "atlantic terminal to columbia university",
    "coney island to times square",
]


@dataclass
class TripResult:
    idx: int
    prompt: str
    status: int = 0
    total_ms: float = 0.0
    ttft_ms: float | None = None  # time to first token
    ttftool_ms: float | None = None  # time to first tool_result
    plan_calls: int = 0
    plan_ok: bool = False
    itineraries: int = 0
    reply_chars: int = 0
    error: str | None = None


def build_payload(prompt: str) -> dict:
    return {
        "message": prompt,
        "stream": True,
        "history": [],
        "context": {
            "lat": ORIGIN_LAT,
            "lon": ORIGIN_LON,
            "bias_lat": ORIGIN_LAT,
            "bias_lon": ORIGIN_LON,
            "bias_source": "gps",
            "bias_label": "current location",
            "timezone": "America/New_York",
        },
    }


async def fire(client: httpx.AsyncClient, base: str, idx: int, prompt: str) -> TripResult:
    res = TripResult(idx=idx, prompt=prompt)
    payload = build_payload(prompt)
    t0 = time.perf_counter()
    try:
        async with client.stream(
            "POST",
            f"{base}/metromind/chat",
            json=payload,
            headers={"Accept": "text/event-stream"},
            timeout=httpx.Timeout(connect=10.0, read=60.0, write=10.0, pool=10.0),
        ) as resp:
            res.status = resp.status_code
            if resp.status_code != 200:
                body = await resp.aread()
                res.error = f"HTTP {resp.status_code}: {body[:200].decode('utf-8','replace')}"
                res.total_ms = (time.perf_counter() - t0) * 1000
                return res

            async for raw in resp.aiter_lines():
                if not raw or not raw.startswith("data:"):
                    continue
                p = raw[5:].strip()
                if not p or p == "[DONE]":
                    continue
                try:
                    evt = json.loads(p)
                except json.JSONDecodeError:
                    continue
                t = evt.get("type")
                now_ms = (time.perf_counter() - t0) * 1000
                if t == "token":
                    if res.ttft_ms is None:
                        res.ttft_ms = now_ms
                    # Token text lives under either 'text' (current schema)
                    # or 'token' (older). Accept both.
                    res.reply_chars += len(evt.get("text") or evt.get("token") or "")
                elif t == "tool_call":
                    if (evt.get("name") or evt.get("tool")) == "plan_route":
                        res.plan_calls += 1
                elif t == "tool_result":
                    if res.ttftool_ms is None:
                        res.ttftool_ms = now_ms
                    if evt.get("name") == "plan_route":
                        ok = bool(evt.get("ok", True))
                        payload_obj = evt.get("payload") or {}
                        if ok and isinstance(payload_obj, dict):
                            n_itin = len(payload_obj.get("itineraries") or [])
                            if n_itin > 0:
                                res.plan_ok = True
                                res.itineraries = max(res.itineraries, n_itin)
                        elif not ok and isinstance(payload_obj, dict):
                            err = (payload_obj.get("error") or "").strip()
                            if err and not res.error:
                                res.error = f"plan_route: {err[:120]}"
                elif t == "error":
                    res.error = str(evt.get("message") or evt.get("error") or "stream error")
    except httpx.TimeoutException as e:
        res.error = f"TIMEOUT: {type(e).__name__}"
    except Exception as e:
        res.error = f"{type(e).__name__}: {e}"
    res.total_ms = (time.perf_counter() - t0) * 1000
    return res


async def run(base: str, count: int, concurrency: int) -> list[TripResult]:
    prompts = TRIPS[:count] if count <= len(TRIPS) else (TRIPS * (count // len(TRIPS) + 1))[:count]
    sem = asyncio.Semaphore(concurrency)
    out: list[TripResult] = []
    async with httpx.AsyncClient() as client:
        async def guard(i: int, p: str):
            async with sem:
                r = await fire(client, base, i, p)
                bar = "✓" if (r.status == 200 and not r.error and r.itineraries > 0) else "✗"
                ttft = f"ttft={r.ttft_ms:.0f}" if r.ttft_ms else "ttft=    "
                ttool = f"tool={r.ttftool_ms:.0f}" if r.ttftool_ms else "tool=    "
                tail = f" plan×{r.plan_calls} itin={r.itineraries}"
                if r.error:
                    tail += f" ← {r.error[:60]}"
                print(
                    f"  {bar} #{i:3d} {r.total_ms:6.0f}ms  {ttft:>10s}  {ttool:>10s}"
                    f"  '{p[:50]:50s}'{tail}",
                    flush=True,
                )
                out.append(r)

        await asyncio.gather(*[asyncio.create_task(guard(i + 1, p)) for i, p in enumerate(prompts)])
    out.sort(key=lambda r: r.idx)
    return out


def pct(vals: list[float], p: float) -> float:
    if not vals:
        return 0.0
    s = sorted(vals)
    k = max(0, min(len(s) - 1, int(round((p / 100) * (len(s) - 1)))))
    return s[k]


def report(results: list[TripResult]) -> None:
    n = len(results)
    http_ok = [r for r in results if r.status == 200]
    engine_ok = [r for r in results if r.plan_ok and r.itineraries > 0]
    engine_bad = [r for r in results if r not in engine_ok]
    totals = [r.total_ms for r in engine_ok]
    ttfts = [r.ttft_ms for r in engine_ok if r.ttft_ms]
    ttools = [r.ttftool_ms for r in engine_ok if r.ttftool_ms]
    plan_calls = [r.plan_calls for r in engine_ok] or [0]
    multi_plan = [r for r in engine_ok if r.plan_calls > 1]

    print()
    print("=" * 78)
    print(f"  Engine speed test — {n} trip prompts")
    print("=" * 78)
    print(f"  HTTP OK            : {len(http_ok):3d}/{n}")
    print(f"  Engine returned itin: {len(engine_ok):3d}/{n}  ({100*len(engine_ok)/n:.1f}%)")
    print(f"  Plans w/ retry     : {len(multi_plan):3d}/{max(1,len(engine_ok))}")
    if engine_ok:
        print(f"  Mean plan_route calls per trip: {statistics.mean(plan_calls):.2f}")

    def block(label: str, vs: list[float]) -> None:
        if not vs:
            return
        print()
        print(f"  {label}")
        print(f"    p50 {pct(vs,50):6.0f}ms  p90 {pct(vs,90):6.0f}ms  "
              f"p95 {pct(vs,95):6.0f}ms  p99 {pct(vs,99):6.0f}ms  "
              f"max {max(vs):6.0f}ms  min {min(vs):4.0f}ms")

    block("Total turn latency (full reply)", totals)
    block("Time-to-first-token  (user sees text)", ttfts)
    block("Time-to-first-tool-result (engine card)", ttools)

    # Bucket histogram on total latency.
    if totals:
        buckets = [(0, 2000), (2000, 4000), (4000, 6000), (6000, 8000),
                   (8000, 12000), (12000, 99999)]
        print()
        print("  Latency buckets")
        for lo, hi in buckets:
            c = sum(1 for v in totals if lo <= v < hi)
            bar = "█" * int(40 * c / len(totals))
            label = f"{lo/1000:>5.1f}-{hi/1000:>5.1f}s" if hi < 99999 else f"{lo/1000:>5.1f}+ s    "
            print(f"    {label}  {c:3d}  {bar}")

    # Slowest 5.
    if totals:
        slow = sorted(engine_ok, key=lambda r: -r.total_ms)[:5]
        print()
        print("  Slowest 5 successful trips")
        for r in slow:
            print(f"    {r.total_ms:6.0f}ms  plan×{r.plan_calls}  itin={r.itineraries}  '{r.prompt}'")

    if engine_bad:
        # Bucket failures by reason.
        reasons: dict[str, int] = {}
        for r in engine_bad:
            why = r.error or ("itin=0" if r.status == 200 else f"HTTP {r.status}")
            head = why.split(":")[0][:50]
            reasons[head] = reasons.get(head, 0) + 1
        print()
        print(f"  Engine failures ({len(engine_bad)}) — by reason")
        for k, v in sorted(reasons.items(), key=lambda x: -x[1]):
            print(f"    {k:50s} {v:3d}")
        print()
        print("  Sample failed trips")
        for r in engine_bad[:10]:
            why = r.error or f"itin={r.itineraries}"
            print(f"    #{r.idx:3d} '{r.prompt[:50]}' → {why[:80]}")
    print()
    print("=" * 78)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--count", type=int, default=50)
    ap.add_argument("--concurrency", type=int, default=4)
    args = ap.parse_args()

    print(f"  → Engine speed test against {args.base}")
    print(f"  → {args.count} trip prompts, concurrency={args.concurrency}")
    print()
    t0 = time.perf_counter()
    results = asyncio.run(run(args.base, args.count, args.concurrency))
    wall = time.perf_counter() - t0
    report(results)
    print(f"  Total wall: {wall:.1f}s  ({args.count/wall:.2f} trips/s)")


if __name__ == "__main__":
    main()
