from __future__ import annotations

import math
from typing import NamedTuple

from shapely.geometry import LineString, Point

import app.services.mapping.corridor_pipeline as corridor_pipeline
from app.models import SubwayLineOverlay
from app.routers.subway import get_all_subway_lines, get_subway_color
from app.services.mapping.subway_shapes import _load_route_shapes, _load_shapes, _unpack_coords
from app.utils.polyline_utils import (
    decode_polyline as _decode_polyline,
    densify_wgs84,
    encode_polyline as _encode_polyline,
)


SKIP_VARIANTS = {"6X", "7X", "FX", "FS", "GS", "SR"}


class GoldScene(NamedTuple):
    name: str
    min_lat: float
    max_lat: float
    min_lon: float
    max_lon: float


NYC_GOLD_SCENES: list[GoldScene] = [
    GoldScene("Lexington Ave", 40.7420, 40.7930, -73.9715, -73.9490),
    GoldScene("Queens Blvd", 40.7200, 40.7560, -73.8900, -73.8050),
    GoldScene("8th Ave", 40.6980, 40.7680, -74.0160, -73.9900),
    GoldScene("6th Ave", 40.7120, 40.7520, -74.0100, -73.9850),
    GoldScene("Broadway", 40.7000, 40.7650, -74.0150, -73.9800),
    GoldScene("DeKalb", 40.6850, 40.6955, -73.9890, -73.9760),
    GoldScene("Canal St", 40.7140, 40.7235, -74.0100, -73.9920),
    GoldScene("Times Sq / 42 St", 40.7520, 40.7615, -73.9935, -73.9820),
    GoldScene("Atlantic Ave / Barclays", 40.6800, 40.6885, -73.9835, -73.9700),
    GoldScene("Jay / Hoyt-Schermerhorn", 40.6860, 40.6960, -73.9970, -73.9830),
    GoldScene("Roosevelt Ave / Jackson Heights", 40.7420, 40.7585, -73.9000, -73.8720),
    GoldScene("Lefferts / Rockaway", 40.5800, 40.6840, -73.8400, -73.7400),
]


def percentile(values: list[float], percent: float) -> float:
    if not values:
        return 0.0
    if percent >= 100:
        return values[-1]
    index = int((len(values) - 1) * percent / 100.0)
    return values[index]


def summarize_distribution(values: list[float]) -> dict[str, float]:
    if not values:
        return {"count": 0, "min": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "min": ordered[0],
        "p50": percentile(ordered, 50),
        "p95": percentile(ordered, 95),
        "p99": percentile(ordered, 99),
        "max": ordered[-1],
    }


def _station_anchor(station: dict) -> tuple[float, float]:
    positions = station.get("positions", [])
    if not positions:
        return (0.0, 0.0)
    avg_lat = sum(pos["lat"] for pos in positions) / len(positions)
    avg_lon = sum(pos["lon"] for pos in positions) / len(positions)
    return (avg_lat, avg_lon)


def _scene_contains(scene: GoldScene, lat: float, lon: float) -> bool:
    return scene.min_lat <= lat <= scene.max_lat and scene.min_lon <= lon <= scene.max_lon


def _build_subway_overlays() -> list[SubwayLineOverlay]:
    route_shapes = _load_route_shapes()
    shapes_data = _load_shapes()
    overlays: list[SubwayLineOverlay] = []

    for line in get_all_subway_lines():
        if line in SKIP_VARIANTS:
            continue
        direction_shapes = route_shapes.get(line)
        if not direction_shapes:
            continue

        primary_dir = 0 if 0 in direction_shapes else min(direction_shapes.keys())
        polylines_raw: list[list[tuple[float, float]]] = []
        for shape_id in direction_shapes[primary_dir]:
            shape_buf = shapes_data.get(shape_id, b"")
            if not shape_buf:
                continue
            polylines_raw.append(_unpack_coords(shape_buf))

        if not polylines_raw:
            continue

        overlays.append(
            SubwayLineOverlay(
                route_id=line,
                color_hex=get_subway_color(line),
                polylines=[_encode_polyline(densify_wgs84(coords)) for coords in polylines_raw],
            )
        )

    return overlays


def _build_trunk_geometries(trunk_polylines: list[dict]) -> dict[int, list[LineString]]:
    result: dict[int, list[LineString]] = {}
    for trunk in trunk_polylines:
        lines: list[LineString] = []
        for encoded in trunk.get("polylines", []):
            coords = _decode_polyline(encoded)
            if len(coords) < 2:
                continue
            projected = [
                corridor_pipeline._to_meters.transform(lon, lat)
                for lat, lon in coords
            ]
            lines.append(LineString(projected))
        result[trunk["trunk_index"]] = lines
    return result


def _distance_to_lines(lat: float, lon: float, lines: list[LineString]) -> float:
    x, y = corridor_pipeline._to_meters.transform(lon, lat)
    point = Point(x, y)
    return min(line.distance(point) for line in lines)


