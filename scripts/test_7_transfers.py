#!/usr/bin/env python3
"""Simulate iOS transfer resolution for the 7 train."""
import json, sys, subprocess
from math import radians, cos, sin, sqrt, atan2

def haversine(lat1, lon1, lat2, lon2):
    R = 6371000
    dlat = radians(lat2 - lat1)
    dlon = radians(lon2 - lon1)
    a = sin(dlat/2)**2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon/2)**2
    return R * 2 * atan2(sqrt(a), sqrt(1-a))

def fetch(url):
    r = subprocess.run(["curl", "-s", url], capture_output=True, text=True)
    return json.loads(r.stdout)

BASE = "https://track-vkrr.onrender.com"

# Fetch stations
stations = fetch(f"{BASE}/subway/stations/all")["stations"]

# Fetch 7 train shape
shape = fetch(f"{BASE}/subway/shape/7")

# Use direction 0 stops (northbound)
dir_stops = shape.get("directions", [{}])[0].get("stops", shape.get("stops", []))

current_route = "7"

# Expected transfers (ground truth)
expected = {
    "Times Sq-42 St": {"1", "2", "3", "N", "Q", "R", "W", "GS"},
    "Grand Central-42 St": {"4", "5", "6", "6X", "GS"},
    "Court Sq": {"G", "E", "F", "FX", "M"},
    "Queensboro Plaza": {"N", "W"},
    "74 St-Broadway": {"E", "F", "FX", "M", "R"},
    "5 Av": set(),
    "Flushing-Main St": set(),
    "Mets-Willets Point": set(),
    "34 St-Hudson Yards": set(),
}

print(f"{'STOP':<30} {'METHOD':<12} {'TRANSFERS FOUND':<40} {'ISSUES'}")
print("=" * 120)

for stop in dir_stops:
    stop_name = stop["name"]
    stop_lat = stop["lat"]
    stop_lon = stop["lon"]
    
    transfers = set()
    method = "NONE"
    matched_stations = []
    
    stop_name_lower = stop_name.lower().strip()
    
    # Source 1: exact name match (iOS uses .first())
    exact_match = None
    for s in stations:
        if s["name"].lower().strip() == stop_name_lower:
            exact_match = s
            for r in s["routes"]:
                if r != current_route:
                    transfers.add(r)
            break
    
    if exact_match:
        method = "EXACT"
        matched_stations.append(f"{exact_match['name']} ({exact_match['routes']})")
    else:
        # Proximity fallback: 100m
        for s in stations:
            dist = haversine(stop_lat, stop_lon, s["lat"], s["lon"])
            if dist <= 100:
                matched_stations.append(f"{s['name']} ({s['routes']}) [{dist:.0f}m]")
                for r in s["routes"]:
                    if r != current_route:
                        transfers.add(r)
        if matched_stations:
            method = "PROXIMITY"
    
    # Compare with expected
    issues = []
    if stop_name in expected:
        exp = expected[stop_name]
        missing = exp - transfers
        extra = transfers - exp - {"7X"}  # 7X is own-line variant
        if missing:
            issues.append(f"MISSING: {sorted(missing)}")
        if extra:
            issues.append(f"WRONG: {sorted(extra)}")
    
    transfers_display = sorted(transfers - {"7X"}) if transfers else ["(none)"]
    issues_str = " | ".join(issues) if issues else ""
    
    indicator = ""
    if issues:
        indicator = "❌ "
    elif stop_name in expected and not expected[stop_name] and not (transfers - {"7X"}):
        indicator = "✅ "
    elif stop_name in expected:
        indicator = "✅ "
    
    print(f"{indicator}{stop_name:<28} {method:<12} {str(transfers_display):<40} {issues_str}")
    if matched_stations and method == "PROXIMITY":
        for ms in matched_stations:
            print(f"{'':>30} ↳ matched: {ms}")
