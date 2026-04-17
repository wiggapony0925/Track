#!/usr/bin/env python3
"""Validate /engine/go response against iOS EngineGoResponseDTO required fields."""

import ssl
import json
import time
import urllib.request

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

now_ts = int(time.time())
payload = {
    "origin": {"label": "Penn Station", "lat": 40.7506, "lon": -73.9935, "stop_id": None, "address": "Penn Station"},
    "destination": {"label": "Times Square", "lat": 40.758, "lon": -73.9855, "stop_id": None, "address": "Times Square"},
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
    "https://track-vkrr.onrender.com/engine/go",
    data=data,
    headers={"Content-Type": "application/json"},
    method="POST",
)
resp = urllib.request.urlopen(req, timeout=20, context=ctx)
body = json.loads(resp.read())


def check_fields(obj, required_fields, name="object"):
    """Check that all required fields exist and have correct types."""
    errors = []
    for field, expected_type, nullable in required_fields:
        if field not in obj:
            errors.append(f"  MISSING: {name}.{field}")
        elif obj[field] is None and not nullable:
            errors.append(f"  NULL (not nullable): {name}.{field}")
        elif obj[field] is not None and not isinstance(obj[field], expected_type):
            errors.append(f"  WRONG TYPE: {name}.{field} = {type(obj[field]).__name__} (expected {expected_type.__name__})")
    return errors


print("=" * 60)
print("Validating /engine/go response against iOS Codable models")
print("=" * 60)

all_errors = []

# EngineGoResponseDTO required fields
response_fields = [
    ("engine_version", str, False),
    ("requested_at_ts", int, False),
    ("now_ts", int, False),
    ("session_kind", str, False),
    ("primary_trip", dict, True),  # nullable
    ("alternatives", list, False),
    ("schedule_note", str, True),  # nullable
]
errs = check_fields(body, response_fields, "EngineGoResponseDTO")
if errs:
    all_errors.extend(errs)
    print("EngineGoResponseDTO:")
    for e in errs:
        print(e)
else:
    print("EngineGoResponseDTO: OK")

# EngineGoTripDTO required fields
trip_fields = [
    ("itinerary", dict, False),
    ("route_chips", list, False),
    # transfers is Optional in iOS
    ("next_action", dict, True),  # nullable
    ("status", str, False),
    ("leave_in_s", int, False),
    ("arrive_in_s", int, False),
    ("reliability_score", int, False),
    ("ranking_score", (int, float), False),
    ("disruption_level", str, False),
    # confidence is Optional in iOS
    ("service_alerts", list, False),
]

for label, trip in [("primary_trip", body.get("primary_trip"))] + \
                    [(f"alt[{i}]", a) for i, a in enumerate(body.get("alternatives", []))]:
    if trip is None:
        continue
    print(f"\n{label}:")
    errs = []
    for field, expected_type, nullable in trip_fields:
        if field not in trip:
            errs.append(f"  MISSING: {label}.{field}")
        elif trip[field] is None and not nullable:
            errs.append(f"  NULL: {label}.{field}")
        elif trip[field] is not None:
            if isinstance(expected_type, tuple):
                if not isinstance(trip[field], expected_type):
                    errs.append(f"  WRONG TYPE: {label}.{field} = {type(trip[field]).__name__}")
            elif not isinstance(trip[field], expected_type):
                errs.append(f"  WRONG TYPE: {label}.{field} = {type(trip[field]).__name__}")
    if errs:
        all_errors.extend(errs)
        for e in errs:
            print(e)
    else:
        print("  All required fields present and typed correctly")

    # Validate EngineItineraryDTO
    itin = trip.get("itinerary", {})
    itin_fields = [
        ("itinerary_id", str, False),
        ("leave_at_ts", int, False),
        ("arrive_at_ts", int, False),
        ("total_duration_s", int, False),
        ("transfer_count", int, False),
        ("walk_meters", (int, float), False),
        # accessible is Optional
        ("legs", list, False),
        # fare is Optional
        # environmental_impact is Optional
    ]
    errs = check_fields(itin, itin_fields, f"{label}.itinerary")
    if errs:
        all_errors.extend(errs)
        for e in errs:
            print(e)
    else:
        print(f"  itinerary: OK ({len(itin.get('legs', []))} legs)")

    # Validate EngineTripLegDTO for each leg
    for li, leg in enumerate(itin.get("legs", [])):
        leg_fields = [
            ("mode", str, False),
            ("route_id", str, False),
            ("route_name", str, False),
            # color_hex, text_color_hex, mode_name, headsign optional
            ("board_stop_id", str, False),
            ("board_stop_name", str, False),
            ("alight_stop_id", str, False),
            ("alight_stop_name", str, False),
            ("departure_ts", int, False),
            ("arrival_ts", int, False),
            ("stop_count", int, False),
            ("walk_meters", (int, float), False),
            # bus_service_type, ada_accessible, crowding, live_status optional
            ("alerts", list, False),
        ]
        errs = check_fields(leg, leg_fields, f"{label}.leg[{li}]")
        if errs:
            all_errors.extend(errs)
            for e in errs:
                print(e)

    # Validate route chips
    for ci, chip in enumerate(trip.get("route_chips", [])):
        chip_fields = [
            ("kind", str, False),
            ("label", str, False),
        ]
        errs = check_fields(chip, chip_fields, f"{label}.chip[{ci}]")
        if errs:
            all_errors.extend(errs)
            for e in errs:
                print(e)

print("\n" + "=" * 60)
if all_errors:
    print(f"VALIDATION FAILURES: {len(all_errors)} issues found!")
    print("These would cause iOS Codable decoding to FAIL silently.")
else:
    print("ALL FIELDS VALID - iOS Codable decoding should succeed.")
print("=" * 60)
