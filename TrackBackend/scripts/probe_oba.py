"""Probe OBA schedule-for-stop to check for M104 trips under M11 SRS."""
import json, urllib.request, os, ssl, re
from datetime import datetime, timezone, timedelta

# Bypass SSL cert verification for local testing
ssl._create_default_https_context = ssl._create_unverified_context

# Load dotenv manually
for line in open(os.path.join(os.path.dirname(__file__), "..", ".env")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())

api_key = os.environ.get("OBA_API_KEY", "")
oba_base = "https://bustime.mta.info/api/where"

# Step 1: Get stops for M11 route
url = f"{oba_base}/stops-for-route/MTA%20NYCT_M11.json?key={api_key}&includePolylines=false&version=2"
print("Fetching stops for M11...")
resp = urllib.request.urlopen(url, timeout=15)
data = json.loads(resp.read())
stops = data.get("data", {}).get("references", {}).get("stops", [])
print(f"  {len(stops)} stops found")

# Simulate the backend's sampling: first, last, + 4 evenly spaced interior
max_sample = 6
if len(stops) <= max_sample:
    sample_stops = stops
else:
    interior_count = max_sample - 2
    interior = stops[1:-1]
    step = len(interior) / interior_count
    sampled_interior = [interior[int(i * step)] for i in range(interior_count)]
    sample_stops = [stops[0]] + sampled_interior + [stops[-1]]

print(f"  Sampling {len(sample_stops)} stops (same logic as backend):")
for s in sample_stops:
    print(f"    {s.get('id')} - {s.get('name')}")

now = datetime.now(timezone(timedelta(hours=-5)))
date_str = now.strftime("%Y-%m-%d")

def normalize(raw):
    token = (raw.split("_", 1)[-1] if "_" in raw else raw).upper()
    token = re.sub(r"(?<=\D)0+(?=\d)", "", token) or token
    token = re.sub(r"\+SBS$", "-SBS", token)
    token = re.sub(r"\+$", "-SBS", token)
    return token

req_token = normalize("M11")
print(f"\nreq_token = {req_token!r}")

total_m104_trips = 0
for stop in sample_stops:
    sid = stop.get("id", "")
    sname = stop.get("name", "")
    url2 = f"{oba_base}/schedule-for-stop/{sid}.json?key={api_key}&date={date_str}"
    try:
        resp2 = urllib.request.urlopen(url2, timeout=15)
        data2 = json.loads(resp2.read())
    except Exception as e:
        print(f"\n  STOP {sid} ({sname}): ERROR {e}")
        continue

    entry = data2.get("data", {}).get("entry", {})
    srs_list = entry.get("stopRouteSchedules", [])
    
    print(f"\n  STOP {sid} ({sname}): {len(srs_list)} SRS entries")
    
    for srs in srs_list:
        srs_route = srs.get("routeId", "")
        srs_token = normalize(srs_route)
        passes_filter = (srs_token == req_token)
        
        if not passes_filter:
            # Check: would this be filtered? Show it briefly
            print(f"    SRS {srs_route} (token={srs_token}) -> FILTERED OUT (correct)")
            continue
        
        print(f"    SRS {srs_route} (token={srs_token}) -> PASSES FILTER")
        for dg in srs.get("stopRouteDirectionSchedules", []):
            hs = dg.get("tripHeadsign", "")
            times = dg.get("scheduleStopTimes", [])
            # Check for M104-branded trip IDs in this M11 SRS block
            m104_trips = [ts for ts in times if "M104" in ts.get("tripId", "").upper()]
            m11_trips = [ts for ts in times if "M11" in ts.get("tripId", "").upper()]
            other_trips = len(times) - len(m104_trips) - len(m11_trips)
            print(f"      hs='{hs}': {len(times)} total, {len(m11_trips)} M11-branded, {len(m104_trips)} M104-branded, {other_trips} other")
            total_m104_trips += len(m104_trips)
            for ts in m104_trips[:3]:
                print(f"        CONTAMINATED: {ts.get('tripId')}")

print(f"\n=== TOTAL M104 trip IDs inside M11 SRS blocks: {total_m104_trips} ===")
if total_m104_trips:
    print("CONFIRMED: OBA nests M104 trips inside M11 route schedule (interlining)")
else:
    print("No contamination found — bug may be elsewhere")
