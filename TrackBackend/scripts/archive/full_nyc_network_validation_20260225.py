from __future__ import annotations

import json
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any

import httpx

BASE = "http://127.0.0.1:8000"
TIMEOUT = 30.0


@dataclass
class EndpointResult:
    method: str
    path: str
    status_code: int
    ok: bool
    error: str | None = None


def safe_len(value: Any) -> int:
    if isinstance(value, (list, dict, str)):
        return len(value)
    return 0


def parse_json(resp: httpx.Response) -> Any:
    try:
        return resp.json()
    except Exception:
        return None


def unique_nonempty(values: list[Any]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for value in values:
        item = str(value or "").strip()
        if item and item not in seen:
            seen.add(item)
            out.append(item)
    return out


class Validator:
    def __init__(self, client: httpx.Client) -> None:
        self.client = client
        self.results: list[EndpointResult] = []
        self.failures: list[dict[str, Any]] = []

    def hit(self, path: str, method: str = "GET", params: dict[str, Any] | None = None) -> tuple[int, Any]:
        try:
            resp = self.client.request(method, BASE + path, params=params)
            body = parse_json(resp)
            ok = 200 <= resp.status_code < 300
            self.results.append(
                EndpointResult(method=method, path=path, status_code=resp.status_code, ok=ok)
            )
            if not ok:
                self.failures.append(
                    {
                        "method": method,
                        "path": path,
                        "status_code": resp.status_code,
                        "body_preview": str(body)[:300],
                    }
                )
            return resp.status_code, body
        except Exception as exc:
            self.results.append(EndpointResult(method=method, path=path, status_code=0, ok=False, error=str(exc)))
            self.failures.append(
                {
                    "method": method,
                    "path": path,
                    "status_code": 0,
                    "body_preview": str(exc),
                }
            )
            return 0, None


def main() -> None:
    out_dir = Path("/Users/jeffreyfernandez/code/Track/TrackBackend/logs")
    out_dir.mkdir(parents=True, exist_ok=True)

    with httpx.Client(timeout=TIMEOUT) as client:
        v = Validator(client)

        # Core sanity
        for path, method, params in [
            ("/config", "GET", None),
            ("/data/status", "GET", None),
            ("/alerts", "GET", None),
            ("/alerts", "GET", {"mode": "subway"}),
            ("/accessibility", "GET", None),
            ("/predict/delay", "GET", {"minutes_away": 5, "route_id": "A", "hour": 8, "day_of_week": 3, "weather": "clear"}),
        ]:
            v.hit(path, method=method, params=params)

        # Bus full catalog
        _, bus_routes_body = v.hit("/bus/routes")
        bus_routes = bus_routes_body if isinstance(bus_routes_body, list) else []
        bus_route_ids = unique_nonempty([route.get("short_name") for route in bus_routes if isinstance(route, dict)])

        bus_stats = {
            "total_routes": len(bus_route_ids),
            "routes_all_2xx": 0,
            "routes_with_stops": 0,
            "routes_with_schedule_directions": 0,
            "routes_with_live_vehicles": 0,
            "routes_with_shape": 0,
            "routes_with_2plus_stop_directions": 0,
            "per_route": [],
        }

        for route_id in bus_route_ids:
            stops_code, stops = v.hit(f"/bus/stops/{route_id}")
            schedule_code, schedule = v.hit(f"/bus/schedule/{route_id}")
            vehicles_code, vehicles = v.hit(f"/bus/vehicles/{route_id}")
            shape_code, shape = v.hit(f"/bus/route-shape/{route_id}")

            stop_list = stops if isinstance(stops, list) else []
            vehicle_list = vehicles if isinstance(vehicles, list) else []
            schedule_dirs = []
            if isinstance(schedule, dict):
                schedule_dirs = schedule.get("directions") or []

            shape_stops = 0
            shape_polylines = 0
            if isinstance(shape, dict):
                shape_stops = safe_len(shape.get("stops") or [])
                shape_polylines = safe_len(shape.get("polylines") or [])

            stop_directions = unique_nonempty([
                stop.get("direction") for stop in stop_list if isinstance(stop, dict)
            ])

            all_ok = all(200 <= code < 300 for code in [stops_code, schedule_code, vehicles_code, shape_code])
            if all_ok:
                bus_stats["routes_all_2xx"] += 1
            if len(stop_list) > 0:
                bus_stats["routes_with_stops"] += 1
            if len(schedule_dirs) > 0:
                bus_stats["routes_with_schedule_directions"] += 1
            if len(vehicle_list) > 0:
                bus_stats["routes_with_live_vehicles"] += 1
            if shape_stops > 0 or shape_polylines > 0:
                bus_stats["routes_with_shape"] += 1
            if len(stop_directions) >= 2:
                bus_stats["routes_with_2plus_stop_directions"] += 1

            bus_stats["per_route"].append(
                {
                    "route_id": route_id,
                    "all_2xx": all_ok,
                    "stops_count": len(stop_list),
                    "schedule_direction_count": len(schedule_dirs),
                    "vehicle_count": len(vehicle_list),
                    "shape_stops": shape_stops,
                    "shape_polylines": shape_polylines,
                    "stop_directions": stop_directions,
                }
            )

        # Subway full catalog
        _, subway_shapes = v.hit("/subway/shapes/all")
        subway_lines = []
        if isinstance(subway_shapes, dict):
            subway_lines = subway_shapes.get("lines") or []
        subway_route_ids = unique_nonempty([
            line.get("route_id") for line in subway_lines if isinstance(line, dict)
        ])

        subway_stats = {
            "total_routes": len(subway_route_ids),
            "routes_all_2xx": 0,
            "routes_with_live_payload": 0,
            "routes_with_shape_payload": 0,
            "per_route": [],
        }

        for route_id in subway_route_ids:
            live_code, live = v.hit(f"/subway/{route_id}")
            shape_code, shape = v.hit(f"/subway/shape/{route_id}")

            live_size = safe_len(live)
            shape_size = safe_len(shape)
            all_ok = all(200 <= code < 300 for code in [live_code, shape_code])
            if all_ok:
                subway_stats["routes_all_2xx"] += 1
            if live_size > 0:
                subway_stats["routes_with_live_payload"] += 1
            if shape_size > 0:
                subway_stats["routes_with_shape_payload"] += 1

            subway_stats["per_route"].append(
                {
                    "route_id": route_id,
                    "all_2xx": all_ok,
                    "live_payload_size": live_size,
                    "shape_payload_size": shape_size,
                }
            )

        # LIRR full catalog
        _, lirr_shapes = v.hit("/lirr/shapes/all")
        lirr_lines = []
        if isinstance(lirr_shapes, dict):
            lirr_lines = lirr_shapes.get("lines") or []
        elif isinstance(lirr_shapes, list):
            lirr_lines = lirr_shapes
        lirr_route_ids = unique_nonempty([
            item.get("route_id") for item in lirr_lines if isinstance(item, dict)
        ])
        v.hit("/lirr")

        lirr_stats = {
            "total_routes": len(lirr_route_ids),
            "routes_shape_2xx": 0,
            "routes_shape_payload": 0,
            "per_route": [],
        }
        for route_id in lirr_route_ids:
            code, body = v.hit(f"/lirr/shape/{route_id}")
            size = safe_len(body)
            if 200 <= code < 300:
                lirr_stats["routes_shape_2xx"] += 1
            if size > 0:
                lirr_stats["routes_shape_payload"] += 1
            lirr_stats["per_route"].append(
                {"route_id": route_id, "shape_2xx": 200 <= code < 300, "shape_payload_size": size}
            )

        # MNR full catalog
        _, mnr_shapes = v.hit("/mnr/shapes/all")
        mnr_lines = []
        if isinstance(mnr_shapes, dict):
            mnr_lines = mnr_shapes.get("lines") or []
        elif isinstance(mnr_shapes, list):
            mnr_lines = mnr_shapes
        mnr_route_ids = unique_nonempty([
            item.get("route_id") for item in mnr_lines if isinstance(item, dict)
        ])
        v.hit("/mnr")

        mnr_stats = {
            "total_routes": len(mnr_route_ids),
            "routes_shape_2xx": 0,
            "routes_shape_payload": 0,
            "per_route": [],
        }
        for route_id in mnr_route_ids:
            code, body = v.hit(f"/mnr/shape/{route_id}")
            size = safe_len(body)
            if 200 <= code < 300:
                mnr_stats["routes_shape_2xx"] += 1
            if size > 0:
                mnr_stats["routes_shape_payload"] += 1
            mnr_stats["per_route"].append(
                {"route_id": route_id, "shape_2xx": 200 <= code < 300, "shape_payload_size": size}
            )

        # Borough-wide grouped coverage (directions integrity)
        boroughs = [
            ("manhattan", 40.7580, -73.9855),
            ("brooklyn", 40.6782, -73.9442),
            ("queens", 40.7282, -73.7949),
            ("bronx", 40.8448, -73.8648),
            ("staten_island", 40.5795, -74.1502),
        ]
        grouped_stats = []
        for name, lat, lon in boroughs:
            _, grouped_bus = v.hit("/nearby/grouped", params={"lat": lat, "lon": lon, "radius": 12000, "mode": "bus"})
            _, grouped_subway = v.hit("/nearby/grouped", params={"lat": lat, "lon": lon, "radius": 12000, "mode": "subway"})
            _, grouped_lirr = v.hit("/nearby/grouped", params={"lat": lat, "lon": lon, "radius": 12000, "mode": "lirr"})
            _, grouped_mnr = v.hit("/nearby/grouped", params={"lat": lat, "lon": lon, "radius": 12000, "mode": "mnr"})
            _, nearby = v.hit("/nearby", params={"lat": lat, "lon": lon, "radius": 12000})

            bus_groups = grouped_bus if isinstance(grouped_bus, list) else []
            subway_groups = grouped_subway if isinstance(grouped_subway, list) else []
            lirr_groups = grouped_lirr if isinstance(grouped_lirr, list) else []
            mnr_groups = grouped_mnr if isinstance(grouped_mnr, list) else []
            nearby_rows = nearby if isinstance(nearby, list) else []
            empty_route_ids = sum(
                1 for item in nearby_rows if not str((item or {}).get("route_id", "")).strip()
            )
            bus_with_dirs = sum(
                1
                for item in bus_groups
                if isinstance(item, dict) and isinstance(item.get("directions"), list) and len(item.get("directions")) > 0
            )
            subway_with_dirs = sum(
                1
                for item in subway_groups
                if isinstance(item, dict) and isinstance(item.get("directions"), list) and len(item.get("directions")) > 0
            )
            lirr_with_dirs = sum(
                1
                for item in lirr_groups
                if isinstance(item, dict) and isinstance(item.get("directions"), list) and len(item.get("directions")) > 0
            )
            mnr_with_dirs = sum(
                1
                for item in mnr_groups
                if isinstance(item, dict) and isinstance(item.get("directions"), list) and len(item.get("directions")) > 0
            )

            grouped_stats.append(
                {
                    "borough": name,
                    "nearby_count": len(nearby_rows),
                    "nearby_empty_route_ids": empty_route_ids,
                    "grouped_bus_total": len(bus_groups),
                    "grouped_bus_with_directions": bus_with_dirs,
                    "grouped_subway_total": len(subway_groups),
                    "grouped_subway_with_directions": subway_with_dirs,
                    "grouped_lirr_total": len(lirr_groups),
                    "grouped_lirr_with_directions": lirr_with_dirs,
                    "grouped_mnr_total": len(mnr_groups),
                    "grouped_mnr_with_directions": mnr_with_dirs,
                }
            )

        total = len(v.results)
        passed = sum(1 for item in v.results if item.ok)

        report = {
            "base_url": BASE,
            "total_endpoint_calls": total,
            "passed_endpoint_calls": passed,
            "failed_endpoint_calls": total - passed,
            "bus": bus_stats,
            "subway": subway_stats,
            "lirr": lirr_stats,
            "mnr": mnr_stats,
            "borough_grouped_checks": grouped_stats,
            "failures": v.failures,
            "endpoint_results": [asdict(item) for item in v.results],
        }

        json_path = out_dir / "full_nyc_network_validation_20260225.json"
        txt_path = out_dir / "full_nyc_network_validation_20260225.txt"

        json_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

        lines: list[str] = []
        lines.append("=== FULL NYC NETWORK VALIDATION ===")
        lines.append(f"total_endpoint_calls={report['total_endpoint_calls']}")
        lines.append(f"passed_endpoint_calls={report['passed_endpoint_calls']}")
        lines.append(f"failed_endpoint_calls={report['failed_endpoint_calls']}")
        lines.append("")
        lines.append("[BUS]")
        lines.append(
            f"routes={bus_stats['total_routes']} all_2xx={bus_stats['routes_all_2xx']} with_stops={bus_stats['routes_with_stops']} with_schedule_directions={bus_stats['routes_with_schedule_directions']} with_live_vehicles={bus_stats['routes_with_live_vehicles']} with_shape={bus_stats['routes_with_shape']} with_2plus_stop_directions={bus_stats['routes_with_2plus_stop_directions']}"
        )
        lines.append("[SUBWAY]")
        lines.append(
            f"routes={subway_stats['total_routes']} all_2xx={subway_stats['routes_all_2xx']} with_live_payload={subway_stats['routes_with_live_payload']} with_shape_payload={subway_stats['routes_with_shape_payload']}"
        )
        lines.append("[LIRR]")
        lines.append(
            f"routes={lirr_stats['total_routes']} shape_2xx={lirr_stats['routes_shape_2xx']} shape_payload={lirr_stats['routes_shape_payload']}"
        )
        lines.append("[MNR]")
        lines.append(
            f"routes={mnr_stats['total_routes']} shape_2xx={mnr_stats['routes_shape_2xx']} shape_payload={mnr_stats['routes_shape_payload']}"
        )
        lines.append("")
        lines.append("[BOROUGH GROUPED CHECKS]")
        for item in grouped_stats:
            lines.append(
                f"{item['borough']}: nearby={item['nearby_count']} empty_route_ids={item['nearby_empty_route_ids']} bus_dirs={item['grouped_bus_with_directions']}/{item['grouped_bus_total']} subway_dirs={item['grouped_subway_with_directions']}/{item['grouped_subway_total']} lirr_dirs={item['grouped_lirr_with_directions']}/{item['grouped_lirr_total']} mnr_dirs={item['grouped_mnr_with_directions']}/{item['grouped_mnr_total']}"
            )

        lines.append("")
        lines.append("[FAILURES]")
        if not v.failures:
            lines.append("none")
        else:
            for failure in v.failures:
                lines.append(
                    f"{failure['status_code']} {failure['method']} {failure['path']} body={failure['body_preview']}"
                )

        txt_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

        print(f"WROTE_JSON={json_path}")
        print(f"WROTE_TXT={txt_path}")
        print(f"TOTAL_CALLS={total} PASSED={passed} FAILED={total - passed}")


if __name__ == "__main__":
    main()
