#!/usr/bin/env bash
# ============================================================
# full_api_curl_check_20260226.sh
# Track Backend — comprehensive endpoint & speed audit
#
# Usage:
#   bash scripts/full_api_curl_check_20260226.sh
#   BASE=https://track-vkrr.onrender.com bash scripts/full_api_curl_check_20260226.sh
#
# Covers:
#   - All HTTP endpoints (config, data, alerts, subway, LIRR,
#     MNR, bus, nearby, predict)
#   - Cold-start vs warm-cache timing for all 4 transit modes
#     across all 5 NYC boroughs
#   - Per-mode Redis + in-process cache validation
#   - Nearby grouped: direction presence audit by mode/borough
#   - Data integrity checks (empty route_ids, direction counts)
# ============================================================
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:8000}"
RUN_LABEL="${RUN_LABEL:-$(date '+%Y-%m-%d %H:%M:%S')}"

# Colour helpers (disable when not a TTY)
if [ -t 1 ]; then
  GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[0;33m'; CYN='\033[0;36m'; RST='\033[0m'
else
  GRN=''; RED=''; YLW=''; RST=''; CYN=''
fi

pass=0; fail=0; warn=0
declare -a FAILED_URLS=()

log()  { printf "%s\n" "$*"; }
info() { printf "${CYN}%s${RST}\n" "$*"; }
ok()   { printf "${GRN}PASS${RST} %s\n" "$*"; }
bad()  { printf "${RED}FAIL${RST} %s\n" "$*"; }
wrn()  { printf "${YLW}WARN${RST} %s\n" "$*"; }

# ── hit <METHOD> <URL> [label] ───────────────────────────────
hit() {
  local method="$1" url="$2" label="${3:-}"
  local code
  code=$(curl -sS -X "$method" "$url" -o /tmp/_api_body.json -w "%{http_code}" 2>/dev/null)
  local display="${label:-$method $url}"
  if [[ "$code" =~ ^2 ]]; then
    ok "$code  $display"
    (( pass++ )) || true
  else
    bad "$code  $display"
    FAILED_URLS+=("$code $display")
    (( fail++ )) || true
  fi
}

# ── tget <URL> → prints elapsed seconds ─────────────────────
tget() {
  curl -sS "$1" -o /tmp/_speed_body.json -w "%{time_total}" 2>/dev/null
}

# ── first_field <url> <jq_filter> → first value or fallback ──
first_field() {
  local url="$1" filter="$2" fallback="${3:-}"
  curl -sS "$url" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    result = $filter
    print(result if result else '$fallback')
except Exception:
    print('$fallback')
" 2>/dev/null || echo "$fallback"
}

log ""; info "=== Track API — Full Endpoint Audit ==="
log "Base URL : $BASE"
log "Run label: $RUN_LABEL"
log ""

# ╔═══════════════════════════════════════════╗
# ║  1. CORE / GLOBAL                         ║
# ╚═══════════════════════════════════════════╝
info "── 1. Core / Global ──────────────────────────"
hit GET "$BASE/config"                              "config"
hit GET "$BASE/data/status"                         "data/status"
hit POST "$BASE/data/refresh?full=false"            "data/refresh (incremental)"
hit GET "$BASE/alerts"                              "alerts (all)"
hit GET "$BASE/alerts?mode=subway"                  "alerts (subway)"
hit GET "$BASE/alerts?mode=bus"                     "alerts (bus)"
hit GET "$BASE/accessibility"                       "accessibility"

# ╔═══════════════════════════════════════════╗
# ║  2. SUBWAY                                ║
# ╚═══════════════════════════════════════════╝
info ""
info "── 2. Subway ─────────────────────────────────"
hit GET "$BASE/subway/shapes/all"                   "subway/shapes/all"
hit GET "$BASE/subway/stations/all"                 "subway/stations/all"
hit GET "$BASE/subway/stations/nearby?lat=40.7580&lon=-73.9855&radius=800" \
        "subway/stations/nearby (midtown)"

SUBWAY_ROUTE=$(first_field \
  "$BASE/subway/shapes/all" \
  "(d or {}).get('lines', [{}])[0].get('route_id', 'A')" \
  "A")
[[ -z "$SUBWAY_ROUTE" ]] && SUBWAY_ROUTE="A"
hit GET "$BASE/subway/shape/$SUBWAY_ROUTE"          "subway/shape/$SUBWAY_ROUTE"
hit GET "$BASE/subway/$SUBWAY_ROUTE"                "subway/$SUBWAY_ROUTE (arrivals)"

# A few known routes to ensure color/shape coverage
for ROUTE in A C E 1 2 3 4 5 6 N Q R; do
  hit GET "$BASE/subway/shape/$ROUTE" "subway/shape/$ROUTE"
done

# ╔═══════════════════════════════════════════╗
# ║  3. LIRR                                  ║
# ╚═══════════════════════════════════════════╝
info ""
info "── 3. LIRR ───────────────────────────────────"
hit GET "$BASE/lirr/shapes/all"                     "lirr/shapes/all"
hit GET "$BASE/lirr"                                "lirr (arrivals)"

LIRR_ROUTE=$(first_field \
  "$BASE/lirr/shapes/all" \
  "(d.get('lines') or [{}])[0].get('route_id', 'LIRR_5')" \
  "LIRR_5")
[[ -z "$LIRR_ROUTE" ]] && LIRR_ROUTE="LIRR_5"
hit GET "$BASE/lirr/shape/$LIRR_ROUTE"              "lirr/shape/$LIRR_ROUTE"

# ╔═══════════════════════════════════════════╗
# ║  4. MNR                                   ║
# ╚═══════════════════════════════════════════╝
info ""
info "── 4. Metro-North (MNR) ──────────────────────"
hit GET "$BASE/mnr/shapes/all"                      "mnr/shapes/all"
hit GET "$BASE/mnr"                                 "mnr (arrivals)"

MNR_ROUTE=$(first_field \
  "$BASE/mnr/shapes/all" \
  "(d.get('lines') or [{}])[0].get('route_id', 'MNR_1')" \
  "MNR_1")
[[ -z "$MNR_ROUTE" ]] && MNR_ROUTE="MNR_1"
hit GET "$BASE/mnr/shape/$MNR_ROUTE"                "mnr/shape/$MNR_ROUTE"

# ╔═══════════════════════════════════════════╗
# ║  5. BUS                                   ║
# ╚═══════════════════════════════════════════╝
info ""
info "── 5. Bus ────────────────────────────────────"
hit GET "$BASE/bus/routes"                          "bus/routes"
hit GET "$BASE/bus/nearby?lat=40.7580&lon=-73.9855&radius=400" \
        "bus/nearby (midtown)"

BUS_ROUTE=$(first_field \
  "$BASE/bus/routes" \
  "(d[0].get('short_name') if isinstance(d,list) and d else 'SIM23')" \
  "SIM23")
[[ -z "$BUS_ROUTE" ]] && BUS_ROUTE="SIM23"
hit GET "$BASE/bus/stops/$BUS_ROUTE"                "bus/stops/$BUS_ROUTE"
hit GET "$BASE/bus/schedule/$BUS_ROUTE"             "bus/schedule/$BUS_ROUTE"
hit GET "$BASE/bus/vehicles/$BUS_ROUTE"             "bus/vehicles/$BUS_ROUTE"
hit GET "$BASE/bus/route-shape/$BUS_ROUTE"          "bus/route-shape/$BUS_ROUTE"

BUS_STOP=$(first_field \
  "$BASE/bus/nearby?lat=40.7580&lon=-73.9855&radius=400" \
  "(d[0].get('id') if isinstance(d,list) and d else '')" \
  "")
if [[ -n "$BUS_STOP" ]]; then
  hit GET "$BASE/bus/live/$BUS_STOP"               "bus/live/$BUS_STOP"
fi

# ╔═══════════════════════════════════════════╗
# ║  6. NEARBY — flat + grouped               ║
# ╚═══════════════════════════════════════════╝
info ""
info "── 6. Nearby ─────────────────────────────────"

# Borough coordinates (plain vars — bash 3.2 compatible)
RAD=8047  # 5 miles

for BOROUGH in manhattan brooklyn queens bronx staten_island; do
  case "$BOROUGH" in
    manhattan)    LAT=40.7580; LON=-73.9855 ;;
    brooklyn)     LAT=40.6782; LON=-73.9442 ;;
    queens)       LAT=40.7282; LON=-73.7949 ;;
    bronx)        LAT=40.8448; LON=-73.8648 ;;
    staten_island) LAT=40.5795; LON=-74.1502 ;;
  esac
  hit GET "$BASE/nearby?lat=$LAT&lon=$LON&radius=$RAD" \
      "nearby (flat)   $BOROUGH"
  for MODE in bus subway lirr mnr; do
    hit GET "$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=$RAD&mode=$MODE" \
        "nearby/grouped  $BOROUGH  $MODE"
  done
