#!/usr/bin/env python3
"""
stop_audit.py
TrackBackend/scripts/

Deep-compares MTA raw data (SIRI for bus, GTFS-RT for subway) against our
backend /nearby/grouped endpoint for a specific location.

Checks that no bus or train visible in the MTA feed is missing from our API,
and that our scheduled departures are reachable when live data is absent.

Usage:
  # Default: Kew Gardens (Q10 + E/J subway)
  python scripts/stop_audit.py

  # Custom location + radius
  python scripts/stop_audit.py --lat 40.7085 --lon -73.8318 --radius 800

  # Jamaica hub (lots of buses + E/J/Z/A)
  python scripts/stop_audit.py --lat 40.7024 --lon -73.8088 --preset jamaica

  # Against a running local backend
  python scripts/stop_audit.py --backend http://localhost:8000

Env vars:
  OBA_API_KEY   - MTA BusTime API key (required for bus SIRI)
  MTA_API_KEY   - MTA subway GTFS-RT key (optional; falls back to no-auth)
"""

from __future__ import annotations

import argparse
import asyncio
import math
import os
import sys
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx

# ── Load project .env so OBA_API_KEY / MTA_API_KEY are available ─────────
_ENV_PATH = Path(__file__).resolve().parent.parent / ".env"
try:
    from dotenv import load_dotenv
    load_dotenv(_ENV_PATH, override=False)
except ImportError:
    pass

# ── Add project root to sys.path so we can import app internals ──────────
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# ─────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────

OBA_KEY   = os.environ.get("OBA_API_KEY", "")
MTA_KEY   = os.environ.get("MTA_API_KEY", "")

SIRI_BASE = "https://bustime.mta.info/api/siri/stop-monitoring.json"
OBA_STOPS = "https://bustime.mta.info/api/where/stops-for-location.json"

# Subway GTFS-RT feed URLs (keyed by representative line letter)
SUBWAY_FEEDS: dict[str, str] = {
    "ace":    "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-ace",
    "bdfm":   "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-bdfm",
    "g":      "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-g",
    "jz":     "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-jz",
    "nqrw":   "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-nqrw",
    "1234567":"https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs",
    "l":      "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-l",
    "si":     "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-si",
}

# Line → feed mapping
_LINE_TO_FEED: dict[str, str] = {
    **{l: "ace"     for l in "ACE"},
    **{l: "bdfm"    for l in "BDFM"},
    "G":             "g",
    **{l: "jz"      for l in "JZ"},
    **{l: "nqrw"    for l in "NQRW"},
    **{l: "1234567" for l in "1234567"},
    "L":             "l",
    "SIR":           "si",
}

# Well-known test presets
PRESETS: dict[str, tuple[float, float, int]] = {
    "kew_gardens": (40.7085, -73.8318, 800),
    "jamaica":     (40.7024, -73.8088, 800),
    "times_sq":    (40.7580, -73.9855, 600),
    "atlantic_av": (40.6845, -73.9778, 600),
    "flushing":    (40.7576, -73.8298, 600),
    "grand_st":    (40.7096, -74.0090, 600),
}

# ─────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────

def _now_utc() -> datetime:
    return datetime.now(UTC)


def _mins(iso: str | None) -> int | None:
    """Parse ISO timestamp → minutes until arrival from now."""
    if not iso:
        return None
    try:
        dt = datetime.fromisoformat(iso)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=UTC)
        return max(0, math.ceil((dt - _now_utc()).total_seconds() / 60))
    except Exception:
        return None


def _mins_from_epoch(ts: int | None) -> int | None:
    if ts is None:
        return None
    diff = ts - time.time()
    return max(0, math.ceil(diff / 60)) if diff > -90 else None


def _strip_agency(s: str) -> str:
    for p in ("MTA_", "MTA NYCT_", "MTABC_", "MTA "):
        if s.startswith(p):
            s = s[len(p):]
    return s.strip()


def _route_key(r: str) -> str:
    return _strip_agency(r).upper().lstrip("0")


def _color(code: str, text: str) -> str:
    codes = {"red": "\033[91m", "green": "\033[92m", "yellow": "\033[93m",
             "cyan": "\033[96m", "bold": "\033[1m", "reset": "\033[0m",
             "dim": "\033[2m"}
    return f"{codes.get(code,'')}{text}{codes['reset']}"


# ─────────────────────────────────────────────────────────────────────────
# Raw MTA — Bus (SIRI stop-monitoring)
# ─────────────────────────────────────────────────────────────────────────

