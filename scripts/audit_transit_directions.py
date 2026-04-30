#!/usr/bin/env python3
"""Audit Track route-direction objects against Transit-style route details.

This script has two layers:

1. Full local Track audit for every known subway, bus, LIRR, and MNR route.
2. Optional Transit API sampling with cache + rate limiting.

Transit's public API is quota-limited, so this script never tries to fetch every
NYC route from Transit in one run. Instead it compares Track's full local object
surface, then samples Transit route_details from hub discoveries or explicit
global_route_id values.
"""

from __future__ import annotations

import argparse
import ssl
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "TrackBackend"
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))
os.chdir(BACKEND)


TRANSIT_BASE_URL = "https://external.transitapp.com/v3/public"
DEFAULT_OUTPUT = ROOT / "test_output" / "transit_direction_audit.json"
DEFAULT_CACHE = ROOT / "test_output" / "transit_api_cache.json"

# A small set of route-dense hubs that discovers subway, bus, LIRR, and MNR
# samples without needing a grid scan. Add more hubs when you intentionally want
# to spend more Transit API quota.
DISCOVERY_HUBS: tuple[tuple[str, float, float, int], ...] = (
    ("jamaica_center", 40.702147, -73.801109, 550),
    ("times_sq", 40.755290, -73.987495, 450),
    ("atlantic_terminal", 40.684105, -73.977667, 500),
    ("grand_central", 40.752726, -73.977229, 500),
    ("flushing_main", 40.759600, -73.830030, 450),
)


@dataclass
class DirectionSummary:
    direction_id: int | str | None
    headsign: str
    polyline_count: int
    stop_count: int
    first_stop: str | None = None
    last_stop: str | None = None
    local_only_stop_count: int = 0


@dataclass
class RouteSummary:
    source: str
    mode: str
    route_id: str
    display_name: str
    polyline_count: int
    stop_count: int
    direction_count: int
    directions: list[DirectionSummary] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)
    gaps: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    elapsed_ms: float = 0


class TransitClient:
    def __init__(
        self,
        api_key: str,
        cache_path: Path,
        max_calls: int,
        min_interval_s: float,
    ) -> None:
        self.api_key = api_key
        self.cache_path = cache_path
        self.max_calls = max_calls
        self.min_interval_s = min_interval_s
        self.calls_made = 0
        self.last_call_at = 0.0
        self.cache: dict[str, Any] = {}
        self.ssl_context = self._ssl_context()
        if cache_path.exists():
            self.cache = json.loads(cache_path.read_text(encoding="utf-8"))

    @staticmethod
    def _ssl_context() -> ssl.SSLContext:
        try:
            import certifi

            return ssl.create_default_context(cafile=certifi.where())
        except Exception:
            return ssl.create_default_context()

    def save_cache(self) -> None:
        self.cache_path.parent.mkdir(parents=True, exist_ok=True)
        self.cache_path.write_text(
            json.dumps(self.cache, indent=2, sort_keys=True),
            encoding="utf-8",
        )

    def get_json(self, path: str, params: dict[str, Any]) -> Any:
        query = urllib.parse.urlencode(params)
        url = f"{TRANSIT_BASE_URL}{path}?{query}"
        cache_key = url
        if cache_key in self.cache:
            return self.cache[cache_key]
        if self.calls_made >= self.max_calls:
            raise RuntimeError(
                f"Transit call cap reached ({self.max_calls}); rerun with a higher "
                "--max-transit-calls only if you want to spend more quota."
            )

        now = time.monotonic()
        wait_s = self.min_interval_s - (now - self.last_call_at)
        if wait_s > 0:
            time.sleep(wait_s)

        request = urllib.request.Request(
            url,
            headers={
                "apiKey": self.api_key,
                "Accept-Language": "en",
                "User-Agent": "Track-direction-audit/1.0",
            },
        )
        with urllib.request.urlopen(request, timeout=30, context=self.ssl_context) as response:
            payload = json.loads(response.read().decode("utf-8"))
        self.calls_made += 1
        self.last_call_at = time.monotonic()
        self.cache[cache_key] = payload
        self.save_cache()
        return payload


