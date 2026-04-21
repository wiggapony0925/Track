#!/usr/bin/env python3
"""
Test that backend-enriched route_ids (the authoritative transfer source iOS now
uses) are correct for key subway routes.

Checks:
  - True positives: well-known transfer stations have the right routes
  - True negatives: stops with no real transfer don't get false ones
  - The 111 St regression: 7-train 111 St must NOT show A or J
"""
import json, subprocess, sys
from math import radians, cos, sin, sqrt, atan2

BASE = "https://track-vkrr.onrender.com"

PASS = "✅"
FAIL = "❌"

def fetch(path: str) -> dict:
    r = subprocess.run(["curl", "-sf", f"{BASE}{path}"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        print(f"  ERROR fetching {path}: {r.stderr.strip()}")
        sys.exit(1)
    return json.loads(r.stdout)


def get_stops_by_name(stops: list[dict]) -> dict[str, list[dict]]:
    index: dict[str, list[dict]] = {}
    for s in stops:
        index.setdefault(s["name"], []).append(s)
    return index


def check(label: str, actual: set[str], must_include: set[str], must_exclude: set[str]) -> bool:
    ok = True
    missing = must_include - actual
    wrong   = must_exclude & actual
    if missing:
        print(f"  {FAIL} {label}: MISSING {sorted(missing)}  (got {sorted(actual)})")
        ok = False
    if wrong:
        print(f"  {FAIL} {label}: WRONG (false positives) {sorted(wrong)}  (got {sorted(actual)})")
        ok = False
    if ok:
        print(f"  {PASS} {label}: {sorted(actual) or '(none)'}")
    return ok


def test_route(route_id: str, cases: list[dict]) -> int:
    """
    cases: list of dicts with keys:
      stop_name     – stop name to look up
      must_include  – set of route IDs that MUST appear in route_ids
      must_exclude  – set of route IDs that must NOT appear
    Returns number of failures.
    """
    print(f"\n{'='*60}")
    print(f"Route {route_id}")
    print(f"{'='*60}")
    data = fetch(f"/subway/shape/{route_id}")
    all_stops: list[dict] = []
    for d in data.get("directions", []):
        all_stops.extend(d.get("stops", []))
    if not all_stops:
        all_stops = data.get("stops", [])

    by_name = get_stops_by_name(all_stops)
    failures = 0

    for case in cases:
        name = case["stop_name"]
        must_include = {r.upper() for r in case.get("must_include", [])}
        must_exclude = {r.upper() for r in case.get("must_exclude", [])}

        if name not in by_name:
            print(f"  {FAIL} '{name}': stop not found in shape response")
            failures += 1
            continue

        # If the stop appears in multiple directions, union the route_ids
        actual: set[str] = set()
        for s in by_name[name]:
            for rid in (s.get("route_ids") or []):
                actual.add(rid.upper())

        ok = check(name, actual, must_include, must_exclude)
        if not ok:
            failures += 1

    return failures


# ── Test cases ────────────────────────────────────────────────────────────────

CASES: list[tuple[str, list[dict]]] = [
    ("7", [
        # Key transfer hubs
        {
            "stop_name": "Times Sq-42 St",
            "must_include": ["1", "2", "3", "N", "Q", "R", "W"],
            "must_exclude": [],
        },
        {
            "stop_name": "Grand Central-42 St",
            "must_include": ["4", "5", "6"],
            "must_exclude": [],
        },
        {
            "stop_name": "74 St-Broadway",
            "must_include": ["E", "F", "M", "R"],
            "must_exclude": [],
        },
        {
            "stop_name": "Queensboro Plaza",
            "must_include": ["N", "W"],
            "must_exclude": [],
        },
        # THE REGRESSION: 7-train 111 St is in Corona, Queens.
        # A-train 111 St is in Ozone Park (~8 km away).
        # J-train 111 St is in Jamaica (~7 km away).
        {
            "stop_name": "111 St",
            "must_include": [],
            "must_exclude": ["A", "J"],
        },
        # Terminals — should have no transfers
        {
            "stop_name": "Flushing-Main St",
            "must_include": [],
            "must_exclude": ["A", "J", "N", "Q", "E", "F"],
        },
        {
            "stop_name": "34 St-Hudson Yards",
            "must_include": [],
            "must_exclude": ["A", "J", "N", "Q"],
        },
    ]),
    ("A", [
        # A's 111 St (Ozone Park) must NOT bleed 7 or J
        {
            "stop_name": "111 St",
            "must_include": [],
            "must_exclude": ["7", "J"],
        },
        {
            # A/C/E station — adjacent to Times Sq complex
            "stop_name": "42 St-Port Authority Bus Terminal",
            "must_include": ["C", "E"],
            "must_exclude": [],
        },
        {
            "stop_name": "Jay St-MetroTech",
            "must_include": ["F", "N", "R"],
            "must_exclude": [],
        },
    ]),
    ("J", [
        {
            "stop_name": "111 St",
            "must_include": [],
            "must_exclude": ["7", "A"],
        },
        {
            "stop_name": "Fulton St",
            "must_include": ["A", "C", "2", "3", "4", "5"],
            "must_exclude": [],
        },
    ]),
]


def main() -> None:
    total_failures = 0
    for route_id, cases in CASES:
        total_failures += test_route(route_id, cases)

    print(f"\n{'='*60}")
    if total_failures == 0:
        print(f"{PASS} All transfer tests passed.")
    else:
        print(f"{FAIL} {total_failures} test(s) failed.")
        sys.exit(1)


if __name__ == "__main__":
    main()
