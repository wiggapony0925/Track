#!/usr/bin/env python3
"""Check which origin candidates the engine would find for Penn Station area."""
import sqlite3, math

db = sqlite3.connect("TrackBackend/app/data/transit_schedule.db")

origin_lat, origin_lon = 40.7527, -73.9990
radius_m = 1400

# Simulate nearby_stops: all stops within radius with departures, deduped by parent
lat_delta = radius_m / 111139.0
lon_delta = radius_m / (111139.0 * math.cos(math.radians(origin_lat)))

all_stops = db.execute("""
    SELECT s.stop_id, s.stop_name, s.stop_lat, s.stop_lon
    FROM stops s
    WHERE s.stop_lat BETWEEN ? AND ?
    AND s.stop_lon BETWEEN ? AND ?
    AND EXISTS (SELECT 1 FROM stop_times WHERE stop_id = s.stop_id LIMIT 1)
""", (origin_lat - lat_delta, origin_lat + lat_delta,
      origin_lon - lon_delta, origin_lon + lon_delta)).fetchall()

# Calculate distances and filter
stops_with_dist = []
for sid, nm, lt, ln in all_stops:
    d = math.sqrt((lt - origin_lat)**2 + (ln - origin_lon)**2) * 111139
    if d <= radius_m:
        stops_with_dist.append((sid, nm, lt, ln, d))

stops_with_dist.sort(key=lambda x: x[4])

# Parent station dedup
def parent_id(sid):
    return sid.rstrip('NS')

station_counts = {}
deduped = []
for sid, nm, lt, ln, d in stops_with_dist:
    pid = parent_id(sid)
    cnt = station_counts.get(pid, 0)
    if cnt < 2:
        deduped.append((sid, nm, lt, ln, d))
        station_counts[pid] = cnt + 1

print(f"Total stops within {radius_m}m: {len(stops_with_dist)}")
print(f"After parent dedup (2/station): {len(deduped)}")
print(f"\nFirst 20 (what nearby_stops(limit=10) would return):")
for i, (sid, nm, lt, ln, d) in enumerate(deduped[:20]):
    # Check which routes serve this stop
    routes = db.execute("""
        SELECT DISTINCT r.route_id FROM trips t
        JOIN routes r ON t.route_id = r.route_id
        JOIN stop_times st ON st.trip_id = t.trip_id
        WHERE st.stop_id = ? LIMIT 5
    """, (sid,)).fetchall()
    route_ids = ",".join(r[0] for r in routes)
    marker = " <<< 7 TRAIN" if "Hudson" in nm else ""
    in_10 = " [IN TOP 10]" if i < 10 else ""
    print(f"  {i+1:3d}. {sid:8s}  {nm:30s}  {d:6.0f}m  routes:{route_ids}{marker}{in_10}")

# Now simulate mode-balanced augmentation for subway
print(f"\n=== Mode augmentation: subway (kPerModeMin=4) ===")
seen = set(s[0] for s in deduped[:10])
subway_stops = db.execute("""
    SELECT s.stop_id, s.stop_name, s.stop_lat, s.stop_lon
    FROM stops s
    JOIN stop_modes sm ON sm.stop_id = s.stop_id
    WHERE s.stop_lat BETWEEN ? AND ?
    AND s.stop_lon BETWEEN ? AND ?
    AND sm.route_type = 1
""", (origin_lat - lat_delta, origin_lat + lat_delta,
      origin_lon - lon_delta, origin_lon + lon_delta)).fetchall()

subway_with_dist = []
for sid, nm, lt, ln in subway_stops:
    d = math.sqrt((lt - origin_lat)**2 + (ln - origin_lon)**2) * 111139
    if d <= radius_m and sid not in seen:
        subway_with_dist.append((sid, nm, lt, ln, d))

subway_with_dist.sort(key=lambda x: x[4])
print(f"  Subway stops NOT already in top-10 (within {radius_m}m): {len(subway_with_dist)}")
for i, (sid, nm, lt, ln, d) in enumerate(subway_with_dist[:10]):
    routes = db.execute("""
        SELECT DISTINCT r.route_id FROM trips t
        JOIN routes r ON t.route_id = r.route_id
        JOIN stop_times st ON st.trip_id = t.trip_id
        WHERE st.stop_id = ? LIMIT 5
    """, (sid,)).fetchall()
    route_ids = ",".join(r[0] for r in routes)
    in_4 = " [WOULD BE ADDED]" if i < 4 else ""
    marker = " <<< 7 TRAIN" if "Hudson" in nm else ""
    print(f"    {i+1:2d}. {sid:8s}  {nm:30s}  {d:6.0f}m  routes:{route_ids}{marker}{in_4}")

# How many unique routes are reachable within 1400m?
print(f"\n=== All unique routes reachable within {radius_m}m ===")
all_route_ids = set()
for sid, nm, lt, ln, d in stops_with_dist:
    routes = db.execute("""
        SELECT DISTINCT r.route_id FROM trips t
        JOIN routes r ON t.route_id = r.route_id
        JOIN stop_times st ON st.trip_id = t.trip_id
        WHERE st.stop_id = ?
    """, (sid,)).fetchall()
    for (rid,) in routes:
        all_route_ids.add(rid)

# Which are subway routes?
subway_routes = set()
for rid in all_route_ids:
    rtype = db.execute("SELECT route_type FROM routes WHERE route_id = ?", (rid,)).fetchone()
    if rtype and rtype[0] == 1:
        subway_routes.add(rid)

print(f"  Subway routes: {sorted(subway_routes)}")
print(f"  All routes: {len(all_route_ids)} total")

db.close()
