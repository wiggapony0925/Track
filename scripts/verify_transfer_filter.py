#!/usr/bin/env python3
"""Verify that Times Sq transfer is being filtered out by prioritize_transfer_rows."""
import sqlite3, math

db = sqlite3.connect("TrackBackend/app/data/transit_schedule.db")

dest_lat, dest_lon = 40.7847, -73.8459

# Find a northbound 1 train trip from Penn Station (128N = northbound)
trip = db.execute("""
    SELECT st.trip_id, st.stop_sequence, st.departure_time
    FROM stop_times st
    JOIN trips t ON st.trip_id = t.trip_id
    WHERE t.route_id = '1'
    AND st.stop_id = '128N'
    AND st.departure_time BETWEEN '10:00:00' AND '12:00:00'
    LIMIT 1
""").fetchone()

if not trip:
    # try southbound
    trip = db.execute("""
        SELECT st.trip_id, st.stop_sequence, st.departure_time
        FROM stop_times st
        JOIN trips t ON st.trip_id = t.trip_id
        WHERE t.route_id = '1'
        AND st.stop_id = '128S'
        AND st.departure_time BETWEEN '10:00:00' AND '12:00:00'
        LIMIT 1
    """).fetchone()

if not trip:
    # try any 1 train from any Penn Station stop
    trip = db.execute("""
        SELECT st.trip_id, st.stop_sequence, st.departure_time
        FROM stop_times st
        JOIN trips t ON st.trip_id = t.trip_id
        WHERE t.route_id = '1'
        AND st.stop_id IN ('128N','128S','128','A28N','A28S','A28')
        AND st.departure_time BETWEEN '10:00:00' AND '12:00:00'
        LIMIT 5
    """).fetchone()

if trip:
    trip_id, seq, dept = trip
    print(f"trip_id: {trip_id}")
    print(f"departure: {dept} (seq {seq})")

    downstream = db.execute("""
        SELECT st.stop_id, st.stop_sequence, st.arrival_time,
               s.stop_name, s.stop_lat, s.stop_lon
        FROM stop_times st
        JOIN stops s ON st.stop_id = s.stop_id
        WHERE st.trip_id = ? AND st.stop_sequence > ?
        ORDER BY st.stop_sequence
    """, (trip_id, seq)).fetchall()

    print(f"\nAll {len(downstream)} downstream stops:")
    for sid, ssq, arr, nm, lt, ln in downstream:
        d = math.sqrt((lt-dest_lat)**2 + (ln-dest_lon)**2) * 111139
        tag = " <<7TRAIN" if "Times" in nm else ""
        print(f"  seq={ssq:3d}  {sid:8s}  {nm:35s}  {d:8.0f}m{tag}")

    ranked = sorted(downstream, key=lambda x: math.sqrt((x[4]-dest_lat)**2 + (x[5]-dest_lon)**2))
    print(f"\nTop 10 by distance (engine selects these):")
    for i, (sid, ssq, arr, nm, lt, ln) in enumerate(ranked[:10]):
        d = math.sqrt((lt-dest_lat)**2 + (ln-dest_lon)**2) * 111139
        tag = " <<7TRAIN" if "Times" in nm else ""
        print(f"  {i+1:2d}. {nm:35s}  {d:8.0f}m  seq={ssq}{tag}")

    tsr = next((i+1 for i, r in enumerate(ranked) if "Times" in r[3]), None)
    print(f"\nTimes Sq rank: {tsr}/{len(downstream)}")
    print(f"In top 10: {'YES' if tsr and tsr <= 10 else 'NO'}")
else:
    print("No 1 train trip found from Penn Station")
    # Show what stop_ids exist for route 1
    stops = db.execute("""
        SELECT DISTINCT st.stop_id, s.stop_name
        FROM stop_times st
        JOIN trips t ON st.trip_id = t.trip_id
        JOIN stops s ON st.stop_id = s.stop_id
        WHERE t.route_id = '1'
        AND s.stop_name LIKE '%Penn%'
    """).fetchall()
    print(f"1 train stops at Penn Station: {stops}")

db.close()
