"""Post-processing quality checks and fixups for subway route polylines."""

from __future__ import annotations

import itertools
import math
from typing import TYPE_CHECKING, NamedTuple

from shapely.geometry import LineString, Point

import app.services.mapping.subway.corridor as corridor_pipeline
from app.models import SubwayLineOverlay
from app.routers.subway import get_all_subway_lines, get_subway_color
from app.services.mapping.subway.shapes import (
    _haversine,
    _load_route_shapes,
    _load_shapes,
    _unpack_coords,
)
from app.utils.polyline_utils import (
    decode_polyline as _decode_polyline,
)
from app.utils.polyline_utils import (
    densify_wgs84,
)
from app.utils.polyline_utils import (
    encode_polyline as _encode_polyline,
)

if TYPE_CHECKING:
    from shapely.geometry.base import BaseGeometry

# ═══════════════════════════════════════════════════════════════════════════════
# Zoom-level simulation constants
# ═══════════════════════════════════════════════════════════════════════════════
# Mirrors the iOS MapLibreStyleConfig zoom stops so backend tests can verify
# that the polyline-to-stop attachment holds at every zoom the user sees.

# Zoom → subway fill width (points). Copied from MapLibreStyleConfig.
ZOOM_FILL_WIDTH_STOPS: list[tuple[float, float]] = [
    (10.0, 1.2),
    (11.0, 1.6),
    (12.0, 2.2),
    (13.0, 2.8),
    (14.0, 3.5),
    (15.0, 4.2),
    (16.0, 5.0),
    (17.0, 6.0),
    (18.0, 7.0),
]
ZOOM_FILL_WIDTH: dict[int, float] = {
    int(zoom): width for zoom, width in ZOOM_FILL_WIDTH_STOPS
}
ZOOM_TEST_LEVELS: list[float] = [value / 2.0 for value in range(20, 37)]

# Zoom → approximate metres-per-pixel at NYC latitude (40.7°).
# These are the standard Web Mercator values × cos(40.7°).
_METRES_PER_PX_Z0 = 156_543.03 * math.cos(math.radians(40.7))
ZOOM_METRES_PER_PX: dict[int, float] = {
    z: _METRES_PER_PX_Z0 / (2**z) for z in range(10, 19)
}

# At each zoom, the acceptable displacement (metres) for a polyline
# vertex relative to a station anchor.  The rendered line width provides
# some visual margin: anything within half the rendered line width is
# visually "on top of" the station dot.  We add a small absolute
# tolerance to account for Google-polyline quantisation (±0.5 m).
LANE_OFFSET_TOUCH_RATIO = 0.98


def _max_acceptable_gap_m(zoom: int) -> float:
    """Maximum geographic gap (metres) that is still visually invisible.

    At the given zoom, a gap smaller than half the rendered line width
    (in metres) is covered by the stroke and therefore invisible.
    We add 1.5 m absolute tolerance for polyline encoding quantisation.
    """
    mpp = ZOOM_METRES_PER_PX.get(zoom, ZOOM_METRES_PER_PX[14])
    fill_px = ZOOM_FILL_WIDTH.get(zoom, ZOOM_FILL_WIDTH[14])
    half_line_m = (fill_px / 2.0) * mpp
    return half_line_m + 1.5


def _interpolated_zoom_value(
    zoom: float,
    stops: list[tuple[float, float]],
    base: float = 1.6,
) -> float:
    if not stops:
        return 0.0

    if zoom <= stops[0][0]:
        return stops[0][1]

    for idx in range(1, len(stops)):
        prev_zoom, prev_value = stops[idx - 1]
        next_zoom, next_value = stops[idx]
        if zoom <= next_zoom:
            span = next_zoom - prev_zoom
            if span <= 0:
                return next_value
            progress = max(0.0, min(zoom - prev_zoom, span))
            if abs(base - 1.0) < 1e-9:
                t = progress / span
            else:
                numerator = pow(base, progress) - 1.0
                denominator = pow(base, span) - 1.0
                t = 0.0 if denominator == 0 else numerator / denominator
            return prev_value + (next_value - prev_value) * t

    return stops[-1][1]


def _fill_width_px_at_zoom(zoom: float) -> float:
    return _interpolated_zoom_value(zoom, ZOOM_FILL_WIDTH_STOPS, base=1.6)


def _metres_per_px_at_zoom(zoom: float) -> float:
    return _METRES_PER_PX_Z0 / (2**zoom)


def _lane_offset_multiplier_at_zoom(zoom: float) -> float:
    return _fill_width_px_at_zoom(zoom) * LANE_OFFSET_TOUCH_RATIO


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


