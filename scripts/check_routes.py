#!/usr/bin/env python3
"""Check which routes serve key stops."""
import sqlite3

db = sqlite3.connect("TrackBackend/app/data/transit_schedule.db")

print("All subway routes (route_type=1):")
for r in db.execute(
    "SELECT route_id, route_short_name, route_long_name, route_type "
    "FROM routes WHERE route_type = 1 ORDER BY route_id"
).fetchall():
    print(f"  {r}")

print("\nRoutes at 128N (Penn Station 1/2/3):")
for r in db.execute("""
    SELECT DISTINCT r.route_id, r.route_short_name, r.route_long_name, r.route_type
    FROM stop_times st
    JOIN trips t ON st.trip_id = t.trip_id
    JOIN routes r ON t.route_id = r.route_id
    WHERE st.stop_id = '128N'
""").fetchall():
    print(f"  {r}")

print("\nRoutes at 726N (Hudson Yards):")
for r in db.execute("""
    SELECT DISTINCT r.route_id, r.route_short_name, r.route_long_name, r.route_type
    FROM stop_times st
    JOIN trips t ON st.trip_id = t.trip_id
    JOIN routes r ON t.route_id = r.route_id
    WHERE st.stop_id = '726N'
""").fetchall():
    print(f"  {r}")

# Check if the routes are correctly inferred
print("\nAll route_type=2 routes:")
for r in db.execute(
    "SELECT route_id, route_short_name, route_long_name, route_type "
    "FROM routes WHERE route_type = 2 ORDER BY route_id"
).fetchall():
    print(f"  {r}")

# What mode does the engine infer for the trip at 128N?
print("\nSample trip from 128N:")
for r in db.execute("""
    SELECT t.trip_id, t.route_id, r.route_short_name, r.route_long_name, r.route_type
    FROM stop_times st
    JOIN trips t ON st.trip_id = t.trip_id
    JOIN routes r ON t.route_id = r.route_id
    WHERE st.stop_id = '128N'
    LIMIT 3
""").fetchall():
    print(f"  {r}")

db.close()