def _encoded_count(polylines: Any) -> int:
    return len(polylines or [])


def _first_last_stop(stops: list[Any]) -> tuple[str | None, str | None]:
    if not stops:
        return None, None
    first = getattr(stops[0], "name", None) or stops[0].get("name")
    last = getattr(stops[-1], "name", None) or stops[-1].get("name")
    return first, last


def _append_shape_issues(summary: RouteSummary) -> None:
    if summary.polyline_count <= 0:
        summary.issues.append("route has no top-level polylines")
    if summary.stop_count <= 0:
        summary.issues.append("route has no top-level stops")
    if summary.direction_count <= 0:
        summary.issues.append("route has no directions")

    seen_identity: set[tuple[str, str]] = set()
    headsign_counts: dict[str, int] = {}
    direction_id_to_headsigns: dict[str, set[str]] = {}
    for direction in summary.directions:
        if direction.polyline_count <= 0:
            summary.issues.append(f"{direction.headsign}: no direction polylines")
        if direction.stop_count <= 1:
            message = f"{direction.headsign}: too few direction stops"
            if summary.mode == "bus" and summary.stop_count > 1:
                summary.gaps.append(
                    message
                    + " (static bus fallback has route-level stops but no per-direction stops)"
                )
            else:
                summary.issues.append(message)
        identity = (str(direction.direction_id), direction.headsign.lower())
        if identity in seen_identity:
            summary.notes.append(
                f"duplicate direction identity {direction.direction_id}/{direction.headsign}"
            )
        seen_identity.add(identity)
        headsign_counts[direction.headsign.lower()] = (
            headsign_counts.get(direction.headsign.lower(), 0) + 1
        )
        direction_id_to_headsigns.setdefault(str(direction.direction_id), set()).add(
            direction.headsign
        )

    for direction_id, headsigns in sorted(direction_id_to_headsigns.items()):
        if len(headsigns) > 1:
            summary.notes.append(
                f"direction_id {direction_id} has {len(headsigns)} branch headsigns"
            )
    for headsign, count in sorted(headsign_counts.items()):
        if headsign and count > 1:
            summary.notes.append(
                f"same headsign appears as {count} separate pattern(s): {headsign}"
            )


def audit_track_subway() -> list[RouteSummary]:
    from app.services.mapping.subway.shapes import get_subway_route_shape
    from app.utils.transit_utils import get_all_subway_lines

    out: list[RouteSummary] = []
    for route_id in sorted(get_all_subway_lines()):
        start = time.perf_counter()
        result = get_subway_route_shape(route_id)
        elapsed_ms = (time.perf_counter() - start) * 1000
        if not result:
            out.append(
                RouteSummary(
                    source="track",
                    mode="subway",
                    route_id=route_id,
                    display_name=route_id,
                    polyline_count=0,
                    stop_count=0,
                    direction_count=0,
                    issues=["missing route shape"],
                    elapsed_ms=elapsed_ms,
                )
            )
            continue
        polylines, stops, directions = result
        direction_summaries: list[DirectionSummary] = []
        for direction in directions:
            first, last = _first_last_stop(list(direction.stops))
            direction_summaries.append(
                DirectionSummary(
                    direction_id=direction.direction_id,
                    headsign=direction.headsign,
                    polyline_count=len(direction.polylines),
                    stop_count=len(direction.stops),
                    first_stop=first,
                    last_stop=last,
                    local_only_stop_count=len(direction.local_only_stop_ids),
                )
            )
        summary = RouteSummary(
            source="track",
            mode="subway",
            route_id=route_id,
            display_name=route_id,
            polyline_count=len(polylines),
            stop_count=len(stops),
            direction_count=len(direction_summaries),
            directions=direction_summaries,
            elapsed_ms=elapsed_ms,
        )
        _append_shape_issues(summary)
        out.append(summary)
    return out


