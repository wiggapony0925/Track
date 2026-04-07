#!/usr/bin/env python3
"""Audit every backend API endpoint against the iOS Swift Codable models.

Hits each endpoint on the local backend (http://127.0.0.1:8000), extracts the
JSON keys returned, and compares them against the keys the Swift models expect
via their CodingKeys enums.

Reports:
  - MISSING: key expected by Swift but absent in JSON (will crash decode)
  - EXTRA:   key in JSON but not in Swift model (harmless, but noted)
  - OK:      all expected keys present

Usage:
    python scripts/model_audit.py
"""

import json
import sys
import urllib.request
import urllib.error
from collections import OrderedDict

BASE = "http://127.0.0.1:8000"

# Coordinates near Penn Station for nearby endpoints
LAT, LON = 40.7506, -73.9935


# ---------------------------------------------------------------------------
# Swift model expected keys  (from CodingKeys enums)
# Format: { json_key: "required" | "optional" | "default" }
#   required = must be present
#   optional = Optional type, safe if missing (auto decodeIfPresent)
#   default  = has default value BUT listed in CodingKeys (DANGEROUS with
#              auto-synthesized init; safe if custom init uses decodeIfPresent)
#   custom_safe = has default AND custom init(from:) that handles missing key
# ---------------------------------------------------------------------------

MODELS = OrderedDict()

MODELS["TransitArrivalResponse"] = {
    "keys": {
        "route_id": "required",
        "station": "required",
        "station_name": "optional",
        "direction": "required",
        "destination": "optional",
        "minutes_away": "required",
        "status": "required",
        "stop_lat": "optional",
        "stop_lon": "optional",
        "trip_id": "optional",
        "arrival_ts": "optional",
        "is_cancelled": "default",  # Bool = false, auto-synth
    },
}

MODELS["BusStop"] = {
    "keys": {
        "id": "required",
        "name": "required",
        "lat": "required",
        "lon": "required",
        "direction": "optional",
        "route_ids": "default",  # [String]? = nil, Optional so safe
    },
}

MODELS["BusArrival"] = {
    "keys": {
        "route_id": "required",
        "vehicle_id": "required",
        "stop_id": "required",
        "stop_name": "optional",
        "status_text": "required",
        "status": "required",
        "expected_arrival": "optional",
        "distance_meters": "optional",
        "bearing": "optional",    # Double? = nil
        "direction_ref": "optional",  # Int? = nil
        "destination_name": "optional",  # String? = nil
        "is_realtime": "default",  # Bool = true, auto-synth -- RISKY
    },
}

MODELS["BusRoute"] = {
    "keys": {
        "id": "required",
        "short_name": "required",
        "long_name": "required",
        "color": "required",
        "description": "required",
    },
}

MODELS["BusScheduleResponse"] = {
    "keys": {
        "route_id": "required",
        "directions": "required",
    },
}

MODELS["BusScheduleDirection"] = {
    "keys": {
        "direction": "required",
        "headsign": "required",
        "departures": "required",
    },
}

MODELS["BusScheduledDeparture"] = {
    "keys": {
        "stop_name": "required",
        "stop_id": "required",
        "departure_time": "required",
        "headsign": "required",
        "trip_id": "required",
    },
}

MODELS["NearbyTransitResponse"] = {
    "keys": {
        "route_id": "required",
        "stop_name": "required",
        "direction": "required",
        "destination": "optional",
        "minutes_away": "default",  # Int = 99, auto-synth -- RISKY
        "status": "required",
        "mode": "required",
        "stop_lat": "optional",
        "stop_lon": "optional",
        "arrival_ts": "optional",
        "vehicle_id": "optional",
        "trip_id": "optional",
        "stop_id": "optional",
        "distance_m": "optional",  # Double? = nil
        "is_real_time": "default",  # Bool = false, auto-synth -- RISKY
        "is_cancelled": "default",  # Bool = false, auto-synth -- RISKY
        "is_express": "default",  # Bool = false, auto-synth -- RISKY
    },
}