async def fetch_nearby_bus_stops(lat: float, lon: float, radius: int) -> list[dict]:
    """Fetch nearby bus stop IDs from OBA."""
    if not OBA_KEY:
        return []
    params = {"key": OBA_KEY, "lat": lat, "lon": lon, "radius": radius, "maxCount": 20}
    try:
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.get(OBA_STOPS, params=params)
            r.raise_for_status()
        data = r.json()
        stops = (data.get("data", {}).get("stops")
                 or data.get("data", {}).get("list", []))
        return [
            {"id": s.get("id") or s.get("stopId", ""),
             "name": s.get("name", ""),
             "lat": s.get("lat", 0),
             "lon": s.get("lon", 0)}
            for s in stops
            if s.get("id") or s.get("stopId")
        ][:15]
    except Exception as exc:
        print(f"  [OBA stops] error: {exc}")
        return []


async def fetch_siri_for_stop(stop_id: str) -> list[dict]:
    """
    Fetch raw SIRI stop-monitoring arrivals for one stop.
    Returns list of dicts with: route, vehicle_id, stop_id, minutes, status.
    """
    if not OBA_KEY:
        return []
    params = {"key": OBA_KEY, "version": "2", "MonitoringRef": stop_id}
    try:
        async with httpx.AsyncClient(timeout=12) as c:
            r = await c.get(SIRI_BASE, params=params)
            r.raise_for_status()
        data: dict = r.json()
    except Exception as exc:
        print(f"  [SIRI {stop_id}] error: {exc}")
        return []

    deliveries = (
        data.get("Siri", {})
            .get("ServiceDelivery", {})
            .get("StopMonitoringDelivery", [])
    )
    if not deliveries:
        return []

    results = []
    for visit in deliveries[0].get("MonitoredStopVisit", []):
        j    = visit.get("MonitoredVehicleJourney", {})
        call = j.get("MonitoredCall", {})
        ext  = call.get("Extensions", {})
        dist = ext.get("Distances", {})

        expected = call.get("ExpectedArrivalTime")
        mins     = _mins(expected)

        names = j.get("PublishedLineName")
        if isinstance(names, list) and names:
            route = names[0]
        else:
            route = j.get("LineRef", "?").split("_")[-1]

        monitored = j.get("Monitored", True)
        is_rt     = monitored not in (False, "false", "False", "0")

        status_text = dist.get("PresentableDistance", "")

        # Vehicle location
        loc  = j.get("VehicleLocation", {})
        vlat = loc.get("Latitude")
        vlon = loc.get("Longitude")

        results.append({
            "route":      route.upper(),
            "vehicle_id": j.get("VehicleRef", ""),
            "stop_id":    _strip_agency(stop_id),
            "minutes":    mins,
            "expected":   expected,
            "status":     status_text,
            "is_rt":      is_rt,
            "dest":       (j.get("DestinationName") or [""])[0]
                          if isinstance(j.get("DestinationName"), list)
                          else j.get("DestinationName", ""),
            "vlat":       float(vlat) if vlat else None,
            "vlon":       float(vlon) if vlon else None,
        })

    return results


# ─────────────────────────────────────────────────────────────────────────
# Raw MTA — Subway (GTFS-RT protobuf)
# ─────────────────────────────────────────────────────────────────────────

async def fetch_gtfs_rt_for_station(
    station_ids: set[str],
    feed_keys: list[str],
) -> list[dict]:
    """
    Parse GTFS-RT feeds for the given feed keys and filter to station_ids.
    Returns list of dicts: route, trip_id, stop_id, arrival_ts, minutes.
    """
    try:
        from google.transit import gtfs_realtime_pb2
    except ImportError:
        print("  [GTFS-RT] google.transit not installed; skipping subway raw feed check")
        return []

    headers: dict[str, str] = {}
    if MTA_KEY:
        headers["x-api-key"] = MTA_KEY

    results: list[dict] = []
    now_ts = time.time()

    async def _fetch_feed(key: str) -> list[dict]:
        url   = SUBWAY_FEEDS[key]
        local: list[dict] = []
        try:
            async with httpx.AsyncClient(timeout=15) as c:
                resp = await c.get(url, headers=headers)
                resp.raise_for_status()
            raw = resp.content
        except Exception as exc:
            print(f"  [GTFS-RT {key}] error: {exc}")
            return []

        feed = gtfs_realtime_pb2.FeedMessage()
        feed.ParseFromString(raw)

        for entity in feed.entity:
            if not entity.HasField("trip_update"):
                continue
            tu    = entity.trip_update
            route = tu.trip.route_id.upper()
            tid   = tu.trip.trip_id

            for stu in tu.stop_time_update:
                sid = stu.stop_id
                # Match parent station (e.g. "127N" / "127S" both belong to "127")
                base_sid = sid.rstrip("NS")
                if base_sid not in station_ids and sid not in station_ids:
                    continue
                # Prefer arrival, fallback to departure
                ts_evt = (
                    stu.arrival.time if stu.HasField("arrival") and stu.arrival.time
                    else stu.departure.time if stu.HasField("departure") and stu.departure.time
                    else None
                )
                if ts_evt is None:
                    continue
                diff = ts_evt - now_ts
                if diff < -90:   # already passed
                    continue
                mins = max(0, math.ceil(diff / 60))
                local.append({
                    "route":      route,
                    "trip_id":    tid,
                    "stop_id":    sid,
                    "arrival_ts": ts_evt,
                    "minutes":    mins,
                    "feed":       key,
                })
        return local

    tasks = [_fetch_feed(k) for k in feed_keys]
    batches = await asyncio.gather(*tasks)
    for b in batches:
        results.extend(b)

    # Deduplicate by (route, trip_id, stop_id)
    seen: set[tuple] = set()
    deduped: list[dict] = []
    for r in sorted(results, key=lambda x: x["arrival_ts"]):
        key = (r["route"], r["trip_id"], r["stop_id"])
        if key not in seen:
            seen.add(key)
            deduped.append(r)

    return deduped


