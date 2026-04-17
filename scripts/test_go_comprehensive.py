#!/usr/bin/env python3
"""Comprehensive /engine/go test suite — 10 diverse NYC trips on production."""

import ssl
import json
import time
import urllib.request

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

BACKEND = "https://track-vkrr.onrender.com"

TRIPS = [
    # Short subway
    ("Penn Station → Times Square", 
     {"label": "Penn Station", "lat": 40.7506, "lon": -73.9935},
     {"label": "Times Square", "lat": 40.758, "lon": -73.9855}),
    # Cross-borough subway
    ("Flushing → Canal St",
     {"label": "Flushing Main St", "lat": 40.7596, "lon": -73.83},
     {"label": "Canal St", "lat": 40.7191, "lon": -74.0}),
    # Queens to Manhattan
    ("Jackson Heights → Union Square",
     {"label": "Jackson Heights", "lat": 40.7466, "lon": -73.8913},
     {"label": "Union Square", "lat": 40.7359, "lon": -73.9906}),
    # Brooklyn to Manhattan
    ("Park Slope → Midtown",
     {"label": "Park Slope", "lat": 40.6710, "lon": -73.9777},
     {"label": "Rockefeller Center", "lat": 40.7587, "lon": -73.9787}),
    # Short hop
    ("14 St → 34 St",
     {"label": "14 St-Union Sq", "lat": 40.7359, "lon": -73.9906},
     {"label": "34 St-Herald Sq", "lat": 40.7490, "lon": -73.9878}),
    # Bronx to Manhattan  
    ("161 St → Columbus Circle",
     {"label": "161 St-Yankee Stadium", "lat": 40.8277, "lon": -73.9256},
     {"label": "Columbus Circle", "lat": 40.7681, "lon": -73.9819}),
    # Long cross-borough
    ("Coney Island → Grand Central",
     {"label": "Coney Island", "lat": 40.5770, "lon": -73.9812},
     {"label": "Grand Central", "lat": 40.7527, "lon": -73.9772}),
    # Bus-heavy area
    ("East Harlem → Chelsea",
     {"label": "East Harlem", "lat": 40.7940, "lon": -73.9425},
     {"label": "Chelsea", "lat": 40.7465, "lon": -73.9971}),
    # Upper West Side
    ("UWS → Financial District",
     {"label": "72 St", "lat": 40.7785, "lon": -73.9820},
     {"label": "Wall St", "lat": 40.7074, "lon": -74.0113}),
    # Astoria → Downtown Brooklyn
    ("Astoria → Downtown Brooklyn",
     {"label": "Astoria-Ditmars", "lat": 40.7752, "lon": -73.912},
     {"label": "Downtown Brooklyn", "lat": 40.6862, "lon": -73.9847}),
]


def test_trip(name, origin, dest):
    now_ts = int(time.time())
    payload = {
        "origin": {**origin, "stop_id": None, "address": origin["label"]},
        "destination": {**dest, "stop_id": None, "address": dest["label"]},
        "user_id": None,
        "depart_at_ts": None,
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
        resp = urllib.request.urlopen(req, timeout=25, context=ctx)
        body = json.loads(resp.read())
        elapsed = time.time() - t0
        pt = body.get("primary_trip")
        alts = body.get("alternatives", [])
        total = (1 if pt else 0) + len(alts)
        if total > 0 and pt:
            chips = " -> ".join(c["label"] for c in pt.get("route_chips", []))
            print(f"  OK  {elapsed:5.1f}s  {total} trips  {pt.get('duration_label'):>8s}  {chips}")
        elif total > 0:
            print(f"  OK  {elapsed:5.1f}s  {total} trips (no primary)")
        else:
            print(f"  EMPTY  {elapsed:5.1f}s  note={body.get('schedule_note')}")
        return total > 0, elapsed
    except urllib.error.HTTPError as e:
        elapsed = time.time() - t0
        print(f"  HTTP {e.code}  {elapsed:5.1f}s  {e.read().decode()[:150]}")
        return False, elapsed
    except Exception as e:
        elapsed = time.time() - t0
        print(f"  ERR  {elapsed:5.1f}s  {e}")
        return False, elapsed


if __name__ == "__main__":
    print("=" * 70)
    print(f"Production /engine/go — 10 trips ({BACKEND})")
    print("=" * 70)
    
    results = []
    for name, origin, dest in TRIPS:
        print(f"\n{name}:")
        ok, elapsed = test_trip(name, origin, dest)
        results.append((name, ok, elapsed))
    
    print(f"\n{'=' * 70}")
    ok_count = sum(1 for _, ok, _ in results if ok)
    fail_count = len(results) - ok_count
    avg_time = sum(e for _, _, e in results) / len(results)
    print(f"Results: {ok_count}/{len(results)} returned trips, {fail_count} empty/error")
    print(f"Average response time: {avg_time:.1f}s")
    
    if fail_count > 0:
        print("\nFailed trips:")
        for name, ok, elapsed in results:
            if not ok:
                print(f"  - {name} ({elapsed:.1f}s)")
    print("=" * 70)
