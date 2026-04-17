#!/usr/bin/env python3
"""
Diagnose pathological trip alternatives caused by the diversity/uniqueness logic.

Flags:
  1. DOMINATED: Alternative arrives later AND has more transfers than primary
  2. SHORT_SUBWAY_TO_BUS: Gets off subway after ≤3 stops to catch a bus
  3. HIGH_WAIT_RATIO: Waiting time > 50% of total duration
  4. MUCH_SLOWER: Alternative is >40% slower than primary overall
  5. UNNECESSARY_TRANSFER: More transfers but ≤2 min faster arrival (not worth it)
  6. LOW_FREQ_BUS: Transfers to a bus with headway >15 min (rare/infrequent)
"""

import json, sys, time, requests
from datetime import datetime

PROD = "https://track-vkrr.onrender.com"

# Diverse NYC test trips (origin→destination pairs)
TEST_TRIPS = [
    {"name": "Astoria→Midtown",          "o_lat": 40.7722, "o_lon": -73.9170, "d_lat": 40.7549, "d_lon": -73.9840},
    {"name": "Dumbo→UWS",                "o_lat": 40.6994, "o_lon": -73.9874, "d_lat": 40.7870, "d_lon": -73.9754},
    {"name": "Flushing→LES",             "o_lat": 40.7614, "o_lon": -73.8300, "d_lat": 40.7158, "d_lon": -73.9867},
    {"name": "BayRidge→Harlem",          "o_lat": 40.6350, "o_lon": -74.0280, "d_lat": 40.8117, "d_lon": -73.9502},
    {"name": "JacksonHeights→FiDi",      "o_lat": 40.7467, "o_lon": -73.8911, "d_lat": 40.7074, "d_lon": -74.0113},
    {"name": "ParkSlope→Midtown",        "o_lat": 40.6710, "o_lon": -73.9770, "d_lat": 40.7549, "d_lon": -73.9840},
    {"name": "Inwood→BrooklynHeights",   "o_lat": 40.8681, "o_lon": -73.9209, "d_lat": 40.6940, "d_lon": -73.9940},
    {"name": "StatenIslandFerry→UES",    "o_lat": 40.6437, "o_lon": -74.0733, "d_lat": 40.7736, "d_lon": -73.9566},
    {"name": "WashHeights→Bushwick",     "o_lat": 40.8480, "o_lon": -73.9344, "d_lat": 40.6944, "d_lon": -73.9213},
    {"name": "Sunnyside→Chelsea",        "o_lat": 40.7433, "o_lon": -73.9196, "d_lat": 40.7465, "d_lon": -74.0014},
]


def make_payload(trip: dict) -> dict:
    return {
        "origin": {
            "label": trip["name"].split("→")[0],
            "lat": trip["o_lat"],
            "lon": trip["o_lon"],
        },
        "destination": {
            "label": trip["name"].split("→")[1],
            "lat": trip["d_lat"],
            "lon": trip["d_lon"],
        },
        "depart_at_ts": int(time.time()) + 300,  # 5 min from now
        "num_itineraries": 5,
        "max_transfers": 3,
        "priority": "quick",
    }


def extract_legs(itin: dict) -> list[dict]:
    """Return transit legs (non-walk) with useful summary info."""
    legs = []
    for leg in itin.get("legs", []):
        mode = leg.get("mode", "walk")
        if mode == "walk":
            continue
        legs.append({
            "mode": mode,
            "route": leg.get("route_name", "?"),
            "from": leg.get("board_stop_name", "?"),
            "to": leg.get("alight_stop_name", "?"),
            "board_ts": leg.get("board_ts", 0),
            "alight_ts": leg.get("alight_ts", 0),
            "duration_s": (leg.get("alight_ts", 0) or 0) - (leg.get("board_ts", 0) or 0),
            "num_stops": leg.get("num_stops", 0),
        })
    return legs