class RenderBranch(NamedTuple):
    geometry: LineString
    lane_offset: float


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
    return (
        scene.min_lat <= lat <= scene.max_lat and scene.min_lon <= lon <= scene.max_lon
    )


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
                polylines=[
                    _encode_polyline(densify_wgs84(coords)) for coords in polylines_raw
                ],
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
                corridor_pipeline._to_meters.transform(lon, lat) for lat, lon in coords
            ]
            lines.append(LineString(projected))
        result[trunk["trunk_index"]] = lines
    return result


def _build_render_branches(
    trunk_polylines: list[dict],
) -> dict[int, list[RenderBranch]]:
    result: dict[int, list[RenderBranch]] = {}
    for trunk in trunk_polylines:
        encoded_polylines = trunk.get("polylines", [])
        local_offsets = trunk.get("polyline_lane_offsets", [])
        branches: list[RenderBranch] = []
        for idx, encoded in enumerate(encoded_polylines):
            coords = _decode_polyline(encoded)
            if len(coords) < 2:
                continue
            projected = [
                corridor_pipeline._to_meters.transform(lon, lat) for lat, lon in coords
            ]
            lane_offset = (
                float(local_offsets[idx])
                if idx < len(local_offsets)
                else float(trunk.get("lane_offset", 0.0))
            )
            branches.append(RenderBranch(LineString(projected), lane_offset))
        result[trunk["trunk_index"]] = branches
    return result


def _distance_to_lines(lat: float, lon: float, lines: list[LineString]) -> float:
    x, y = corridor_pipeline._to_meters.transform(lon, lat)
    point = Point(x, y)
    return min(line.distance(point) for line in lines)


def _offset_geometry_for_zoom(
    geometry: LineString,
    lane_offset: float,
    zoom: float,
) -> BaseGeometry:
    if abs(lane_offset) < 1e-9:
        return geometry

    offset_m = (
        lane_offset
        * _lane_offset_multiplier_at_zoom(zoom)
        * _metres_per_px_at_zoom(zoom)
    )
    if abs(offset_m) < 1e-9:
        return geometry

    side = "right" if offset_m > 0 else "left"
    try:
        shifted = geometry.parallel_offset(abs(offset_m), side=side, join_style=1)
        if shifted.is_empty:
            return geometry
        return shifted
    except Exception:
        return geometry


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
        lines = [
            line
            for trunk_idx in trunk_ids
            for line in trunk_geometries.get(trunk_idx, [])
        ]
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


def _rendered_gap_for_station(
    station: dict,
    render_branches: dict[int, list[RenderBranch]],
    zoom: float,
) -> float | None:
    lat = station["lat"]
    lon = station["lon"]
    x, y = corridor_pipeline._to_meters.transform(lon, lat)
    point = Point(x, y)

    trunk_ids: set[int] = set()
    for rid in station.get("routes", []):
        trunk_idx = corridor_pipeline.ROUTE_TO_TRUNK.get(rid)
        if trunk_idx is not None:
            trunk_ids.add(trunk_idx)

    best = float("inf")
    found = False
    for trunk_idx in trunk_ids:
        for branch in render_branches.get(trunk_idx, []):
            rendered = _offset_geometry_for_zoom(
                branch.geometry, branch.lane_offset, zoom
            )
            distance = rendered.distance(point)
            if distance < best:
                best = distance
                found = True

    return best if found else None


def _segment_lengths_m(trunk_polylines: list[dict]) -> list[float]:
    lengths: list[float] = []
    for trunk in trunk_polylines:
        for encoded in trunk.get("polylines", []):
            coords = _decode_polyline(encoded)
            for start, end in itertools.pairwise(coords):
                x0, y0 = corridor_pipeline._to_meters.transform(start[1], start[0])
                x1, y1 = corridor_pipeline._to_meters.transform(end[1], end[0])
                lengths.append(math.hypot(x1 - x0, y1 - y0))
    return lengths


def _lane_neighbor_deltas(trunk_polylines: list[dict]) -> list[dict]:
    lane_offsets = {
        trunk["trunk_index"]: trunk["lane_offset"] for trunk in trunk_polylines
    }
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


def _merged_path_count() -> int:
    raw_paths = corridor_pipeline._trunk_raw_paths_cache or {}
    return sum(len(paths) for paths in raw_paths.values())