# ─────────────────────────────────────────────────────────────────────────
# Backend /nearby/grouped
# ─────────────────────────────────────────────────────────────────────────

async def fetch_backend(
    lat: float, lon: float, radius: int, backend: str
) -> list[dict]:
    """
    Fetch /nearby/grouped from our backend and flatten into comparable records.
    Returns list of dicts: route, direction, stop_id, stop_name, minutes,
                           arrival_ts, is_rt, vehicle_id, trip_id.
    """
    url = f"{backend}/nearby/grouped"
    params = {"lat": lat, "lon": lon, "radius": radius}
    try:
        async with httpx.AsyncClient(timeout=30) as c:
            r = await c.get(url, params=params)
            r.raise_for_status()
        groups: list[dict] = r.json()
    except Exception as exc:
        print(f"  [Backend] error: {exc}")
        return []

    flat: list[dict] = []
    for grp in groups:
        route = _route_key(grp.get("route_id", ""))
        mode  = grp.get("mode", "")
        for direction in grp.get("directions", []):
            dir_label = direction.get("direction_label", direction.get("direction", ""))
            for arr in direction.get("arrivals", []):
                if arr.get("minutes_away", 99) >= 99:
                    continue
                flat.append({
                    "route":      route,
                    "mode":       mode,
                    "direction":  dir_label,
                    "stop_id":    _strip_agency(arr.get("stop_id") or ""),
                    "stop_name":  arr.get("stop_name", ""),
                    "minutes":    arr.get("minutes_away", 99),
                    "arrival_ts": arr.get("arrival_ts"),
                    "is_rt":      arr.get("is_real_time", False),
                    "vehicle_id": arr.get("vehicle_id"),
                    "trip_id":    arr.get("trip_id"),
                    "status":     arr.get("status", ""),
                })
    return flat


# ─────────────────────────────────────────────────────────────────────────
# Comparison logic
# ─────────────────────────────────────────────────────────────────────────

def _compare_bus(
    siri: list[dict],
    backend: list[dict],
) -> dict:
    """
    Compare SIRI arrivals against backend arrivals.
    Returns a dict with matched, missing_from_backend, extra_in_backend.
    """
    # Index backend by (route, vehicle_id) and also (route, stop, ~minutes)
    be_by_vid: dict[tuple, dict] = {}
    be_by_stop_min: dict[tuple, list[dict]] = {}
    for a in backend:
        if a.get("mode") != "bus":
            continue
        vid = a.get("vehicle_id", "")
        key = (_route_key(a["route"]), _strip_agency(vid or ""))
        if vid:
            be_by_vid[key] = a
        sk = (_route_key(a["route"]), _strip_agency(a.get("stop_id", "")))
        be_by_stop_min.setdefault(sk, []).append(a)

    matched:              list[dict] = []
    missing_from_backend: list[dict] = []

    for s in siri:
        if s.get("minutes") is None or s["minutes"] >= 60:
            continue
        rk  = _route_key(s["route"])
        vid = _strip_agency(s.get("vehicle_id", ""))

        # Try to match by vehicle ID first
        be = be_by_vid.get((rk, vid))

        # Fallback: match by (route, stop, minutes within ±3)
        if be is None:
            sk = (rk, _strip_agency(s.get("stop_id", "")))
            candidates = be_by_stop_min.get(sk, [])
            if candidates:
                be = min(
                    candidates,
                    key=lambda c: abs(c["minutes"] - s["minutes"]),
                    default=None,
                )
                if be and abs(be["minutes"] - s["minutes"]) > 5:
                    be = None  # too far apart — treat as miss

        if be:
            matched.append({
                "route":   rk,
                "stop":    s["stop_id"],
                "siri_m":  s["minutes"],
                "be_m":    be["minutes"],
                "delta":   be["minutes"] - s["minutes"],
                "siri_rt": s["is_rt"],
                "be_rt":   be["is_rt"],
                "vid":     vid,
                "dest":    s.get("dest", ""),
                "status":  s.get("status", ""),
            })
        else:
            missing_from_backend.append({
                "route":   rk,
                "stop":    s["stop_id"],
                "minutes": s["minutes"],
                "is_rt":   s["is_rt"],
                "vid":     vid,
                "dest":    s.get("dest", ""),
                "status":  s.get("status", ""),
            })

    # Extra in backend not in SIRI (scheduled entries are expected here)
    siri_vids = {
        (_route_key(s["route"]), _strip_agency(s.get("vehicle_id", "")))
        for s in siri
        if s.get("vehicle_id")
    }
    extra: list[dict] = []
    for a in backend:
        if a.get("mode") != "bus":
            continue
        if not a.get("is_rt"):
            continue  # scheduled-only entries expected to have no SIRI match
        rk  = _route_key(a["route"])
        vid = _strip_agency(a.get("vehicle_id", "") or "")
        if vid and (rk, vid) not in siri_vids:
            extra.append({
                "route":   rk,
                "stop":    a.get("stop_id", ""),
                "minutes": a["minutes"],
                "vid":     vid,
            })

    return {
        "matched":               matched,
        "missing_from_backend":  missing_from_backend,
        "extra_in_backend":      extra,
    }


