#!/usr/bin/env python3
"""Check distances between transfer complexes."""
import json, subprocess
from math import radians, cos, sin, sqrt, atan2

def hav(lat1, lon1, lat2, lon2):
    R = 6371000
    dl = radians(lat2 - lat1)
    dn = radians(lon2 - lon1)
    x = sin(dl/2)**2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dn/2)**2
    return R * 2 * atan2(sqrt(x), sqrt(1-x))

def fetch(url):
    r = subprocess.run(["curl", "-s", url], capture_output=True, text=True)
    return json.loads(r.stdout)

stations = fetch("https://track-vkrr.onrender.com/subway/stations/all")["stations"]

checks = [
    ("74 St-Broadway (7)", 40.746848, -73.891394),
    ("Court Sq (7)", 40.747023, -73.945264),
    ("Queensboro Plaza (7)", 40.750582, -73.940202),
    ("Times Sq-42 St (7)", 40.755477, -73.987691),
    ("Grand Central-42 St (7)", 40.751431, -73.976041),
]

for label, lat, lon in checks:
    print(f"\n=== Stations within 300m of {label} ===")
    nearby = []
    for s in stations:
        d = hav(lat, lon, s["lat"], s["lon"])
        if d <= 300:
            nearby.append((d, s["name"], s["routes"]))
    nearby.sort()
    for d, name, routes in nearby:
        print(f"  {d:>5.0f}m  {name:40s}  {routes}")
