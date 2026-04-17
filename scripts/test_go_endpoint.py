#!/usr/bin/env python3
"""Test the /engine/go endpoint with realistic iOS-like payloads."""

import json
import time
import urllib.request

BACKEND = "http://127.0.0.1:8000"

TRIPS = [
    {
        "name": "Penn Station → Times Square (subway)",
        "origin": {"label": "Penn Station", "lat": 40.7506, "lon": -73.9935, "stop_id": None, "address": "Penn Station, Manhattan"},
        "destination": {"label": "Times Square", "lat": 40.7580, "lon": -73.9855, "stop_id": None, "address": "Times Square, Manhattan"},
    },
    {
        "name": "Grand Central → Brooklyn Bridge (subway+bus)",
        "origin": {"label": "Grand Central", "lat": 40.7527, "lon": -73.9772, "stop_id": None, "address": "Grand Central, Manhattan"},
        "destination": {"label": "Brooklyn Bridge", "lat": 40.6983, "lon": -73.9903, "stop_id": None, "address": "Brooklyn Bridge, Brooklyn"},
    },
    {
        "name": "Flushing Main St → Canal St (subway)",
        "origin": {"label": "Flushing Main St", "lat": 40.7596, "lon": -73.8300, "stop_id": None, "address": "Flushing, Queens"},
        "destination": {"label": "Canal St", "lat": 40.7191, "lon": -74.0000, "stop_id": None, "address": "Canal St, Manhattan"},
    },
    {
        "name": "Jackson Heights → Wall St (subway)",
        "origin": {"label": "Jackson Heights", "lat": 40.7466, "lon": -73.8913, "stop_id": None, "address": "Jackson Heights, Queens"},
        "destination": {"label": "Wall St", "lat": 40.7074, "lon": -74.0113, "stop_id": None, "address": "Wall St, Manhattan"},
    },
    {
        "name": "Astoria → Union Square (subway)",
        "origin": {"label": "Astoria-Ditmars Blvd", "lat": 40.7752, "lon": -73.9120, "stop_id": None, "address": "Astoria, Queens"},
        "destination": {"label": "Union Square", "lat": 40.7359, "lon": -73.9906, "stop_id": None, "address": "Union Square, Manhattan"},
    },
]


def test_go(trip: dict) -> dict:
    now_ts = int(time.time())
    payload = {
        "origin": trip["origin"],
        "destination": trip["destination"],
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
    try:
        with urllib.request.urlopen(req, timeout=45) as resp:
            body = json.loads(resp.read())
            return {"status": resp.status, "body": body}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        return {"status": e.code, "error": err_body}
    except Exception as e:
        return {"status": 0, "error": str(e)}


def summarize(result: dict):
    if result["status"] != 200:
        print(f"  ❌ HTTP {result['status']}: {result.get('error', '')[:200]}")
        return

    body = result["body"]
    pt = body.get("primary_trip")
    alts = body.get("alternatives", [])
    session = body.get("session_kind", "?")
    note = body.get("schedule_note")

    primary_count = 1 if pt else 0
    total = primary_count + len(alts)

    print(f"  session_kind={session}, total_trips={total} (primary={'yes' if pt else 'null'}, alts={len(alts)})")

    if note:
        print(f"  schedule_note: {note}")

    if pt:
        itin = pt.get("itinerary", {})
        legs = itin.get("legs", [])
        dur = itin.get("duration_minutes", "?")
        leg_desc = " → ".join(
            f"{l.get('route_short_name', 'Walk')}" for l in legs
        )
        print(f"  Primary: {dur}m | {leg_desc} | status={pt.get('status')} | confidence={pt.get('confidence')}")

    for i, alt in enumerate(alts):
        itin = alt.get("itinerary", {})
        legs = itin.get("legs", [])
        dur = itin.get("duration_minutes", "?")
        leg_desc = " → ".join(
            f"{l.get('route_short_name', 'Walk')}" for l in legs
        )
        print(f"  Alt {i+1}: {dur}m | {leg_desc} | status={alt.get('status')} | confidence={alt.get('confidence')}")

    if total == 0:
        print("  ⚠️  NO TRIPS RETURNED — this is what the frontend would see as empty!")


if __name__ == "__main__":
    print("=" * 70)
    print("Testing /engine/go endpoint (iOS-like payloads)")
    print("=" * 70)

    passed = 0
    failed = 0
    empty = 0

    for trip in TRIPS:
        print(f"\n🔍 {trip['name']}")
        t0 = time.time()
        result = test_go(trip)
        elapsed = time.time() - t0
        print(f"  Response time: {elapsed:.1f}s")
        summarize(result)
        if result["status"] == 200:
            body = result["body"]
            total = (1 if body.get("primary_trip") else 0) + len(body.get("alternatives", []))
            if total > 0:
                passed += 1
            else:
                empty += 1
        else:
            failed += 1

    print(f"\n{'=' * 70}")
    print(f"Results: {passed} with trips, {empty} empty, {failed} errors (out of {len(TRIPS)})")
    print("=" * 70)