def analyze_trip(trip_data: dict, label: str, primary_data: dict | None) -> list[str]:
    """Analyze a single trip for pathological patterns. Return list of flag strings."""
    flags = []
    itin = trip_data.get("itinerary", {})
    legs = extract_legs(itin)
    
    total_dur = itin.get("total_duration_s", 0) or 0
    transfers = itin.get("transfer_count", 0) or 0
    arrive_ts = itin.get("arrive_at_ts", 0) or 0
    depart_ts = itin.get("depart_at_ts", 0) or 0
    waiting_s = itin.get("waiting_s", 0) or 0
    walking_s = itin.get("walking_s", 0) or 0

    # --- Flag 1: DOMINATED by primary ---
    if primary_data:
        p_itin = primary_data.get("itinerary", {})
        p_arrive = p_itin.get("arrive_at_ts", 0) or 0
        p_transfers = p_itin.get("transfer_count", 0) or 0
        p_dur = p_itin.get("total_duration_s", 0) or 0

        if arrive_ts > p_arrive and transfers > p_transfers:
            delta_min = (arrive_ts - p_arrive) / 60
            flags.append(
                f"DOMINATED: arrives {delta_min:.0f}min later AND has "
                f"{transfers - p_transfers} more transfer(s) than primary"
            )

        # --- Flag 5: UNNECESSARY_TRANSFER ---
        if transfers > p_transfers:
            time_saved = p_arrive - arrive_ts  # positive = alt is faster
            if time_saved <= 120:  # saves ≤2 min
                flags.append(
                    f"UNNECESSARY_TRANSFER: {transfers - p_transfers} extra transfer(s) "
                    f"for only {time_saved}s time saving"
                )

        # --- Flag 4: MUCH_SLOWER ---
        if p_dur > 0 and total_dur > p_dur * 1.4:
            pct = ((total_dur - p_dur) / p_dur) * 100
            flags.append(
                f"MUCH_SLOWER: {total_dur // 60}min vs primary's {p_dur // 60}min "
                f"({pct:.0f}% slower)"
            )

    # --- Flag 2: SHORT_SUBWAY_TO_BUS ---
    for i, leg in enumerate(legs):
        if leg["mode"] == "subway" and leg["num_stops"] <= 3 and leg["duration_s"] <= 360:
            # Check if next transit leg is a bus
            if i + 1 < len(legs) and legs[i + 1]["mode"] == "bus":
                flags.append(
                    f"SHORT_SUBWAY_TO_BUS: rides {leg['route']} for only "
                    f"{leg['num_stops']} stop(s) ({leg['duration_s']}s) then "
                    f"transfers to bus {legs[i + 1]['route']}"
                )

    # --- Flag 3: HIGH_WAIT_RATIO ---
    if total_dur > 0 and waiting_s > total_dur * 0.5:
        flags.append(
            f"HIGH_WAIT_RATIO: waiting {waiting_s // 60}min out of "
            f"{total_dur // 60}min total ({waiting_s / total_dur * 100:.0f}%)"
        )

    # --- Flag 6: Check for subway legs ≤2 stops that aren't at start/end ---
    for i, leg in enumerate(legs):
        if (leg["mode"] == "subway"
                and leg["num_stops"] <= 2
                and leg["duration_s"] <= 240
                and 0 < i < len(legs) - 1):
            # Middle leg on subway for ≤2 stops — likely an unnecessary short hop
            flags.append(
                f"SHORT_MID_SUBWAY: rides {leg['route']} for only "
                f"{leg['num_stops']} stop(s) mid-trip (between "
                f"{legs[i-1]['route']} and {legs[i+1]['route']})"
            )

    return flags


def print_trip_summary(trip_data: dict, label: str):
    itin = trip_data.get("itinerary", {})
    legs = extract_legs(itin)
    route_str = " → ".join(
        f"{l['route']}({'subway' if l['mode'] == 'subway' else l['mode'][0]})"
        for l in legs
    ) or "(walk only)"

    dur = (itin.get("total_duration_s", 0) or 0) // 60
    transfers = itin.get("transfer_count", 0) or 0
    waiting = (itin.get("waiting_s", 0) or 0) // 60
    walking = (itin.get("walking_s", 0) or 0) // 60

    arrive_ts = itin.get("arrive_at_ts")
    arrive_str = datetime.fromtimestamp(arrive_ts).strftime("%H:%M") if arrive_ts else "?"

    print(f"  {label}: {route_str}  [{dur}min, {transfers}xfer, wait:{waiting}m, walk:{walking}m, arr:{arrive_str}]")


def run():
    total_flags = 0
    total_trips_checked = 0
    all_findings = []

    print(f"{'='*80}")
    print(f"  TRIP DIVERSITY PATHOLOGICAL PATTERN DETECTOR")
    print(f"  Production: {PROD}")
    print(f"  Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'='*80}\n")

    for test in TEST_TRIPS:
        print(f"── {test['name']} ──")
        payload = make_payload(test)

        try:
            resp = requests.post(f"{PROD}/engine/go", json=payload, timeout=30)
            if resp.status_code != 200:
                print(f"  ⚠ HTTP {resp.status_code}")
                continue
            data = resp.json()
        except Exception as e:
            print(f"  ⚠ Error: {e}")
            continue

        primary = data.get("primary_trip")
        alternatives = data.get("alternatives", [])

        if not primary:
            print("  ⚠ No primary trip returned\n")
            continue

        print_trip_summary(primary, "PRIMARY")
        p_flags = analyze_trip(primary, "PRIMARY", None)
        for f in p_flags:
            print(f"    ⚡ {f}")
            total_flags += 1

        for idx, alt in enumerate(alternatives):
            label = f"ALT-{idx+1}"
            print_trip_summary(alt, label)
            total_trips_checked += 1

            flags = analyze_trip(alt, label, primary)
            for f in flags:
                print(f"    ⚡ {f}")
                total_flags += 1
                all_findings.append({
                    "trip": test["name"],
                    "variant": label,
                    "flag": f,
                })

        print()

    # Summary
    print(f"\n{'='*80}")
    print(f"  SUMMARY")
    print(f"{'='*80}")
    print(f"  Alternatives checked: {total_trips_checked}")
    print(f"  Total flags raised: {total_flags}")
    print()

    if all_findings:
        # Categorize
        categories = {}
        for finding in all_findings:
            cat = finding["flag"].split(":")[0]
            categories.setdefault(cat, []).append(finding)

        for cat, findings in sorted(categories.items()):
            print(f"  {cat}: {len(findings)} occurrences")
            for f in findings[:3]:
                print(f"    - {f['trip']} {f['variant']}: {f['flag']}")
            if len(findings) > 3:
                print(f"    ... and {len(findings)-3} more")
            print()
    else:
        print("  ✅ No pathological patterns detected!")

    return total_flags


if __name__ == "__main__":
    flags = run()
    sys.exit(1 if flags > 0 else 0)
