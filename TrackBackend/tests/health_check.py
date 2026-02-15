
import asyncio
import httpx
import sys

# Test configuration
BASE_URL = "http://127.0.0.1:8000"
TEST_LINE = "L"
TEST_BUS_ROUTE = "MTA NYCT_B63"
TEST_BUS_STOP = "MTA_308214"
LAT = 40.718  # Williamsburg
LON = -73.96
RADIUS = 500

async def test_endpoints():
    print(f"🚀 Starting Endpoint Health Check...")
    print(f"Target: {BASE_URL}")
    print("--------------------------------------------------")

    endpoints = [
        # System
        ("GET", "/config"),
        
        # Subway - Static
        ("GET", "/subway/shapes/all"),
        ("GET", "/subway/stations/all"),
        ("GET", f"/subway/shape/{TEST_LINE}"),
        
        # Subway - Live (check for arrival_ts!)
        ("GET", f"/subway/{TEST_LINE}"),
        
        # Bus - Static
        ("GET", "/bus/routes"),
        ("GET", f"/bus/stops/{TEST_BUS_ROUTE}"),
        ("GET", f"/bus/route-shape/{TEST_BUS_ROUTE}"),

        # Bus - Live
        ("GET", f"/bus/live/{TEST_BUS_STOP}"),
        ("GET", f"/bus/vehicles/{TEST_BUS_ROUTE}"),
        
        # Nearby (Unified)
        ("GET", f"/nearby?lat={LAT}&lon={LON}&radius={RADIUS}"),
        ("GET", f"/nearby/grouped?lat={LAT}&lon={LON}&radius={RADIUS}"),
        ("GET", f"/bus/nearby?lat={LAT}&lon={LON}&radius={RADIUS}"),

        # Other Modes / Status
        ("GET", "/lirr"),
        ("GET", "/alerts"),
        ("GET", "/accessibility"),
    ]

    async with httpx.AsyncClient(timeout=10.0) as client:
        for method, path in endpoints:
            url = f"{BASE_URL}{path}"
            print(f"👉 Testing {method} {path}...", end=" ")
            
            try:
                response = await client.request(method, url)
                if response.status_code == 200:
                    data = response.json()
                    count = len(data) if isinstance(data, list) else len(data.keys()) if isinstance(data, dict) else "N/A"
                    print(f"✅ OK ({count} items)")
                    
                    # Specific checks for arrival_ts
                    if path == f"/subway/{TEST_LINE}" and isinstance(data, list) and len(data) > 0:
                        sample = data[0]
                        has_ts = sample.get("arrival_ts") is not None
                        print(f"   🔎 Subway arrival_ts present? {has_ts}")
                        
                    if path.startswith("/nearby") and isinstance(data, list) and len(data) > 0:
                        sample = data[0]
                        # Handling grouped response vs flat
                        if "directions" in sample: # Grouped
                            first_arrival = sample["directions"][0]["arrivals"][0]
                            has_ts = first_arrival.get("arrival_ts") is not None
                            print(f"   🔎 Nearby (Grouped) arrival_ts present? {has_ts}")
                        else: # Flat
                            has_ts = sample.get("arrival_ts") is not None
                            print(f"   🔎 Nearby (Flat) arrival_ts present? {has_ts}")

                else:
                    print(f"❌ FAILED ({response.status_code})")
                    print(f"   Response: {response.text[:100]}...")
            except Exception as e:
                print(f"❌ ERROR: {e}")

    print("--------------------------------------------------")
    print("Health check complete.")

if __name__ == "__main__":
    asyncio.run(test_endpoints())
