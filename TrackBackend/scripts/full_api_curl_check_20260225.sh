#!/usr/bin/env bash
set -u
BASE="http://127.0.0.1:8000"
LAT="${LAT:-40.75308}"
LON="${LON:--73.99945}"
RAD="${RAD:-8047}"
RUN_LABEL="${RUN_LABEL:-default}"

pass=0
fail=0

log(){ printf "%s\n" "$1"; }

time_get(){
  local url="$1"
  curl -sS "$url" -o /tmp/api_body.json -w "%{time_total}"
}

log "=== RUN $RUN_LABEL lat=$LAT lon=$LON radius=$RAD ==="

hit(){
  local method="$1"; shift
  local url="$1"; shift || true
  local code
  code=$(curl -sS -X "$method" "$url" -o /tmp/api_body.json -w "%{http_code}")
  if [[ "$code" =~ ^2 ]]; then
    log "PASS $code $method $url"
    pass=$((pass+1))
  else
    log "FAIL $code $method $url"
    fail=$((fail+1))
  fi
}

# core/global
hit GET "$BASE/config"
hit GET "$BASE/data/status"
hit POST "$BASE/data/refresh?full=false"
hit GET "$BASE/alerts"
hit GET "$BASE/alerts?mode=subway"
hit GET "$BASE/accessibility"

# subway
hit GET "$BASE/subway/shapes/all"
hit GET "$BASE/subway/stations/all"
hit GET "$BASE/subway/stations/nearby?lat=$LAT&lon=$LON&radius=$RAD"
subway_route=$(curl -sS "$BASE/subway/shapes/all" | python -c "import sys, json; d=json.load(sys.stdin); lines=(d or {}).get('lines') or []; print((lines[0] or {}).get('route_id') if lines else 'A')" 2>/dev/null)
[[ -z "$subway_route" ]] && subway_route="A"
hit GET "$BASE/subway/shape/$subway_route"
hit GET "$BASE/subway/$subway_route"

# commuter rail
hit GET "$BASE/lirr/shapes/all"
hit GET "$BASE/lirr"
lirr_route=$(curl -sS "$BASE/lirr/shapes/all" | python -c "import sys, json; d=json.load(sys.stdin); print(d[0].get('route_id') if isinstance(d,list) and d and isinstance(d[0],dict) and d[0].get('route_id') else 'LIRR_5')" 2>/dev/null)
[[ -z "$lirr_route" ]] && lirr_route="LIRR_5"
hit GET "$BASE/lirr/shape/$lirr_route"

hit GET "$BASE/mnr/shapes/all"
hit GET "$BASE/mnr"
mnr_route=$(curl -sS "$BASE/mnr/shapes/all" | python -c "import sys, json; d=json.load(sys.stdin); print(d[0].get('route_id') if isinstance(d,list) and d and isinstance(d[0],dict) and d[0].get('route_id') else 'MNR_1')" 2>/dev/null)
[[ -z "$mnr_route" ]] && mnr_route="MNR_1"
hit GET "$BASE/mnr/shape/$mnr_route"

# bus
hit GET "$BASE/bus/routes"
hit GET "$BASE/bus/nearby?lat=$LAT&lon=$LON&radius=$RAD"
bus_route=$(curl -sS "$BASE/bus/routes" | python -c "import sys, json; d=json.load(sys.stdin); print(d[0].get('short_name') if isinstance(d,list) and d and isinstance(d[0],dict) and d[0].get('short_name') else 'SIM23')" 2>/dev/null)
[[ -z "$bus_route" ]] && bus_route="SIM23"
hit GET "$BASE/bus/stops/$bus_route"
hit GET "$BASE/bus/schedule/$bus_route"
hit GET "$BASE/bus/vehicles/$bus_route"
hit GET "$BASE/bus/route-shape/$bus_route"

# nearby
hit GET "$BASE/nearby?lat=$LAT&lon=$LON&radius=$RAD"
hit GET "$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=$RAD"
hit GET "$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=$RAD&mode=bus"
hit GET "$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=$RAD&mode=subway"
hit GET "$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=$RAD&mode=lirr"
hit GET "$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=$RAD&mode=mnr"