def _endpoint_gap_outliers(trunk_polylines: list[dict]) -> list[dict]:
    """Find suspicious export gaps between nearby polyline endpoints.

    If two endpoints from the same trunk are close enough to plausibly
    continue the same corridor (< 500 m) but still stop more than 100 m
    apart, the export is likely fragmented. That is exactly the artifact
    the system-map client renders as broken or strangely kinked trunks.
    """
    outliers: list[dict] = []
    gap_threshold_m = 100.0
    near_threshold_m = 500.0

    for trunk in trunk_polylines:
        decoded: list[list[tuple[float, float]]] = []
        for encoded in trunk.get("polylines", []):
            coords = _decode_polyline(encoded)
            if len(coords) >= 2:
                decoded.append(coords)
        if len(decoded) < 2:
            continue

        endpoints: list[tuple[int, str, tuple[float, float]]] = []
        for idx, coords in enumerate(decoded):
            endpoints.append((idx, "start", coords[0]))
            endpoints.append((idx, "end", coords[-1]))

        def _nearest_opposite_endpoint(
            polyline_index: int,
            endpoint_tag: str,
            point: tuple[float, float],
        ) -> tuple[int, str, tuple[float, float], float] | None:
            target_tag = "end" if endpoint_tag == "start" else "start"
            best: tuple[int, str, tuple[float, float], float] | None = None
            for other_idx, other_tag, other_point in endpoints:
                if other_idx == polyline_index or other_tag != target_tag:
                    continue
                dist = _haversine(
                    point[0], point[1], other_point[0], other_point[1]
                )
                if best is None or dist < best[3]:
                    best = (other_idx, other_tag, other_point, dist)
            return best

        seen_pairs: set[frozenset[tuple[int, str]]] = set()

        for idx, coords in enumerate(decoded):
            for endpoint_tag, point in (("start", coords[0]), ("end", coords[-1])):
                nearest = _nearest_opposite_endpoint(idx, endpoint_tag, point)
                if nearest is None:
                    continue

                other_idx, other_tag, other_point, distance_m = nearest
                if not (gap_threshold_m < distance_m < near_threshold_m):
                    continue

                reverse = _nearest_opposite_endpoint(
                    other_idx, other_tag, other_point
                )
                if reverse is None:
                    continue
                if reverse[0] != idx or reverse[1] != endpoint_tag:
                    continue

                pair_key = frozenset({(idx, endpoint_tag), (other_idx, other_tag)})
                if pair_key in seen_pairs:
                    continue
                seen_pairs.add(pair_key)

                outliers.append(
                    {
                        "trunk_index": trunk["trunk_index"],
                        "route_ids": trunk["route_ids"],
                        "polyline_index": idx,
                        "endpoint": endpoint_tag,
                        "distance_m": distance_m,
                        "nearest_polyline_index": other_idx,
                        "nearest_endpoint": other_tag,
                    }
                )

    outliers.sort(key=lambda item: item["distance_m"], reverse=True)
    return outliers


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
    render_branches = _build_render_branches(trunk_polylines)

    station_distances, position_distances, outliers = _station_attachment_metrics(
        processed_stops,
        trunk_geometries,
    )

    # Raw MTA station → polyline attachment (ground truth — stops never move)
    raw_mta_distances, raw_mta_outliers = _raw_mta_station_attachment(trunk_geometries)

    # Per-zoom-level quality analysis
    zoom_quality = _zoom_level_quality(render_branches)

    segment_lengths = _segment_lengths_m(trunk_polylines)
    lane_neighbor_deltas = _lane_neighbor_deltas(trunk_polylines)
    lane_delta_values = [item["delta"] for item in lane_neighbor_deltas]
    endpoint_gap_outliers = _endpoint_gap_outliers(trunk_polylines)

    return {
        "trunk_count": len(trunk_polylines),
        "merged_path_count": _merged_path_count(),
        "polyline_count": sum(
            len(trunk.get("polylines", [])) for trunk in trunk_polylines
        ),
        "station_count": len(processed_stops),
        "station_attachment_distances_m": station_distances,
        "position_attachment_distances_m": position_distances,
        "attachment_outliers": outliers,
        "station_attachment_summary": summarize_distribution(station_distances),
        "position_attachment_summary": summarize_distribution(position_distances),
        # Raw MTA station attachment: polyline must reach the stop, not vice versa
        "raw_mta_attachment_distances_m": raw_mta_distances,
        "raw_mta_attachment_summary": summarize_distribution(raw_mta_distances),
        "raw_mta_outliers": raw_mta_outliers,
        # Per-zoom quality (zoom 10–18)
        "zoom_quality": zoom_quality,
        "segment_lengths_m": segment_lengths,
        "segment_length_summary": summarize_distribution(segment_lengths),
        "endpoint_gap_outliers": endpoint_gap_outliers,
        "lane_neighbor_deltas": lane_neighbor_deltas,
        "lane_neighbor_delta_summary": summarize_distribution(lane_delta_values),
        "scene_summaries": _scene_summaries(trunk_polylines, processed_stops),
    }


