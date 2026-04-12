#!/usr/bin/env python3
"""Diagnose why the engine misses the 7→Q26 route corridor."""
import sqlite3, math

db = sqlite3.connect("TrackBackend/app/data/transit_schedule.db")

print("=== Q26 in routes ===")
for r in db.execute("SELECT route_id, route_short_name, route_long_name, route_type FROM routes WHERE route_short_name LIKE '%Q26%'").fetchall():
    print(r)

print("\n=== Q26 trips (sample) ===")
for r in db.execute("""
    SELECT t.trip_id, t.route_id, t.service_id, t.direction_id
    FROM trips t JOIN routes r ON t.route_id = r.route_id
    WHERE r.route_short_name LIKE '%Q26%' LIMIT 10
""").fetchall():
    print(r)

print("\n=== 7 train stops near origin (34 St / Hudson Yards / Times Sq) ===")
for r in db.execute("""
    SELECT stop_id, stop_name, stop_lat, stop_lon FROM stops
    WHERE (stop_name LIKE '%Hudson Yard%'
       OR stop_name LIKE '%34 St - Hudson%'
       OR (stop_name LIKE '%Times Sq%' AND stop_name LIKE '%42%'))
""").fetchall():
    print(r)

print("\n=== Flushing Main St subway stops ===")
for r in db.execute("SELECT stop_id, stop_name, stop_lat, stop_lon FROM stops WHERE stop_name LIKE '%Flushing%Main%'").fetchall():
    print(r)

print("\n=== Q26 bus stops near Flushing (within ~1km) ===")
for r in db.execute("""
    SELECT DISTINCT s.stop_id, s.stop_name, s.stop_lat, s.stop_lon
    FROM stop_times st
    JOIN stops s ON st.stop_id = s.stop_id
    JOIN trips t ON st.trip_id = t.trip_id
    JOIN routes r ON t.route_id = r.route_id
    WHERE r.route_short_name = 'Q26'
    AND s.stop_lat BETWEEN 40.755 AND 40.770
    AND s.stop_lon BETWEEN -73.840 AND -73.825
    LIMIT 15
""").fetchall():
    print(r)

print("\n=== Q26 stop_times near College Point destination ===")
for r in db.execute("""
    SELECT DISTINCT s.stop_id, s.stop_name, s.stop_lat, s.stop_lon
    FROM stop_times st
    JOIN stops s ON st.stop_id = s.stop_id
    JOIN trips t ON st.trip_id = t.trip_id
    JOIN routes r ON t.route_id = r.route_id
    WHERE r.route_short_name = 'Q26'
    AND s.stop_lat BETWEEN 40.78 AND 40.80
    AND s.stop_lon BETWEEN -73.86 AND -73.83
    LIMIT 15
""").fetchall():
    print(r)

# Check distance from Flushing-Main St to nearest Q26 stop
flushing = db.execute("SELECT stop_lat, stop_lon FROM stops WHERE stop_name LIKE '%Flushing%Main%' LIMIT 1").fetchone()
if flushing:
    q26_near = db.execute("""
        SELECT DISTINCT s.stop_id, s.stop_name, s.stop_lat, s.stop_lon
        FROM stop_times st
        JOIN stops s ON st.stop_id = s.stop_id
        JOIN trips t ON st.trip_id = t.trip_id
        JOIN routes r ON t.route_id = r.route_id
        WHERE r.route_short_name = 'Q26'
        ORDER BY ABS(s.stop_lat - ?) + ABS(s.stop_lon - ?)
        LIMIT 5
    """, (flushing[0], flushing[1])).fetchall()
    print(f"\n=== Closest Q26 stops to Flushing-Main St ({flushing[0]:.4f}, {flushing[1]:.4f}) ===")
    for sid, name, lat, lon in q26_near:
        d = math.sqrt((lat - flushing[0])**2 + (lon - flushing[1])**2) * 111139
        print(f"  {name:40s}  ({lat:.4f}, {lon:.4f})  ~{d:.0f}m")

# Check stop_modes table
print("\n=== stop_modes table exists? ===")
tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
if 'stop_modes' in tables:
    print("YES - stop_modes exists")
    # Check what modes are near the destination
    print("\n=== stop_modes near College Point (40.7847, -73.8459) ===")
    for r in db.execute("""
        SELECT * FROM stop_modes
        WHERE stop_lat BETWEEN 40.78 AND 40.80
        AND stop_lon BETWEEN -73.86 AND -73.83
        LIMIT 15
    """).fetchall():
        print(r)
else:
    print("NO - stop_modes does NOT exist")
    print("Available tables:", [t for t in tables if not t.startswith('sqlite')])

# Check transfer walk radius used by engine
print("\n=== Check engine nearby_stops radius ===")
# The engine uses 1400m walk radius for origin/dest and ~800m for transfers
# Flushing Main St subway: 40.7596, -73.8300
# Let's see if there are Q26 stops within 800m of Flushing Main St
if flushing:
    q26_within_800 = []
    for sid, name, lat, lon in db.execute("""
        SELECT DISTINCT s.stop_id, s.stop_name, s.stop_lat, s.stop_lon
        FROM stop_times st
        JOIN stops s ON st.stop_id = s.stop_id
        JOIN trips t ON st.trip_id = t.trip_id
        JOIN routes r ON t.route_id = r.route_id
        WHERE r.route_short_name = 'Q26'
    """).fetchall():
        d = math.sqrt((lat - flushing[0])**2 + (lon - flushing[1])**2) * 111139
        if d < 800:
            q26_within_800.append((name, lat, lon, d))
    print(f"\n  Q26 stops within 800m of Flushing Main St: {len(q26_within_800)}")
    for name, lat, lon, d in sorted(q26_within_800, key=lambda x: x[3]):
        print(f"    {name:40s} ~{d:.0f}m")

db.close()