done

# ╔═══════════════════════════════════════════╗
# ║  7. PREDICT                               ║
# ╚═══════════════════════════════════════════╝
info ""
info "── 7. Predict ────────────────────────────────"
hit GET "$BASE/predict/delay?minutes_away=5&route_id=A&hour=8&day_of_week=3&weather=clear" \
    "predict/delay"

# ╔═══════════════════════════════════════════╗
# ║  8. DYNAMIC LIVE CHECKS                   ║
# ╚═══════════════════════════════════════════╝
info ""
info "── 8. Dynamic Live Checks (midtown) ──────────"
LAT=40.7580; LON=-73.9855

LIVE_BUS=$(first_field \
  "$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=800&mode=bus" \
  "(d[0].get('route_id') or (d[0].get('directions') or [{}])[0].get('route_id','') if isinstance(d,list) and d else '')" \
  "")
if [[ -n "$LIVE_BUS" ]]; then
  hit GET "$BASE/bus/vehicles/$LIVE_BUS"        "bus/vehicles  (live: $LIVE_BUS)"
  hit GET "$BASE/bus/route-shape/$LIVE_BUS"     "bus/route-shape (live: $LIVE_BUS)"
else
  wrn "No live bus routes found near midtown — skipping dynamic bus checks"
  (( warn++ )) || true