def audit_track_bus() -> list[RouteSummary]:
    from app.clients.bus_client import _load_static_bus_route_shape_index

    out: list[RouteSummary] = []
    start = time.perf_counter()
    index = _load_static_bus_route_shape_index()
    index_elapsed_ms = (time.perf_counter() - start) * 1000
    for route_id in sorted(index):
        shape = index[route_id]
        direction_summaries: list[DirectionSummary] = []
        for direction in shape.directions:
            first, last = _first_last_stop(direction.stops)
            direction_summaries.append(
                DirectionSummary(
                    direction_id=direction.direction_id,
                    headsign=direction.headsign,
                    polyline_count=_encoded_count(direction.polylines),
                    stop_count=len(direction.stops),
                    first_stop=first,
                    last_stop=last,
                    local_only_stop_count=len(direction.local_only_stop_ids),
                )
            )
        summary = RouteSummary(
            source="track",
            mode="bus",
            route_id=shape.route_id,
            display_name=route_id,
            polyline_count=_encoded_count(shape.polylines),
            stop_count=len(shape.stops),
            direction_count=len(direction_summaries),
            directions=direction_summaries,
            elapsed_ms=index_elapsed_ms / max(1, len(index)),
        )
        _append_shape_issues(summary)
        out.append(summary)
    return out


def _rail_route_id(raw: str) -> str:
    return raw.split("_", 1)[1] if "_" in raw else raw


def audit_track_rail(mode: str) -> list[RouteSummary]:
    from app.services.mapping.rail.shapes import (
        get_all_lirr_lines,
        get_all_mnr_lines,
        get_single_lirr_line,
        get_single_mnr_line,
    )

    if mode == "lirr":
        lines = get_all_lirr_lines()
        get_single = get_single_lirr_line
    elif mode == "mnr":
        lines = get_all_mnr_lines()
        get_single = get_single_mnr_line
    else:
        raise ValueError(mode)

    out: list[RouteSummary] = []
    for line in lines:
        route_id = _rail_route_id(str(line.get("route_id", "")))
        start = time.perf_counter()
        shape = get_single(route_id)
        elapsed_ms = (time.perf_counter() - start) * 1000
        if not shape:
            out.append(
                RouteSummary(
                    source="track",
                    mode=mode,
                    route_id=route_id,
                    display_name=str(line.get("name") or route_id),
                    polyline_count=0,
                    stop_count=0,
                    direction_count=0,
                    issues=["missing route shape"],
                    elapsed_ms=elapsed_ms,
                )
            )
            continue
        direction_summaries: list[DirectionSummary] = []
        for direction in shape.get("directions", []):
            stops = direction.get("stops", [])
            first, last = _first_last_stop(stops)
            direction_summaries.append(
                DirectionSummary(
                    direction_id=direction.get("direction_id"),
                    headsign=direction.get("headsign") or "",
                    polyline_count=len(direction.get("polylines") or []),
                    stop_count=len(stops),
                    first_stop=first,
                    last_stop=last,
                )
            )
        summary = RouteSummary(
            source="track",
            mode=mode,
            route_id=str(shape.get("route_id") or route_id),
            display_name=str(shape.get("name") or line.get("name") or route_id),
            polyline_count=len(shape.get("polylines") or []),
            stop_count=len(shape.get("stops") or []),
            direction_count=len(direction_summaries),
            directions=direction_summaries,
            elapsed_ms=elapsed_ms,
        )
        _append_shape_issues(summary)
        out.append(summary)
    return out


def discover_transit_routes(client: TransitClient) -> dict[str, dict[str, Any]]:
    discovered: dict[str, dict[str, Any]] = {}
    for name, lat, lon, radius in DISCOVERY_HUBS:
        payload = client.get_json(
            "/nearby_routes",
            {
                "lat": lat,
                "lon": lon,
                "max_distance": radius,
                "should_update_realtime": "false",
                "max_num_departures": 1,
            },
        )
        for route in payload.get("routes", []):
            global_id = route.get("global_route_id")
            if not global_id:
                continue
            discovered.setdefault(
                global_id,
                {
                    "global_route_id": global_id,
                    "route_short_name": route.get("route_short_name"),
                    "route_long_name": route.get("route_long_name"),
                    "first_seen_hub": name,
                },
            )
    return discovered