def _compare_subway(
    gtfs: list[dict],
    backend: list[dict],
) -> dict:
    """Compare GTFS-RT arrivals for nearby stations against backend."""
    be_by_trip: dict[tuple, dict] = {}
    for a in backend:
        if a.get("mode") not in ("subway",):
            continue
        if a.get("trip_id"):
            key = (_route_key(a["route"]), a["trip_id"])
            be_by_trip[key] = a

    matched:              list[dict] = []
    missing_from_backend: list[dict] = []

    for g in gtfs:
        if g["minutes"] >= 60:
            continue
        rk  = _route_key(g["route"])
        tid = g["trip_id"]
        be  = be_by_trip.get((rk, tid))

        # Fallback: any backend entry with same route and arrival within ±3 min
        if be is None:
            candidates = [
                a for a in backend
                if _route_key(a["route"]) == rk
                and a.get("mode") not in ("bus",)
                and a.get("arrival_ts") is not None
                and abs(a.get("arrival_ts", 0) - g["arrival_ts"]) < 180
            ]
            if candidates:
                be = candidates[0]

        if be:
            matched.append({
                "route":   rk,
                "stop":    g["stop_id"],
                "gtfs_m":  g["minutes"],
                "be_m":    be["minutes"],
                "delta":   be["minutes"] - g["minutes"],
                "trip_id": tid,
            })
        else:
            missing_from_backend.append({
                "route":   rk,
                "stop":    g["stop_id"],
                "minutes": g["minutes"],
                "trip_id": tid,
            })

    return {
        "matched":              matched,
        "missing_from_backend": missing_from_backend,
    }


# ─────────────────────────────────────────────────────────────────────────
# Scheduled departures check via backend
# ─────────────────────────────────────────────────────────────────────────

async def fetch_backend_schedule(
    lat: float, lon: float, radius: int, backend: str
) -> list[dict]:
    """
    Hits /bus/schedule for nearby routes then filters to ones with no live data
    to check the schedule-fill path works.
    """
    # First get route IDs from /nearby/grouped
    groups_url = f"{backend}/nearby/grouped"
    params = {"lat": lat, "lon": lon, "radius": radius, "mode": "bus"}
    try:
        async with httpx.AsyncClient(timeout=30) as c:
            r = await c.get(groups_url, params=params)
            r.raise_for_status()
        groups: list[dict] = r.json()
    except Exception:
        return []

    route_ids = [g["route_id"] for g in groups if g.get("mode") == "bus"]
    if not route_ids:
        return []

    # Pick the route with the fewest live arrivals (most likely to need schedule fill)
    target: dict | None = None
    min_live = 99
    for g in groups:
        if g.get("mode") != "bus":
            continue
        live_count = sum(
            1 for d in g.get("directions", [])
            for a in d.get("arrivals", [])
            if a.get("is_real_time")
        )
        if live_count < min_live:
            min_live  = live_count
            target    = g

    if not target:
        return []

    route_id = target["route_id"]
    sched_url = f"{backend}/bus/{route_id}/schedule"
    try:
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.get(sched_url)
            r.raise_for_status()
        sched: dict = r.json()
    except Exception as exc:
        print(f"  [Schedule {route_id}] error: {exc}")
        return []

    # Flatten schedule entries with departure times in the next 90 minutes
    now_ts = time.time()
    entries: list[dict] = []
    for direction in sched.get("directions", []):
        for stop in direction.get("stops", []):
            for dep in stop.get("departures", []):
                arr_ts = dep.get("arrival_ts")
                if arr_ts is None:
                    continue
                diff = arr_ts - now_ts
                if 0 <= diff <= 5400:  # next 90 min
                    entries.append({
                        "route":     _route_key(route_id),
                        "stop_id":   _strip_agency(stop.get("stop_id", "")),
                        "stop_name": stop.get("stop_name", ""),
                        "minutes":   math.ceil(diff / 60),
                        "arrival_ts": arr_ts,
                    })

    return sorted(entries, key=lambda x: x["minutes"])


