#!/usr/bin/env python3
"""
Fetch precise NYC subway track data from OpenStreetMap via Overpass API.
OSM has survey-grade subway track alignments that follow actual infrastructure.
"""

from __future__ import annotations

import json
import ssl
import urllib.request

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

# Overpass query for NYC subway tracks (railway=subway + railway=light_rail for SIR)
# Bounding box: roughly NYC area
query = """
[out:json][timeout:60];
(
  way["railway"="subway"](40.49,-74.27,40.92,-73.68);
  way["railway"="light_rail"](40.49,-74.27,40.92,-73.68);
);
out body;
>;
out skel qt;
"""

url = "https://overpass-api.de/api/interpreter"
data = f"data={query}".encode()

print("Fetching NYC subway tracks from OpenStreetMap Overpass API...")
print("(This may take 30-60 seconds)")

req = urllib.request.Request(url, data=data, headers={"User-Agent": "Track/1.0"})
with urllib.request.urlopen(req, timeout=120, context=ctx) as resp:
    result = json.loads(resp.read())

elements = result.get("elements", [])
ways = [e for e in elements if e["type"] == "way"]
nodes = {e["id"]: (e["lat"], e["lon"]) for e in elements if e["type"] == "node"}

print(f"Ways: {len(ways)}")
print(f"Nodes: {len(nodes)}")

# Show some sample ways with their tags
route_tags = set()
for w in ways[:20]:
    tags = w.get("tags", {})
    name = tags.get("name", "?")
    colour = tags.get("colour", "?")
    service = tags.get("service", "")
    ref = tags.get("ref", "")
    nds = w.get("nodes", [])
    print(
        f"  Way {w['id']}: name={name}, colour={colour}, ref={ref}, service={service}, nodes={len(nds)}"
    )
    for k in tags:
        route_tags.add(k)

print(f"\nAll tag keys used: {sorted(route_tags)}")

# Count unique route names
names = {}
for w in ways:
    tags = w.get("tags", {})
    name = tags.get("name", "unknown")
    names[name] = names.get(name, 0) + 1
print(f"\nTrack segments by name ({len(names)} unique):")
for n, c in sorted(names.items(), key=lambda x: -x[1]):
    print(f"  {n}: {c} segments")

# Save raw data for further processing
outpath = "/Users/jeffreyfernandez/code/Track/TrackBackend/scripts/osm_subway_raw.json"
with open(outpath, "w") as f:
    json.dump(result, f)
print(f"\nSaved raw data to {outpath}")
print(f"Size: {len(json.dumps(result))} bytes")
