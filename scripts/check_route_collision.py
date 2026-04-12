#!/usr/bin/env python3
"""Investigate whether subway numbered lines are present but mislabeled."""
import sqlite3

db = sqlite3.connect("TrackBackend/app/data/transit_schedule.db")

# Check a sample trip from 128N with route_id '1' — is it subway or MNR?
trip = db.execute("""
    SELECT t.trip_id, t.route_id, t.service_id, t.trip_headsign
    FROM stop_times st
    JOIN trips t ON st.trip_id = t.trip_id
    WHERE st.stop_id = '128N' AND t.route_id = '1'
    LIMIT 1
""").fetchone()

if trip:
    trip_id = trip[0]
    print(f"Trip: {trip_id}")
    print(f"  route_id: {trip[1]}, service_id: {trip[2]}, headsign: {trip[3]}")
    
    # Get all stops on this trip
    stops = db.execute("""
        SELECT st.stop_sequence, st.stop_id, s.stop_name, st.departure_time
        FROM stop_times st
        JOIN stops s ON st.stop_id = s.stop_id
        WHERE st.trip_id = ?
        ORDER BY st.stop_sequence
    """, (trip_id,)).fetchall()
    
    print(f"\n  All {len(stops)} stops on this trip:")
    for seq, sid, nm, dept in stops:
        print(f"    {seq:3d}  {sid:8s}  {nm:35s}  {dept}")

# Also check the 7 train — trip from 726N
trip7 = db.execute("""
    SELECT t.trip_id, t.route_id, t.service_id, t.trip_headsign
    FROM stop_times st
    JOIN trips t ON st.trip_id = t.trip_id
    WHERE st.stop_id = '726N' AND t.route_id = '7'
    LIMIT 1
""").fetchone()

if trip7:
    trip7_id = trip7[0]
    print(f"\n7 Train Trip: {trip7_id}")
    print(f"  route_id: {trip7[1]}, service_id: {trip7[2]}, headsign: {trip7[3]}")
    
    stops7 = db.execute("""
        SELECT st.stop_sequence, st.stop_id, s.stop_name, st.departure_time
        FROM stop_times st
        JOIN stops s ON st.stop_id = s.stop_id
        WHERE st.trip_id = ?
        ORDER BY st.stop_sequence
    """, (trip7_id,)).fetchall()
    
    print(f"\n  All {len(stops7)} stops:")
    for seq, sid, nm, dept in stops7:
        print(f"    {seq:3d}  {sid:8s}  {nm:35s}  {dept}")

# Check all distinct route_ids that use stops starting with '1' (subway 1 line stops)
print("\n=== How many trips total for route_id '1'? ===")
count = db.execute("SELECT COUNT(*) FROM trips WHERE route_id = '1'").fetchone()
print(f"  {count[0]} trips")

# Check if there is a separate subway feed — look for agency
print("\n=== Agencies in database ===")
try:
    for r in db.execute("SELECT * FROM agency").fetchall():
        print(f"  {r}")
except:
    print("  No agency table")

# Check feed_info
print("\n=== Feed info ===")
try:
    for r in db.execute("SELECT * FROM feed_info").fetchall():
        print(f"  {r}")
except:
    print("  No feed_info table")

db.close()