MODELS["DirectionArrivalsResponse"] = {
    "keys": {
        "direction": "required",
        "direction_label": "optional",
        "arrivals": "required",
    },
}

MODELS["InlineAlertResponse"] = {
    "keys": {
        "title": "required",
        "severity": "required",
        "affected_routes": "custom_safe",  # custom init
        "alert_type": "optional",
        "sort_order": "custom_safe",  # custom init
    },
}

MODELS["GroupedNearbyTransitResponse"] = {
    "keys": {
        "route_id": "required",
        "display_name": "required",
        "mode": "required",
        "color_hex": "optional",
        "directions": "required",
        "sorting_key": "default",  # String = "", auto-synth -- RISKY
        "alerts": "default",  # [InlineAlertResponse] = [], auto-synth -- RISKY
        "express_routes": "default",  # [String] = [], auto-synth -- RISKY
    },
}

MODELS["BusVehicleResponse"] = {
    "keys": {
        "vehicle_id": "required",
        "route_id": "required",
        "lat": "required",
        "lon": "required",
        "bearing": "optional",
        "next_stop": "optional",
        "status_text": "optional",
        "direction_ref": "optional",
        "expected_arrival": "optional",
        "onward_calls": "default",  # [BusArrival]? = [], auto-synth
        "is_realtime": "default",  # Bool = true, auto-synth -- RISKY
        "position_recorded_at": "optional",  # Date? = nil
    },
}

MODELS["DirectionShapeResponse"] = {
    "keys": {
        "direction_id": "required",
        "headsign": "required",
        "polylines": "required",
        "stops": "required",
        "service_type": "optional",
        "local_only_stop_ids": "custom_safe",  # custom init
    },
}

MODELS["RouteShapeResponse"] = {
    "keys": {
        "route_id": "required",
        "polylines": "required",
        "stops": "required",
        "directions": "required",
        "service_type": "optional",
    },
}

MODELS["SubwayLineOverlay"] = {
    "keys": {
        "route_id": "required",
        "color_hex": "required",
        "polylines": "required",
    },
}

MODELS["CrossingPoint"] = {
    "keys": {
        "lat": "required",
        "lng": "required",
        "trunk_indices": "required",
    },
}

MODELS["TrunkGroupPolylines"] = {
    "keys": {
        "trunk_index": "required",
        "color_hex": "required",
        "route_ids": "required",
        "polylines": "required",
        "lane_offset": "custom_safe",  # custom init
        "polyline_lane_offsets": "custom_safe",  # custom init
    },
}

MODELS["AllSubwayLinesResponse"] = {
    "keys": {
        "lines": "required",
        "trunk_polylines": "optional",
        "crossings": "optional",
    },
}

MODELS["CommuterRailStopOverlay"] = {
    "keys": {
        "stop_id": "required",
        "name": "required",
        "lat": "required",
        "lon": "required",
    },
}

MODELS["CommuterRailLineOverlay"] = {
    "keys": {
        "route_id": "required",
        "name": "required",
        "color_hex": "required",
        "polylines": "required",
        "mode": "required",
        "stops": "custom_safe",  # custom init
    },
}

MODELS["AllCommuterRailLinesResponse"] = {
    "keys": {
        "lines": "required",
    },
}

MODELS["SubwayStation"] = {
    "keys": {
        "id": "required",
        "name": "required",
        "lat": "required",
        "lon": "required",
        "routes": "required",
    },
}

MODELS["AllSubwayStationsResponse"] = {
    "keys": {
        "stations": "required",
    },
}

MODELS["ProcessedStopPosition"] = {
    "keys": {
        "route_id": "required",
        "lat": "required",
        "lon": "required",
    },
}

MODELS["ProcessedStation"] = {
    "keys": {
        "station_id": "required",
        "name": "required",
        "is_transfer": "required",
        "positions": "required",
    },
}

MODELS["ProcessedStationsResponse"] = {
    "keys": {
        "stations": "required",
    },
}

MODELS["DelayPrediction"] = {
    "keys": {
        "adjusted_minutes": "required",
        "original_minutes": "required",
        "delay_factor": "required",
        "adjustment_reason": "optional",
        "model_source": "required",
        "recency_error_seconds": "required",
    },
}

