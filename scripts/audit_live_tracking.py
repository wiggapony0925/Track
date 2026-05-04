#!/usr/bin/env python3
"""Audit Track live vehicle tracking against Transit-style nearby realtime data.

The goal is to test the frontend contract, not just whether endpoints return 200:

* buses need stable vehicle IDs, real coordinates, direction refs/destinations,
  and onward calls so chips can stay synced with markers;
* trains need stable trip/vehicle IDs, coordinates or stop-anchored positions,
  current stop/status data, and route IDs so the map can filter by direction;
* Transit API sampling is optional, cached, and quota-limited.
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import statistics
import time
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "test_output" / "live_tracking_audit.json"
DEFAULT_CACHE = ROOT / "test_output" / "transit_api_cache.json"
TRANSIT_BASE_URL = "https://external.transitapp.com/v3/public"


@dataclass
class VehicleIssue:
    severity: str
    message: str
    vehicle_id: str | None = None


@dataclass
class TrackVehicleSummary:
    mode: str
    route_id: str
    endpoint: str
    vehicle_count: int
    realtime_count: int = 0
    with_position_count: int = 0
    with_stable_identity_count: int = 0
    with_trip_id_count: int = 0
    with_next_stop_count: int = 0
    with_onward_calls_count: int = 0
    with_confidence_count: int = 0
    stale_position_count: int = 0
    position_source_counts: dict[str, int] = field(default_factory=dict)
    sample_vehicle_ids: list[str] = field(default_factory=list)
    issues: list[VehicleIssue] = field(default_factory=list)
    elapsed_ms: float = 0.0


@dataclass
class TransitNearbySummary:
    lat: float
    lon: float
    route_count: int
    departure_count: int
    realtime_departure_count: int
    sample_routes: list[dict[str, Any]] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)
    elapsed_ms: float = 0.0


class JsonClient:
    def __init__(self) -> None:
        self.ssl_context = self._ssl_context()

    @staticmethod
    def _ssl_context() -> ssl.SSLContext:
        try:
            import certifi

            return ssl.create_default_context(cafile=certifi.where())
        except Exception:
            return ssl.create_default_context()

    def get_json(self, url: str, headers: dict[str, str] | None = None) -> Any:
        request = urllib.request.Request(
            url,
            headers=headers or {"User-Agent": "Track-live-tracking-audit/1.0"},
        )
        with urllib.request.urlopen(request, timeout=30, context=self.ssl_context) as response:
            return json.loads(response.read().decode("utf-8"))


class TransitClient(JsonClient):
    def __init__(
        self,
        api_key: str,
        cache_path: Path,
        max_calls: int,
        min_interval_s: float,
    ) -> None:
        super().__init__()
        self.api_key = api_key
        self.cache_path = cache_path
        self.max_calls = max_calls
        self.min_interval_s = min_interval_s
        self.calls_made = 0
        self.last_call_at = 0.0
        self.cache: dict[str, Any] = {}
        if cache_path.exists():
            self.cache = json.loads(cache_path.read_text(encoding="utf-8"))

    def save_cache(self) -> None:
        self.cache_path.parent.mkdir(parents=True, exist_ok=True)
        self.cache_path.write_text(
            json.dumps(self.cache, indent=2, sort_keys=True),
            encoding="utf-8",
        )

    def get_public_json(self, path: str, params: dict[str, Any]) -> Any:
        query = urllib.parse.urlencode(params)
        url = f"{TRANSIT_BASE_URL}{path}?{query}"
        if url in self.cache:
            return self.cache[url]
        if self.calls_made >= self.max_calls:
            raise RuntimeError(f"Transit call cap reached ({self.max_calls})")

        wait_s = self.min_interval_s - (time.monotonic() - self.last_call_at)
        if wait_s > 0:
            time.sleep(wait_s)

        payload = self.get_json(
            url,
            headers={
                "apiKey": self.api_key,
                "Accept-Language": "en",
                "User-Agent": "Track-live-tracking-audit/1.0",
            },
        )
        self.calls_made += 1
        self.last_call_at = time.monotonic()
        self.cache[url] = payload
        self.save_cache()
        return payload


def _track_url(base_url: str, path: str) -> str:
    return base_url.rstrip("/") + path


def _valid_coord(lat: Any, lon: Any) -> bool:
    return isinstance(lat, (int, float)) and isinstance(lon, (int, float)) and lat != 0 and lon != 0


def _parse_iso_epoch(value: Any) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        from datetime import datetime

        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def _position_age_s(vehicle: dict[str, Any]) -> float | None:
    if isinstance(vehicle.get("timestamp"), (int, float)):
        return time.time() - float(vehicle["timestamp"])
    recorded_at = _parse_iso_epoch(vehicle.get("position_recorded_at"))
    if recorded_at is not None:
        return time.time() - recorded_at
    return None


def _record_quality_metadata(summary: TrackVehicleSummary, vehicle: dict[str, Any]) -> None:
    confidence = vehicle.get("position_confidence")
    if isinstance(confidence, (int, float)):
        summary.with_confidence_count += 1
        if confidence < 0.5:
            summary.issues.append(
                VehicleIssue(
                    "warning",
                    f"vehicle confidence below visible threshold ({confidence:.2f})",
                    vehicle.get("vehicle_id"),
                )
            )

    source = vehicle.get("position_source")
    if isinstance(source, str) and source:
        summary.position_source_counts[source] = summary.position_source_counts.get(source, 0) + 1


def audit_track_bus(client: JsonClient, base_url: str, route_id: str) -> TrackVehicleSummary:
    encoded = urllib.parse.quote(route_id, safe="")
    endpoint = f"/bus/live-vehicles/{encoded}"
    start = time.perf_counter()
    try:
        vehicles = client.get_json(_track_url(base_url, endpoint))
        uses_live_detail = True
    except Exception:
        endpoint = f"/bus/vehicles/{encoded}"
        vehicles = client.get_json(_track_url(base_url, endpoint))
        uses_live_detail = False
    elapsed_ms = (time.perf_counter() - start) * 1000
    summary = TrackVehicleSummary(
        mode="bus",
        route_id=route_id,
        endpoint=endpoint,
        vehicle_count=len(vehicles or []),
        elapsed_ms=elapsed_ms,
    )
    for vehicle in vehicles or []:
        vehicle_id = vehicle.get("vehicle_id")
        _record_quality_metadata(summary, vehicle)
        if vehicle_id:
            summary.with_stable_identity_count += 1
            if len(summary.sample_vehicle_ids) < 8:
                summary.sample_vehicle_ids.append(str(vehicle_id))
        else:
            summary.issues.append(VehicleIssue("error", "bus missing vehicle_id"))
        if vehicle.get("is_realtime") is True:
            summary.realtime_count += 1
        if _valid_coord(vehicle.get("lat"), vehicle.get("lon")):
            summary.with_position_count += 1
        else:
            summary.issues.append(VehicleIssue("error", "bus missing valid lat/lon", vehicle_id))
        if vehicle.get("next_stop_id") or vehicle.get("next_stop"):
            summary.with_next_stop_count += 1
        if vehicle.get("downstream_stop_count", 0) > 0 or vehicle.get("onward_calls"):
            summary.with_onward_calls_count += 1
        age_s = vehicle.get("position_age_seconds") if uses_live_detail else _position_age_s(vehicle)
        is_stale = bool(vehicle.get("is_stale")) or (age_s is not None and age_s > 180)
        if is_stale:
            summary.stale_position_count += 1
            age_text = f"{age_s:.0f}s" if age_s is not None else "unknown age"
            summary.issues.append(
                VehicleIssue("warning", f"bus position is stale ({age_text})", vehicle_id)
            )
        if vehicle.get("direction_id") is None and vehicle.get("direction_ref") is None:
            summary.issues.append(
                VehicleIssue("warning", "bus missing direction_ref; frontend falls back to destination text", vehicle_id)
            )
    if summary.vehicle_count == 0:
        summary.issues.append(VehicleIssue("warning", "no live bus vehicles returned"))
    return summary


def audit_track_train(client: JsonClient, base_url: str, line_id: str) -> TrackVehicleSummary:
    encoded = urllib.parse.quote(line_id, safe="")
    endpoint = f"/subway/live-vehicles/{encoded}"
    start = time.perf_counter()
    try:
        vehicles = client.get_json(_track_url(base_url, endpoint))
        uses_live_detail = True
    except Exception:
        endpoint = f"/subway/vehicles/{encoded}"
        vehicles = client.get_json(_track_url(base_url, endpoint))
        uses_live_detail = False
    elapsed_ms = (time.perf_counter() - start) * 1000
    summary = TrackVehicleSummary(
        mode="subway",
        route_id=line_id,
        endpoint=endpoint,
        vehicle_count=len(vehicles or []),
        elapsed_ms=elapsed_ms,
    )
    for vehicle in vehicles or []:
        vehicle_id = vehicle.get("vehicle_id")
        trip_id = vehicle.get("trip_id")
        _record_quality_metadata(summary, vehicle)
        if vehicle_id or trip_id:
            summary.with_stable_identity_count += 1
            if len(summary.sample_vehicle_ids) < 8:
                summary.sample_vehicle_ids.append(str(vehicle_id or trip_id))
        else:
            summary.issues.append(VehicleIssue("error", "train missing vehicle_id/trip_id"))
        if trip_id:
            summary.with_trip_id_count += 1
        if _valid_coord(vehicle.get("lat"), vehicle.get("lon")):
            summary.with_position_count += 1
        else:
            summary.issues.append(VehicleIssue("error", "train missing valid lat/lon", vehicle_id))
        if (
            vehicle.get("next_stop_id")
            or vehicle.get("next_stop_name")
            or vehicle.get("current_stop_id")
            or vehicle.get("current_stop_name")
        ):
            summary.with_next_stop_count += 1
        if vehicle.get("route_id") and str(vehicle["route_id"]).upper() != line_id.upper():
            summary.issues.append(
                VehicleIssue("error", f"wrong route_id {vehicle['route_id']}", vehicle_id)
            )
        age_s = vehicle.get("position_age_seconds") if uses_live_detail else _position_age_s(vehicle)
        is_stale = bool(vehicle.get("is_stale")) or (age_s is not None and age_s > 180)
        if is_stale:
            summary.stale_position_count += 1
            age_text = f"{age_s:.0f}s" if age_s is not None else "unknown age"
            summary.issues.append(
                VehicleIssue("warning", f"train position is stale ({age_text})", vehicle_id)
            )
    if summary.vehicle_count == 0:
        summary.issues.append(VehicleIssue("warning", "no live train vehicles returned"))
    return summary


def _walk_departures(value: Any) -> tuple[int, int]:
    total = 0
    realtime = 0
    if isinstance(value, dict):
        keys = {"departure_time", "scheduled_departure_time", "estimated_departure_time"}
        if keys.intersection(value):
            total += 1
            if value.get("is_real_time") or value.get("rt") or value.get("realtime"):
                realtime += 1
        for child in value.values():
            child_total, child_realtime = _walk_departures(child)
            total += child_total
            realtime += child_realtime
    elif isinstance(value, list):
        for item in value:
            child_total, child_realtime = _walk_departures(item)
            total += child_total
            realtime += child_realtime
    return total, realtime


def summarize_transit_nearby(
    client: TransitClient,
    lat: float,
    lon: float,
    radius: int,
) -> TransitNearbySummary:
    start = time.perf_counter()
    payload = client.get_public_json(
        "/nearby_routes",
        {
            "lat": lat,
            "lon": lon,
            "max_distance": radius,
            "should_update_realtime": "true",
            "max_num_departures": 5,
        },
    )
    elapsed_ms = (time.perf_counter() - start) * 1000
    routes = payload.get("routes") or []
    departure_count, realtime_count = _walk_departures(routes)
    samples: list[dict[str, Any]] = []
    for route in routes[:8]:
        samples.append(
            {
                "global_route_id": route.get("global_route_id"),
                "short_name": route.get("route_short_name"),
                "long_name": route.get("route_long_name"),
                "itinerary_count": len(route.get("itineraries") or []),
            }
        )
    summary = TransitNearbySummary(
        lat=lat,
        lon=lon,
        route_count=len(routes),
        departure_count=departure_count,
        realtime_departure_count=realtime_count,
        sample_routes=samples,
        elapsed_ms=elapsed_ms,
    )
    if not routes:
        summary.issues.append("Transit nearby_routes returned no routes for sample coordinate")
    return summary


def frontend_contract_summary(track: list[TrackVehicleSummary]) -> dict[str, Any]:
    total = sum(item.vehicle_count for item in track)
    missing_identity = sum(item.vehicle_count - item.with_stable_identity_count for item in track)
    missing_position = sum(item.vehicle_count - item.with_position_count for item in track)
    missing_confidence = sum(item.vehicle_count - item.with_confidence_count for item in track)
    stale = sum(item.stale_position_count for item in track)
    return {
        "total_track_vehicles_sampled": total,
        "missing_identity": missing_identity,
        "missing_position": missing_position,
        "missing_confidence": missing_confidence,
        "stale_positions": stale,
        "frontend_handles_well": [
            "stable IDs are used for SwiftUI diffing, so markers do not recreate every GPS tick",
            "bus GPS targets are stored separately and animated toward, avoiding snap-forward/jump-back flicker",
            "impossible bus jumps are dampened before GPS targets feed marker interpolation or ETA speed history",
            "marker quality is explicit: GPS is solid, crowdsourced/interpolated/stop-anchor is estimated, stale is faded",
            "train markers prefer GTFS-RT VehiclePosition entries and fall back to polyline interpolation",
            "direction-scoped filteredBusVehicles/filteredTrainVehicles prevent wrong-direction markers from being shown",
            "12s grace buffers keep markers from vanishing on one bad poll cycle",
        ],
        "frontend_risks_to_watch": [
            "Transit appears to model route detail as backend-owned itineraries; Track still builds some train movement from arrivals + shape",
            "NYCT subway VehiclePosition often has stop-anchored positions instead of GPS, so Track can look less fluid than buses",
            "bus directionRef is only 0/1, so multi-branch/short-turn buses depend on destination text matching",
            "the public Transit API comparison may expose realtime departures, but not necessarily all raw vehicle GPS positions",
        ],
    }


def _ratio(numerator: int, denominator: int) -> float:
    if denominator <= 0:
        return 0.0
    return numerator / denominator


def build_superiority_scorecard(
    track: list[TrackVehicleSummary],
    transit: TransitNearbySummary | None,
) -> dict[str, Any]:
    total = sum(item.vehicle_count for item in track)
    identity_count = sum(item.with_stable_identity_count for item in track)
    position_count = sum(item.with_position_count for item in track)
    confidence_count = sum(item.with_confidence_count for item in track)
    stale_count = sum(item.stale_position_count for item in track)
    error_count = sum(
        1
        for item in track
        for issue in item.issues
        if issue.severity == "error"
    )
    avg_track_latency_ms = (
        statistics.mean(item.elapsed_ms for item in track) if track else 0.0
    )

    identity_rate = _ratio(identity_count, total)
    position_rate = _ratio(position_count, total)
    confidence_rate = _ratio(confidence_count, total)
    stale_rate = _ratio(stale_count, total)

    gates: list[dict[str, Any]] = [
        {
            "name": "stable_marker_identity",
            "passed": total > 0 and identity_rate == 1.0,
            "metric": identity_rate,
            "threshold": 1.0,
            "evidence": f"{identity_count}/{total} sampled vehicles expose stable vehicle_id/trip_id",
        },
        {
            "name": "valid_marker_positions",
            "passed": total > 0 and position_rate == 1.0,
            "metric": position_rate,
            "threshold": 1.0,
            "evidence": f"{position_count}/{total} sampled vehicles expose usable lat/lon",
        },
        {
            "name": "confidence_transparency",
            "passed": total > 0 and confidence_rate >= 0.95,
            "metric": confidence_rate,
            "threshold": 0.95,
            "evidence": f"{confidence_count}/{total} sampled vehicles expose position_confidence",
        },
        {
            "name": "freshness_control",
            "passed": total > 0 and stale_rate <= 0.05,
            "metric": stale_rate,
            "threshold": 0.05,
            "evidence": f"{stale_count}/{total} sampled vehicles are stale",
        },
        {
            "name": "frontend_contract_errors",
            "passed": error_count == 0,
            "metric": error_count,
            "threshold": 0,
            "evidence": f"{error_count} error-level contract issues found",
        },
        {
            "name": "track_endpoint_latency",
            "passed": bool(track) and avg_track_latency_ms <= 750,
            "metric": avg_track_latency_ms,
            "threshold": 750,
            "evidence": f"average Track live endpoint latency is {avg_track_latency_ms:.0f}ms",
        },
    ]

    if transit:
        gates.append(
            {
                "name": "measured_transit_latency_advantage",
                "passed": bool(track) and avg_track_latency_ms < transit.elapsed_ms,
                "metric": avg_track_latency_ms,
                "threshold": transit.elapsed_ms,
                "evidence": (
                    f"Track avg live latency {avg_track_latency_ms:.0f}ms vs "
                    f"Transit nearby sample {transit.elapsed_ms:.0f}ms"
                ),
            }
        )
    else:
        gates.append(
            {
                "name": "measured_transit_latency_advantage",
                "passed": False,
                "metric": None,
                "threshold": None,
                "evidence": "Transit API sample unavailable; cannot prove this category yet",
            }
        )

    core_passed = all(gate["passed"] for gate in gates[:-1])
    transit_passed = gates[-1]["passed"]
    proven_better_than_transit = core_passed and transit_passed

    return {
        "verdict": "proven_for_measured_categories" if proven_better_than_transit else "not_proven_yet",
        "proven_better_than_transit": proven_better_than_transit,
        "can_claim_publicly": proven_better_than_transit,
        "honest_claim": (
            "Track beat Transit in this measured audit."
            if proven_better_than_transit
            else "Track has strong measured tracking gates, but this run does not prove it is better than Transit."
        ),
        "sampled_track_vehicle_count": total,
        "identity_rate": identity_rate,
        "position_rate": position_rate,
        "confidence_rate": confidence_rate,
        "stale_rate": stale_rate,
        "avg_track_latency_ms": avg_track_latency_ms,
        "transit_latency_ms": transit.elapsed_ms if transit else None,
        "gates": gates,
    }


def write_markdown_report(payload: dict[str, Any], output: Path) -> None:
    scorecard = payload["superiority_scorecard"]
    lines = [
        "# Track Live Tracking Proof Scorecard",
        "",
        f"Generated at: `{payload['generated_at']}`",
        f"Track backend: `{payload['track_base_url']}`",
        "",
        f"Verdict: **{scorecard['verdict']}**",
        "",
        scorecard["honest_claim"],
        "",
        "## Measured Summary",
        "",
        f"- Track vehicles sampled: `{scorecard['sampled_track_vehicle_count']}`",
        f"- Stable identity rate: `{scorecard['identity_rate']:.1%}`",
        f"- Valid position rate: `{scorecard['position_rate']:.1%}`",
        f"- Confidence metadata rate: `{scorecard['confidence_rate']:.1%}`",
        f"- Stale position rate: `{scorecard['stale_rate']:.1%}`",
        f"- Average Track live endpoint latency: `{scorecard['avg_track_latency_ms']:.0f}ms`",
        f"- Transit comparison latency: `{scorecard['transit_latency_ms']:.0f}ms`"
        if scorecard["transit_latency_ms"] is not None
        else "- Transit comparison latency: `not measured`",
        "",
        "## Proof Gates",
        "",
        "| Gate | Result | Evidence |",
        "| --- | --- | --- |",
    ]
    for gate in scorecard["gates"]:
        status = "PASS" if gate["passed"] else "FAIL"
        lines.append(f"| `{gate['name']}` | {status} | {gate['evidence']} |")

    lines.extend(
        [
            "",
            "## Track Endpoint Samples",
            "",
            "| Mode | Route | Vehicles | Positions | IDs | Confidence | Stale | Sources | Latency | Issues |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |",
        ]
    )
    for item in payload["track"]:
        sources = ", ".join(
            f"{name}:{count}" for name, count in item["position_source_counts"].items()
        ) or "n/a"
        lines.append(
            "| "
            f"{item['mode']} | {item['route_id']} | {item['vehicle_count']} | "
            f"{item['with_position_count']} | {item['with_stable_identity_count']} | "
            f"{item['with_confidence_count']} | {item['stale_position_count']} | "
            f"{sources} | {item['elapsed_ms']:.0f}ms | {len(item['issues'])} |"
        )

    lines.extend(
        [
            "",
            "## What This Proves",
            "",
            "This run proves Track's sampled live marker contract is strong when the gates pass: stable marker identity, usable positions, explicit confidence metadata, stale-position handling, and acceptable endpoint latency.",
            "",
            "It does not prove Track is better than Transit unless a Transit API sample is included and the Transit comparison gate passes. That is intentional: the app should earn that claim with evidence, not vibes.",
            "",
        ]
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--track-base-url", default="https://track-vkrr.onrender.com")
    parser.add_argument("--bus-route", default="MTA NYCT_B63")
    parser.add_argument("--train-lines", default="E,A,7,L,N,Q,1")
    parser.add_argument("--skip-track", action="store_true")
    parser.add_argument("--skip-transit", action="store_true")
    parser.add_argument("--transit-lat", type=float, default=40.755290)
    parser.add_argument("--transit-lon", type=float, default=-73.987495)
    parser.add_argument("--transit-radius", type=int, default=550)
    parser.add_argument("--max-transit-calls", type=int, default=1)
    parser.add_argument("--min-transit-interval-s", type=float, default=13.0)
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--markdown-output",
        type=Path,
        default=None,
        help="Optional markdown proof report path. Defaults to output path with .md suffix.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero unless the scorecard proves Track better for measured categories.",
    )
    return parser


def main() -> None:
    args = build_parser().parse_args()
    client = JsonClient()
    track_results: list[TrackVehicleSummary] = []

    if not args.skip_track:
        track_results.append(audit_track_bus(client, args.track_base_url, args.bus_route))
        for line in [item.strip() for item in args.train_lines.split(",") if item.strip()]:
            track_results.append(audit_track_train(client, args.track_base_url, line))

    transit_summary: TransitNearbySummary | None = None
    transit_error: str | None = None
    if not args.skip_transit:
        api_key = os.environ.get("TRANSIT_API_KEY")
        if not api_key:
            transit_error = "TRANSIT_API_KEY is not set; skipped Transit API sample"
        else:
            try:
                transit_client = TransitClient(
                    api_key=api_key,
                    cache_path=args.cache,
                    max_calls=args.max_transit_calls,
                    min_interval_s=args.min_transit_interval_s,
                )
                transit_summary = summarize_transit_nearby(
                    transit_client,
                    lat=args.transit_lat,
                    lon=args.transit_lon,
                    radius=args.transit_radius,
                )
            except Exception as exc:
                transit_error = str(exc)

    scorecard = build_superiority_scorecard(track_results, transit_summary)
    payload = {
        "generated_at": int(time.time()),
        "track_base_url": args.track_base_url,
        "track": [asdict(item) for item in track_results],
        "transit_nearby": asdict(transit_summary) if transit_summary else None,
        "transit_error": transit_error,
        "frontend_contract": frontend_contract_summary(track_results),
        "superiority_scorecard": scorecard,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    markdown_output = args.markdown_output or args.output.with_suffix(".md")
    write_markdown_report(payload, markdown_output)

    print(f"Wrote {args.output}")
    print(f"Wrote {markdown_output}")
    for item in track_results:
        issue_count = len(item.issues)
        print(
            f"{item.mode} {item.route_id}: vehicles={item.vehicle_count} "
            f"positions={item.with_position_count} ids={item.with_stable_identity_count} "
            f"issues={issue_count} elapsed={item.elapsed_ms:.0f}ms"
        )
    if transit_summary:
        print(
            "transit nearby: "
            f"routes={transit_summary.route_count} departures={transit_summary.departure_count} "
            f"realtime={transit_summary.realtime_departure_count} "
            f"elapsed={transit_summary.elapsed_ms:.0f}ms"
        )
    elif transit_error:
        print(f"transit nearby: skipped/error: {transit_error}")

    print(f"scorecard verdict: {scorecard['verdict']}")
    for gate in scorecard["gates"]:
        status = "PASS" if gate["passed"] else "FAIL"
        print(f"  {status} {gate['name']}: {gate['evidence']}")

    if args.strict and not scorecard["proven_better_than_transit"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()