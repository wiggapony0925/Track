import httpx

BASE = "http://127.0.0.1:8000"

with httpx.Client(timeout=90) as client:
    for route in ["M12", "SIM24", "M11"]:
        response = client.get(f"{BASE}/bus/route-shape/{route}")
        payload = response.json() if response.status_code == 200 else {}
        polylines = len(payload.get("polylines") or []) if isinstance(payload, dict) else -1
        stops = len(payload.get("stops") or []) if isinstance(payload, dict) else -1
        directions = len(payload.get("directions") or []) if isinstance(payload, dict) else -1
        print(f"route={route} status={response.status_code} polylines={polylines} stops={stops} directions={directions}")

    lat = 40.75308
    lon = -73.99945
    radius = 8047
    response = client.get(
        f"{BASE}/nearby/grouped",
        params={"lat": lat, "lon": lon, "radius": radius, "mode": "bus"},
    )
    groups = response.json() if response.status_code == 200 else []
    one_direction = [
        group.get("route_id")
        for group in groups
        if isinstance(group, dict) and len(group.get("directions") or []) == 1
    ]

    print(f"grouped_status={response.status_code}")
    print(f"grouped_bus_total={len(groups) if isinstance(groups, list) else -1}")
    print(f"grouped_bus_one_direction_count={len(one_direction)}")
    print(f"grouped_bus_one_direction_sample={one_direction[:20]}")
