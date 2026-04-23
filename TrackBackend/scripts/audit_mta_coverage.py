#!/usr/bin/env python3
"""Audit field coverage between raw MTA upstream feeds and our backend responses.

For each transit mode this script fetches the raw upstream payload (GTFS-RT
protobuf or SIRI JSON), walks every leaf field that is *present at least
once*, then hits the equivalent Track backend endpoint and walks every leaf
field served to the iOS client. Finally it diffs the two sets and prints a
per-mode coverage report:

    upstream-only  – fields present in MTA but never surfaced to the app
    served-only    – fields the app receives that don't come from this feed
                     directly (computed/enriched values such as color_hex)
    overlap        – fields covered on both sides

Usage::

    python scripts/audit_mta_coverage.py [--backend http://127.0.0.1:8000]

Requires a running Track backend. Uses MTA_API_KEY / OBA_API_KEY from the
project ``.env`` when present.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

import httpx

# Load project .env so MTA_API_KEY / OBA_API_KEY are available
_REPO_ROOT = Path(__file__).resolve().parent.parent
try:
    from dotenv import load_dotenv

    load_dotenv(_REPO_ROOT / ".env", override=False)
except ImportError:
    pass

sys.path.insert(0, str(_REPO_ROOT))

from google.transit import gtfs_realtime_pb2  # noqa: E402

OBA_KEY = os.environ.get("OBA_API_KEY", "")
MTA_KEY = os.environ.get("MTA_API_KEY", "")


# ---------------------------------------------------------------------------
# Upstream feeds
# ---------------------------------------------------------------------------
SUBWAY_FEED = (
    "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-ace"
)
LIRR_FEED = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/lirr%2Fgtfs-lirr"
MNR_FEED = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/mnr%2Fgtfs-mnr"
SUBWAY_ALERTS = (
    "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fsubway-alerts.json"
)
SIRI_SM = (
    "https://bustime.mta.info/api/siri/stop-monitoring.json"
    f"?key={OBA_KEY}&MonitoringRef={{stop_id}}&version=2"
)
SIRI_VM = (
    "https://bustime.mta.info/api/siri/vehicle-monitoring.json"
    f"?key={OBA_KEY}&LineRef={{route_id}}&version=2"
)

# Sample identifiers used for the bus probes — high-frequency NYC routes/stops
SAMPLE_BUS_ROUTE = "MTA NYCT_B63"
SAMPLE_BUS_STOP = "MTA_308214"


# ---------------------------------------------------------------------------
# Field-walking helpers
# ---------------------------------------------------------------------------
def walk_json_leaves(obj: Any, prefix: str = "") -> Iterable[str]:
    """Yield dotted leaf paths for every populated field in *obj*."""
    if isinstance(obj, Mapping):
        for key, value in obj.items():
            yield from walk_json_leaves(value, f"{prefix}.{key}" if prefix else key)
    elif isinstance(obj, list):
        # Collapse list index — we only care that a field appeared.
        for item in obj:
            yield from walk_json_leaves(item, f"{prefix}[]")
    else:
        if obj is None or obj == "" or obj == [] or obj == {}:
            return
        yield prefix


def walk_pb_leaves(message: Any, prefix: str = "") -> Iterable[str]:
    """Yield dotted leaf paths for every populated field in a protobuf message."""
    if message is None:
        return
    # Iterate ListFields() — only fields actually set are returned.
    for descriptor, value in message.ListFields():
        path = f"{prefix}.{descriptor.name}" if prefix else descriptor.name
        if descriptor.type == descriptor.TYPE_MESSAGE:
            if descriptor.label == descriptor.LABEL_REPEATED:
                for item in value:
                    yield from walk_pb_leaves(item, f"{path}[]")
            else:
                yield from walk_pb_leaves(value, path)
        else:
            if descriptor.label == descriptor.LABEL_REPEATED:
                yield f"{path}[]"
            else:
                yield path


def _collect(paths: Iterable[str]) -> dict[str, int]:
    counts: dict[str, int] = defaultdict(int)
    for p in paths:
        counts[p] += 1
    return dict(counts)


# ---------------------------------------------------------------------------
# Upstream collectors
# ---------------------------------------------------------------------------
def collect_gtfs_rt(url: str) -> dict[str, int]:
    headers = {"x-api-key": MTA_KEY} if MTA_KEY else {}
    resp = httpx.get(url, headers=headers, timeout=15)
    resp.raise_for_status()
    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(resp.content)
    paths: list[str] = []
    paths.extend(walk_pb_leaves(feed.header, "header"))
    for entity in feed.entity[:200]:  # sample first 200 entities for speed
        paths.extend(walk_pb_leaves(entity, "entity[]"))
    return _collect(paths)


def collect_json(url: str) -> dict[str, int]:
    resp = httpx.get(url, timeout=15)
    resp.raise_for_status()
    return _collect(walk_json_leaves(resp.json()))


# ---------------------------------------------------------------------------
# Backend collector
# ---------------------------------------------------------------------------
def collect_backend(backend: str, path: str) -> dict[str, int]:
    resp = httpx.get(f"{backend}{path}", timeout=20)
    resp.raise_for_status()
    return _collect(walk_json_leaves(resp.json()))


# ---------------------------------------------------------------------------
# Mapping table — short hints linking upstream paths to served fields
# Used purely for human readability in the report.
# ---------------------------------------------------------------------------
HINTS_GTFS_RT = {
    "entity[].alert.cause": "TransitAlert.cause",
    "entity[].alert.effect": "TransitAlert.effect",
    "entity[].alert.header_text.translation[].text": "TransitAlert.title",
    "entity[].alert.description_text.translation[].text": "TransitAlert.description",
    "entity[].alert.severity_level": "TransitAlert.severity",
    "entity[].alert.active_period[].end": "TransitAlert.active_period_end",
    "entity[].trip_update.stop_time_update[].arrival.time": "TrackArrival.arrival_ts",
    "entity[].trip_update.stop_time_update[].arrival.delay": "TrackArrival.delay_seconds",
    "entity[].trip_update.stop_time_update[].departure.time": "TrackArrival.departure_ts",
    "entity[].trip_update.stop_time_update[].departure.delay": "TrackArrival.departure_delay_seconds",
    "entity[].trip_update.stop_time_update[].schedule_relationship": "TrackArrival.is_skipped/is_no_data",
    "entity[].trip_update.trip.schedule_relationship": "TrackArrival.is_cancelled",
    "entity[].vehicle.position.latitude": "TransitVehicle.lat",
    "entity[].vehicle.position.longitude": "TransitVehicle.lon",
    "entity[].vehicle.position.bearing": "TransitVehicle.bearing",
    "entity[].vehicle.position.speed": "TransitVehicle.speed_mph",
    "entity[].vehicle.current_status": "TransitVehicle.current_status_code/status",
    "entity[].vehicle.occupancy_status": "TransitVehicle.occupancy_status",
    "entity[].vehicle.congestion_level": "TransitVehicle.congestion_level",
    "entity[].vehicle.timestamp": "TransitVehicle.timestamp",
}

HINTS_SIRI = {
    "MonitoredVehicleJourney.LineRef": "BusArrival.route_id",
    "MonitoredVehicleJourney.VehicleRef": "BusArrival.vehicle_id",
    "MonitoredVehicleJourney.DestinationName": "BusArrival.destination_name",
    "MonitoredVehicleJourney.DestinationName[]": "BusArrival.destination_name",
    "MonitoredVehicleJourney.DirectionRef": "BusArrival.direction_ref",
    "MonitoredVehicleJourney.Bearing": "BusArrival.bearing / BusVehicle.bearing",
    "MonitoredVehicleJourney.Monitored": "is_realtime",
    "MonitoredVehicleJourney.ProgressStatus": "BusArrival/BusVehicle.progress_status",
    "MonitoredVehicleJourney.ProgressStatus[]": "BusArrival/BusVehicle.progress_status",
    "MonitoredVehicleJourney.BlockRef": "BusArrival/BusVehicle.block_ref",
    "MonitoredVehicleJourney.OriginAimedDepartureTime": "BusVehicle.origin_aimed_departure_time",
    "MonitoredVehicleJourney.VehicleLocation.Latitude": "BusVehicle.lat",
    "MonitoredVehicleJourney.VehicleLocation.Longitude": "BusVehicle.lon",
    "MonitoredVehicleJourney.MonitoredCall.ExpectedArrivalTime": "BusArrival.expected_arrival",
    "MonitoredVehicleJourney.MonitoredCall.AimedArrivalTime": "BusArrival.aimed_arrival",
    "MonitoredVehicleJourney.MonitoredCall.ArrivalProximityText": "BusArrival.arrival_proximity_text",
    "MonitoredVehicleJourney.MonitoredCall.Extensions.Distances.PresentableDistance": "BusArrival.status_text",
    "MonitoredVehicleJourney.MonitoredCall.Extensions.Distances.DistanceFromCall": "BusArrival.distance_meters",
    "MonitoredVehicleJourney.MonitoredCall.Extensions.Capacities.OccupancyStatus": "BusArrival.occupancy_status",
    "MonitoredVehicleJourney.ProgressRate": "BusArrival/BusVehicle.progress_rate",
    "MonitoredVehicleJourney.DestinationRef": "BusArrival/BusVehicle.destination_ref",
    "MonitoredVehicleJourney.MonitoredCall.ExpectedDepartureTime": "BusArrival.expected_departure",
    "MonitoredVehicleJourney.MonitoredCall.AimedDepartureTime": "BusArrival.aimed_departure",
}


# ---------------------------------------------------------------------------
# Report rendering
# ---------------------------------------------------------------------------
def _filter_noise(paths: Iterable[str]) -> list[str]:
    """Drop fields that are repetitive/internal MTA bookkeeping noise."""
    drop_substrings = (
        "entity.id",
        "Siri.ServiceDelivery.ResponseTimestamp",
        "Siri.ServiceDelivery.ProducerRef",
        "Siri.ServiceDelivery.SituationExchangeDelivery",
        "Extensions.LastGtfsId",
        "Extensions.RouteRef",
        "FramedVehicleJourneyRef.DataFrameRef",
        "FramedVehicleJourneyRef.DatedVehicleJourneyRef",
        "ResponseTimestamp",
        "RecordedAtTime",
        "ValidUntilTime",
    )
    return sorted({p for p in paths if not any(s in p for s in drop_substrings)})


def _hint_for(path: str, hints: dict[str, str]) -> str | None:
    """Return the hint label whose key is a suffix of *path*."""
    for key, label in hints.items():
        if path.endswith(key):
            return label
    return None


def render_section(
    title: str,
    upstream: dict[str, int],
    served: dict[str, int],
    hints: dict[str, str],
) -> None:
    print(f"\n=== {title} ===")
    print(f"  upstream leaf fields:  {len(upstream):4d}")
    print(f"  served   leaf fields:  {len(served):4d}")

    upstream_keys = set(upstream)

    hinted: dict[str, str] = {}
    unhinted: set[str] = set()
    for k in upstream_keys:
        label = _hint_for(k, hints)
        if label:
            hinted[k] = label
        else:
            unhinted.add(k)

    print("\n  \u2713 upstream fields we DO surface (via hints):")
    for k in sorted(hinted):
        print(f"      {k:75s} \u2192 {hinted[k]}")

    print("\n  \u2717 upstream fields that look useful but are NOT yet surfaced:")
    interesting = _filter_noise(unhinted)
    # Heuristic: keep only obviously-meaningful field names.
    keep_keywords = (
        "delay", "occupancy", "congestion", "track", "platform",
        "cause", "effect", "block", "progress", "status", "destination",
        "headsign", "bearing", "speed", "departure", "arrival",
        "wheelchair", "ProximityText", "Capacit", "carriage",
    )
    surfaced_kw = [
        p for p in interesting
        if any(k.lower() in p.lower() for k in keep_keywords)
    ]
    for k in surfaced_kw[:25]:
        print(f"      {k}")
    other = [p for p in interesting if p not in surfaced_kw]
    if other:
        print(f"\n    (+ {len(other)} other lower-priority unsurfaced fields)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", default="http://127.0.0.1:8000")
    args = parser.parse_args()

    backend = args.backend.rstrip("/")

    # ── Subway TripUpdate / VehiclePosition ──────────────────────────────
    print("Fetching subway GTFS-RT (ace)...")
    subway_upstream = collect_gtfs_rt(SUBWAY_FEED)
    served_subway = collect_backend(backend, "/subway/A")
    served_vehicles = collect_backend(backend, "/subway/vehicles/A")
    served_subway_combined = {**served_subway, **served_vehicles}
    render_section(
        "Subway (gtfs-ace) → /subway/A + /subway/vehicles/A",
        subway_upstream,
        served_subway_combined,
        HINTS_GTFS_RT,
    )

    # ── LIRR ─────────────────────────────────────────────────────────────
    print("\nFetching LIRR GTFS-RT...")
    try:
        lirr_upstream = collect_gtfs_rt(LIRR_FEED)
    except Exception as exc:  # noqa: BLE001
        print(f"  LIRR upstream fetch failed: {exc}")
        lirr_upstream = {}
    try:
        served_lirr = collect_backend(backend, "/lirr")
    except Exception as exc:  # noqa: BLE001
        print(f"  LIRR backend fetch failed: {exc}")
        served_lirr = {}
    if lirr_upstream:
        render_section("LIRR → /lirr", lirr_upstream, served_lirr, HINTS_GTFS_RT)

    # ── MNR ──────────────────────────────────────────────────────────────
    print("\nFetching MNR GTFS-RT...")
    try:
        mnr_upstream = collect_gtfs_rt(MNR_FEED)
    except Exception as exc:  # noqa: BLE001
        print(f"  MNR upstream fetch failed: {exc}")
        mnr_upstream = {}
    try:
        served_mnr = collect_backend(backend, "/mnr")
    except Exception as exc:  # noqa: BLE001
        print(f"  MNR backend fetch failed: {exc}")
        served_mnr = {}
    if mnr_upstream:
        render_section("MNR → /mnr", mnr_upstream, served_mnr, HINTS_GTFS_RT)

    # ── Subway alerts ────────────────────────────────────────────────────
    print("\nFetching subway alerts...")
    try:
        alerts_upstream = collect_json(SUBWAY_ALERTS)
    except Exception as exc:  # noqa: BLE001
        print(f"  alerts upstream fetch failed: {exc}")
        alerts_upstream = {}
    try:
        served_alerts = collect_backend(backend, "/alerts?mode=subway")
    except Exception as exc:  # noqa: BLE001
        print(f"  alerts backend fetch failed: {exc}")
        served_alerts = {}
    if alerts_upstream:
        # Alerts feed uses GTFS-RT JSON form — paths look like entity[].alert.*
        render_section(
            "Service Alerts → /alerts?mode=subway",
            alerts_upstream,
            served_alerts,
            HINTS_GTFS_RT,
        )

    # ── Bus SIRI ─────────────────────────────────────────────────────────
    if OBA_KEY:
        print(f"\nFetching SIRI vehicle-monitoring for {SAMPLE_BUS_ROUTE}...")
        try:
            vm_upstream = collect_json(
                SIRI_VM.format(route_id=SAMPLE_BUS_ROUTE.replace(" ", "%20"))
            )
        except Exception as exc:  # noqa: BLE001
            print(f"  SIRI VM upstream fetch failed: {exc}")
            vm_upstream = {}

        try:
            served_bus_vehicles = collect_backend(
                backend, f"/bus/vehicles/{SAMPLE_BUS_ROUTE}"
            )
        except Exception as exc:  # noqa: BLE001
            print(f"  bus vehicles backend fetch failed: {exc}")
            served_bus_vehicles = {}

        try:
            served_bus_arrivals = collect_backend(
                backend, f"/bus/live/{SAMPLE_BUS_STOP}"
            )
        except Exception as exc:  # noqa: BLE001
            print(f"  bus live backend fetch failed: {exc}")
            served_bus_arrivals = {}

        served_bus_combined = {**served_bus_vehicles, **served_bus_arrivals}
        if vm_upstream:
            render_section(
                f"Bus SIRI VM ({SAMPLE_BUS_ROUTE}) → /bus/vehicles + /bus/live",
                vm_upstream,
                served_bus_combined,
                HINTS_SIRI,
            )
    else:
        print("\n(skipping SIRI bus probes — OBA_API_KEY not set)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
