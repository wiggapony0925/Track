#!/usr/bin/env python3
"""Test the local rebuilt C++ engine for diversity fix verification."""
import requests, time, json
from datetime import datetime, timezone, timedelta

LOCAL = "http://localhost:8081"

now = int(time.time()) + 300
# Compute service day for NYC (ET = UTC-4)
ny_offset = timedelta(hours=-4)
ny_time = datetime.fromtimestamp(now, tz=timezone(ny_offset))
if ny_time.hour < 3:
    service_date = (ny_time - timedelta(days=1)).date()
else:
    service_date = ny_time.date()
yyyymmdd = int(service_date.strftime("%Y%m%d"))
weekday = service_date.weekday()
midnight = datetime(service_date.year, service_date.month, service_date.day,
                    0, 0, 0, tzinfo=timezone(ny_offset))
midnight_ts = int(midnight.timestamp())

print(f"service_day={yyyymmdd}, weekday={weekday}, midnight_ts={midnight_ts}")
print()

TRIPS = [
    ("Dumbo->UWS", 40.6994, -73.9874, 40.7870, -73.9754),
    ("Inwood->BkHts", 40.8681, -73.9209, 40.6940, -73.9940),
    ("WashHts->Bushwick", 40.8480, -73.9344, 40.6944, -73.9213),
    ("ParkSlope->Midtown", 40.6710, -73.9770, 40.7549, -73.9840),
    ("Astoria->Midtown", 40.7722, -73.9170, 40.7549, -73.9840),
]

for name, o_lat, o_lon, d_lat, d_lon in TRIPS:
    payload = {
        "origin": {"label": name.split("->")[0], "lat": o_lat, "lon": o_lon},
        "destination": {"label": name.split("->")[1], "lat": d_lat, "lon": d_lon},
        "depart_at_ts": now,
        "query_ts": now,
        "service_day_yyyymmdd": yyyymmdd,
        "service_weekday": weekday,
        "service_day_midnight_ts": midnight_ts,
        "num_itineraries": 5,
        "max_transfers": 3,
    }
    try:
        r = requests.post(f"{LOCAL}/go", json=payload, timeout=30)
        data = r.json()
    except Exception as e:
        print(f"{name}: ERROR {e}")
        continue

    primary = data.get("primary_trip")
    alts = data.get("alternatives", [])
    total = (1 if primary else 0) + len(alts)
    print(f"── {name} ({total} trips) ──")

    for label, trip in [("PRIMARY", primary)] + [(f"ALT-{i+1}", a) for i, a in enumerate(alts)]:
        if not trip:
            continue
        it = trip["itinerary"]
        legs = [l for l in it["legs"] if l["mode"] != "walk"]
        route_str = " -> ".join(l["route_name"] for l in legs) or "(walk)"
        dur = it["total_duration_s"] // 60
        xfers = it["transfer_count"]
        arrive = it["arrive_at_ts"]
        print(f"  {label}: {route_str}  dur={dur}m xfers={xfers} arrive_ts={arrive}")

    # Check for dominated alternatives
    if primary and alts:
        p_arrive = primary["itinerary"]["arrive_at_ts"]
        p_xfers = primary["itinerary"]["transfer_count"]
        for i, alt in enumerate(alts):
            a_arrive = alt["itinerary"]["arrive_at_ts"]
            a_xfers = alt["itinerary"]["transfer_count"]
            if a_arrive >= p_arrive and a_xfers > p_xfers:
                print(f"  ⚡ ALT-{i+1} STILL DOMINATED: arrives same/later with {a_xfers-p_xfers} more transfer(s)")
    print()
