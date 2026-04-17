#!/usr/bin/env python3
"""Dump raw /engine/go response for diagnostic."""

import json
import time
import urllib.request

BACKEND = "http://127.0.0.1:8000"

now_ts = int(time.time())
payload = {
    "origin": {"label": "Penn Station", "lat": 40.7506, "lon": -73.9935, "stop_id": None, "address": "Penn Station, Manhattan"},
    "destination": {"label": "Times Square", "lat": 40.7580, "lon": -73.9855, "stop_id": None, "address": "Times Square, Manhattan"},
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

print(f"Sending request at ts={now_ts}...")
t0 = time.time()
try:
    with urllib.request.urlopen(req, timeout=45) as resp:
        body = json.loads(resp.read())
        elapsed = time.time() - t0
        print(f"HTTP {resp.status} in {elapsed:.1f}s\n")

        # Print primary trip details
        pt = body.get("primary_trip")
        if pt:
            print("=== PRIMARY TRIP ===")
            itin = pt.get("itinerary", {})
            print(f"  duration_minutes: {itin.get('duration_minutes')}")
            print(f"  total_walk_minutes: {itin.get('total_walk_minutes')}")
            print(f"  transfers: {itin.get('transfers')}")
            print(f"  route_chips: {json.dumps(pt.get('route_chips', []), indent=4)}")
            print(f"  status: {pt.get('status')}")
            print(f"  leave_label: {pt.get('leave_label')}")
            print(f"  arrive_label: {pt.get('arrive_label')}")
            print(f"  duration_label: {pt.get('duration_label')}")
            print(f"\n  Legs ({len(itin.get('legs', []))}):")
            for i, leg in enumerate(itin.get("legs", [])):
                print(f"    Leg {i}: mode={leg.get('mode')}, route={leg.get('route_short_name')}, "
                      f"from={leg.get('from_name')} → to={leg.get('to_name')}, "
                      f"duration={leg.get('duration_minutes')}m, "
                      f"color={leg.get('color_hex')}, headsign={leg.get('headsign')}")
        else:
            print("=== PRIMARY TRIP: null ===")

        alts = body.get("alternatives", [])
        print(f"\n=== ALTERNATIVES: {len(alts)} ===")
        for j, alt in enumerate(alts):
            itin = alt.get("itinerary", {})
            print(f"\n  Alt {j+1}: duration={itin.get('duration_minutes')}m, status={alt.get('status')}")
            for i, leg in enumerate(itin.get("legs", [])):
                print(f"    Leg {i}: mode={leg.get('mode')}, route={leg.get('route_short_name')}, "
                      f"from={leg.get('from_name')} → to={leg.get('to_name')}, "
                      f"duration={leg.get('duration_minutes')}m")

        print(f"\nschedule_note: {body.get('schedule_note')}")
        print(f"session_kind: {body.get('session_kind')}")

        # Also dump the raw JSON for one trip
        if pt:
            print("\n=== RAW PRIMARY TRIP JSON (first 3000 chars) ===")
            raw = json.dumps(pt, indent=2)
            print(raw[:3000])
except urllib.error.HTTPError as e:
    print(f"HTTP ERROR {e.code}: {e.read().decode()[:1000]}")
except Exception as e:
    print(f"ERROR: {e}")
