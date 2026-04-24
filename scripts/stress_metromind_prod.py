#!/usr/bin/env python3
"""MetroMind production stress test — 100 mixed-intent messages.

Hammers https://track-vkrr.onrender.com/metromind/chat with a wide variety
of realistic transit prompts: route planning, trip questions, advice,
service alerts, station info, history/trivia, accessibility, "near me"
proximity (mixing GPS + dropped-pin bias), and edge cases.

Captures per-message: latency (ms), HTTP status, tool calls used, reply
length, error classification.  Prints a final report with p50/p95/p99,
tool-usage histogram, error breakdown, and per-category latency.

Usage:
    python scripts/stress_metromind_prod.py
    python scripts/stress_metromind_prod.py --concurrency 5 --count 100
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import statistics
import time
from dataclasses import dataclass, field
from typing import Any

import httpx

DEFAULT_BASE = "https://track-vkrr.onrender.com"

# ── NYC reference points ─────────────────────────────────────────────
TIMES_SQUARE = (40.7580, -73.9855)
GRAND_CENTRAL = (40.7527, -73.9772)
WILLIAMSBURG = (40.7081, -73.9571)
BUSHWICK = (40.6943, -73.9213)
ASTORIA = (40.7644, -73.9235)
JFK = (40.6413, -73.7781)
LGA = (40.7769, -73.8740)
PROSPECT_PARK = (40.6602, -73.9690)
HARLEM = (40.8116, -73.9465)
DUMBO = (40.7033, -73.9881)


def coord_str(c: tuple[float, float]) -> str:
    return f"{c[0]:.5f},{c[1]:.5f}"


# ── Message bank: (prompt, category, [optional bias_pin]) ────────────
# bias_pin = None → use device GPS (Times Square by default).
# bias_pin = (lat, lon) → simulate a dropped search pin at that spot.
MESSAGES: list[tuple[str, str, tuple[float, float] | None]] = [
    # ── Trip planning (real coordinates, exercises the engine) ──
    ("how do i get from times square to jfk", "plan", None),
    ("plan a trip from grand central to dumbo", "plan", None),
    ("fastest way from williamsburg to harlem right now", "plan", None),
    ("how do i get to laguardia from astoria", "plan", None),
    ("trip from prospect park to times square", "plan", None),
    ("get me from bushwick to grand central", "plan", None),
    ("how do i get to jfk from manhattan", "plan", None),
    ("plan from union square to coney island", "plan", None),
    ("how do i get from penn station to flushing", "plan", None),
    ("fastest from soho to upper east side", "plan", None),
    ("get me to brooklyn from midtown", "plan", None),
    ("how do i get from world trade center to yankee stadium", "plan", None),

    # ── Vague trip planning (model has to ask or use saved places) ──
    ("how do i get home", "plan_vague", None),
    ("plan my commute", "plan_vague", None),
    ("get me to work", "plan_vague", None),
    ("what's the fastest way out of here", "plan_vague", None),

    # ── Live arrivals / route status ──
    ("when's the next L train", "arrivals", None),
    ("any 7 trains coming", "arrivals", None),
    ("when's the next 6 train northbound", "arrivals", None),
    ("how long til the next A train", "arrivals", None),
    ("is the F running", "arrivals", None),
    ("when's the next G train brooklyn-bound", "arrivals", None),
    ("next R train downtown", "arrivals", None),
    ("when does the next M train come", "arrivals", None),

    # ── Service alerts ──
    ("any delays on the 4 train", "alerts", None),
    ("is the L suspended", "alerts", None),
    ("what's going on with the A train", "alerts", None),
    ("any service alerts right now", "alerts", None),
    ("are there any suspensions tonight", "alerts", None),
    ("anything going on with the 1 2 3", "alerts", None),
    ("weekend service changes", "alerts", None),

    # ── Stop / station info ──
    ("is bedford avenue accessible", "stop_info", None),
    ("what trains stop at union square", "stop_info", None),
    ("is the elevator working at 14th street", "stop_info", None),
    ("escalators at times square", "stop_info", None),
    ("what's leaving from atlantic avenue right now", "stop_info", None),
    ("is grand central wheelchair accessible", "stop_info", None),

    # ── Equipment outages ──
    ("any escalators broken in manhattan", "outages", None),
    ("what elevators are out of service", "outages", None),
    ("equipment outages on the L line", "outages", None),

    # ── "Near me" with GPS bias (Times Square) ──
    ("what's the closest train to me", "near_me_gps", None),
    ("what stations are around me", "near_me_gps", None),
    ("nearest subway entrance", "near_me_gps", None),
    ("what trains can i catch nearby", "near_me_gps", None),

    # ── "Near me" with DROPPED PIN bias (this is the new behavior!) ──
    ("what's the closest train to me", "near_me_pin_brooklyn", BUSHWICK),
    ("what stations are around me", "near_me_pin_williamsburg", WILLIAMSBURG),
    ("nearest subway entrance", "near_me_pin_astoria", ASTORIA),
    ("what trains can i catch nearby", "near_me_pin_harlem", HARLEM),
    ("any escalators broken near me", "near_me_pin_jfk", JFK),
    ("what's leaving from the closest stop", "near_me_pin_dumbo", DUMBO),
    ("which subway lines are closest", "near_me_pin_prospect", PROSPECT_PARK),
    ("nearest accessible station", "near_me_pin_lga", LGA),

    # ── Trip planning WITH a dropped pin (origin should = pin) ──
    ("how do i get to times square from here", "plan_pin", WILLIAMSBURG),
    ("trip from here to jfk", "plan_pin", BUSHWICK),
    ("get me to grand central from here", "plan_pin", ASTORIA),
    ("how do i get home from here", "plan_pin", DUMBO),
    ("fastest way out of here to manhattan", "plan_pin", PROSPECT_PARK),

    # ── Advice / open-ended transit Qs ──
    ("what's the best way to get to laguardia", "advice", None),
    ("is uber faster than the subway tonight", "advice", None),
    ("which is better for brooklyn the L or the J", "advice", None),
    ("should i take the express or local 4", "advice", None),
    ("how late do trains run", "advice", None),
    ("when does service stop tonight", "advice", None),
    ("what's the cheapest way to the airport", "advice", None),

    # ── History / trivia (no tool needed) ──
    ("what are the new MTA trains", "trivia", None),
    ("when did the second avenue subway open", "trivia", None),
    ("why is the G train so short", "trivia", None),
    ("what happened to the redbird trains", "trivia", None),
    ("tell me about the R211", "trivia", None),
    ("what's CBTC", "trivia", None),
    ("history of the IRT", "trivia", None),
    ("when did OMNY launch", "trivia", None),

    # ── Fares ──
    ("how much is the subway", "fares", None),
    ("how much is the airtrain to jfk", "fares", None),
    ("can i transfer for free", "fares", None),
    ("is OMNY cheaper than metrocard", "fares", None),

    # ── Mobility beyond subway ──
    ("can i bike to work", "mobility", None),
    ("how do i get to staten island", "mobility", None),
    ("is the staten island ferry running", "mobility", None),
    ("citi bike or subway to soho", "mobility", None),
    ("how do i get to newark airport", "mobility", None),

    # ── App / saved-place questions ──
    ("how do i save a place", "app", None),
    ("what does the go button do", "app", None),
    ("what are my saved places", "app", None),

    # ── Edge cases / scope refusal ──
    ("write me a python linked list class", "refuse", None),
    ("what's the best pizza in nyc", "refuse", None),
    ("can you help me with my homework", "refuse", None),
    ("tell me a joke", "refuse", None),
    ("how do i get to chicago", "refuse", None),
    ("what's the weather like", "edge", None),

    # ── Conversational / single-word ──
    ("hi", "conv", None),
    ("thanks", "conv", None),
    ("ok cool", "conv", None),
    ("what about now", "conv", None),
    ("nevermind", "conv", None),

    # ── Stress: long questions ──
    (
        "i'm trying to get from williamsburg to flushing on a saturday "
        "afternoon with a stroller, what's the most accessible route and "
        "are there any elevator outages i should worry about along the way",
        "complex", WILLIAMSBURG,
    ),
    (
        "if the L is messed up tonight what are my best options for getting "
        "from bushwick back to the upper east side, i'm willing to walk a bit",
        "complex", BUSHWICK,
    ),
    (
        "compare the J the M and the L for getting from williamsburg to "
        "midtown during rush hour, which is most reliable",
        "complex", WILLIAMSBURG,
    ),

    # ── Filler to round out 100 ──
    ("any G train alerts", "alerts", None),
    ("when's the next 1 train uptown", "arrivals", None),
    ("trip from harlem to dumbo", "plan", None),
    ("is the 7 train delayed", "alerts", None),
    ("plan from queens to brooklyn", "plan", None),
    ("how do i get to coney island", "plan", None),
    ("nearest L train", "near_me_pin_bk", BUSHWICK),
    ("when's the next express bus", "arrivals", None),

    # ── NEW: system-wide subway status ──
    ("how's the subway tonight", "system_status", None),
    ("any major delays right now", "system_status", None),
    ("what lines are running normal", "system_status", None),
    ("anything down systemwide", "system_status", None),

    # ── NEW: weather-aware advice ──
    ("should i bike to work", "weather_advice", None),
    ("is it raining outside", "weather", None),
    ("will i get wet waiting for the bus", "weather_advice", None),
    ("how cold is it", "weather", None),

    # ── NEW: Citi Bike availability ──
    ("any citi bikes near me", "citibike_gps", None),
    ("any e-bikes nearby", "citibike_gps", None),
    ("where can i dock a citi bike", "citibike_pin_wb", WILLIAMSBURG),
    ("citi bike or train to soho", "citibike_advice", None),

    # ── NEW: previously-failing ambiguous trip prompts ──
    ("fastest way from williamsburg to harlem right now", "plan_retry", None),
    ("fastest from soho to upper east side", "plan_retry", None),
]

assert len(MESSAGES) >= 100, f"Need ≥100 messages, have {len(MESSAGES)}"


@dataclass
class Result:
    idx: int
    category: str
    prompt: str
    bias_source: str
    status: int = 0
    elapsed_ms: float = 0.0
    reply_chars: int = 0
    tools_used: list[str] = field(default_factory=list)
    error: str | None = None
    sse_events: int = 0


def build_payload(prompt: str, bias_pin: tuple[float, float] | None) -> dict[str, Any]:
    """Build a /metromind/chat request body.  Mirrors what the iOS app sends."""
    gps = TIMES_SQUARE
    ctx: dict[str, Any] = {
        "timezone": "America/New_York",
    }
    if bias_pin is not None:
        # Drop-pin mode: app overrides lat/lon with the pin coordinate so the
        # backend sees ONE coherent location.
        ctx["lat"] = bias_pin[0]
        ctx["lon"] = bias_pin[1]
        ctx["bias_lat"] = bias_pin[0]
        ctx["bias_lon"] = bias_pin[1]
        ctx["bias_source"] = "map_pin"
        ctx["bias_label"] = "dropped pin"
    else:
        # GPS mode
        ctx["lat"] = gps[0]
        ctx["lon"] = gps[1]
        ctx["bias_lat"] = gps[0]
        ctx["bias_lon"] = gps[1]
        ctx["bias_source"] = "gps"
        ctx["bias_label"] = "current location"

    return {
        "message": prompt,
        "stream": True,
        "history": [],
        "context": ctx,
    }


async def fire(
    client: httpx.AsyncClient,
    base: str,
    idx: int,
    prompt: str,
    category: str,
    bias_pin: tuple[float, float] | None,
) -> Result:
    payload = build_payload(prompt, bias_pin)
    bias_source = "map_pin" if bias_pin else "gps"
    res = Result(idx=idx, category=category, prompt=prompt, bias_source=bias_source)

    t0 = time.perf_counter()
    try:
        async with client.stream(
            "POST",
            f"{base}/metromind/chat",
            json=payload,
            headers={"Accept": "text/event-stream"},
            timeout=httpx.Timeout(connect=10.0, read=90.0, write=10.0, pool=10.0),
        ) as resp:
            res.status = resp.status_code
            if resp.status_code != 200:
                body = await resp.aread()
                res.error = f"HTTP {resp.status_code}: {body[:200].decode('utf-8', 'replace')}"
                res.elapsed_ms = (time.perf_counter() - t0) * 1000.0
                return res

            reply_chars = 0
            tools: list[str] = []
            sse = 0
            async for raw_line in resp.aiter_lines():
                if not raw_line:
                    continue
                if raw_line.startswith("event:"):
                    sse += 1
                    continue
                if not raw_line.startswith("data:"):
                    continue
                payload_str = raw_line[5:].strip()
                if not payload_str or payload_str == "[DONE]":
                    continue
                try:
                    evt = json.loads(payload_str)
                except json.JSONDecodeError:
                    continue
                etype = evt.get("type")
                if etype == "token":
                    reply_chars += len(evt.get("token", ""))
                elif etype == "tool_call":
                    tname = evt.get("name") or evt.get("tool")
                    if tname:
                        tools.append(tname)
                elif etype == "error":
                    res.error = str(evt.get("message") or evt.get("error") or "stream error")

            res.reply_chars = reply_chars
            res.tools_used = tools
            res.sse_events = sse
    except httpx.TimeoutException as e:
        res.error = f"TIMEOUT: {type(e).__name__}"
    except Exception as e:  # noqa: BLE001
        res.error = f"{type(e).__name__}: {e}"

    res.elapsed_ms = (time.perf_counter() - t0) * 1000.0
    return res


async def run(base: str, count: int, concurrency: int) -> list[Result]:
    msgs = MESSAGES[:count] if count <= len(MESSAGES) else (
        MESSAGES + random.choices(MESSAGES, k=count - len(MESSAGES))
    )

    sem = asyncio.Semaphore(concurrency)
    results: list[Result] = []

    async with httpx.AsyncClient(http2=False) as client:
        async def guarded(idx: int, item):
            prompt, category, bias_pin = item
            async with sem:
                r = await fire(client, base, idx, prompt, category, bias_pin)
                bar = "✓" if (r.status == 200 and not r.error) else "✗"
                tail = ""
                if r.error:
                    tail = f"  ← {r.error[:80]}"
                elif r.tools_used:
                    tail = f"  [{','.join(r.tools_used)}]"
                print(
                    f"  {bar} #{idx:3d} {r.elapsed_ms:7.0f}ms  "
                    f"{r.bias_source:7s}  {category:22s}  "
                    f"{prompt[:60]:60s}{tail}",
                    flush=True,
                )
                results.append(r)

        tasks = [asyncio.create_task(guarded(i + 1, m)) for i, m in enumerate(msgs)]
        await asyncio.gather(*tasks)

    results.sort(key=lambda r: r.idx)
    return results


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1)))))
    return s[k]


def report(results: list[Result]) -> None:
    n = len(results)
    ok = [r for r in results if r.status == 200 and not r.error]
    bad = [r for r in results if r not in ok]
    lats = [r.elapsed_ms for r in ok]

    print()
    print("=" * 78)
    print(f"  MetroMind stress test — {n} messages")
    print("=" * 78)
    print(f"  Successful : {len(ok):3d}/{n}  ({100 * len(ok) / n:.1f}%)")
    print(f"  Failures   : {len(bad):3d}/{n}")
    if lats:
        print()
        print("  Latency (successful turns)")
        print(f"    mean   : {statistics.mean(lats):7.0f} ms")
        print(f"    median : {statistics.median(lats):7.0f} ms")
        print(f"    p50    : {pct(lats, 50):7.0f} ms")
        print(f"    p90    : {pct(lats, 90):7.0f} ms")
        print(f"    p95    : {pct(lats, 95):7.0f} ms")
        print(f"    p99    : {pct(lats, 99):7.0f} ms")
        print(f"    max    : {max(lats):7.0f} ms")
        print(f"    min    : {min(lats):7.0f} ms")

    # Tool histogram
    tools: dict[str, int] = {}
    for r in ok:
        for t in r.tools_used:
            tools[t] = tools.get(t, 0) + 1
    if tools:
        print()
        print("  Tool calls")
        for name, c in sorted(tools.items(), key=lambda x: -x[1]):
            print(f"    {name:24s} {c:4d}")

    # Per-category latency
    cats: dict[str, list[float]] = {}
    for r in ok:
        cats.setdefault(r.category, []).append(r.elapsed_ms)
    print()
    print("  Latency by category (n / mean / p95)")
    for cat in sorted(cats):
        vs = cats[cat]
        print(f"    {cat:24s} {len(vs):3d}  mean={statistics.mean(vs):6.0f}ms  p95={pct(vs, 95):6.0f}ms")

    # Failure breakdown
    if bad:
        print()
        print("  Failures")
        kinds: dict[str, int] = {}
        for r in bad:
            key = r.error or f"HTTP {r.status}"
            head = key.split(":")[0][:40]
            kinds[head] = kinds.get(head, 0) + 1
        for k, v in sorted(kinds.items(), key=lambda x: -x[1]):
            print(f"    {k:40s} {v:3d}")
        print()
        print("  Sample failed prompts")
        for r in bad[:8]:
            print(f"    #{r.idx:3d} [{r.category}] '{r.prompt[:50]}' → {r.error}")

    # Bias source breakdown
    pin_results = [r for r in ok if r.bias_source == "map_pin"]
    gps_results = [r for r in ok if r.bias_source == "gps"]
    if pin_results and gps_results:
        print()
        print("  GPS vs dropped-pin")
        print(f"    GPS       n={len(gps_results):3d}  mean={statistics.mean([r.elapsed_ms for r in gps_results]):6.0f}ms")
        print(f"    map_pin   n={len(pin_results):3d}  mean={statistics.mean([r.elapsed_ms for r in pin_results]):6.0f}ms")

    print()
    print("=" * 78)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--count", type=int, default=100)
    ap.add_argument("--concurrency", type=int, default=4)
    args = ap.parse_args()

    print(f"  → Hitting {args.base}/metromind/chat")
    print(f"  → {args.count} messages, concurrency={args.concurrency}")
    print()

    t0 = time.perf_counter()
    results = asyncio.run(run(args.base, args.count, args.concurrency))
    wall_s = time.perf_counter() - t0

    report(results)
    print(f"  Total wall time: {wall_s:.1f}s "
          f"({args.count / wall_s:.2f} msg/s)")


if __name__ == "__main__":
    main()