def _station_attachment_metrics(
    processed_stops: list[dict],
    trunk_geometries: dict[int, list[LineString]],
) -> tuple[list[float], list[float], list[dict]]:
    station_distances: list[float] = []
    position_distances: list[float] = []
    outliers: list[dict] = []

    for station in processed_stops:
        positions = station.get("positions", [])
        if not positions:
            continue

        trunk_ids = {
            corridor_pipeline.ROUTE_TO_TRUNK.get(position["route_id"])
            for position in positions
        }
        trunk_ids.discard(None)
        lines = [line for trunk_idx in trunk_ids for line in trunk_geometries.get(trunk_idx, [])]
        if not lines:
            continue

        anchor_lat, anchor_lon = _station_anchor(station)
        station_distance = _distance_to_lines(anchor_lat, anchor_lon, lines)
        station_distances.append(station_distance)
        if station_distance > 15.0:
            outliers.append(
                {
                    "distance_m": station_distance,
                    "station_name": station["name"],
                    "routes": sorted({position["route_id"] for position in positions}),
                }
            )

        for position in positions:
            position_distances.append(
                _distance_to_lines(position["lat"], position["lon"], lines)
            )

    outliers.sort(key=lambda item: item["distance_m"], reverse=True)
    return station_distances, position_distances, outliers


def _segment_lengths_m(trunk_polylines: list[dict]) -> list[float]:
    lengths: list[float] = []
    for trunk in trunk_polylines:
        for encoded in trunk.get("polylines", []):
            coords = _decode_polyline(encoded)
            for start, end in zip(coords, coords[1:]):
                x0, y0 = corridor_pipeline._to_meters.transform(start[1], start[0])
                x1, y1 = corridor_pipeline._to_meters.transform(end[1], end[0])
                lengths.append(math.hypot(x1 - x0, y1 - y0))
    return lengths


def _lane_neighbor_deltas(trunk_polylines: list[dict]) -> list[dict]:
    lane_offsets = {trunk["trunk_index"]: trunk["lane_offset"] for trunk in trunk_polylines}
    deltas: list[dict] = []

    for left_trunk, neighbors in corridor_pipeline._corridor_neighbors_cache.items():
        for right_trunk in neighbors:
            if left_trunk >= right_trunk:
                continue
            left_offset = lane_offsets.get(left_trunk)
            right_offset = lane_offsets.get(right_trunk)
            if left_offset is None or right_offset is None:
                continue
            deltas.append(
                {
                    "left_trunk": left_trunk,
                    "right_trunk": right_trunk,
                    "delta": abs(left_offset - right_offset),
                }
            )

    deltas.sort(key=lambda item: item["delta"])
    return deltas


def _scene_summaries(
    trunk_polylines: list[dict],
    processed_stops: list[dict],
) -> list[dict]:
    summaries: list[dict] = []
    for scene in NYC_GOLD_SCENES:
        trunks_present: set[int] = set()
        for trunk in trunk_polylines:
            for encoded in trunk.get("polylines", []):
                coords = _decode_polyline(encoded)
                if any(_scene_contains(scene, lat, lon) for lat, lon in coords):
                    trunks_present.add(trunk["trunk_index"])
                    break

        station_count = 0
        transfer_count = 0
        for station in processed_stops:
            lat, lon = _station_anchor(station)
            if _scene_contains(scene, lat, lon):
                station_count += 1
                if station.get("is_transfer"):
                    transfer_count += 1

        summaries.append(
            {
                "name": scene.name,
                "trunk_count": len(trunks_present),
                "station_count": station_count,
                "transfer_count": transfer_count,
            }
        )

    return summaries


def build_subway_quality_snapshot() -> dict:
    overlays = _build_subway_overlays()
    corridor_pipeline.apply_topological_offsets(overlays)

    trunk_polylines = corridor_pipeline.get_trunk_polylines()
    processed_stops = corridor_pipeline.get_processed_stops()
    trunk_geometries = _build_trunk_geometries(trunk_polylines)

    station_distances, position_distances, outliers = _station_attachment_metrics(
        processed_stops,
        trunk_geometries,
    )
    segment_lengths = _segment_lengths_m(trunk_polylines)
    lane_neighbor_deltas = _lane_neighbor_deltas(trunk_polylines)
    lane_delta_values = [item["delta"] for item in lane_neighbor_deltas]

    return {
        "trunk_count": len(trunk_polylines),
        "polyline_count": sum(len(trunk.get("polylines", [])) for trunk in trunk_polylines),
        "station_count": len(processed_stops),
        "station_attachment_distances_m": station_distances,
        "position_attachment_distances_m": position_distances,
        "attachment_outliers": outliers,
        "station_attachment_summary": summarize_distribution(station_distances),
        "position_attachment_summary": summarize_distribution(position_distances),
        "segment_lengths_m": segment_lengths,
        "segment_length_summary": summarize_distribution(segment_lengths),
        "lane_neighbor_deltas": lane_neighbor_deltas,
        "lane_neighbor_delta_summary": summarize_distribution(lane_delta_values),
        "scene_summaries": _scene_summaries(trunk_polylines, processed_stops),
    }
