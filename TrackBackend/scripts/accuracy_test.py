#!/usr/bin/env python3
"""
accuracy_test.py
TrackBackend/scripts/

Accuracy comparison: Track ML model  vs  raw MTA SIRI times.

Usage:
  python scripts/accuracy_test.py [--lat 40.7085] [--lon -73.8318] [--radius 800]

How it works:
  1. Hits your local /nearby endpoint  → ML-corrected minutes_away
  2. Hits MTA SIRI StopMonitoring directly → raw MTA minutes_away (no correction)
  3. Prints a side-by-side diff table
  4. Optionally re-polls after N seconds to check which prediction was closer
     to the actual GPS timestamp (--watch 60)

Ground truth:
  "Raw MTA" is ExpectedArrivalTime from SIRI — already a real-time GPS-based
  prediction. So the diff shows exactly what the ML layer is adding on top.
  Positive diff = ML says it'll be later than MTA claims.
  When the recency model has observations, it also folds in the stop's recent
  running-late/early history.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import sys
import time
from datetime import datetime, timezone
from typing import Any

import httpx

# ── Config ────────────────────────────────────────────────────────────────
LOCAL_BACKEND   = "http://localhost:8000"
MTA_SIRI_BASE   = "https://bustime.mta.info/api/siri/stop-monitoring.json"
MTA_BUS_KEY     = "d5e1a531-5aa6-4db0-bd29-8dbdec47a27a"

# OBA stops-for-location (to discover stop IDs near the user)
OBA_NEARBY      = "https://bustime.mta.info/api/where/stops-for-location.json"
OBA_KEY         = MTA_BUS_KEY

# Default: Kew Gardens, Queens (near Q10, J/Z subway)
DEFAULT_LAT = 40.7085
DEFAULT_LON = -73.8318


# ── Helpers ──────────────────────────────────────────────────────────────

def _minutes_until(iso_str: str | None) -> int | None:
    if not iso_str:
        return None
    try:
        dt = datetime.fromisoformat(iso_str)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        diff = (dt - datetime.now(timezone.utc)).total_seconds()
        return max(0, math.ceil(diff / 60))
    except Exception:
        return None


def _bar(value: int, max_val: int = 20, width: int = 15) -> str:
    filled = min(int(value / max_val * width), width)
    return "█" * filled + "░" * (width - filled)


# ── Step 1: get our backend's corrected arrivals ──────────────────────────

async def fetch_track_nearby(lat: float, lon: float, radius: int) -> list[dict]:
    url = f"{LOCAL_BACKEND}/nearby?lat={lat}&lon={lon}&radius={radius}"
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.get(url)
        resp.raise_for_status()
    raw: list[dict] = resp.json()
    # Only keep bus routes (have cleaner SIRI comparison data)
    return [a for a in raw if a.get("mode") == "bus" and a.get("minutes_away", 99) < 60]


# ── Step 2: discover nearby stops via OBA, then hit SIRI per stop ─────────

async def fetch_nearby_stop_ids(lat: float, lon: float, radius: int) -> list[str]:
    params = {
        "key": OBA_KEY,
        "lat": lat,
        "lon": lon,
        "radius": radius,
        "maxCount": 20,
    }
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.get(OBA_NEARBY, params=params)
        resp.raise_for_status()
    data = resp.json()
    stops = data.get("data", {}).get("stops", []) or data.get("data", {}).get("list", [])
    ids = []
    for s in stops:
        sid = s.get("id", "") or s.get("stopId", "")
        if sid:
            # OBA IDs include agency prefix e.g. "MTA NYCT_308214"
            ids.append(sid)
    return ids[:10]


async def fetch_siri_for_stop(stop_id: str) -> list[dict]:
    """Return list of {route, minutes, status, expected_iso} from SIRI."""
    params = {
        "key": MTA_BUS_KEY,
        "version": "2",
        "MonitoringRef": stop_id,
    }
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(MTA_SIRI_BASE, params=params)
            resp.raise_for_status()
        data: dict[str, Any] = resp.json()
    except Exception as exc:
        print(f"  SIRI error for {stop_id}: {exc}", file=sys.stderr)
        return []

    deliveries = (
        data.get("Siri", {})
            .get("ServiceDelivery", {})
            .get("StopMonitoringDelivery", [])
    )
    if not deliveries:
        return []

    visits = deliveries[0].get("MonitoredStopVisit", [])
    results = []
    for visit in visits:
        journey = visit.get("MonitoredVehicleJourney", {})
        call = journey.get("MonitoredCall", {})

        expected_iso = call.get("ExpectedArrivalTime")
        aimed_iso    = call.get("AimedArrivalTime")
        mins         = _minutes_until(expected_iso)

        if mins is None:
            continue

        # Deviation vs schedule
        dev_s: int | None = None
        if expected_iso and aimed_iso:
            exp_m = _minutes_until(expected_iso)
            aim_m = _minutes_until(aimed_iso)
            if exp_m is not None and aim_m is not None:
                dev_s = (exp_m - aim_m) * 60  # approximate

        names = journey.get("PublishedLineName")
        if isinstance(names, list) and names:
            route = names[0]
        else:
            route = journey.get("LineRef", "?").split("_")[-1]

        ext = call.get("Extensions", {})
        dist = ext.get("Distances", {})
        status = dist.get("PresentableDistance", "")

        dest_raw = journey.get("DestinationName")
        dest = ""
        if isinstance(dest_raw, list) and dest_raw:
            dest = dest_raw[0]
        elif isinstance(dest_raw, str):
            dest = dest_raw

        results.append({
            "route": route,
            "stop_id": stop_id,
            "raw_minutes": mins,
            "status": status,
            "destination": dest,
            "expected_iso": expected_iso,
            "dev_s": dev_s,
        })

    return results


# ── Step 3: match & compare ───────────────────────────────────────────────

def match_and_compare(
    track_arrivals: list[dict],
    siri_arrivals: list[dict],
) -> list[dict]:
    """Join on (route, stop_id) and diff minutes_away."""
    rows = []

    # Index SIRI by (route, stop_id)
    siri_index: dict[tuple[str, str], list[dict]] = {}
    for s in siri_arrivals:
        key = (s["route"].upper(), _canon_stop(s["stop_id"]))
        siri_index.setdefault(key, []).append(s)

    for t in track_arrivals:
        route = t.get("route_id", "").upper()
        stop  = _canon_stop(t.get("stop_id", ""))
        key   = (route, stop)

        ml_mins = t.get("minutes_away", -1)

        siri_matches = siri_index.get(key, [])
        if not siri_matches:
            # Try partial route match (SIRI sometimes omits agency)
            for (sr, ss), sv in siri_index.items():
                if sr.endswith(route) or route.endswith(sr):
                    if ss == stop:
                        siri_matches = sv
                        break

        if siri_matches:
            # Pick closest minutes match
            best = min(siri_matches, key=lambda x: abs(x["raw_minutes"] - ml_mins))
            rows.append({
                "route": route,
                "stop_id": stop,
                "stop_name": t.get("stop_name", ""),
                "destination": best["destination"] or t.get("destination", ""),
                "status": best["status"],
                "raw_mta_min":  best["raw_minutes"],
                "ml_model_min": ml_mins,
                "diff": ml_mins - best["raw_minutes"],
                "dev_s":        best.get("dev_s"),
                "expected_iso": best["expected_iso"],
                "matched": True,
            })
        else:
            rows.append({
                "route": route,
                "stop_id": stop,
                "stop_name": t.get("stop_name", ""),
                "destination": t.get("destination", ""),
                "status": t.get("status", ""),
                "raw_mta_min":  None,
                "ml_model_min": ml_mins,
                "diff":         None,
                "dev_s":        None,
                "expected_iso": None,
                "matched": False,
            })

    return rows


def _canon_stop(sid: str) -> str:
    s = (sid or "").strip()
    for prefix in ("MTA_", "MTA NYCT_", "MTABC_"):
        if s.startswith(prefix):
            s = s[len(prefix):]
    return s


# ── Printing ─────────────────────────────────────────────────────────────

def print_table(rows: list[dict]) -> None:
    matched = [r for r in rows if r["matched"]]
    unmatched = [r for r in rows if not r["matched"]]

    # Sort by route then raw_mta_min
    matched.sort(key=lambda x: (x["route"], x["raw_mta_min"] or 99))

    # Compute accuracy stats
    diffs = [abs(r["diff"]) for r in matched if r["diff"] is not None]

    print()
    print("━" * 90)
    print("  TRACK ML  vs  RAW MTA SIRI  —  Arrival Time Comparison")
    print("━" * 90)
    print(f"  {'Route':<8} {'Stop':<22} {'MTA raw':>9} {'ML model':>9} {'Diff':>6}  {'Bar (MTA vs ML)'}")
    print("  " + "─" * 87)

    for r in matched:
        route    = r["route"]
        stop     = (r["stop_name"] or r["stop_id"])[:21]
        raw_m    = r["raw_mta_min"]
        ml_m     = r["ml_model_min"]
        diff     = r["diff"]
        dev_s    = r["dev_s"]
        dest     = r["destination"][:24] if r["destination"] else ""

        diff_str = f"+{diff}m" if diff > 0 else f"{diff}m"
        dev_str  = f"  [SIRI dev {dev_s:+d}s]" if dev_s else ""

        # Visual bar: MTA time in blue░ ML extension in red█
        bar_raw = _bar(raw_m, max_val=30, width=12)
        ext_len = min(max(0, diff), 6)
        bar_ext = "▓" * ext_len

        print(f"  {route:<8} {stop:<22} {raw_m:>6} min  {ml_m:>6} min  {diff_str:>5}  {bar_raw}{bar_ext}  → {dest}{dev_str}")

    if unmatched:
        print(f"\n  ⚠  {len(unmatched)} Track arrivals had no SIRI match (stop resolved differently or bus not in SIRI yet):")
        for r in unmatched[:5]:
            print(f"     {r['route']:<8} stop={r['stop_id']:<15} ml={r['ml_model_min']} min  ({r['stop_name']})")

    print()
    print("━" * 90)
    if diffs:
        avg  = sum(diffs) / len(diffs)
        maxd = max(diffs)
        zero = sum(1 for d in diffs if d == 0)
        print(f"  Matched arrivals : {len(matched)}")
        print(f"  Avg ML correction: {avg:.2f} min  (how much the model added on top of MTA raw)")
        print(f"  Max correction   : {maxd} min")
        print(f"  No correction    : {zero}/{len(matched)} arrivals (model agreed with MTA exactly)")
        print()
        print("  ℹ  Diffs of 0 = model factor rounds to same minute (correct for reliable routes).")
        print("  ℹ  Diffs of +1 or +2 = model correctly inflating for rush/weather/bad routes.")
        print("  ℹ  Diffs > 3 = recency correction active (stop has logged recent late trips).")
    print("━" * 90)


# ── Watch mode: re-poll and check actual vs predicted ────────────────────

async def watch_mode(rows: list[dict], wait_seconds: int) -> None:
    """
    Wait `wait_seconds` then re-check SIRI.  Any bus that has now departed
    (ExpectedArrivalTime passed) tells us which prediction was closer.
    """
    print(f"\n  ↩  Watch mode: re-polling in {wait_seconds}s to verify predictions …")
    await asyncio.sleep(wait_seconds)

    now = datetime.now(timezone.utc)
    print()
    print("━" * 90)
    print(f"  RESULT CHECK after {wait_seconds}s")
    print("━" * 90)

    for r in rows:
        if not r["matched"] or not r["expected_iso"]:
            continue
        try:
            exp_dt = datetime.fromisoformat(r["expected_iso"])
            if exp_dt.tzinfo is None:
                exp_dt = exp_dt.replace(tzinfo=timezone.utc)
        except Exception:
            continue

        # Re-query SIRI for this stop
        fresh = await fetch_siri_for_stop(r["stop_id"])
        still_there = any(
            f["route"].upper() == r["route"] and f["raw_minutes"] <= r["raw_mta_min"] + 2
            for f in fresh
        )
        actual_delta_s = (now - exp_dt).total_seconds()

        if not still_there and actual_delta_s > 0:
            # Bus likely arrived — how late was it?
            late_min = round(actual_delta_s / 60, 1)
            ml_error  = abs(r["ml_model_min"] - (r["raw_mta_min"] + late_min))
            raw_error = abs(late_min)
            winner = "ML ✓" if ml_error <= raw_error else "MTA raw ✓"
            print(
                f"  {r['route']:<6} arrived ~{late_min:+.1f}m vs MTA schedule  "
                f"raw_err={raw_error:.1f}m  ml_err={ml_error:.1f}m  → {winner}"
            )
        else:
            remaining = _minutes_until(r["expected_iso"])
            print(f"  {r['route']:<6} still {remaining}m away — not yet arrived, check later")

    print("━" * 90)


# ── Main ──────────────────────────────────────────────────────────────────

async def main() -> None:
    parser = argparse.ArgumentParser(description="Compare Track ML predictions vs raw MTA SIRI times")
    parser.add_argument("--lat",    type=float, default=DEFAULT_LAT, help="Latitude (default: Kew Gardens)")
    parser.add_argument("--lon",    type=float, default=DEFAULT_LON, help="Longitude (default: Kew Gardens)")
    parser.add_argument("--radius", type=int,   default=800,         help="Search radius in meters")
    parser.add_argument("--watch",  type=int,   default=0,
                        help="Re-poll after N seconds to check actual arrival vs prediction")
    args = parser.parse_args()

    print(f"\n  📍  Location: {args.lat}, {args.lon}  |  radius={args.radius}m")
    print(f"  🕐  {datetime.now().strftime('%H:%M:%S')}  (fetching…)\n")

    t0 = time.perf_counter()

    # 1. Track backend (ML-corrected)
    print("  [1/3] Fetching Track /nearby (ML-corrected) …")
    track_arrivals = await fetch_track_nearby(args.lat, args.lon, args.radius)
    print(f"        → {len(track_arrivals)} bus arrivals")

    if not track_arrivals:
        print("\n  ⚠  No bus arrivals near this location. Try --radius 1500 or a busier location.")
        print("     E.g.:  python scripts/accuracy_test.py --lat 40.7580 --lon -73.9855  (Times Square)")
        return

    # 2. Discover stop IDs then hit SIRI directly
    print("  [2/3] Discovering nearby stops via OBA + hitting MTA SIRI …")
    stop_ids = await fetch_nearby_stop_ids(args.lat, args.lon, args.radius)
    # Also pull stop_ids directly from Track arrivals
    track_stop_ids = list({a.get("stop_id", "") for a in track_arrivals if a.get("stop_id")})
    all_stop_ids = list(set(stop_ids + track_stop_ids))[:15]
    print(f"        → {len(all_stop_ids)} stops to query SIRI on")

    siri_tasks = [fetch_siri_for_stop(sid) for sid in all_stop_ids]
    siri_results = await asyncio.gather(*siri_tasks)
    siri_arrivals: list[dict] = [arr for batch in siri_results for arr in batch]
    print(f"        → {len(siri_arrivals)} raw SIRI arrivals")

    elapsed = time.perf_counter() - t0
    print(f"  [3/3] Comparing … ({elapsed:.1f}s total fetch)")

    # 3. Match and print
    rows = match_and_compare(track_arrivals, siri_arrivals)
    print_table(rows)

    # 4. Optional watch mode
    if args.watch > 0:
        await watch_mode(rows, args.watch)


if __name__ == "__main__":
    asyncio.run(main())