# ═══════════════════════════════════════════════════════════════════════════════
# Raw MTA station attachment — ground truth metric
# ═══════════════════════════════════════════════════════════════════════════════


def _raw_mta_station_attachment(
    trunk_geometries: dict[int, list[LineString]],
) -> tuple[list[float], list[dict]]:
    """Measure distance from every raw MTA station to its trunk polylines.

    Unlike ``_station_attachment_metrics`` (which uses processed/snapped
    positions), this function Always uses the exact coordinates the MTA
    published.  The polyline is what must move — these distances tell us
    how well the polyline passes through the station.
    """
    from app.services.mapping.subway.shapes import get_all_subway_stations

    raw_stations = get_all_subway_stations()
    if not raw_stations:
        return [], []

    distances: list[float] = []
    outliers: list[dict] = []

    for station in raw_stations:
        lat = station["lat"]
        lon = station["lon"]
        routes = station.get("routes", [])

        trunk_ids: set[int] = set()
        for rid in routes:
            t = corridor_pipeline.ROUTE_TO_TRUNK.get(rid)
            if t is not None:
                trunk_ids.add(t)

        lines = [
            line
            for trunk_idx in trunk_ids
            for line in trunk_geometries.get(trunk_idx, [])
        ]
        if not lines:
            continue

        dist = _distance_to_lines(lat, lon, lines)
        distances.append(dist)

        if dist > 10.0:
            outliers.append(
                {
                    "distance_m": dist,
                    "station_name": station["name"],
                    "station_id": station["id"],
                    "routes": sorted(set(routes)),
                }
            )

    outliers.sort(key=lambda item: item["distance_m"], reverse=True)
    return distances, outliers


# ═══════════════════════════════════════════════════════════════════════════════
# Zoom-level quality analysis
# ═══════════════════════════════════════════════════════════════════════════════


def _zoom_level_quality(
    render_branches: dict[int, list[RenderBranch]],
) -> list[dict]:
    """Evaluate rendered polyline-to-station fit at every zoom checkpoint.

    For each zoom we compute:
      - ``max_acceptable_gap_m``: the geographic distance that is invisible
        because it falls within half the rendered line width.
      - ``stations_visible_gap``: count of stations whose polyline gap
        exceeds the rendered line width (i.e. the gap is visible).
      - ``pct_within_line``: percentage of stations whose gap is hidden by
        the rendered stroke.
      - ``worst_gap_m``: largest raw gap for reference.

    The important detail is that this uses the exported per-polyline
    ``polyline_lane_offsets`` and simulates the same zoom-dependent
    screen-space lineOffset shift the iOS client applies.  Raw MTA stop
    coordinates remain fixed; the rendered line is what must cover them.
    """
    from app.services.mapping.subway.shapes import get_all_subway_stations

    raw_stations = get_all_subway_stations()
    if not raw_stations:
        return []

    all_lane_offsets = [
        abs(branch.lane_offset)
        for branches in render_branches.values()
        for branch in branches
    ]
    results: list[dict] = []

    for zoom in ZOOM_TEST_LEVELS:
        fill_px = _fill_width_px_at_zoom(zoom)
        mpp = _metres_per_px_at_zoom(zoom)
        gap = (fill_px / 2.0) * mpp + 1.5

        distances: list[float] = []
        for station in raw_stations:
            distance = _rendered_gap_for_station(station, render_branches, zoom)
            if distance is not None:
                distances.append(distance)

        sorted_dists = sorted(distances)
        total = len(sorted_dists)
        # Count stations with a visible (larger than line-width) gap
        visible_count = sum(1 for d in sorted_dists if d > gap)
        pct_within = 100.0 * (total - visible_count) / total if total else 0.0

        max_lane_offset = max(all_lane_offsets, default=0.0)
        max_lane_displacement_m = (
            max_lane_offset * _lane_offset_multiplier_at_zoom(zoom) * mpp
        )

        results.append(
            {
                "zoom": zoom,
                "metres_per_px": round(mpp, 4),
                "fill_width_px": round(fill_px, 3),
                "max_acceptable_gap_m": round(gap, 3),
                "stations_visible_gap": visible_count,
                "pct_within_line": round(pct_within, 2),
                "worst_gap_m": round(sorted_dists[-1], 3) if sorted_dists else 0.0,
                "p95_gap_m": (
                    round(percentile(sorted_dists, 95), 3) if sorted_dists else 0.0
                ),
                "max_lane_displacement_m": round(max_lane_displacement_m, 3),
            }
        )

    return results
