#!/usr/bin/env python3
"""Test 7 train routing by using Hudson Yards as explicit origin stop."""
import json, sys, urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

ENGINE = "http://127.0.0.1:8090"
NY = ZoneInfo("America/New_York")

def call_go(origin, dest, query_dt, **kwargs):
    midnight = query_dt.replace(hour=0, minute=0, second=0, microsecond=0)
    payload = {
        "origin": origin,
        "destination": dest,
        "now_ts": int(query_dt.timestamp()),
        "query_ts": int(query_dt.timestamp()),
        "service_day_yyyymmdd": int(query_dt.strftime("%Y%m%d")),
        "service_weekday": query_dt.weekday(),
        "service_day_midnight_ts": int(midnight.timestamp()),
        "max_transfers": kwargs.get("max_transfers", 2),
        "max_origin_walk_m": kwargs.get("max_origin_walk_m", 1400),
        "max_destination_walk_m": kwargs.get("max_destination_walk_m", 1400),
        "max_transfer_walk_m": kwargs.get("max_transfer_walk_m", 800),
        "search_window_minutes": 120,
        "num_itineraries": 8,
        "modes": ["subway", "bus", "lirr", "mnr"],
    }
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{ENGINE}/go", data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=45) as resp:
        return json.loads(resp.read())

def print_trips(data, label=""):
    pt = data.get("primary_trip")
    alts = data.get("alternatives", [])
    all_trips = ([pt] if pt else []) + alts
    print(f"\n{label}")
    if not all_trips:
        print("  *** NO TRIPS ***")
        return
    for i, trip in enumerate(all_trips):
        itin = trip.get("itinerary", {})
        legs = itin.get("legs", [])
        dur = itin.get("total_duration_s", 0)
        chain = " → ".join(l.get("route_name", "Walk") for l in legs)
        modes = " → ".join(l["mode"] for l in legs)
        print(f"  [{i}] {dur//60}min: {chain}")
        print(f"      modes: {modes}")
        for l in legs:
            print(f"      {l['mode']:7s} {l.get('route_name',''):5s} {l['board_stop_name']} → {l['alight_stop_name']}")

# Check engine health
try:
    with urllib.request.urlopen(f"{ENGINE}/health", timeout=5) as r:
        h = json.loads(r.read())
        if not h.get("ready"):
            sys.exit("Engine not ready")
except Exception as e:
    sys.exit(f"Engine not reachable: {e}")

print(f"Engine v{h.get('version')} ready\n")

next_sat = datetime(2026, 4, 18, 11, 0, tzinfo=NY)
dest = {"label": "110-4 14th Rd", "lat": 40.7847, "lon": -73.8459}

# Test 1: Normal origin (Penn Station area)
origin1 = {"label": "450 W 33rd St", "lat": 40.7527, "lon": -73.9990}
print("=" * 70)
print("TEST 1: Normal origin (Penn Station area), max_transfers=2")
data1 = call_go(origin1, dest, next_sat, max_transfers=2)
print_trips(data1, "Results:")

# Test 2: Origin at Hudson Yards stop directly
origin2 = {"label": "34 St-Hudson Yards", "lat": 40.7559, "lon": -74.0019, "stop_id": "726N"}
print("\n" + "=" * 70)
print("TEST 2: Origin at Hudson Yards 7 train (stop_id=726N), max_transfers=1")
data2 = call_go(origin2, dest, next_sat, max_transfers=1)
print_trips(data2, "Results:")

# Test 3: Check if the engine sees the 7 train in the modes
# Use /plan endpoint to get more detail
print("\n" + "=" * 70)
print("TEST 3: Times Sq origin, max_transfers=1 (7→Q26 should be direct)")
origin3 = {"label": "Times Sq-42 St", "lat": 40.7553, "lon": -73.9877, "stop_id": "725N"}
data3 = call_go(origin3, dest, next_sat, max_transfers=1)
print_trips(data3, "Results:")
