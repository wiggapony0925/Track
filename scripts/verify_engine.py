#!/usr/bin/env python3
"""Full end-to-end verification of the College Point routing fix.

Tests diverse NYC origin→destination pairs to ensure the engine
never returns zero trips for any reachable location.
"""
import json
import urllib.request
import datetime
import calendar as cal

ENGINE_URL = "http://localhost:8090"


def test_route(name, origin, destination, date_tuple, time_hour=10):
    dt = datetime.date(*date_tuple)
    weekday = dt.weekday()
    midnight_ts = int(cal.timegm((dt.year, dt.month, dt.day, 4, 0, 0, 0, 0, 0)))
    query_ts = midnight_ts + time_hour * 3600

    payload = {
        "origin": origin,
        "destination": destination,
        "service_day_yyyymmdd": int(dt.strftime("%Y%m%d")),
        "service_weekday": weekday,
        "service_day_midnight_ts": midnight_ts,
        "query_ts": query_ts,
        "num_itineraries": 5,
        "max_transfers": 2,
        "modes": ["subway", "bus"],
    }

    req = urllib.request.Request(
        f"{ENGINE_URL}/go",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
        # /go returns primary_trip + alternatives (not "trips")
        trips = []
        if data.get("primary_trip"):
            trips.append(data["primary_trip"])
        trips.extend(data.get("alternatives", []))
        status = "PASS" if trips else "FAIL"
        print(f"  [{status}] {name} ({dt.strftime('%a')}) => {len(trips)} trips")
        for i, t in enumerate(trips[:3]):
            legs = t.get("legs", [])
            route_names = [l.get("route_name", "walk") for l in legs]
            dur = t.get("total_duration_s", 0)
            transfers = t.get("transfer_count", 0)
            # /go nests details differently — try route_chips for summary
            chips = t.get("route_chips", [])
            chip_names = [c.get("label", "") for c in chips if c.get("label")]
            summary = " -> ".join(chip_names) if chip_names else " -> ".join(route_names)
            duration_label = t.get("duration_label", f"{dur // 60} min")
            print(f"        {summary} ({duration_label})")
        return len(trips) > 0
    except Exception as e:
        print(f"  [FAIL] {name} => ERROR: {e}")
        return False


# ── Test cases: diverse NYC locations ──
TESTS = [
    # (name, origin, destination, date)
    ("College Point -> Times Square (Sun)",
     {"lat": 40.7847, "lon": -73.8459, "label": "College Point"},
     {"lat": 40.758, "lon": -73.9855, "label": "Times Square"},
     (2026, 4, 12)),
    ("College Point -> Times Square (Mon)",
     {"lat": 40.7847, "lon": -73.8459, "label": "College Point"},
     {"lat": 40.758, "lon": -73.9855, "label": "Times Square"},
     (2026, 4, 13)),
    ("Astoria -> Downtown Brooklyn",
     {"lat": 40.7722, "lon": -73.9175, "label": "Astoria"},
     {"lat": 40.6894, "lon": -73.9857, "label": "Downtown Brooklyn"},
     (2026, 4, 12)),
    ("South Bronx -> Midtown",
     {"lat": 40.8176, "lon": -73.9209, "label": "South Bronx"},
     {"lat": 40.7512, "lon": -73.9765, "label": "Midtown"},
     (2026, 4, 12)),
    ("Bay Ridge -> East Harlem",
     {"lat": 40.6348, "lon": -74.0284, "label": "Bay Ridge"},
     {"lat": 40.7946, "lon": -73.9425, "label": "East Harlem"},
     (2026, 4, 12)),
    ("Bushwick -> Financial District",
     {"lat": 40.6946, "lon": -73.9214, "label": "Bushwick"},
     {"lat": 40.7075, "lon": -74.0096, "label": "Financial District"},
     (2026, 4, 12)),
    ("Flushing -> Penn Station",
     {"lat": 40.7580, "lon": -73.8295, "label": "Flushing"},
     {"lat": 40.7506, "lon": -73.9935, "label": "Penn Station"},
     (2026, 4, 12)),
    ("Inwood -> Coney Island",
     {"lat": 40.8682, "lon": -73.9209, "label": "Inwood"},
     {"lat": 40.5749, "lon": -73.9816, "label": "Coney Island"},
     (2026, 4, 12)),
]

print("Engine End-to-End Verification")
print("=" * 60)
results = [test_route(*t) for t in TESTS]
passed = sum(results)
print(f"\n{'=' * 60}")
print(f"Results: {passed}/{len(results)} passed")
if passed == len(results):
    print("All tests passed!")
else:
    for i, (r, t) in enumerate(zip(results, TESTS)):
        if not r:
            print(f"  FAILED: {t[0]}")