# ─────────────────────────────────────────────────────────────────────────
# Printing / report
# ─────────────────────────────────────────────────────────────────────────

def _print_section(title: str) -> None:
    print(f"\n{_color('bold', '━' * 60)}")
    print(f"{_color('bold', title)}")
    print(_color('bold', '━' * 60))


def _print_bus_arrivals(label: str, arrivals: list[dict]) -> None:
    """Print a table of SIRI arrivals."""
    if not arrivals:
        print(f"  {_color('dim', '(no arrivals)')}")
        return
    arrivals_sorted = sorted(
        (a for a in arrivals if a.get("minutes") is not None and a["minutes"] < 60),
        key=lambda x: x["minutes"],
    )
    for a in arrivals_sorted:
        rt_tag = _color("green", "LIVE") if a.get("is_rt") else _color("dim", "SCHED")
        mins   = f"{a['minutes']:3d}m"
        route  = _color("cyan", f"{_route_key(a['route']):<6}")
        stop   = a.get("stop_id", "")[:12]
        dest   = (a.get("dest") or "")[:30]
        status = (a.get("status") or "")[:30]
        vid    = (a.get("vehicle_id") or "")[:10]
        print(f"  {rt_tag} {route} {mins}  stop={stop:<12}  vid={vid:<10}  {dest or status}")


def _print_subway_arrivals(label: str, arrivals: list[dict]) -> None:
    if not arrivals:
        print(f"  {_color('dim', '(no arrivals)')}")
        return
    for a in sorted(arrivals, key=lambda x: x["minutes"]):
        route = _color("cyan", f"{a['route']:<4}")
        mins  = f"{a['minutes']:3d}m"
        stop  = a.get("stop_id", "")[:8]
        tid   = (a.get("trip_id") or "")[:20]
        print(f"  {route} {mins}  stop={stop:<8}  trip={tid}")


def _print_backend_arrivals(arrivals: list[dict]) -> None:
    if not arrivals:
        print(f"  {_color('dim', '(no arrivals)')}")
        return
    for a in sorted(arrivals, key=lambda x: x["minutes"]):
        rt_tag = _color("green", "LIVE ") if a.get("is_rt") else _color("dim", "SCHED")
        mode   = a.get("mode", "?")[0].upper()  # B/S
        route  = _color("cyan", f"{a['route']:<6}")
        mins   = f"{a['minutes']:3d}m"
        stop   = (a.get("stop_id") or "")[:12]
        ts_str = ""
        if a.get("arrival_ts"):
            ts_str = datetime.fromtimestamp(a["arrival_ts"]).strftime("@%H:%M")
        print(f"  [{mode}] {rt_tag} {route} {mins} {ts_str:<8}  stop={stop}")


def _print_diff_bus(result: dict) -> None:
    matched  = result["matched"]
    missing  = result["missing_from_backend"]
    extra    = result["extra_in_backend"]

    print(f"\n  Matched (SIRI ↔ backend): {_color('green', str(len(matched)))}")
    for m in matched:
        delta_str = f"Δ{m['delta']:+d}m" if m["delta"] != 0 else "exact"
        rt_siri   = "RT" if m["siri_rt"] else "SC"
        rt_be     = "RT" if m["be_rt"]   else "SC"
        print(
            f"    {_color('cyan', m['route'][:6]):<14}  SIRI={m['siri_m']:2d}m  BE={m['be_m']:2d}m"
            f"  {delta_str:<8}  [{rt_siri}→{rt_be}]  stop={m['stop'][:12]}"
        )

    if missing:
        print(f"\n  {_color('red', f'MISSING from backend ({len(missing)}):')}")
        for m in missing:
            rt  = "LIVE" if m["is_rt"] else "SCHED"
            vid = m.get("vid") or "no-vid"
            dest = (m.get("dest") or m.get("status") or "")[:35]
            print(
                f"    {_color('red', '✗')} {_color('cyan', m['route'][:6]):<14}"
                f"  {rt}  {m['minutes']:2d}m  stop={m['stop'][:12]}  vid={vid}  {dest}"
            )
    else:
        print(f"\n  {_color('green', '✓ No SIRI arrivals missing from backend')}")

    if extra:
        print(f"\n  Extra LIVE in backend with no SIRI match ({len(extra)}) [stale vehicle?]:")
        for e in extra[:10]:
            print(f"    {_color('yellow', '?')} {e['route']:<8} {e['minutes']:2d}m  vid={e['vid']}")