MODELS["TransitAlert"] = {
    "keys": {
        "route_id": "optional",
        "title": "required",
        "description": "required",
        "severity": "required",
        "mode": "custom_safe",  # custom init
        "updated_at": "optional",
        "affected_routes": "custom_safe",  # custom init
        "alert_type": "optional",
        "sort_order": "custom_safe",  # custom init
        "display_before_active": "optional",
        "active_period_end": "optional",
    },
}

MODELS["ElevatorStatus"] = {
    "keys": {
        "station": "required",
        "equipment_type": "required",
        "description": "required",
        "outage_since": "optional",
    },
}

MODELS["BusScheduleResponse_inner"] = {
    "keys": {
        "route_id": "required",
        "directions": "required",
    },
}


# ---------------------------------------------------------------------------
# Endpoints to test
# ---------------------------------------------------------------------------

ENDPOINTS = [
    {
        "name": "Subway Arrivals (A)",
        "url": f"{BASE}/subway/A",
        "model": "TransitArrivalResponse",
        "is_list": True,
    },
    {
        "name": "Nearby Bus Stops",
        "url": f"{BASE}/bus/nearby?lat={LAT}&lon={LON}&radius=400",
        "model": "BusStop",
        "is_list": True,
    },
    {
        "name": "Bus Live Arrivals (MTA_308214)",
        "url": f"{BASE}/bus/live/MTA_308214",
        "model": "BusArrival",
        "is_list": True,
    },
    {
        "name": "Bus Routes",
        "url": f"{BASE}/bus/routes",
        "model": "BusRoute",
        "is_list": True,
    },
    {
        "name": "Bus Schedule (M7)",
        "url": f"{BASE}/bus/schedule/M7",
        "model": "BusScheduleResponse",
        "is_list": False,
        "nested": [
            ("directions[]", "BusScheduleDirection"),
            ("directions[].departures[]", "BusScheduledDeparture"),
        ],
    },
    {
        "name": "Nearby Transit",
        "url": f"{BASE}/nearby?lat={LAT}&lon={LON}&radius=400",
        "model": "NearbyTransitResponse",
        "is_list": True,
    },
    {
        "name": "Nearby Grouped",
        "url": f"{BASE}/nearby/grouped?lat={LAT}&lon={LON}&radius=400",
        "model": "GroupedNearbyTransitResponse",
        "is_list": True,
        "nested": [
            ("directions[]", "DirectionArrivalsResponse"),
            ("directions[].arrivals[]", "NearbyTransitResponse"),
            ("alerts[]", "InlineAlertResponse"),
        ],
    },
    {
        "name": "Bus Vehicles (MTA NYCT_M7)",
        "url": f"{BASE}/bus/vehicles/MTA%20NYCT_M7",
        "model": "BusVehicleResponse",
        "is_list": True,
    },
    {
        "name": "Bus Route Shape (MTA NYCT_M7)",
        "url": f"{BASE}/bus/route-shape/MTA%20NYCT_M7",
        "model": "RouteShapeResponse",
        "is_list": False,
        "nested": [
            ("directions[]", "DirectionShapeResponse"),
            ("stops[]", "BusStop"),
            ("directions[].stops[]", "BusStop"),
        ],
    },
    {
        "name": "Subway Shape (A)",
        "url": f"{BASE}/subway/shape/A",
        "model": "RouteShapeResponse",
        "is_list": False,
        "nested": [
            ("directions[]", "DirectionShapeResponse"),
            ("stops[]", "BusStop"),
            ("directions[].stops[]", "BusStop"),
        ],
    },
    {
        "name": "LIRR Shape (1)",
        "url": f"{BASE}/lirr/shape/1",
        "model": "RouteShapeResponse",
        "is_list": False,
        "nested": [
            ("directions[]", "DirectionShapeResponse"),
        ],
    },
    {
        "name": "MNR Shape (1)",
        "url": f"{BASE}/mnr/shape/1",
        "model": "RouteShapeResponse",
        "is_list": False,
        "nested": [
            ("directions[]", "DirectionShapeResponse"),
        ],
    },
    {
        "name": "All Subway Shapes",
        "url": f"{BASE}/subway/shapes/all",
        "model": "AllSubwayLinesResponse",
        "is_list": False,
        "nested": [
            ("lines[]", "SubwayLineOverlay"),
            ("trunk_polylines[]", "TrunkGroupPolylines"),
            ("crossings[]", "CrossingPoint"),
        ],
    },
    {
        "name": "All LIRR Shapes",
        "url": f"{BASE}/lirr/shapes/all",
        "model": "AllCommuterRailLinesResponse",
        "is_list": False,
        "nested": [
            ("lines[]", "CommuterRailLineOverlay"),
            ("lines[].stops[]", "CommuterRailStopOverlay"),
        ],
    },
    {
        "name": "All MNR Shapes",
        "url": f"{BASE}/mnr/shapes/all",
        "model": "AllCommuterRailLinesResponse",
        "is_list": False,
        "nested": [
            ("lines[]", "CommuterRailLineOverlay"),
            ("lines[].stops[]", "CommuterRailStopOverlay"),
        ],
    },
    {
        "name": "All Subway Stations",
        "url": f"{BASE}/subway/stations/all",
        "model": "AllSubwayStationsResponse",
        "is_list": False,
        "nested": [
            ("stations[]", "SubwayStation"),
        ],
    },
    {
        "name": "Processed Stations",
        "url": f"{BASE}/subway/stations/processed",
        "model": "ProcessedStationsResponse",
        "is_list": False,
        "nested": [
            ("stations[]", "ProcessedStation"),
            ("stations[].positions[]", "ProcessedStopPosition"),
        ],
    },
    {
        "name": "Nearby Subway Stations",
        "url": f"{BASE}/subway/stations/nearby?lat={LAT}&lon={LON}&radius=1600",
        "model": "AllSubwayStationsResponse",
        "is_list": False,
        "nested": [
            ("stations[]", "SubwayStation"),
        ],
    },
    {
        "name": "Delay Prediction",
        "url": (
            f"{BASE}/predict/delay?minutes_away=5&route_id=A"
            f"&hour=12&day_of_week=3&weather=clear&mode=subway"
        ),
        "model": "DelayPrediction",
        "is_list": False,
    },
    {
        "name": "Alerts",
        "url": f"{BASE}/alerts",
        "model": "TransitAlert",
        "is_list": True,
    },
    {
        "name": "Accessibility",
        "url": f"{BASE}/accessibility",
        "model": "ElevatorStatus",
        "is_list": True,
    },
    {
        "name": "LIRR Arrivals",
        "url": f"{BASE}/lirr",
        "model": "TransitArrivalResponse",
        "is_list": True,
    },
    {
        "name": "MNR Arrivals",
        "url": f"{BASE}/mnr",
        "model": "TransitArrivalResponse",
        "is_list": True,
    },
]


