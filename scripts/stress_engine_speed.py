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

# Diverse prompts across many categories — trip planning, alerts,
# arrivals, weather, citibike, abbreviations, typos, slang, hostility,
# off-topic refusals, complex multi-part questions, transit trivia, and
# random NYC mobility questions. Each entry is (category, prompt).
PROMPTS: list[tuple[str, str]] = [
    # ── Core trip planning (50) ───────────────────────────────────────
    ("trip", "how do i get from times square to grand central"),
    ("trip", "trip from times square to penn station"),
    ("trip", "plan from times square to union square"),
    ("trip", "fastest from times square to brooklyn bridge"),
    ("trip", "times square to wall street"),
    ("trip", "how do i get from times square to dumbo"),
    ("trip", "times square to williamsburg"),
    ("trip", "times square to bushwick"),
    ("trip", "times square to atlantic terminal"),
    ("trip", "times square to coney island"),
    ("trip", "how do i get to jfk from times square"),
    ("trip", "times square to laguardia"),
    ("trip", "times square to newark airport"),
    ("trip", "times square to flushing"),
    ("trip", "times square to astoria"),
    ("trip", "times square to forest hills"),
    ("trip", "times square to jamaica center"),
    ("trip", "times square to harlem"),
    ("trip", "times square to washington heights"),
    ("trip", "times square to inwood"),
    ("trip", "times square to yankee stadium"),
    ("trip", "times square to bronx zoo"),
    ("trip", "times square to upper east side"),
    ("trip", "times square to upper west side"),
    ("trip", "times square to columbia university"),
    ("trip", "times square to nyu washington square"),
    ("trip", "times square to chelsea market"),
    ("trip", "times square to high line"),
    ("trip", "times square to met museum"),
    ("trip", "times square to lincoln center"),
    ("trip", "times square to world trade center"),
    ("trip", "times square to south street seaport"),
    ("trip", "times square to roosevelt island"),
    ("trip", "times square to long island city"),
    ("trip", "times square to greenpoint"),
    ("trip", "times square to park slope"),
    ("trip", "times square to prospect park"),
    ("trip", "times square to bedford avenue"),
    ("trip", "times square to barclays center"),
    ("trip", "times square to ridgewood"),
    ("trip", "trip from grand central to brooklyn"),
    ("trip", "fastest way from penn station to jfk"),
    ("trip", "how do i get from union square to harlem"),
    ("trip", "wall street to times square"),
    ("trip", "brooklyn bridge to flushing"),
    ("trip", "dumbo to laguardia"),
    ("trip", "williamsburg to grand central"),
    ("trip", "bushwick to upper east side"),
    ("trip", "atlantic terminal to columbia university"),
    ("trip", "coney island to times square"),

    # ── Trip planning with abbreviations / shorthand (25) ─────────────
    ("trip_abbrev", "ts to gc"),
    ("trip_abbrev", "ts -> penn"),
    ("trip_abbrev", "wtc to bk"),
    ("trip_abbrev", "ues to uws"),
    ("trip_abbrev", "lic to soho"),
    ("trip_abbrev", "fidi to midtown"),
    ("trip_abbrev", "lower east side to harlem"),
    ("trip_abbrev", "how do i get 2 jfk"),
    ("trip_abbrev", "trip 2 grand central"),
    ("trip_abbrev", "go from bx to qns"),
    ("trip_abbrev", "manhattan to bk"),
    ("trip_abbrev", "from astoria 2 the village"),
    ("trip_abbrev", "ges me to penn from ts plz"),
    ("trip_abbrev", "ts -> ues"),
    ("trip_abbrev", "best route ts -> jfk"),
    ("trip_abbrev", "wsq to gc"),
    ("trip_abbrev", "ts to gct"),
    ("trip_abbrev", "ts to lga"),
    ("trip_abbrev", "ts to ewr"),
    ("trip_abbrev", "ts to bbridge"),
    ("trip_abbrev", "msg to barclays"),
    ("trip_abbrev", "rock center to wsq"),
    ("trip_abbrev", "lic to dumbo"),
    ("trip_abbrev", "harlem -> wash heights"),
    ("trip_abbrev", "soho to noho"),

    # ── Trip planning with typos / spelling mistakes (25) ─────────────
    ("trip_typo", "tims sqr to grand cntrl"),
    ("trip_typo", "trip from tymes square to penn statoin"),
    ("trip_typo", "how do i get to jffk"),
    ("trip_typo", "times sqaure to brklyn bridge"),
    ("trip_typo", "wall stret to times sqaure"),
    ("trip_typo", "times square to washingtom heights"),
    ("trip_typo", "times sq to colombia university"),
    ("trip_typo", "ts to flushinng"),
    ("trip_typo", "midtown to grenpoint"),
    ("trip_typo", "broklyn briddge to flushng"),
    ("trip_typo", "rockefelller center to wall st"),
    ("trip_typo", "from tims to gran central"),
    ("trip_typo", "how do i go to lguardia"),
    ("trip_typo", "trip frm union sq 2 brooklyn"),
    ("trip_typo", "times sq to mannhattan bridge"),
    ("trip_typo", "broklyn to qweens"),
    ("trip_typo", "ts to atlatntic terminal"),
    ("trip_typo", "best route 2 brnx zoo"),
    ("trip_typo", "times sqr to columba uni"),
    ("trip_typo", "trip frm hells kitchen to soho"),
    ("trip_typo", "i need to git to penn"),
    ("trip_typo", "from west village to easst village"),
    ("trip_typo", "times sq to coney iland"),
    ("trip_typo", "ts to laguardiia airport"),
    ("trip_typo", "how do i get to braclays center"),

    # ── Service alerts (25) ───────────────────────────────────────────
    ("alerts", "is the L running"),
    ("alerts", "any delays on the 7"),
    ("alerts", "what's wrong with the F"),
    ("alerts", "is the g working"),
    ("alerts", "alerts for the A line"),
    ("alerts", "any issues on the n train"),
    ("alerts", "is the q delayed"),
    ("alerts", "how's the 4 5 6 today"),
    ("alerts", "any service changes on the L"),
    ("alerts", "is the J running tonight"),
    ("alerts", "what's going on with the c train"),
    ("alerts", "are there any reroutes today"),
    ("alerts", "is there a planned shutdown this weekend"),
    ("alerts", "how's the b line"),
    ("alerts", "delays on the 1 train"),
    ("alerts", "any problems with the d"),
    ("alerts", "is the m train running normal"),
    ("alerts", "alerts for r train"),
    ("alerts", "is the e suspended"),
    ("alerts", "is the w running"),
    ("alerts", "any subway alerts right now"),
    ("alerts", "is the lirr on time"),
    ("alerts", "metro north status"),
    ("alerts", "any bus reroutes on the m15"),
    ("alerts", "are buses delayed today"),

    # ── Live arrivals (20) ────────────────────────────────────────────
    ("arrivals", "when's the next 6 train"),
    ("arrivals", "next L to manhattan"),
    ("arrivals", "how long til the next 7"),
    ("arrivals", "next northbound 4"),
    ("arrivals", "when's the next downtown 1"),
    ("arrivals", "next a train to brooklyn"),
    ("arrivals", "when does the q come"),
    ("arrivals", "next train at union square"),
    ("arrivals", "when's the next f at jay st"),
    ("arrivals", "next g train"),
    ("arrivals", "how soon is the next n"),
    ("arrivals", "next r train uptown"),
    ("arrivals", "when's the m at delancey"),
    ("arrivals", "next train at grand central"),
    ("arrivals", "next train heading downtown from 14 st"),
    ("arrivals", "when does the next d arrive"),
    ("arrivals", "next b train at 7 av"),
    ("arrivals", "when's the next bus on m15"),
    ("arrivals", "next bx12 select bus"),
    ("arrivals", "when's the next train at bedford ave"),

    # ── System-wide status (10) ───────────────────────────────────────
    ("status", "how's the subway tonight"),
    ("status", "any major delays right now"),
    ("status", "what lines are down"),
    ("status", "is everything running normal"),
    ("status", "subway status check"),
    ("status", "what's running tonight"),
    ("status", "any planned work this weekend"),
    ("status", "how bad is the subway right now"),
    ("status", "is the system messed up tonight"),
    ("status", "give me a system overview"),

    # ── Weather (15) ──────────────────────────────────────────────────
    ("weather", "is it raining"),
    ("weather", "should i bike home"),
    ("weather", "how cold is it outside"),
    ("weather", "weather check"),
    ("weather", "will it rain in the next hour"),
    ("weather", "is it bad outside"),
    ("weather", "what's the temp right now"),
    ("weather", "do i need a jacket"),
    ("weather", "should i wait inside"),
    ("weather", "is it nice out"),
    ("weather", "is it snowing"),
    ("weather", "humidity right now"),
    ("weather", "is it windy"),
    ("weather", "weather for the next few hours"),
    ("weather", "should i walk or take the train weather wise"),

    # ── Citi Bike (15) ────────────────────────────────────────────────
    ("citibike", "any citi bikes near me"),
    ("citibike", "where's the closest citi bike"),
    ("citibike", "ebikes nearby"),
    ("citibike", "are there docks near me"),
    ("citibike", "open docks at union square"),
    ("citibike", "find me a citi bike"),
    ("citibike", "is there a bike near times square"),
    ("citibike", "how many ebikes nearby"),
    ("citibike", "closest dock with bikes"),
    ("citibike", "citi bike availability"),
    ("citibike", "can i grab a bike right now"),
    ("citibike", "show me citi bikes within a few blocks"),
    ("citibike", "is there a citi bike i can rent"),
    ("citibike", "ebike near me"),
    ("citibike", "where can i return a bike"),

    # ── Stops / accessibility / station info (15) ─────────────────────
    ("stations", "what's the closest subway station"),
    ("stations", "stations near me"),
    ("stations", "is bedford ave wheelchair accessible"),
    ("stations", "is times square ada accessible"),
    ("stations", "elevator status at union square"),
    ("stations", "are the elevators working at 14 st"),
    ("stations", "what trains stop at jay st"),
    ("stations", "what's at canal street"),
    ("stations", "how do i find an accessible station nearby"),
    ("stations", "elevator outages today"),
    ("stations", "is the f stop at york st accessible"),
    ("stations", "what trains run through atlantic ave"),
    ("stations", "info on grand central"),
    ("stations", "is there an escalator at 34 st penn"),
    ("stations", "what station is closest to me"),

    # ── Off-topic / should refuse (20) ────────────────────────────────
    ("offtopic", "write me a python linked list"),
    ("offtopic", "what's the recipe for lasagna"),
    ("offtopic", "tell me a joke about cats"),
    ("offtopic", "explain quantum entanglement"),
    ("offtopic", "how do i invest in stocks"),
    ("offtopic", "write me a haiku"),
    ("offtopic", "what's the meaning of life"),
    ("offtopic", "help me with my math homework"),
    ("offtopic", "give me dating advice"),
    ("offtopic", "translate this to french: hello"),
    ("offtopic", "what's the best pizza in chicago"),
    ("offtopic", "tell me about the london tube"),
    ("offtopic", "what's the bart schedule"),
    ("offtopic", "write me a sql query"),
    ("offtopic", "summarize war and peace"),
    ("offtopic", "should i break up with my girlfriend"),
    ("offtopic", "what's a good workout routine"),
    ("offtopic", "compose an email to my boss"),
    ("offtopic", "draw me a picture"),
    ("offtopic", "what stocks should i buy"),

    # ── Curse words / hostile / venting (10) ─────────────────────────
    ("hostile", "fuck this app"),
    ("hostile", "you suck"),
    ("hostile", "this is bullshit help me get home"),
    ("hostile", "wtf is wrong with the L"),
    ("hostile", "shit when's the next train"),
    ("hostile", "fucking mta is always late"),
    ("hostile", "damn it i need to get to jfk"),
    ("hostile", "this is so annoying just tell me when the 6 comes"),
    ("hostile", "stop being useless and plan my trip to harlem"),
    ("hostile", "ugh just get me to brooklyn already"),

    # ── Complex multi-part questions (15) ────────────────────────────
    ("complex", "i need to get to jfk by 6pm what should i take and is the L running"),
    ("complex", "my flight is at 8 should i leave now or in 30 min from times square"),
    ("complex", "compare driving vs subway from times square to jfk"),
    ("complex", "i'm at union square and need to be at columbia by 7 what's fastest and is it raining"),
    ("complex", "plan a trip from soho to laguardia and tell me if there are any delays"),
    ("complex", "what's the fastest way to dumbo and any alerts on the way"),
    ("complex", "if i bike from times square to brooklyn how long and is it safe weather wise"),
    ("complex", "i need to be at yankee stadium in 45 min from grand central is that doable"),
    ("complex", "i'm in chelsea trying to get to laguardia in an hour what's my move"),
    ("complex", "plan from times square to coney island and what's the weather like there"),
    ("complex", "from williamsburg to jfk and tell me if i should leave now"),
    ("complex", "i'm running late to a meeting at wall street from upper west side help"),
    ("complex", "best route from astoria to dumbo and is there a citi bike near the start"),
    ("complex", "what time should i leave times square to make it to ewr by 5pm"),
    ("complex", "i need to pick up something in soho then get to jfk by 7 plan it"),

    # ── Transit history / trivia (10) ────────────────────────────────
    ("trivia", "tell me about the R211"),
    ("trivia", "history of the second avenue subway"),
    ("trivia", "why is the G train so short"),
    ("trivia", "what's CBTC"),
    ("trivia", "tell me about the redbird trains"),
    ("trivia", "what happened to the R32s"),
    ("trivia", "history of the IRT"),
    ("trivia", "what's the oldest subway line"),
    ("trivia", "tell me about omny"),
    ("trivia", "what's the deal with the J train"),

    # ── Random NYC mobility (15) ─────────────────────────────────────
    ("nycmisc", "what's congestion pricing"),
    ("nycmisc", "how does omny work"),
    ("nycmisc", "is the staten island ferry free"),
    ("nycmisc", "how much is a subway ride"),
    ("nycmisc", "how do i pay for the bus"),
    ("nycmisc", "do unlimited metrocards still exist"),
    ("nycmisc", "what's the airtrain"),
    ("nycmisc", "can i bring my bike on the subway"),
    ("nycmisc", "is the path the same as the subway"),
    ("nycmisc", "what's the cheapest way to get to jfk"),
    ("nycmisc", "how late does the subway run"),
    ("nycmisc", "is there 24 hour service"),
    ("nycmisc", "do i tap or swipe"),
    ("nycmisc", "can i use apple pay on the subway"),
    ("nycmisc", "kids ride free right"),
]

