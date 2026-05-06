#!/usr/bin/env python3
"""
capture_contract_fixtures.py — capture real backend responses for the
heavy iOS↔backend contract test.

Hits every endpoint the iOS app decodes through `TrackAPI`, persists the
raw JSON body to `TrackTests/Fixtures/Contract/<slug>.json`, and emits a
`manifest.json` enumerating each fixture together with the Swift
Codable type that must decode it.

The companion XCTest (`TrackTests/ContractFixtureDecodeTests.swift`)
loads the manifest and decodes each fixture through the *real* iOS
Codable models — catching every drift between Pydantic and Swift before
it ships.

Usage:
    cd TrackBackend
    .venv/bin/python scripts/capture_contract_fixtures.py
    # Override server: TRACK_BASE=http://127.0.0.1:8001 .venv/bin/python ...

The server must already be running (e.g. `python run.py`).
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

try:
    import httpx
except ImportError:  # pragma: no cover - dev-only helper script
    print("ERROR: httpx not installed. Run: pip install httpx")
    sys.exit(1)


BASE = os.environ.get("TRACK_BASE", "http://127.0.0.1:8000")
TIMEOUT = 60.0

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = REPO_ROOT / "TrackTests" / "Fixtures" / "Contract"


@dataclass
class EndpointSpec:
    """Single endpoint capture descriptor.

    `slug` becomes the fixture filename; `swift_type` names the iOS
    Codable type the XCTest must decode the saved JSON through.
    """

    slug: str
    path: str
    swift_type: str  # e.g. "[TransitArrivalResponse]" or "RouteShapeResponse"
    params: dict[str, Any] = field(default_factory=dict)
    # When True, an empty array response is acceptable but does NOT prove
    # the schema (no objects to decode). The Swift test will still attempt
    # the decode and only flag truly malformed payloads.
    allow_empty: bool = False


# Realistic GPS / IDs known to return populated payloads.
PENN_LAT, PENN_LON = 40.7505, -73.9934
RADIUS = 800
MANHATTAN_LAT, MANHATTAN_LON = 40.7580, -73.9855
SAMPLE_BUS_ROUTE = "MTA NYCT_M15"
SAMPLE_BUS_STOP = "MTA_305168"


ENDPOINTS: list[EndpointSpec] = [
    # Config
    # `/config` is consumed by iOS as a raw `[String: Any]` dictionary —
    # use the magic type `__rawJSON__` so the Swift test only validates
    # that the payload is well-formed JSON.
    EndpointSpec("config", "/config", "__rawJSON__"),
    # Subway arrivals (lines that consistently have data)
    EndpointSpec("subway_A", "/subway/A", "[TransitArrivalResponse]", allow_empty=True),
    EndpointSpec("subway_1", "/subway/1", "[TransitArrivalResponse]", allow_empty=True),
    EndpointSpec("subway_7", "/subway/7", "[TransitArrivalResponse]", allow_empty=True),
    EndpointSpec("subway_L", "/subway/L", "[TransitArrivalResponse]", allow_empty=True),
    # Subway shapes / stations
    EndpointSpec("subway_shapes_all", "/subway/shapes/all", "AllSubwayLinesResponse"),
    EndpointSpec("subway_stations_all", "/subway/stations/all", "AllSubwayStationsResponse"),
    EndpointSpec(
        "subway_stations_processed",
        "/subway/stations/processed",
        "ProcessedStationsResponse",
    ),
    EndpointSpec(
        "subway_stations_nearby",
        "/subway/stations/nearby",
        "AllSubwayStationsResponse",
        params={"lat": PENN_LAT, "lon": PENN_LON, "radius": RADIUS},
    ),
    EndpointSpec("subway_shape_A", "/subway/shape/A", "RouteShapeResponse"),
    EndpointSpec("subway_shape_7", "/subway/shape/7", "RouteShapeResponse"),
    EndpointSpec("subway_vehicles_A", "/subway/vehicles/A", "[TrainVehicle]", allow_empty=True),
    EndpointSpec(
        "subway_live_vehicles_A",
        "/subway/live-vehicles/A",
        "[LiveVehicleDetailResponse]",
        allow_empty=True,
    ),
    # Bus
    EndpointSpec("bus_routes", "/bus/routes", "[BusRoute]"),
    EndpointSpec(
        "bus_nearby",
        "/bus/nearby",
        "[BusStop]",
        params={"lat": PENN_LAT, "lon": PENN_LON, "radius": RADIUS},
    ),
    EndpointSpec("bus_live_stop", f"/bus/live/{SAMPLE_BUS_STOP}", "[BusArrival]", allow_empty=True),
    EndpointSpec(
        "bus_vehicles_M15",
        f"/bus/vehicles/{SAMPLE_BUS_ROUTE}",
        "[BusVehicleResponse]",
        allow_empty=True,
    ),
    EndpointSpec(
        "bus_live_vehicles_M15",
        f"/bus/live-vehicles/{SAMPLE_BUS_ROUTE}",
        "[LiveVehicleDetailResponse]",
        allow_empty=True,
    ),
    EndpointSpec(
        "bus_route_shape_M15",
        f"/bus/route-shape/{SAMPLE_BUS_ROUTE}",
        "RouteShapeResponse",
    ),
    EndpointSpec(
        "bus_schedule_M15",
        f"/bus/schedule/{SAMPLE_BUS_ROUTE}",
        "BusScheduleResponse",
    ),
    EndpointSpec("bus_tile_data", "/bus/tile-data", "BusTileDataResponse"),
    # Commuter rail
    EndpointSpec(
        "lirr",
        "/lirr",
        "[TransitArrivalResponse]",
        params={"lat": PENN_LAT, "lon": PENN_LON},
        allow_empty=True,
    ),
    EndpointSpec("lirr_shapes_all", "/lirr/shapes/all", "AllCommuterRailLinesResponse"),
    EndpointSpec(
        "mnr",
        "/mnr",
        "[TransitArrivalResponse]",
        params={"lat": PENN_LAT, "lon": PENN_LON},
        allow_empty=True,
    ),
    EndpointSpec("mnr_shapes_all", "/mnr/shapes/all", "AllCommuterRailLinesResponse"),
    # Nearby
    EndpointSpec(
        "nearby",
        "/nearby",
        "[NearbyTransitResponse]",
        params={"lat": PENN_LAT, "lon": PENN_LON, "radius": RADIUS},
    ),
    EndpointSpec(
        "nearby_grouped",
        "/nearby/grouped",
        "[GroupedNearbyTransitResponse]",
        params={"lat": PENN_LAT, "lon": PENN_LON, "radius": RADIUS},
    ),
    EndpointSpec(
        "nearby_grouped_subway",
        "/nearby/grouped",
        "[GroupedNearbyTransitResponse]",
        params={
            "lat": PENN_LAT,
            "lon": PENN_LON,
            "radius": RADIUS,
            "mode": "subway",
        },
    ),
    EndpointSpec(
        "nearby_grouped_bus",
        "/nearby/grouped",
        "[GroupedNearbyTransitResponse]",
        params={"lat": PENN_LAT, "lon": PENN_LON, "radius": RADIUS, "mode": "bus"},
    ),
    EndpointSpec(
        "nearby_inactive",
        "/nearby/inactive",
        "[InactiveRouteResponse]",
        params={"lat": MANHATTAN_LAT, "lon": MANHATTAN_LON, "radius": RADIUS},
        allow_empty=True,
    ),
    # System
    EndpointSpec("alerts", "/alerts", "[TransitAlert]", allow_empty=True),
    EndpointSpec("accessibility", "/accessibility", "[ElevatorStatus]", allow_empty=True),
    EndpointSpec(
        "predict_delay",
        "/predict/delay",
        "DelayPrediction",
        params={"minutes_away": 5, "route_id": "A", "hour": 8},
    ),
]


def _capture_one(client: httpx.Client, spec: EndpointSpec) -> dict[str, Any]:
    """Hit one endpoint and persist its body. Returns manifest entry."""
    url = f"{BASE}{spec.path}"
    qs = f"?{urlencode(spec.params)}" if spec.params else ""
    full = f"{url}{qs}"

    try:
        r = client.get(url, params=spec.params or None)
    except httpx.HTTPError as exc:
        return {
            "slug": spec.slug,
            "path": spec.path,
            "params": spec.params,
            "status": 0,
            "swift_type": spec.swift_type,
            "skipped": True,
            "reason": f"network error: {exc!r}",
        }

    body_bytes = r.content
    fixture_path = FIXTURE_DIR / f"{spec.slug}.json"

    skipped = False
    reason: str | None = None
    if r.status_code != 200:
        skipped = True
        reason = f"status {r.status_code}"
    else:
        try:
            parsed = json.loads(body_bytes)
        except json.JSONDecodeError as exc:
            skipped = True
            reason = f"non-JSON body: {exc!r}"
        else:
            is_empty = parsed in ([], {}, None)
            if is_empty and not spec.allow_empty:
                skipped = True
                reason = "empty payload (no objects to decode)"
            else:
                # Pretty-print so diffs against fixtures are reviewable.
                fixture_path.write_text(
                    json.dumps(parsed, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8",
                )

    return {
        "slug": spec.slug,
        "path": spec.path,
        "params": spec.params,
        "url": full,
        "status": r.status_code,
        "swift_type": spec.swift_type,
        "fixture_file": f"{spec.slug}.json" if not skipped else None,
        "bytes": len(body_bytes),
        "skipped": skipped,
        "reason": reason,
    }


def main() -> int:
    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)

    print(f"📡 Capturing contract fixtures from {BASE}")
    print(f"   → {FIXTURE_DIR.relative_to(REPO_ROOT)}")
    print()

    # Bail early if server is unreachable.
    try:
        httpx.get(f"{BASE}/alerts", timeout=5.0)
    except httpx.ConnectError:
        print(f"❌ Cannot reach {BASE}. Start the backend first:")
        print("     cd TrackBackend && python run.py")
        return 1

    manifest: list[dict[str, Any]] = []
    captured = 0
    skipped = 0

    with httpx.Client(timeout=TIMEOUT) as client:
        for spec in ENDPOINTS:
            entry = _capture_one(client, spec)
            manifest.append(entry)
            if entry["skipped"]:
                skipped += 1
                print(
                    f"  ⏭  {spec.slug:<32s} {entry['status']:>4}"
                    f"  ({entry['reason']})"
                )
            else:
                captured += 1
                print(
                    f"  ✅ {spec.slug:<32s} {entry['status']:>4}"
                    f"  {entry['bytes']:>8,d} bytes  → {spec.swift_type}"
                )

    manifest_path = FIXTURE_DIR / "manifest.json"
    manifest_payload = {
        "captured_at": datetime.now(UTC).isoformat(),
        "base_url": BASE,
        "entries": manifest,
    }
    manifest_path.write_text(
        json.dumps(manifest_payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    print()
    print(f"📄 Manifest: {manifest_path.relative_to(REPO_ROOT)}")
    print(f"   {captured} captured, {skipped} skipped, {len(manifest)} total")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
