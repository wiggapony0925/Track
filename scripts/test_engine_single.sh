#!/usr/bin/env bash
set -e

DB="/Users/jeffreyfernandez/code/Track/TrackBackend/app/data/transit_schedule.db"
BIN="/Users/jeffreyfernandez/code/Track/TrackEngine/build/bin/trackengine"
PORT=8081

# Kill any existing engine
pkill -9 -f trackengine 2>/dev/null || true
sleep 1

# Start engine
echo "Starting engine..."
TRACK_ENGINE_SCHEDULE_DB="$DB" TRACK_ENGINE_PORT=$PORT "$BIN" &
ENGINE_PID=$!
echo "Engine PID: $ENGINE_PID"

# Wait for it to be ready (up to 30s)
for i in $(seq 1 30); do
    if curl -sf http://localhost:$PORT/health >/dev/null 2>&1; then
        echo "Engine ready after ${i}s"
        break
    fi
    sleep 1
done

# Health check
echo ""
echo "=== Health ==="
curl -s http://localhost:$PORT/health | python3 -m json.tool

# Single /go request
echo ""
echo "=== Single /go request ==="
python3 -c "
import httpx, time, json
from datetime import datetime, timezone, timedelta, time as tv
now_ts = int(time.time())
NY = timezone(timedelta(hours=-4))
now_ny = datetime.fromtimestamp(now_ts, tz=NY)
sd = now_ny.date()
mid = datetime.combine(sd, tv.min, tzinfo=NY)
payload = {
    'origin': {'label': 'Penn Station', 'lat': 40.7505, 'lon': -73.9934},
    'destination': {'label': 'Grand Central', 'lat': 40.7527, 'lon': -73.9772},
    'depart_at_ts': now_ts,
    'query_ts': now_ts,
    'service_day_yyyymmdd': int(sd.strftime('%Y%m%d')),
    'service_weekday': sd.weekday(),
    'service_day_midnight_ts': int(mid.timestamp()),
    'max_transfers': 2,
    'max_origin_walk_m': 1200,
    'max_destination_walk_m': 1200,
    'max_transfer_walk_m': 800,
    'search_window_minutes': 180,
    'num_itineraries': 4,
    'modes': ['subway', 'bus'],
    'now_ts': now_ts,
}
print('Service day:', sd.strftime('%Y-%m-%d'), 'weekday:', sd.weekday())
print('query_ts:', now_ts, 'midnight_ts:', int(mid.timestamp()))
print('delta:', now_ts - int(mid.timestamp()), 'seconds since midnight')
start = time.monotonic()
resp = httpx.post('http://localhost:$PORT/go', json=payload, timeout=30)
ms = (time.monotonic() - start) * 1000
data = resp.json()
print(f'HTTP {resp.status_code}, {ms:.0f}ms')
primary = data.get('primary_trip')
alts = data.get('alternatives', [])
print(f'primary: {\"YES\" if primary else \"NO\"}, alternatives: {len(alts)}')
if primary:
    it = primary['itinerary']
    print(f'  duration: {it[\"total_duration_s\"]}s, transfers: {it[\"transfer_count\"]}')
    for leg in it.get('legs', []):
        print(f'  leg: {leg.get(\"mode\",\"?\")} {leg.get(\"route_name\",\"\")} {leg.get(\"origin_stop_name\",\"\")} -> {leg.get(\"destination_stop_name\",\"\")}')
else:
    print('Full response:')
    print(json.dumps(data, indent=2)[:1000])
"

echo ""
echo "=== Done. Leaving engine running (PID $ENGINE_PID) ==="
# kill $ENGINE_PID 2>/dev/null || true
echo "SCRIPT_COMPLETE"