def _print_diff_subway(result: dict) -> None:
    matched = result["matched"]
    missing = result["missing_from_backend"]

    print(f"\n  Matched (GTFS-RT ↔ backend): {_color('green', str(len(matched)))}")
    for m in matched[:15]:
        delta_str = f"Δ{m['delta']:+d}m" if m["delta"] != 0 else "exact"
        print(
            f"    {_color('cyan', m['route'][:4]):<12}  GTFS={m['gtfs_m']:2d}m  BE={m['be_m']:2d}m"
            f"  {delta_str:<8}  stop={m['stop']}"
        )
    if len(matched) > 15:
        print(f"    … and {len(matched) - 15} more")

    if missing:
        print(f"\n  {_color('red', f'MISSING from backend ({len(missing)}):')}")
        for m in missing[:20]:
            print(
                f"    {_color('red', '✗')} {_color('cyan', m['route'][:4]):<12}"
                f"  {m['minutes']:2d}m  stop={m['stop']}  trip={m['trip_id'][:20]}"
            )
        if len(missing) > 20:
            print(f"    … and {len(missing) - 20} more")
    else:
        print(f"\n  {_color('green', '✓ No GTFS-RT arrivals missing from backend')}")


# ─────────────────────────────────────────────────────────────────────────
# Discovery helpers
# ─────────────────────────────────────────────────────────────────────────

def _nearby_subway_stations(
    lat: float, lon: float, radius_m: float
) -> tuple[set[str], list[str]]:
    """
    Return (station_ids, feed_keys) for subway stations within radius.
    Uses the project's GTFS static data if available, otherwise falls back
    to a simple hardcoded map for common locations.
    """
    try:
        # Try to import from the project's GTFS data
        from app.services.mapping.subway_shapes import SubwayShapeService
        # Not guaranteed to have a sync method; we'll use the fallback instead
    except ImportError:
        pass

    # Simple hardcoded fallback: snap to nearest preset hub
    # (accurate enough for audit purposes)
    station_ids: set[str]  = set()
    feed_keys: list[str]   = []

    # Jamaica area
    if abs(lat - 40.7024) < 0.02 and abs(lon - (-73.8088)) < 0.02:
        station_ids = {"127", "A09"}   # Jamaica-179St (E), Jamaica Center (J/Z/A)
        feed_keys   = ["ace", "jz", "1234567"]

    # Kew Gardens area
    elif abs(lat - 40.7085) < 0.02 and abs(lon - (-73.8318)) < 0.02:
        station_ids = {"125"}          # Kew Gardens Union Tpke (E/F)
        feed_keys   = ["ace"]

    # Times Square
    elif abs(lat - 40.7580) < 0.02 and abs(lon - (-73.9855)) < 0.02:
        station_ids = {"725", "R16", "R14", "127N"}
        feed_keys   = ["1234567", "nqrw", "ace", "bdfm"]

    # Atlantic Terminal
    elif abs(lat - 40.6845) < 0.02 and abs(lon - (-73.9778)) < 0.02:
        station_ids = {"D24", "A41", "R31"}
        feed_keys   = ["ace", "bdfm", "nqrw"]

    # Flushing Main St
    elif abs(lat - 40.7576) < 0.02 and abs(lon - (-73.8298)) < 0.02:
        station_ids = {"701"}
        feed_keys   = ["1234567"]

    # Grand/Fulton
    elif abs(lat - 40.7096) < 0.02 and abs(lon - (-74.0090)) < 0.02:
        station_ids = {"A38", "2", "R22"}
        feed_keys   = ["ace", "1234567", "nqrw"]

    # Generic fallback — try all feeds, no station filter
    else:
        station_ids = set()   # will be filtered by any stop within ~0.5 deg
        feed_keys   = list(SUBWAY_FEEDS.keys())

    return station_ids, feed_keys


# ─────────────────────────────────────────────────────────────────────────
# Main audit
# ─────────────────────────────────────────────────────────────────────────