def fetch(url: str, timeout: int = 30):
    """Fetch JSON from a URL, return parsed data or None on error."""
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return json.loads(raw)
    except urllib.error.HTTPError as exc:
        return {"__error__": f"HTTP {exc.code}"}
    except Exception as exc:
        return {"__error__": str(exc)}


def get_first_item(data, path: str):
    """Navigate into nested JSON.  path like 'directions[].arrivals[]'."""
    parts = path.split(".")
    current = data
    for part in parts:
        if part.endswith("[]"):
            key = part[:-2]
            if isinstance(current, list):
                current = current[0] if current else None
            if current is None:
                return None
            items = current.get(key, [])
            current = items[0] if items else None
        else:
            if isinstance(current, dict):
                current = current.get(part)
            else:
                return None
        if current is None:
            return None
    return current


def check_model(json_obj: dict, model_name: str) -> dict:
    """Compare JSON keys against Swift model expectations.

    Returns:
        {
            "missing_critical": [...],  # keys that would crash decode
            "missing_safe": [...],      # optional/custom_safe - won't crash
            "extra": [...],             # in JSON but not in model
        }
    """
    if model_name not in MODELS:
        return {"error": f"Unknown model: {model_name}"}

    expected = MODELS[model_name]["keys"]
    actual_keys = set(json_obj.keys()) if isinstance(json_obj, dict) else set()

    missing_critical = []
    missing_safe = []
    for key, kind in expected.items():
        if key not in actual_keys:
            if kind == "required":
                missing_critical.append(key)
            elif kind == "default":
                # auto-synthesized default — WILL crash if key missing
                missing_critical.append(f"{key} (default, no custom init!)")
            elif kind in ("optional", "custom_safe"):
                missing_safe.append(key)

    extra = sorted(actual_keys - set(expected.keys()))

    return {
        "missing_critical": missing_critical,
        "missing_safe": missing_safe,
        "extra": extra,
    }


