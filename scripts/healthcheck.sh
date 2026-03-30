#!/bin/bash
BASE="https://track-vkrr.onrender.com"

hit() {
  local label="$1"
  local url="$2"
  local out
  out=$(curl -s -o /dev/null -w "%{http_code} %{size_download} %{time_total}" --max-time 30 "$url" 2>&1)
  local code=$(echo "$out" | awk '{print $1}')
  local size=$(echo "$out" | awk '{print $2}')
  local time=$(echo "$out" | awk '{print $3}')
  local icon="OK"
  if [[ "$code" != 2* ]]; then icon="FAIL"; fi
  printf "[%4s] %-45s HTTP %s  %8s bytes  %6ss\n" "$icon" "$label" "$code" "$size" "$time"
}

echo "=== TRACK PRODUCTION API HEALTH CHECK ==="
echo "Date: $(date)"
echo ""

echo "-- CORE --"
hit "GET /health" "$BASE/health"
hit "GET /config" "$BASE/config"
hit "GET /data/status" "$BASE/data/status"

echo ""
echo "-- SUBWAY --"
hit "GET /subway/shapes/all" "$BASE/subway/shapes/all"
hit "GET /subway/stations/all" "$BASE/subway/stations/all"
hit "GET /subway/stations/processed" "$BASE/subway/stations/processed"
hit "GET /subway/stations/nearby" "$BASE/subway/stations/nearby?lat=40.753&lon=-73.999&radius=800"
hit "GET /subway/shape/1" "$BASE/subway/shape/1"
hit "GET /subway/A" "$BASE/subway/A"

echo ""
echo "-- LIRR --"
hit "GET /lirr/shapes/all" "$BASE/lirr/shapes/all"
hit "GET /lirr/shape/Babylon" "$BASE/lirr/shape/Babylon"
hit "GET /lirr" "$BASE/lirr"

echo ""
echo "-- METRO-NORTH --"
hit "GET /mnr/shapes/all" "$BASE/mnr/shapes/all"
hit "GET /mnr/shape/Hudson" "$BASE/mnr/shape/Hudson"
hit "GET /mnr" "$BASE/mnr"

echo ""
echo "-- BUS --"
hit "GET /bus/routes" "$BASE/bus/routes"
hit "GET /bus/stops/M11" "$BASE/bus/stops/M11"
hit "GET /bus/schedule/M11" "$BASE/bus/schedule/M11"
hit "GET /bus/nearby" "$BASE/bus/nearby?lat=40.753&lon=-73.999&radius=500"
hit "GET /bus/live/308209" "$BASE/bus/live/308209"
hit "GET /bus/vehicles/M11" "$BASE/bus/vehicles/M11"
hit "GET /bus/route-shape/M11" "$BASE/bus/route-shape/M11"

echo ""
echo "-- ALERTS / ACCESSIBILITY --"
hit "GET /alerts" "$BASE/alerts"
hit "GET /alerts?mode=subway" "$BASE/alerts?mode=subway"
hit "GET /accessibility" "$BASE/accessibility"

echo ""
echo "-- NEARBY --"
hit "GET /nearby" "$BASE/nearby?lat=40.753&lon=-73.999&radius=1600"
hit "GET /nearby/grouped" "$BASE/nearby/grouped?lat=40.753&lon=-73.999&radius=1600"
hit "GET /nearby/grouped?mode=bus" "$BASE/nearby/grouped?lat=40.753&lon=-73.999&radius=1600&mode=bus"
hit "GET /nearby/grouped?mode=subway" "$BASE/nearby/grouped?lat=40.753&lon=-73.999&radius=1600&mode=subway"

echo ""
echo "-- ML / WEATHER --"
hit "GET /predict/delay" "$BASE/predict/delay?minutes_away=5&route_id=A&hour=17&day_of_week=6"
hit "GET /weather" "$BASE/weather?lat=40.753&lon=-73.999"

echo ""
echo "=== DONE ==="
