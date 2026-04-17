#!/usr/bin/env python3
"""Test /engine/go exactly as iOS sends it for Leave Now."""

import ssl
import json
import time
import urllib.request

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

BACKENDS = {
    "local": "http://127.0.0.1:8000",
    "production": "https://track-vkrr.onrender.com",
}

# Exact iOS "Leave Now" payload: depart_at_ts=null, arrive_by_ts=null
now_ts = int(time.time())
PAYLOAD = {
    "origin": {"label": "Penn Station", "lat": 40.7506, "lon": -73.9935, "stop_id": None, "address": "Penn Station, Manhattan"},
    "destination": {"label": "Times Square", "lat": 40.758, "lon": -73.9855, "stop_id": None, "address": "Times Square, Manhattan"},
    "user_id": None,
    "depart_at_ts": None,  # <- Leave Now sends null!
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


def test(backend_name, backend_url, payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{backend_url}/engine/go",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.time()
    try:
        kw = {"timeout": 20}
        if backend_url.startswith("https"):
            kw["context"] = ctx
        resp = urllib.request.urlopen(req, **kw)
        body = json.loads(resp.read())
        elapsed = time.time() - t0
        pt = body.get("primary_trip")
        alts = body.get("alternatives", [])
        total = (1 if pt else 0) + len(alts)
        print(f"  [{backend_name}] HTTP {resp.status} in {elapsed:.1f}s | trips={total} session={body.get('session_kind')}")
        if pt:
            chips = " -> ".join(c["label"] for c in pt.get("route_chips", []))
            print(f"    Primary: {pt.get('duration_label')} | {chips}")
        for i, a in enumerate(alts):
            chips = " -> ".join(c["label"] for c in a.get("route_chips", []))
            print(f"    Alt {i+1}: {a.get('duration_label')} | {chips}")
        if total == 0:
            print(f"    *** EMPTY *** note={body.get('schedule_note')}")
    except urllib.error.HTTPError as e:
        elapsed = time.time() - t0
        print(f"  [{backend_name}] HTTP {e.code} in {elapsed:.1f}s: {e.read().decode()[:300]}")
    except Exception as e:
        elapsed = time.time() - t0
        print(f"  [{backend_name}] ERROR in {elapsed:.1f}s: {e}")


print("=" * 60)
print("Testing iOS 'Leave Now' scenario (depart_at_ts=null)")
print(f"now_ts={now_ts}")
print("=" * 60)

# Test 1: Leave Now with depart_at_ts=null
print("\n1. Leave Now (depart_at_ts=null):")
for name, url in BACKENDS.items():
    test(name, url, PAYLOAD)

# Test 2: Leave Now with depart_at_ts=now_ts (how we tested before)
print("\n2. Leave Now with explicit depart_at_ts=now_ts:")
payload2 = {**PAYLOAD, "depart_at_ts": now_ts}
for name, url in BACKENDS.items():
    test(name, url, payload2)

# Test 3: Different trip - Flushing → Canal St
print("\n3. Flushing → Canal St (depart_at_ts=null):")
payload3 = {
    **PAYLOAD,
    "origin": {"label": "Flushing Main St", "lat": 40.7596, "lon": -73.83, "stop_id": None, "address": "Flushing"},
    "destination": {"label": "Canal St", "lat": 40.7191, "lon": -74.0, "stop_id": None, "address": "Canal St"},
}
for name, url in BACKENDS.items():
    test(name, url, payload3)

# Test 4: With stop_id (subway station)
print("\n4. With stop_id (34 St-Penn → Times Sq-42 St):")
payload4 = {
    **PAYLOAD,
    "origin": {"label": "34 St-Penn Station", "lat": 40.7506, "lon": -73.9935, "stop_id": "A28", "address": "34 St-Penn Station"},
    "destination": {"label": "Times Sq-42 St", "lat": 40.7559, "lon": -73.9869, "stop_id": "R16", "address": "Times Sq-42 St"},
}
for name, url in BACKENDS.items():
    test(name, url, payload4)
