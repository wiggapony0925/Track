#!/usr/bin/env python3
"""Test the C++ engine directly with real NYC trips."""

import json
import sys
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

ENGINE_URL = "http://127.0.0.1:8081"
NY = ZoneInfo("America/New_York")


def main():
    now = datetime.now(NY)
    now_ts = int(now.timestamp())
    midnight = int(now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp())
    yyyymmdd = int(now.strftime("%Y%m%d"))
    weekday = now.weekday()

    print(f"Time: {now.strftime('%H:%M %Z')}, ts={now_ts}, date={yyyymmdd}, weekday={weekday}")
    print()

    trips = [
        ("Penn Station -> Times Square",     40.7506, -73.9935, 40.7580, -73.9855, ["subway"]),
        ("Grand Central -> Brooklyn Bridge", 40.7527, -73.9772, 40.6983, -73.9903, ["subway", "bus"]),
        ("Jamaica Stn -> Barclays Center",   40.7003, -73.8020, 40.6826, -73.9754, ["subway", "bus"]),
        ("Flushing Main St -> Canal St",     40.7596, -73.8300, 40.7191, -73.9999, ["subway"]),
        ("East Harlem -> Wall St",           40.7957, -73.9390, 40.7074, -74.0113, ["subway", "bus"]),
    ]

    total_ok = 0
    total_empty = 0

    for label, olat, olon, dlat, dlon, modes in trips:
        payload = {
            "origin": {"label": "Origin", "lat": olat, "lon": olon},
            "destination": {"label": "Dest", "lat": dlat, "lon": dlon},
            "depart_at_ts": now_ts,
            "query_ts": now_ts,
            "service_day_yyyymmdd": yyyymmdd,
            "service_weekday": weekday,
            "service_day_midnight_ts": midnight,
            "max_transfers": 2,
            "max_origin_walk_m": 800,
            "max_destination_walk_m": 800,
            "max_transfer_walk_m": 500,
            "search_window_minutes": 30,
            "num_itineraries": 3,
            "modes": modes,
        }
        req = urllib.request.Request(
            f"{ENGINE_URL}/plan",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode())
                itins = data.get("itineraries", [])
                status = "OK" if itins else "EMPTY"
                if itins:
                    total_ok += 1
                else:
                    total_empty += 1
                print(f"[{status}] {label} ({'+'.join(modes)}): {len(itins)} itineraries")
                for i, it in enumerate(itins):
                    legs = it.get("legs", [])
                    route_summary = " -> ".join(
                        leg.get("route_short_name") or leg.get("route_id", "walk")
                        for leg in legs
                    )
                    dur = it["total_duration_s"]
                    xfers = it["transfer_count"]
                    print(f"  #{i+1}: {dur//60}m{dur%60}s, {xfers} xfer: {route_summary}")
        except Exception as e:
            total_empty += 1
            print(f"[ERROR] {label}: {e}")
        print()

    print(f"Summary: {total_ok} OK, {total_empty} empty/error out of {len(trips)} trips")

    # Now test through the backend if it's running
    print("\n--- Testing through Python backend (port 8000) ---\n")
    for label, olat, olon, dlat, dlon, modes in trips[:2]:
        payload = {
            "origin": {"label": "Origin", "lat": olat, "lon": olon},
            "destination": {"label": "Dest", "lat": dlat, "lon": dlon},
            "depart_at_ts": now_ts,
            "max_transfers": 2,
            "max_origin_walk_m": 800,
            "max_destination_walk_m": 800,
            "max_transfer_walk_m": 500,
            "search_window_minutes": 30,
            "num_itineraries": 3,
            "modes": modes,
        }
        req = urllib.request.Request(
            "http://127.0.0.1:8000/engine/plan",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode())
                itins = data.get("itineraries", [])
                print(f"[{'OK' if itins else 'EMPTY'}] {label}: {len(itins)} itineraries")
                if not itins:
                    print(f"  Full response keys: {list(data.keys())}")
                    print(f"  schedule_note: {data.get('schedule_note')}")
        except urllib.error.HTTPError as e:
            body = e.read().decode()
            print(f"[HTTP {e.code}] {label}: {body[:300]}")
        except Exception as e:
            print(f"[CONN ERROR] {label}: {e} (backend probably not running)")
            break
        print()


if __name__ == "__main__":
    main()
