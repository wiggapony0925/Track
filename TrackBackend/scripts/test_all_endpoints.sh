#!/bin/bash
BASE="http://127.0.0.1:8767"
PASS=0
FAIL=0
SKIP=0
RESULTS=""

test_ep() {
    local method="$1" url="$2" label="$3" expected="${4:-200}"
    if [ "$method" = "GET" ]; then
        resp=$(curl -s -o /tmp/ep_body.json -w "%{http_code}|%{size_download}|%{time_total}" "$BASE$url" --max-time 30 2>&1)
    else
        resp=$(curl -s -o /tmp/ep_body.json -w "%{http_code}|%{size_download}|%{time_total}" -X "$method" "$BASE$url" --max-time 30 2>&1)
    fi
    code=$(echo "$resp" | cut -d'|' -f1)
    size=$(echo "$resp" | cut -d'|' -f2)
    ttime=$(echo "$resp" | cut -d'|' -f3)
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        FAIL=$((FAIL+1))
        RESULTS="${RESULTS}FAIL  ${label}  => TIMEOUT/CONN_ERR\n"
        return
    fi
    if [ "$code" = "$expected" ]; then
        PASS=$((PASS+1))
        RESULTS="${RESULTS}PASS  ${label}  => ${code} (${size}B, ${ttime}s)\n"
    else
        FAIL=$((FAIL+1))
        body_preview=$(head -c 200 /tmp/ep_body.json 2>/dev/null)
        RESULTS="${RESULTS}FAIL  ${label}  => ${code} (expected ${expected}) ${body_preview}\n"
    fi
}

echo "=========================================="
echo "  Testing endpoints on $BASE"
echo "=========================================="

# Core
test_ep GET "/health" "GET /health"
test_ep GET "/config" "GET /config"
test_ep GET "/metrics" "GET /metrics"

# Docs
test_ep GET "/api-docs?token=test-secret-123" "GET /api-docs"
test_ep GET "/openapi.json?token=test-secret-123" "GET /openapi.json"
test_ep GET "/docs" "GET /docs (redirect)" "307"
test_ep GET "/redoc" "GET /redoc (redirect)" "307"

# Subway
test_ep GET "/subway/A" "GET /subway/A"
test_ep GET "/subway/stations/all" "GET /subway/stations/all"
test_ep GET "/subway/stations/nearby?lat=40.7531&lon=-73.9994" "GET /subway/stations/nearby"
test_ep GET "/subway/stations/processed?lat=40.7531&lon=-73.9994" "GET /subway/stations/processed"
test_ep GET "/subway/shape/A" "GET /subway/shape/A"
test_ep GET "/subway/shapes/all" "GET /subway/shapes/all"

# Bus
test_ep GET "/bus/nearby?lat=40.7531&lon=-73.9994" "GET /bus/nearby"
test_ep GET "/bus/routes" "GET /bus/routes"
test_ep GET "/bus/live/MTA_300184" "GET /bus/live/{stop_id}"
test_ep GET "/bus/stops/M34-SBS" "GET /bus/stops/M34-SBS"
test_ep GET "/bus/vehicles/M34-SBS" "GET /bus/vehicles/M34-SBS"
test_ep GET "/bus/route-shape/M34-SBS" "GET /bus/route-shape/M34-SBS"
test_ep GET "/bus/schedule/M34-SBS" "GET /bus/schedule/M34-SBS"

# LIRR
test_ep GET "/lirr?lat=40.7531&lon=-73.9994" "GET /lirr"
test_ep GET "/lirr/shape/Babylon" "GET /lirr/shape/Babylon"
test_ep GET "/lirr/shapes/all" "GET /lirr/shapes/all"

# Metro-North
test_ep GET "/mnr?lat=40.7531&lon=-73.9994" "GET /mnr"
test_ep GET "/mnr/shape/Hudson" "GET /mnr/shape/Hudson"
test_ep GET "/mnr/shapes/all" "GET /mnr/shapes/all"

# Combined nearby
test_ep GET "/nearby?lat=40.7531&lon=-73.9994" "GET /nearby"
test_ep GET "/nearby/grouped?lat=40.7531&lon=-73.9994" "GET /nearby/grouped"

# Alerts & Accessibility
test_ep GET "/alerts" "GET /alerts"
test_ep GET "/accessibility" "GET /accessibility"

# Weather
test_ep GET "/weather?lat=40.7531&lon=-73.9994" "GET /weather"

# Predict
test_ep GET "/predict/delay?minutes_away=5&route_id=A&hour=15&day_of_week=2&weather=clear&mode=subway&stop_id=A27N" "GET /predict/delay"

# Admin
test_ep GET "/admin/cache/inspect" "GET /admin/cache/inspect"
test_ep GET "/data/status" "GET /data/status"

# POST endpoints
test_ep POST "/data/refresh" "POST /data/refresh"
test_ep POST "/predict/reload-model" "POST /predict/reload-model"

echo ""
echo "SKIP  POST /admin/cache/clear (preserved)"
SKIP=$((SKIP+1))

echo ""
echo "=========================================="
echo "  RESULTS"
echo "=========================================="
echo -e "$RESULTS"
echo "=========================================="
echo "  PASS: $PASS  |  FAIL: $FAIL  |  SKIP: $SKIP  |  TOTAL: $((PASS+FAIL+SKIP))"
echo "=========================================="