# Backwards-compat alias for the old API; some tests may still import.
TRIPS: list[str] = [p for c, p in PROMPTS if c == "trip"]


@dataclass
class TripResult:
    idx: int
    prompt: str
    category: str = "trip"
    status: int = 0
    total_ms: float = 0.0
    ttft_ms: float | None = None  # time to first token
    ttftool_ms: float | None = None  # time to first tool_result
    plan_calls: int = 0
    plan_ok: bool = False
    itineraries: int = 0
    reply_chars: int = 0
    tool_names: list[str] = field(default_factory=list)
    error: str | None = None


# Per-category success criteria. ``trip*`` requires the engine to have
# produced an itinerary (plan_ok). Information categories just need a
# substantial reply. ``offtopic`` and ``hostile`` only need *any* reply
# (the bot is allowed to refuse politely). ``complex`` is success if the
# engine ran AND we got a real reply.
def _is_success(r: "TripResult") -> bool:
    if r.status != 200:
        return False
    cat = r.category
    if cat in ("trip", "trip_abbrev", "trip_typo"):
        # For trip prompts, an engine error IS the failure mode. We need
        # either a real itinerary OR a substantive textual fallback.
        if r.error:
            return False
        return r.plan_ok or r.reply_chars > 80
    if cat == "complex":
        if r.error:
            return False
        return r.plan_ok or r.reply_chars > 100
    # For non-trip prompts (alerts, hostile, offtopic, etc.) the engine
    # may still throw a stray plan_route error if the model speculatively
    # called it; what matters is whether the user got a useful reply.
    if cat in ("alerts", "arrivals", "status", "weather", "citibike",
               "stations", "trivia", "nycmisc"):
        return r.reply_chars > 50
    if cat in ("offtopic", "hostile"):
        return r.reply_chars > 10
    return r.reply_chars > 30


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


