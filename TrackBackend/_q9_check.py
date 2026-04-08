"""Temp script to check Q9 OBA/SIRI data."""
import httpx
import json
import sys

sys.path.insert(0, "/Users/jeffreyfernandez/code/Track/TrackBackend")
from app.config import get_settings

settings = get_settings()
key = settings.api_keys.mta_bus_key

# 1) OBA routes-for-agency: get Q9's full route object
url = settings.urls.bus_oba_base + "/routes-for-agency/MTABC.json"
resp = httpx.get(url, params={"key": key}, timeout=15)
data = resp.json()
routes = data.get("data", {}).get("list", [])
q9_route = None
for r in routes:
    if r.get("shortName", "").upper() == "Q9":
        q9_route = r
        print("=== Q9 from routes-for-agency ===")
        print(json.dumps(r, indent=2))
        break

# 2) Get stops for Q9
url2 = settings.urls.bus_oba_base + "/stops-for-route/MTABC_Q09.json"
resp2 = httpx.get(url2, params={"key": key}, timeout=15)
data2 = resp2.json()
stop_ids = data2.get("data", {}).get("entry", {}).get("stopIds", [])
print(f"\nQ9 has {len(stop_ids)} stops")

# Also check: does stops-for-route include polylines, stopGroupings, etc.?
entry = data2.get("data", {}).get("entry", {})
print("stops-for-route keys:", list(entry.keys()))

# Check stopGroupings for direction names
groupings = entry.get("stopGroupings", [])
for g in groupings:
    print("\nstopGrouping:", json.dumps(g.get("type", ""), indent=2))
    for sg in g.get("stopGroups", []):
        print(f"  direction: {sg.get('id')}, name: {sg.get('name', {})}")

# 3) SIRI stop-monitoring: find a Q9 arrival
print("\n=== Checking SIRI for Q9 arrivals ===")
for stop_id in stop_ids[:5]:
    siri_url = settings.urls.bus_siri_base + "/stop-monitoring.json"
    params = {"key": key, "version": "2", "MonitoringRef": stop_id}
    try:
        sr = httpx.get(siri_url, params=params, timeout=15)
        sd = sr.json()
        deliveries = (
            sd.get("Siri", {})
            .get("ServiceDelivery", {})
            .get("StopMonitoringDelivery", [])
        )
        if not deliveries:
            continue
        visits = deliveries[0].get("MonitoredStopVisit", [])
        for v in visits:
            j = v.get("MonitoredVehicleJourney", {})
            pln = j.get("PublishedLineName", "")
            if isinstance(pln, list):
                pln = pln[0] if pln else ""
            if "Q9" in pln.upper():
                print(f"\nFound Q9 at stop {stop_id}!")
                print("Full MonitoredVehicleJourney keys:", list(j.keys()))
                print(json.dumps(j, indent=2, default=str))
                sys.exit(0)
    except Exception as e:
        print(f"  stop {stop_id}: {e}")

print("No live Q9 vehicles found at this time")

# 4) Also try SIRI vehicle-monitoring for Q9 line
print("\n=== SIRI vehicle-monitoring for Q9 ===")
vm_url = settings.urls.bus_siri_base + "/vehicle-monitoring.json"
vm_params = {"key": key, "version": "2", "LineRef": "MTABC_Q09"}
try:
    vmr = httpx.get(vm_url, params=vm_params, timeout=15)
    vmd = vmr.json()
    deliveries = (
        vmd.get("Siri", {})
        .get("ServiceDelivery", {})
        .get("VehicleMonitoringDelivery", [])
    )
    if deliveries:
        activities = deliveries[0].get("VehicleActivity", [])
        if activities:
            j = activities[0].get("MonitoredVehicleJourney", {})
            print("First Q9 vehicle journey keys:", list(j.keys()))
            print(json.dumps(j, indent=2, default=str))
        else:
            print("No vehicle activities found")
    else:
        print("No deliveries")
except Exception as e:
    print(f"Error: {e}")
