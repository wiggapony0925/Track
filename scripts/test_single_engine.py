#!/usr/bin/env python3
"""Single request test to verify the engine returns trips."""
import httpx, time, json
from datetime import datetime, timezone, timedelta, time as tv

now_ts = int(time.time())
NY = timezone(timedelta(hours=-4))
now_ny = datetime.fromtimestamp(now_ts, tz=NY)
sd = now_ny.date()
mid = datetime.combine(sd, tv.min, tzinfo=NY)

payload = {
    "origin": {"label": "Penn Station", "lat": 40.7505, "lon": -73.9934},
    "destination": {"label": "Grand Central", "lat": 40.7527, "lon": -73.9772},
    "depart_at_ts": now_ts,
    "query_ts": now_ts,
    "service_day_yyyymmdd": int(sd.strftime("%Y%m%d")),
    "service_weekday": sd.weekday(),
    "service_day_midnight_ts": int(mid.timestamp()),
    "max_transfers": 2,
    "max_origin_walk_m": 1200,
    "max_destination_walk_m": 1200,
    "max_transfer_walk_m": 800,
    "search_window_minutes": 180,
    "num_itineraries": 4,
    "modes": ["subway", "bus"],
    "now_ts": now_ts,
}

print("Payload:")
print(json.dumps(payload, indent=2))
print()

# --- Direct engine test ---
print("=== Direct Engine (port 8081) ===")
start = time.monotonic()
try:
    resp = httpx.post("http://localhost:8081/go", json=payload, timeout=30)
    ms = (time.monotonic() - start) * 1000
    data = resp.json()
    primary = data.get("primary_trip")
    alts = data.get("alternatives", [])
    print(f"HTTP {resp.status_code}, {ms:.0f}ms")
    print(f"  primary: {'YES' if primary else 'NO'}")
    print(f"  alternatives: {len(alts)}")
    if primary:
        it = primary["itinerary"]
        print(f"  duration: {it['total_duration_s']}s, transfers: {it['transfer_count']}")
    else:
        # Show any debug info in the response
        for k, v in data.items():
            if k not in ("primary_trip", "alternatives"):
                print(f"  {k}: {v}")
except Exception as e:
    print(f"ERROR: {e}")

print()

# --- Backend test ---
print("=== Backend (port 8000) ===")
start = time.monotonic()
try:
    resp = httpx.post("http://localhost:8000/engine/go", json=payload, timeout=30)
    ms = (time.monotonic() - start) * 1000
    data = resp.json()
    trips = data.get("trips", [])
    print(f"HTTP {resp.status_code}, {ms:.0f}ms")
    print(f"  trips: {len(trips)}")
    if trips:
        for i, t in enumerate(trips[:3]):
            legs = t.get("legs", [])
            print(f"  trip {i}: {len(legs)} legs, {t.get('total_duration_s', '?')}s")
    else:
        note = data.get("schedule_note") or data.get("error") or data.get("detail")
        if note:
            print(f"  note: {note}")
except Exception as e:
    print(f"ERROR: {e}")