def main():
    print("=" * 72)
    print("  Track API → Swift Model Compatibility Audit")
    print("=" * 72)
    print()

    total_pass = 0
    total_fail = 0
    total_warn = 0
    issues = []

    for ep in ENDPOINTS:
        name = ep["name"]
        url = ep["url"]
        model = ep["model"]
        is_list = ep.get("is_list", False)
        nested = ep.get("nested", [])

        print(f"▸ {name}")
        print(f"  GET {url.replace(BASE, '')}")

        data = fetch(url, timeout=60)
        if data is None:
            print("  ✗ No response")
            total_fail += 1
            issues.append((name, model, "No response"))
            print()
            continue

        if isinstance(data, dict) and "__error__" in data:
            print(f"  ✗ {data['__error__']}")
            total_fail += 1
            issues.append((name, model, data["__error__"]))
            print()
            continue

        # Get the first item for list endpoints
        if is_list:
            if not isinstance(data, list) or not data:
                print(f"  ⚠ Empty list or not a list (type={type(data).__name__})")
                total_warn += 1
                print()
                continue
            item = data[0]
            print(f"  ✓ Got {len(data)} items")
        else:
            item = data
            print(f"  ✓ Got response ({len(json.dumps(data)):,} bytes)")

        # Check top-level model
        result = check_model(item, model)
        _report_result(name, model, result, issues)
        if result.get("missing_critical"):
            total_fail += 1
        elif result.get("extra"):
            total_pass += 1
        else:
            total_pass += 1

        # Check nested models
        for path, nested_model in nested:
            nested_item = get_first_item(data if not is_list else data[0] if data else {},
                                          path)
            if nested_item is None:
                print(f"    ⚠ {path} → {nested_model}: no data to check")
                total_warn += 1
                continue
            nr = check_model(nested_item, nested_model)
            _report_result(f"{name}.{path}", nested_model, nr, issues)
            if nr.get("missing_critical"):
                total_fail += 1
            else:
                total_pass += 1

        print()

    # Summary
    print("=" * 72)
    print(f"  RESULTS: {total_pass} OK  |  {total_fail} FAIL  |  {total_warn} WARN")
    print("=" * 72)

    if issues:
        print("\n  ISSUES TO FIX:")
        for name, model, detail in issues:
            print(f"    • {name} ({model}): {detail}")
    else:
        print("\n  ✓ All models match their API responses perfectly!")

    return 1 if total_fail > 0 else 0


def _report_result(name, model, result, issues):
    if result.get("error"):
        print(f"    ✗ {model}: {result['error']}")
        issues.append((name, model, result["error"]))
        return

    missing_crit = result["missing_critical"]
    missing_safe = result["missing_safe"]
    extra = result["extra"]

    if missing_crit:
        print(f"    ✗ {model}: MISSING CRITICAL keys → {missing_crit}")
        issues.append(
            (name, model, f"Missing critical: {missing_crit}")
        )
    else:
        print(f"    ✓ {model}: all required keys present")

    if missing_safe:
        print(f"      ℹ safe-missing (optional/custom): {missing_safe}")

    if extra:
        print(f"      + extra keys in JSON (harmless): {extra}")


if __name__ == "__main__":
    sys.exit(main())