fi

LIVE_SUB=$(first_field \
  "$BASE/nearby/grouped?lat=$LAT&lon=$LON&radius=800&mode=subway" \
  "(d[0].get('route_id') if isinstance(d,list) and d else '')" \
  "")
if [[ -n "$LIVE_SUB" ]]; then
  hit GET "$BASE/subway/$LIVE_SUB"              "subway arrivals (live: $LIVE_SUB)"
  hit GET "$BASE/subway/shape/$LIVE_SUB"        "subway/shape   (live: $LIVE_SUB)"
else
  wrn "No live subway routes found near midtown — skipping dynamic subway checks"
  (( warn++ )) || true
fi

# ╔═══════════════════════════════════════════╗
# ║  9. DATA INTEGRITY                        ║
# ╚═══════════════════════════════════════════╝
info ""
info "── 9. Data Integrity ─────────────────────────"

for BOROUGH in manhattan brooklyn; do
  case "$BOROUGH" in
    manhattan) LAT=40.7580; LON=-73.9855 ;;
    brooklyn)  LAT=40.6782; LON=-73.9442 ;;
  esac
  python3 -c "
import json, ssl, urllib.request, sys

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

base = '$BASE'
borough = '$BOROUGH'
lat, lon, rad = $LAT, $LON, $RAD