def transit_route_summary(route: dict[str, Any]) -> RouteSummary:
    route_obj = route.get("route", route)
    global_id = route_obj.get("global_route_id") or route.get("global_route_id") or "unknown"
    short_name = route_obj.get("route_short_name") or route.get("route_short_name") or global_id
    long_name = route_obj.get("route_long_name") or route.get("route_long_name") or short_name
    mode = str(global_id).split(":", 1)[0].lower()
    itineraries = route_obj.get("itineraries") or route.get("itineraries") or []
    directions: list[DirectionSummary] = []
    total_stops = 0
    total_shapes = 0
    for item in itineraries:
        stops = item.get("stops") or []
        shape = item.get("shape")
        total_stops += len(stops)
        total_shapes += 1 if shape else 0
        first = stops[0].get("stop_name") if stops else None
        last = stops[-1].get("stop_name") if stops else None
        directions.append(
            DirectionSummary(
                direction_id=item.get("direction_id"),
                headsign=item.get("headsign") or item.get("merged_headsign") or "",
                polyline_count=1 if shape else 0,
                stop_count=len(stops),
                first_stop=first,
                last_stop=last,
            )
        )
    summary = RouteSummary(
        source="transit",
        mode=mode,
        route_id=global_id,
        display_name=f"{short_name} {long_name}".strip(),
        polyline_count=total_shapes,
        stop_count=total_stops,
        direction_count=len(directions),
        directions=directions,
    )
    _append_shape_issues(summary)
    return summary


def audit_transit_samples(
    client: TransitClient,
    explicit_global_ids: list[str],
    sample_limit: int,
    skip_discovery: bool,
) -> list[RouteSummary]:
    discovered = {} if skip_discovery else discover_transit_routes(client)
    ordered_ids = list(dict.fromkeys(explicit_global_ids + sorted(discovered)))
    out: list[RouteSummary] = []
    for global_id in ordered_ids[:sample_limit]:
        start = time.perf_counter()
        payload = client.get_json(
            "/route_details",
            {
                "global_route_id": global_id,
                "include_next_departure": "false",
            },
        )
        summary = transit_route_summary(payload)
        summary.elapsed_ms = (time.perf_counter() - start) * 1000
        out.append(summary)
    return out


def compare_transit_to_track(
    track: list[RouteSummary],
    transit: list[RouteSummary],
) -> list[dict[str, Any]]:
    by_display: dict[str, list[RouteSummary]] = {}
    for item in track:
        by_display.setdefault(item.display_name.upper(), []).append(item)
        by_display.setdefault(item.route_id.upper(), []).append(item)

    comparisons: list[dict[str, Any]] = []
    for item in transit:
        short = item.display_name.split()[0].upper() if item.display_name else ""
        candidates = by_display.get(short, [])
        if not candidates:
            comparisons.append(
                {
                    "transit_route_id": item.route_id,
                    "transit_display_name": item.display_name,
                    "status": "no obvious Track route match",
                }
            )
            continue
        track_item = candidates[0]
        comparisons.append(
            {
                "track_route_id": track_item.route_id,
                "track_mode": track_item.mode,
                "track_directions": track_item.direction_count,
                "track_headsigns": [d.headsign for d in track_item.directions],
                "transit_route_id": item.route_id,
                "transit_directions": item.direction_count,
                "transit_headsigns": [d.headsign for d in item.directions],
                "direction_count_delta": track_item.direction_count - item.direction_count,
                "status": "matched by display token",
            }
        )
    return comparisons