async def fire(
    client: httpx.AsyncClient,
    base: str,
    idx: int,
    category: str,
    prompt: str,
) -> TripResult:
    res = TripResult(idx=idx, prompt=prompt, category=category)
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
                    name = evt.get("name") or evt.get("tool") or ""
                    if name and name not in res.tool_names:
                        res.tool_names.append(name)
                    if name == "plan_route":
                        res.plan_calls += 1
                elif t == "tool_result":
                    if res.ttftool_ms is None:
                        res.ttftool_ms = now_ms
                    if evt.get("name") == "plan_route":
                        ok = bool(evt.get("ok", True))
                        payload_obj = evt.get("payload") or {}
                        if ok and isinstance(payload_obj, dict):
                            n_itin = len(payload_obj.get("itineraries") or [])
                            # Engine succeeded — itineraries empty is a valid
                            # answer for out-of-service-area destinations
                            # (Newark, Hoboken, etc.). The model is expected
                            # to give NJ Transit / PATH guidance.
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
    if count <= len(PROMPTS):
        items = PROMPTS[:count]
    else:
        # Cycle through to reach the requested count.
        items = (PROMPTS * (count // len(PROMPTS) + 1))[:count]
    sem = asyncio.Semaphore(concurrency)
    out: list[TripResult] = []
    async with httpx.AsyncClient() as client:
        async def guard(i: int, cat: str, p: str):
            async with sem:
                r = await fire(client, base, i, cat, p)
                bar = "✓" if _is_success(r) else "✗"
                ttft = f"ttft={r.ttft_ms:.0f}" if r.ttft_ms else "ttft=    "
                tail = f" {cat[:8]:8s} chars={r.reply_chars}"
                if r.plan_calls:
                    tail += f" plan×{r.plan_calls} itin={r.itineraries}"
                if r.error:
                    tail += f" ← {r.error[:50]}"
                print(
                    f"  {bar} #{i:3d} {r.total_ms:6.0f}ms  {ttft:>10s}"
                    f"  '{p[:46]:46s}'{tail}",
                    flush=True,
                )
                out.append(r)

        await asyncio.gather(*[
            asyncio.create_task(guard(i + 1, cat, p))
            for i, (cat, p) in enumerate(items)
        ])
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
    ok = [r for r in results if _is_success(r)]
    bad = [r for r in results if not _is_success(r)]
    totals = [r.total_ms for r in ok]
    ttfts = [r.ttft_ms for r in ok if r.ttft_ms]
    ttools = [r.ttftool_ms for r in ok if r.ttftool_ms]

    print()
    print("=" * 78)
    print(f"  Chatbot stress test — {n} prompts across multiple categories")
    print("=" * 78)
    print(f"  HTTP OK            : {len(http_ok):3d}/{n}")
    print(f"  Overall success    : {len(ok):3d}/{n}  ({100*len(ok)/n:.1f}%)")

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

    # Per-category breakdown.
    cats: dict[str, list[TripResult]] = {}
    for r in results:
        cats.setdefault(r.category, []).append(r)
    print()
    print("  Per-category breakdown")
    print(f"    {'category':<14s} {'n':>3s}  {'pass':>6s}  {'rate':>6s}  "
          f"{'p50':>6s}  {'p90':>6s}  {'avg_chars':>9s}  {'plan_ok':>7s}")
    for cat in sorted(cats.keys()):
        rs = cats[cat]
        passes = [r for r in rs if _is_success(r)]
        cat_totals = [r.total_ms for r in rs if r.status == 200]
        avg_chars = (sum(r.reply_chars for r in rs) / len(rs)) if rs else 0
        plan_ok_n = sum(1 for r in rs if r.plan_ok)
        rate = 100 * len(passes) / len(rs)
        p50 = pct(cat_totals, 50) if cat_totals else 0
        p90 = pct(cat_totals, 90) if cat_totals else 0
        print(f"    {cat:<14s} {len(rs):3d}  {len(passes):3d}/{len(rs):<2d}  "
              f"{rate:5.1f}%  {p50:5.0f}ms {p90:5.0f}ms  {avg_chars:9.0f}  {plan_ok_n:7d}")

    # Bucket histogram on total latency.
    if totals:
        buckets = [(0, 2000), (2000, 4000), (4000, 6000), (6000, 8000),
                   (8000, 12000), (12000, 99999)]
        print()
        print("  Latency buckets (successful turns)")
        for lo, hi in buckets:
            c = sum(1 for v in totals if lo <= v < hi)
            bar = "█" * int(40 * c / len(totals))
            label = f"{lo/1000:>5.1f}-{hi/1000:>5.1f}s" if hi < 99999 else f"{lo/1000:>5.1f}+ s    "
            print(f"    {label}  {c:3d}  {bar}")

    # Slowest 5.
    if totals:
        slow = sorted(ok, key=lambda r: -r.total_ms)[:5]
        print()
        print("  Slowest 5 successful turns")
        for r in slow:
            print(f"    {r.total_ms:6.0f}ms  [{r.category:<10s}] '{r.prompt[:55]}'")

    if bad:
        # Bucket failures by category + reason.
        print()
        print(f"  Failures ({len(bad)}) — by category")
        fail_by_cat: dict[str, int] = {}
        for r in bad:
            fail_by_cat[r.category] = fail_by_cat.get(r.category, 0) + 1
        for k, v in sorted(fail_by_cat.items(), key=lambda x: -x[1]):
            print(f"    {k:<14s} {v:3d}")

        reasons: dict[str, int] = {}
        for r in bad:
            why = r.error or (
                f"reply too short ({r.reply_chars} chars)" if r.status == 200
                else f"HTTP {r.status}"
            )
            head = why.split(":")[0][:50]
            reasons[head] = reasons.get(head, 0) + 1
        print()
        print(f"  Failures ({len(bad)}) — by reason")
        for k, v in sorted(reasons.items(), key=lambda x: -x[1]):
            print(f"    {k:<50s} {v:3d}")
        print()
        print("  Sample failed turns (up to 15)")
        for r in bad[:15]:
            why = r.error or f"reply={r.reply_chars}c plan_ok={r.plan_ok}"
            print(f"    #{r.idx:3d} [{r.category:<10s}] '{r.prompt[:50]}' → {why[:70]}")
    print()
    print("=" * 78)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--count", type=int, default=len(PROMPTS))
    ap.add_argument("--concurrency", type=int, default=4)
    args = ap.parse_args()

    print(f"  → Chatbot stress test against {args.base}")
    print(f"  → {args.count} prompts (of {len(PROMPTS)} unique), concurrency={args.concurrency}")
    print()
    t0 = time.perf_counter()
    results = asyncio.run(run(args.base, args.count, args.concurrency))
    wall = time.perf_counter() - t0
    report(results)
    print(f"  Total wall: {wall:.1f}s  ({args.count/wall:.2f} prompts/s)")


if __name__ == "__main__":
    main()
