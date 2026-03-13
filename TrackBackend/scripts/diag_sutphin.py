#!/usr/bin/env python3
"""Check if A train shape geometry passes near Sutphin Blvd."""
import csv, math
from collections import defaultdict

DATA_DIR = "app/data"

# Sutphin Blvd-Archer Av station coordinates
SUTPHIN_LAT = 40.7005
SUTPHIN_LON = -73.8080

def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))

# Load shapes for A, C, E
shapes_data = defaultdict(list)
with open(f"{DATA_DIR}/shapes.txt") as f:
    for row in csv.DictReader(f):
        sid = row["shape_id"]
        if sid.startswith(("A..", "C..", "E..")):
            lat = float(row["shape_pt_lat"])
            lon = float(row["shape_pt_lon"])
            seq = int(row["shape_pt_sequence"])
            shapes_data[sid].append((seq, lat, lon))

# The dedup keeps these for direction 0:
# A: A..N09R, A..N04R, A..N65R
# E: E..N05R, E..N57R
a_kept = ["A..N09R", "A..N04R", "A..N65R"]
e_kept = ["E..N05R", "E..N57R"]

# Check distance to Sutphin for each kept shape
print("=" * 70)
print(f"Points within 500m of Sutphin Blvd ({SUTPHIN_LAT}, {SUTPHIN_LON})")
print("=" * 70)

for sid in a_kept + e_kept:
    pts = sorted(shapes_data.get(sid, []))
    nearby = []
    min_dist = float('inf')
    for seq, lat, lon in pts:
        d = haversine_m(lat, lon, SUTPHIN_LAT, SUTPHIN_LON)
        if d < min_dist:
            min_dist = d
        if d < 500:
            nearby.append((seq, lat, lon, d))
    
    route = sid.split("..")[0]
    print(f"\n  {sid} ({len(pts)} pts): min_dist={min_dist:.0f}m to Sutphin")
    if nearby:
        print(f"    {len(nearby)} points within 500m:")
        for seq, lat, lon, d in nearby[:5]:
            print(f"      seq={seq}: ({lat:.4f}, {lon:.4f}) dist={d:.0f}m")
    else:
        print(f"    No points within 500m")

# Also check ALL A train shapes (not just dedup-kept ones)
print("\n" + "=" * 70)
print("ALL A train shapes - closest approach to Sutphin Blvd")
print("=" * 70)
for sid in sorted(shapes_data.keys()):
    if not sid.startswith("A.."):
        continue
    pts = sorted(shapes_data[sid])
    min_dist = float('inf')
    closest = None
    for seq, lat, lon in pts:
        d = haversine_m(lat, lon, SUTPHIN_LAT, SUTPHIN_LON)
        if d < min_dist:
            min_dist = d
            closest = (seq, lat, lon)
    print(f"  {sid}: min_dist={min_dist:.0f}m, closest_pt=({closest[1]:.4f}, {closest[2]:.4f})")

# Check the corridor_pipeline trunk merge result
# The trunk merge pools A+C+E polylines, so the E train's Jamaica extension
# becomes part of the TRUNK.  Even though A's original shapes don't go to 
# Jamaica, the trunk baseline will cover Jamaica because E goes there.
print("\n" + "=" * 70)
print("TRUNK MERGE ANALYSIS: Blue trunk (A/C/E) coverage grid")
print("=" * 70)
print("\nAll shapes that go into Blue trunk group:")
for route in ["A", "C", "E"]:
    for sid in sorted(shapes_data.keys()):
        if sid.startswith(f"{route}.."):
            pts = sorted(shapes_data[sid])
            min_dist_sutphin = min(haversine_m(lat, lon, SUTPHIN_LAT, SUTPHIN_LON) for _, lat, lon in pts)
            if min_dist_sutphin < 500:
                print(f"  {sid}: reaches within {min_dist_sutphin:.0f}m of Sutphin")
