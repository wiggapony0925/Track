from __future__ import annotations

from shapely.geometry import LineString, Point

from app.services.mapping.corridor_pipeline import _to_meters
from app.utils.polyline_utils import decode_polyline as _decode_polyline
from tests.test_all_endpoints import client

SKIPPED_SYSTEM_MAP_VARIANTS = {"FS", "GS", "SR", "H"}

# Known GTFS data artifacts: the MTA GTFS assigns a stop to a route's shape
# sequence even though the route does not actually serve that station in
# revenue service. The (station_id_prefix, route_id) pairs listed here are
# excluded from the attachment check so the test reflects operational reality
# rather than raw GTFS shape-stop snap artefacts.
#
# D14 "7 Av" (Park Slope B/D station) appears in several E-train shape-stop
# sequences because the GTFS shape for the E traces a track segment near that
# station. In practice the E train never serves D14.
KNOWN_GTFS_ARTIFACTS: frozenset[tuple[str, str]] = frozenset({
    ("D14", "E"),
})


def test_processed_stations_touch_exported_trunk_polylines():
    """Polylines must pass through the raw MTA station coordinates.

    Station positions are ground truth from the MTA — they never move.
    The polyline is responsible for routing through each station.
    This test verifies that the exported trunk polylines are within
    2 m of every raw MTA station position at the endpoint level.
    """
    shapes_response = client.get("/subway/shapes/all")
    assert shapes_response.status_code == 200
    shapes = shapes_response.json()

    stations_response = client.get("/subway/stations/all")
    assert stations_response.status_code == 200
    stations = stations_response.json()["stations"]

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

    for station in stations:
        # Derive the stop-id prefix (strip N/S direction suffix if present).
        station_id = station["id"]
        station_prefix = (
            station_id[:-1]
            if len(station_id) > 2 and station_id[-1] in "NS"
            else station_id
        )
        for route_id in station["routes"]:
            if (station_prefix, route_id) in KNOWN_GTFS_ARTIFACTS:
                continue

            lines = route_lines.get(route_id, [])
            if not lines:
                skipped_routes.add(route_id)
                continue

            x, y = _to_meters.transform(station["lon"], station["lat"])
            distance_m = min(line.distance(Point(x, y)) for line in lines)
            checked += 1

            if distance_m > 2.0:
                outliers.append((distance_m, station["name"], route_id))

    assert checked >= 1000
    assert skipped_routes <= SKIPPED_SYSTEM_MAP_VARIANTS
    assert not outliers, (
        "Raw MTA stations should sit on exported trunk polylines; "
        f"found outliers: {sorted(outliers, reverse=True)[:10]}"
    )
