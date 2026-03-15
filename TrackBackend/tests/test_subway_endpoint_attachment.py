from __future__ import annotations

from shapely.geometry import LineString, Point

from app.services.mapping.corridor_pipeline import _to_meters
from app.utils.polyline_utils import decode_polyline as _decode_polyline
from tests.test_all_endpoints import client


SKIPPED_SYSTEM_MAP_VARIANTS = {"FS", "GS", "SR"}


def test_processed_stations_touch_exported_trunk_polylines():
    shapes_response = client.get("/subway/shapes/all")
    assert shapes_response.status_code == 200
    shapes = shapes_response.json()

    processed_response = client.get("/subway/stations/processed")
    assert processed_response.status_code == 200
    processed = processed_response.json()["stations"]

    route_lines: dict[str, list[LineString]] = {}
    for trunk in shapes["trunk_polylines"]:
        lines: list[LineString] = []
        for encoded in trunk["polylines"]:
            coords = _decode_polyline(encoded)
            if len(coords) < 2:
                continue
            projected = [_to_meters.transform(lon, lat) for lat, lon in coords]
            lines.append(LineString(projected))

        for route_id in trunk["route_ids"]:
            route_lines.setdefault(route_id, []).extend(lines)

    outliers: list[tuple[float, str, str]] = []
    checked = 0
    skipped_routes: set[str] = set()

    for station in processed:
        for position in station["positions"]:
            lines = route_lines.get(position["route_id"], [])
            if not lines:
                skipped_routes.add(position["route_id"])
                continue

            x, y = _to_meters.transform(position["lon"], position["lat"])
            distance_m = min(line.distance(Point(x, y)) for line in lines)
            checked += 1

            if distance_m > 2.0:
                outliers.append((distance_m, station["name"], position["route_id"]))

    assert checked >= 1000
    assert skipped_routes <= SKIPPED_SYSTEM_MAP_VARIANTS
    assert not outliers, (
        "Processed stations should sit on exported trunk polylines; "
        f"found outliers: {sorted(outliers, reverse=True)[:10]}"
    )