# predict
hit GET "$BASE/predict/delay?minutes_away=5&route_id=A&hour=8&day_of_week=3&weather=clear"

# dynamic live tracking
live_bus_route=$(curl -sS "$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=$RAD&mode=bus" | python -c "import sys, json; d=json.load(sys.stdin); print(d[0].get('route_id') if isinstance(d,list) and d and isinstance(d[0],dict) and d[0].get('route_id') else '')" 2>/dev/null)
if [[ -n "$live_bus_route" ]]; then
  hit GET "$BASE/bus/vehicles/$live_bus_route"
  hit GET "$BASE/bus/route-shape/$live_bus_route"
fi

live_train_route=$(curl -sS "$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=$RAD&mode=subway" | python -c "import sys, json; d=json.load(sys.stdin); print(d[0].get('route_id') if isinstance(d,list) and d and isinstance(d[0],dict) and d[0].get('route_id') else '')" 2>/dev/null)
if [[ -n "$live_train_route" ]]; then
  hit GET "$BASE/subway/$live_train_route"
  hit GET "$BASE/subway/shape/$live_train_route"
fi

nearby_stop=$(curl -sS "$BASE/bus/nearby?lat=$LAT&lon=$LON&radius=$RAD" | python -c "import sys, json; d=json.load(sys.stdin); print(d[0].get('id') if isinstance(d,list) and d and isinstance(d[0],dict) and d[0].get('id') else '')" 2>/dev/null)
if [[ -n "$nearby_stop" ]]; then
  hit GET "$BASE/bus/live/$nearby_stop"
fi

# integrity checks
curl -sS "$BASE/nearby?lat=$LAT&lon=$LON&radius=$RAD" > /tmp/nearby.json
curl -sS "$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=$RAD&mode=bus" > /tmp/grouped_bus.json
curl -sS "$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=$RAD&mode=subway" > /tmp/grouped_subway.json

python -c "import json, pathlib; nearby=json.loads(pathlib.Path('/tmp/nearby.json').read_text() or '[]'); bus=json.loads(pathlib.Path('/tmp/grouped_bus.json').read_text() or '[]'); sub=json.loads(pathlib.Path('/tmp/grouped_subway.json').read_text() or '[]'); empty=sum(1 for x in nearby if not str((x or {}).get('route_id','')).strip()) if isinstance(nearby,list) else -1; bt=len(bus) if isinstance(bus,list) else 0; bw=sum(1 for g in bus if isinstance(g,dict) and isinstance(g.get('directions'),list) and len(g.get('directions'))>0) if isinstance(bus,list) else 0; st=len(sub) if isinstance(sub,list) else 0; sw=sum(1 for g in sub if isinstance(g,dict) and isinstance(g.get('directions'),list) and len(g.get('directions'))>0) if isinstance(sub,list) else 0; print('\n=== VALIDATION ==='); print(f'nearby_count={len(nearby) if isinstance(nearby,list) else -1}'); print(f'nearby_empty_route_ids={empty}'); print(f'grouped_bus_total={bt} grouped_bus_with_directions={bw}'); print(f'grouped_subway_total={st} grouped_subway_with_directions={sw}')"

log "\n=== SUMMARY ==="
log "pass=$pass fail=$fail"

log "\n=== SPEED CHECK (/nearby/grouped) ==="
curl -sS -X POST "$BASE/admin/cache/clear" >/dev/null || true

url_grouped="$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=$RAD"
url_grouped_bus="$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=$RAD&mode=bus"

t_cold_all=$(time_get "$url_grouped")
t_warm_all_1=$(time_get "$url_grouped")
t_warm_all_2=$(time_get "$url_grouped")

t_cold_bus=$(time_get "$url_grouped_bus")
t_warm_bus_1=$(time_get "$url_grouped_bus")
t_warm_bus_2=$(time_get "$url_grouped_bus")

log "grouped(all): cold=${t_cold_all}s warm1=${t_warm_all_1}s warm2=${t_warm_all_2}s"
log "grouped(bus): cold=${t_cold_bus}s warm1=${t_warm_bus_1}s warm2=${t_warm_bus_2}s"