def summarize(routes: list[RouteSummary]) -> dict[str, Any]:
    by_mode: dict[str, dict[str, Any]] = {}
    for route in routes:
        bucket = by_mode.setdefault(
            route.mode,
            {
                "routes": 0,
                "directions": 0,
                "issues": 0,
                "gaps": 0,
                "notes": 0,
                "avg_elapsed_ms": 0.0,
            },
        )
        bucket["routes"] += 1
        bucket["directions"] += route.direction_count
        bucket["issues"] += len(route.issues)
        bucket["gaps"] += len(route.gaps)
        bucket["notes"] += len(route.notes)
        bucket["avg_elapsed_ms"] += route.elapsed_ms
    for bucket in by_mode.values():
        if bucket["routes"]:
            bucket["avg_elapsed_ms"] = round(bucket["avg_elapsed_ms"] / bucket["routes"], 3)
    return by_mode


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--skip-bus", action="store_true")
    parser.add_argument("--skip-transit", action="store_true")
    parser.add_argument("--max-transit-calls", type=int, default=12)
    parser.add_argument("--transit-sample-limit", type=int, default=8)
    parser.add_argument("--min-transit-interval-s", type=float, default=13.0)
    parser.add_argument(
        "--skip-transit-discovery",
        action="store_true",
        help="Only fetch explicit --transit-route-id values; avoids nearby_routes discovery calls.",
    )
    parser.add_argument(
        "--transit-route-id",
        action="append",
        default=[],
        help="Explicit Transit global_route_id to fetch, e.g. MTAS:2238. Can repeat.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    track_routes: list[RouteSummary] = []
    track_routes.extend(audit_track_subway())
    track_routes.extend(audit_track_rail("lirr"))
    track_routes.extend(audit_track_rail("mnr"))
    if not args.skip_bus:
        track_routes.extend(audit_track_bus())

    transit_routes: list[RouteSummary] = []
    transit_error: str | None = None
    api_key = os.environ.get("TRANSIT_API_KEY")
    if not args.skip_transit:
        if not api_key:
            transit_error = "TRANSIT_API_KEY is not set; skipped Transit API sampling."
        else:
            try:
                client = TransitClient(
                    api_key=api_key,
                    cache_path=args.cache,
                    max_calls=args.max_transit_calls,
                    min_interval_s=args.min_transit_interval_s,
                )
                transit_routes = audit_transit_samples(
                    client,
                    explicit_global_ids=args.transit_route_id,
                    sample_limit=args.transit_sample_limit,
                    skip_discovery=args.skip_transit_discovery,
                )
            except Exception as exc:  # noqa: BLE001 - audit script should report, not hide context
                transit_error = str(exc)

    report = {
        "track_summary": summarize(track_routes),
        "transit_summary": summarize(transit_routes),
        "transit_error": transit_error,
        "comparisons": compare_transit_to_track(track_routes, transit_routes),
        "track_routes_with_issues": [
            asdict(route) for route in track_routes if route.issues
        ],
        "track_routes_with_gaps": [
            asdict(route) for route in track_routes if route.gaps
        ],
        "track_routes_with_notes": [
            asdict(route) for route in track_routes if route.notes
        ],
        "transit_routes": [asdict(route) for route in transit_routes],
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("Track summary")
    print(json.dumps(report["track_summary"], indent=2))
    if transit_error:
        print(f"Transit sampling: {transit_error}")
    else:
        print("Transit summary")
        print(json.dumps(report["transit_summary"], indent=2))
    print(f"Wrote {args.output}")
    if report["track_routes_with_issues"]:
        print(f"Track routes with issues: {len(report['track_routes_with_issues'])}")
    if report["track_routes_with_gaps"]:
        print(f"Track routes with model gaps: {len(report['track_routes_with_gaps'])}")
    if report["track_routes_with_notes"]:
        print(f"Track routes with notes: {len(report['track_routes_with_notes'])}")
    return 1 if report["track_routes_with_issues"] else 0


if __name__ == "__main__":
    raise SystemExit(main())