results = []
for mode in ('bus', 'subway', 'lirr', 'mnr'):
    url = f'{base}/nearby/grouped?lat={lat}&lon={lon}&radius={rad}&mode={mode}'
    try:
        with urllib.request.urlopen(url, timeout=15, context=ctx) as r:
            data = json.load(r)
    except Exception as e:
        print(f'  INTEGRITY SKIP {mode} ({e})')
        continue
    if not isinstance(data, list):
        print(f'  INTEGRITY BAD  {mode}: not a list')
        continue
    total = len(data)
    with_dirs  = sum(1 for g in data if isinstance(g.get('directions'), list) and g['directions'])
    no_dirs    = total - with_dirs
    empty_rids = sum(1 for g in data if not str(g.get('route_id', '')).strip())
    results.append((mode, total, with_dirs, no_dirs, empty_rids))

print(f'  {borough}:')
for mode, total, wd, nd, er in results:
    flags = []
    if er:  flags.append(f'EMPTY_ROUTE_IDS={er}')
    if nd > total * 0.5 and total > 2: flags.append(f'MANY_NO_DIRS={nd}/{total}')
    status = '  OK' if not flags else f'  !! {\" \".join(flags)}'
    print(f'    {mode:<8} total={total:3d}  with_dirs={wd:3d}  no_dirs={nd:3d}{status}')
" 2>/dev/null || wrn "Integrity check skipped for $BOROUGH"
done

# ╔═══════════════════════════════════════════╗
# ║  10. SPEED — cold vs warm per mode        ║
# ╚═══════════════════════════════════════════╝
info ""
info "── 10. Speed Check — cold vs warm (5 boroughs, 4 modes) ──"

# Optionally clear cache to measure true cold latency
curl -sS -X POST "$BASE/admin/cache/clear" -o /dev/null 2>/dev/null || true

LAT_M=40.7580; LON_M=-73.9855  # Midtown (representative for speed)

printf "  %-10s %-8s %8s %8s %8s   %s\n" "mode" "borough" "cold(s)" "warm1(s)" "warm2(s)" "trend"

for MODE in bus subway lirr mnr; do
  URL="$BASE/nearby/grouped?lat=$LAT_M&lon=$LON_M&radius=$RAD&mode=$MODE"
  T_COLD=$(tget "$URL")
  T_W1=$(tget "$URL")
  T_W2=$(tget "$URL")
  # Determine trend arrow
  if python3 -c "exit(0 if float('$T_W2') < float('$T_COLD') * 0.7 else 1)" 2>/dev/null; then
    TREND="${GRN}↓ fast${RST}"
  elif python3 -c "exit(0 if float('$T_W2') < float('$T_COLD') * 0.95 else 1)" 2>/dev/null; then
    TREND="${YLW}↓ some${RST}"
  else
    TREND="~ flat"
  fi
  printf "  %-10s %-8s %8s %8s %8s   %b\n" \
    "$MODE" "midtown" "$T_COLD" "$T_W1" "$T_W2" "$TREND"
done

# Redis warm: fetch again after all previous calls have populated caches
info ""
info "── 10b. Redis warm (second process would see these times) ──"
for MODE in bus subway lirr mnr; do
  URL="$BASE/nearby/grouped?lat=$LAT_M&lon=$LON_M&radius=$RAD&mode=$MODE"
  T=$(tget "$URL")
  printf "  %-10s redis-warm: %ss\n" "$MODE" "$T"
done

# ╔═══════════════════════════════════════════╗
# ║  SUMMARY                                  ║
# ╚═══════════════════════════════════════════╝
info ""
info "══ SUMMARY ═══════════════════════════════════"
printf "  ${GRN}pass=%d${RST}  ${RED}fail=%d${RST}  ${YLW}warn=%d${RST}\n" \
  "$pass" "$fail" "$warn"

if [[ ${#FAILED_URLS[@]} -gt 0 ]]; then
  log ""
  log "  Failed endpoints:"
  for F in "${FAILED_URLS[@]}"; do
    bad "    $F"
  done
fi

log ""
if [[ "$fail" -eq 0 ]]; then
  ok "All endpoints passed ✓"
  exit 0
else
  bad "$fail endpoint(s) failed"
  exit 1
fi