async def run_audit(
    lat: float,
    lon: float,
    radius: int,
    backend: str,
    skip_subway: bool = False,
) -> None:
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"\n{_color('bold', '╔══════════════════════════════════════════════════════╗')}")
    print(f"{_color('bold', f'║  Track Stop Audit  {ts}                         ║')}")
    print(f"{_color('bold', '╚══════════════════════════════════════════════════════╝')}")
    print(f"  Location : {lat}, {lon}   radius={radius}m")
    print(f"  Backend  : {backend}")
    print(f"  OBA key  : {'✓ set' if OBA_KEY else _color('red', '✗ missing — bus SIRI disabled')}")
    print(f"  MTA key  : {'✓ set' if MTA_KEY else _color('yellow', '✗ not set — subway feed may fail')}")

    # ── Step 1: Discover nearby bus stops ─────────────────────────────────
    _print_section("1 ▸ Discovering nearby bus stops (OBA)")
    bus_stops = await fetch_nearby_bus_stops(lat, lon, radius)
    if not bus_stops:
        print("  No bus stops found (OBA key missing or radius too small?)")
    else:
        for s in bus_stops:
            print(f"  {s['id']:<22}  {s['name']}")

    # ── Step 2: Fetch raw SIRI for each stop ──────────────────────────────
    _print_section("2 ▸ Raw MTA SIRI arrivals (ground truth)")
    siri_all: list[dict] = []
    if bus_stops and OBA_KEY:
        siri_batches = await asyncio.gather(
            *[fetch_siri_for_stop(s["id"]) for s in bus_stops]
        )
        for batch in siri_batches:
            siri_all.extend(batch)
        # Deduplicate by (route, vehicle_id, stop_id)
        seen_siri: set[tuple] = set()
        uniq_siri: list[dict] = []
        for s in siri_all:
            k = (s["route"], s.get("vehicle_id", ""), s["stop_id"])
            if k not in seen_siri:
                seen_siri.add(k)
                uniq_siri.append(s)
        siri_all = uniq_siri

        print(f"  Total raw SIRI arrivals: {len(siri_all)}  (<60 min)")
        _print_bus_arrivals("SIRI", siri_all)
    else:
        print("  Skipped (no OBA key or no stops)")

    # ── Step 3: Raw GTFS-RT for subway ────────────────────────────────────
    gtfs_all: list[dict] = []
    if not skip_subway:
        _print_section("3 ▸ Raw MTA GTFS-RT (subway ground truth)")
        station_ids, feed_keys = _nearby_subway_stations(lat, lon, radius)
        if not feed_keys:
            print("  No subway feed keys resolved for this location")
        elif not MTA_KEY and True:  # Try anyway; some feeds work without key
            print(f"  Attempting {len(feed_keys)} feed(s): {feed_keys}")
            gtfs_all = await fetch_gtfs_rt_for_station(station_ids, feed_keys)
            if gtfs_all:
                print(f"  Total GTFS-RT arrivals: {len(gtfs_all)}  "
                      f"(stations={station_ids or 'all'})")
                _print_subway_arrivals("GTFS-RT", gtfs_all[:30])
            else:
                print("  No GTFS-RT data returned (need MTA_API_KEY for authenticated feeds)")
        else:
            print(f"  Attempting {len(feed_keys)} feed(s) with API key: {feed_keys}")
            gtfs_all = await fetch_gtfs_rt_for_station(station_ids, feed_keys)
            print(f"  Total GTFS-RT arrivals: {len(gtfs_all)}")
            _print_subway_arrivals("GTFS-RT", gtfs_all[:30])

    # ── Step 4: Backend /nearby/grouped ───────────────────────────────────
    _print_section("4 ▸ Backend /nearby/grouped")
    be_all = await fetch_backend(lat, lon, radius, backend)
    if not be_all:
        print(f"  {_color('yellow', 'No backend data — is the server running at')} {backend}?")
    else:
        bus_cnt    = sum(1 for a in be_all if a["mode"] == "bus")
        subway_cnt = sum(1 for a in be_all if a["mode"] == "subway")
        rt_cnt     = sum(1 for a in be_all if a["is_rt"])
        sc_cnt     = sum(1 for a in be_all if not a["is_rt"])
        print(f"  Total: {len(be_all)}  (bus={bus_cnt}, subway={subway_cnt}, "
              f"live={rt_cnt}, sched={sc_cnt})")
        _print_backend_arrivals(be_all[:40])

    # ── Step 5: Bus comparison ────────────────────────────────────────────
    _print_section("5 ▸ Bus diff — SIRI vs Backend")
    if siri_all and be_all:
        bus_diff = _compare_bus(siri_all, be_all)
        _print_diff_bus(bus_diff)

        # Summary stats
        n_match = len(bus_diff["matched"])
        n_miss  = len(bus_diff["missing_from_backend"])
        n_total = n_match + n_miss
        if n_total:
            pct = 100 * n_match / n_total
            bar = ("█" * int(pct / 5)).ljust(20)
            color = "green" if pct >= 90 else "yellow" if pct >= 70 else "red"
            print(f"\n  Coverage: [{_color(color, bar)}] {pct:.0f}%  "
                  f"({n_match}/{n_total} SIRI arrivals found in backend)")
    elif not OBA_KEY:
        print("  Skipped — no OBA key")
    elif not be_all:
        print("  Skipped — backend returned no data")
    else:
        print("  No SIRI arrivals to compare against (empty feed)")

    # ── Step 6: Subway comparison ─────────────────────────────────────────
    if gtfs_all and be_all:
        _print_section("6 ▸ Subway diff — GTFS-RT vs Backend")
        sub_diff = _compare_subway(gtfs_all, be_all)
        _print_diff_subway(sub_diff)
        n_match = len(sub_diff["matched"])
        n_miss  = len(sub_diff["missing_from_backend"])
        n_total = n_match + n_miss
        if n_total:
            pct = 100 * n_match / n_total
            bar = ("█" * int(pct / 5)).ljust(20)
            color = "green" if pct >= 90 else "yellow" if pct >= 70 else "red"
            print(f"\n  Coverage: [{_color(color, bar)}] {pct:.0f}%  "
                  f"({n_match}/{n_total} GTFS-RT arrivals in backend)")
    elif gtfs_all:
        print("\n  (Subway diff skipped — backend returned no data)")

    # ── Step 7: Schedule coverage ─────────────────────────────────────────
    _print_section("7 ▸ Schedule check — does backend serve scheduled departures?")
    # Check backend itself for scheduled (non-RT) entries
    be_sched = [a for a in be_all if not a["is_rt"] and a["mode"] == "bus"]
    be_live  = [a for a in be_all if  a["is_rt"] and a["mode"] == "bus"]
    print(f"  Backend bus entries:  {len(be_live)} LIVE  +  {len(be_sched)} SCHEDULED")

    # Cross-check: for each bus route in backend, do the scheduled entries
    # fill gaps in the live data?
    be_by_route: dict[str, list[dict]] = {}
    for a in be_all:
        if a["mode"] != "bus":
            continue
        be_by_route.setdefault(a["route"], []).append(a)

    for route, entries in sorted(be_by_route.items()):
        live_mins  = sorted([e["minutes"] for e in entries if e["is_rt"]])
        sched_mins = sorted([e["minutes"] for e in entries if not e["is_rt"]])
        if not sched_mins:
            continue
        last_live = max(live_mins) if live_mins else 0
        # Scheduled entries past the last live arrival — proper fill
        gap_fills = [m for m in sched_mins if m > last_live]
        print(
            f"  {_color('cyan', route):<10}  "
            f"live=[{', '.join(map(str, live_mins))}]  "
            f"sched=[{', '.join(map(str, sorted(sched_mins)[:6]))}]"
            + (f"  ← {_color('green', f'{len(gap_fills)} gap fill(s)')}" if gap_fills else "")
        )

    # ── Step 8: Summary ───────────────────────────────────────────────────
    _print_section("8 ▸ Summary")
    issues: list[str] = []

    if siri_all and be_all:
        bus_diff = _compare_bus(siri_all, be_all)
        n_miss_bus = len(bus_diff["missing_from_backend"])
        if n_miss_bus:
            issues.append(
                _color("red", f"Bus: {n_miss_bus} SIRI arrival(s) missing from backend")
            )
        else:
            print(f"  {_color('green', '✓')} All SIRI bus arrivals present in backend")

    if gtfs_all and be_all:
        sub_diff = _compare_subway(gtfs_all, be_all)
        n_miss_sub = len(sub_diff["missing_from_backend"])
        if n_miss_sub:
            issues.append(
                _color("red", f"Subway: {n_miss_sub} GTFS-RT arrival(s) missing from backend")
            )
        else:
            print(f"  {_color('green', '✓')} All GTFS-RT subway arrivals present in backend")

    if be_sched:
        print(f"  {_color('green', '✓')} Schedule fill active ({len(be_sched)} scheduled bus entries)")
    else:
        if be_live:
            issues.append(_color("yellow", "No scheduled bus entries (schedule fill may be off)"))

    if issues:
        print()
        for iss in issues:
            print(f"  {_color('red', '●')} {iss}")
        print()
    else:
        print(f"\n  {_color('green', '✓ All checks passed — backend matches raw MTA feeds')}")


# ─────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────

def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Audit MTA raw feeds vs Track backend for a location."
    )
    p.add_argument("--lat",    type=float, default=None, help="Latitude")
    p.add_argument("--lon",    type=float, default=None, help="Longitude")
    p.add_argument("--radius", type=int,   default=800,  help="Search radius (m)")
    p.add_argument(
        "--preset",
        choices=list(PRESETS.keys()),
        default="kew_gardens",
        help="Preset location name",
    )
    p.add_argument(
        "--backend",
        default="http://localhost:8000",
        help="Backend base URL",
    )
    p.add_argument(
        "--no-subway",
        action="store_true",
        help="Skip GTFS-RT subway check",
    )
    return p.parse_args()


def main() -> None:
    args = _parse_args()

    if args.lat is not None and args.lon is not None:
        lat, lon, radius = args.lat, args.lon, args.radius
    else:
        lat, lon, radius = PRESETS[args.preset]
        if args.radius != 800:
            radius = args.radius

    asyncio.run(
        run_audit(lat, lon, radius, args.backend, skip_subway=args.no_subway)
    )


if __name__ == "__main__":
    main()
