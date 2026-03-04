#!/usr/bin/env python3
"""Debug script to test schedule service query for QM63."""
import sys
import sqlite3
from datetime import datetime

sys.path.insert(0, ".")
from app.services.schedule_service import schedule_service

now = datetime.now()
current_date = now.strftime("%Y%m%d")
current_time_str = now.strftime("%H:%M:%S")
stop_id = "402146"
route_id = "QM63"

conn = sqlite3.connect("app/data/transit_schedule.db")
cursor = conn.cursor()
active_services = schedule_service._resolve_active_services(cursor, current_date)

print(f"Active services: {len(active_services)}")
print(f"Current time: {current_time_str}")
print(f"stop_id: {stop_id}")
print(f"route_id: {route_id}")

# Test 1: Without route filter
placeholders = ",".join(["?"] * len(active_services))
q1 = f"""SELECT COUNT(*) FROM stop_times st JOIN trips t ON st.trip_id=t.trip_id
WHERE st.stop_id = ? AND t.service_id IN ({placeholders}) AND st.arrival_time >= ?"""
p1 = [stop_id] + active_services + [current_time_str]
cursor.execute(q1, p1)
print(f"Without route filter: {cursor.fetchone()[0]} rows")

# Test 2: With route only (no service filter)
q2 = """SELECT COUNT(*) FROM stop_times st JOIN trips t ON st.trip_id=t.trip_id
WHERE st.stop_id = ? AND t.route_id = ? COLLATE NOCASE AND st.arrival_time >= ?"""
p2 = [stop_id, route_id, current_time_str]
cursor.execute(q2, p2)
print(f"With route only (no service filter): {cursor.fetchone()[0]} rows")

# Test 3: With QV services + route
qv_svcs = [s for s in active_services if "QV" in s]
print(f"QV services: {qv_svcs}")
placeholders_qv = ",".join(["?"] * len(qv_svcs))
q3 = f"""SELECT COUNT(*) FROM stop_times st JOIN trips t ON st.trip_id=t.trip_id
WHERE st.stop_id = ? AND t.service_id IN ({placeholders_qv}) AND t.route_id = ? COLLATE NOCASE AND st.arrival_time >= ?"""
p3 = [stop_id] + qv_svcs + [route_id, current_time_str]
cursor.execute(q3, p3)
print(f"With QV services + route: {cursor.fetchone()[0]} rows")

# Test 4: Exact same query as schedule service (use the LIKE '%' route filter)
route_filter = (
    "AND (t.route_id = ? COLLATE NOCASE"
    " OR t.route_id LIKE (? || '%') COLLATE NOCASE"
    " OR t.route_id IN"
    "   (SELECT route_id FROM routes"
    "    WHERE route_short_name = ? COLLATE NOCASE"
    "       OR route_short_name LIKE (? || '-%') COLLATE NOCASE))"
)
route_params = [route_id, route_id, route_id, route_id]

query = f"""
SELECT t.route_id, st.stop_id, st.arrival_time, t.trip_headsign, t.direction_id, t.trip_id
FROM stop_times st
JOIN trips t ON st.trip_id = t.trip_id
WHERE st.stop_id = ?
AND t.service_id IN ({placeholders})
{route_filter}
AND st.arrival_time >= ?
GROUP BY t.route_id, st.arrival_time
ORDER BY st.arrival_time ASC
LIMIT ?
"""
params = [stop_id] + active_services + route_params + [current_time_str, 10]
cursor.execute(query, params)
rows = cursor.fetchall()
print(f"\nFull query (like schedule service): {len(rows)} rows")
for row in rows[:5]:
    print(f"  {row}")

# Test 5: Call the actual schedule_service method
print(f"\nDirect schedule_service call:")
results = schedule_service.get_scheduled_arrivals(stop_id, route_id=route_id, limit=5)
print(f"  Results: {len(results)}")
for r in results:
    print(f"  route={r.route_id} stop={r.station} dest={r.destination} mins={r.minutes_away}")

conn.close()
