#!/usr/bin/env python3
"""Test /engine/go on PRODUCTION (skip SSL cert verify)."""

import ssl
import json
import time
import urllib.request

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

BACKEND = "https://track-vkrr.onrender.com"

TRIPS = [
    ("Penn Station → Times Square",
     {"label": "Penn Station", "lat": 40.7506, "lon": -73.9935, "stop_id": None, "address": "Penn Station"},
     {"label": "Times Square", "lat": 40.7580, "lon": -73.9855, "stop_id": None, "address": "Times Square"}),
    ("Grand Central → Brooklyn Bridge",
     {"label": "Grand Central", "lat": 40.7527, "lon": -73.9772, "stop_id": None, "address": "Grand Central"},
     {"label": "Brooklyn Bridge", "lat": 40.6983, "lon": -73.9903, "stop_id": None, "address": "Brooklyn Bridge"}),
    ("Flushing → Canal St",
     {"label": "Flushing Main St", "lat": 40.7596, "lon": -73.8300, "stop_id": None, "address": "Flushing"},
     {"label": "Canal St", "lat": 40.7191, "lon": -74.0000, "stop_id": None, "address": "Canal St"}),
    ("Astoria → Union Square",
     {"label": "Astoria-Ditmars", "lat": 40.7752, "lon": -73.9120, "stop_id": None, "address": "Astoria"},
     {"label": "Union Square", "lat": 40.7359, "lon": -73.9906, "stop_id": None, "address": "Union Square"}),
    ("Jackson Heights → Wall St",
     {"label": "Jackson Heights", "lat": 40.7466, "lon": -73.8913, "stop_id": None, "address": "Jackson Heights"},
     {"label": "Wall St", "lat": 40.7074, "lon": -74.0113, "stop_id": None, "address": "Wall St"}),
]


def test_go(name, origin, destination):
    now_ts = int(time.time())
    payload = {
        "origin": origin,
        "destination": destination,
        "user_id": None,
        "depart_at_ts": now_ts,
        "arrive_by_ts": None,
        "max_transfers": 2,
        "max_origin_walk_m": 800,
        "max_destination_walk_m": 800,
        "max_transfer_walk_m": 500,
        "search_window_minutes": 180,
        "num_itineraries": 4,
        "modes": ["subway", "bus"],
        "record_recent": False,
        "now_ts": now_ts,
        "priority": "fastest",
        "accessibility_priority": False,
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{BACKEND}/engine/go",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.time()
    try:
        resp = urllib.request.urlopen(req, timeout=30, context=ctx)
        body = json.loads(resp.read())
        elapsed = time.time() - t0
        pt = body.get("primary_trip")
        alts = body.get("alternatives", [])
        total = (1 if pt else 0) + len(alts)
        print(f"  HTTP {resp.status} in {elapsed:.1f}s | trips={total} | session={body.get('session_kind')}")
        if pt:
            chips = pt.get("route_chips", [])
            chip_str = " -> ".join(c.get("label", "?") for c in chips)
            print(f"  Primary: {pt.get('duration_label')} | {chip_str}")
            legs = pt.get("itinerary", {}).get("legs", [])
            for i, leg in enumerate(legs):
                live = leg.get("live_status")
                live_txt = f" [{live.get('status_text', '?')}]" if live else ""
                print(f"    Leg {i}: {leg.get('mode')}/{leg.get('route_name','walk')} "
                      f"{leg.get('board_stop_name')} -> {leg.get('alight_stop_name')}{live_txt}")
        for j, alt in enumerate(alts):
            chips = alt.get("route_chips", [])
            chip_str = " -> ".join(c.get("label", "?") for c in chips)
            print(f"  Alt {j+1}: {alt.get('duration_label')} | {chip_str}")
        if total == 0:
            print(f"  WARNING EMPTY! note={body.get('schedule_note')}")
        return total > 0
    except urllib.error.HTTPError as e:
        elapsed = time.time() - t0
        err = e.read().decode()[:300]
        print(f"  HTTP {e.code} in {elapsed:.1f}s: {err}")
        return False
    except Exception as e:
        elapsed = time.time() - t0
        print(f"  ERROR in {elapsed:.1f}s: {e}")
        return False


if __name__ == "__main__":
    print("=" * 70)
    print(f"Production /engine/go test ({BACKEND})")
    print("=" * 70)
    ok = 0
    for name, origin, dest in TRIPS:
        print(f"\n{name}")
        if test_go(name, origin, dest):
            ok += 1
    print(f"\n{'=' * 70}")
    print(f"{ok}/{len(TRIPS)} returned trips")
