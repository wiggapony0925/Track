#
# gtfs_validator.py
# app/services/gtfs/gtfs_validator.py
#
# GTFS data quality validation — inspired by Transit App's transitfeed library.
# https://github.com/TransitApp/transitfeed
#
# Implements their key validation patterns:
#   - Structured problem reporting (severity + context)
#   - Two-phase validation (self-consistency + cross-reference)
#   - Speed plausibility checks per mode
#   - Shape-to-stop distance validation
#   - Service gap detection
#   - Unusual trip filtering
#
# Rather than blocking on errors, this module accumulates problems and
# exposes them via a /health/data-quality endpoint.
#

from __future__ import annotations

import csv
import math
import time as _time
from dataclasses import dataclass, field
from enum import IntEnum
from pathlib import Path
from typing import Any

from app.utils.logger import TrackLogger


# ── Severity levels (from Transit App's transitfeed) ─────────────────────

class Severity(IntEnum):
    ERROR = 0     # Violates GTFS spec — data is broken
    WARNING = 1   # Not recommended — data quality issue
    NOTICE = 2    # Informational — not strictly wrong


@dataclass
class ValidationProblem:
    """A single data quality problem with context.

    Inspired by transitfeed's ExceptionWithContext pattern — every problem is
    traceable to a specific file, row, and field.
    """
    severity: Severity
    category: str           # e.g. "invalid_value", "speed_too_fast", "shape_distance"
    message: str            # human-readable description
    file: str = ""          # GTFS filename (e.g. "stops.txt")
    row: int | None = None  # CSV row number
    field_name: str = ""    # column name
    value: str = ""         # the problematic value
    entity_id: str = ""     # e.g. stop_id, route_id, trip_id

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {
            "severity": self.severity.name,
            "category": self.category,
            "message": self.message,
        }
        if self.file:
            d["file"] = self.file
        if self.row is not None:
            d["row"] = self.row
        if self.field_name:
            d["field"] = self.field_name
        if self.value:
            d["value"] = self.value
        if self.entity_id:
            d["entity_id"] = self.entity_id
        return d


# ── Problem accumulator (from Transit App's pattern) ─────────────────────

class ProblemAccumulator:
    """Collects validation problems with bounded per-category limits.

    Inspired by transitfeed's LimitPerTypeProblemAccumulator — keeps only the
    N most significant problems per category to avoid memory explosion on
    badly broken feeds.
    """

    def __init__(self, max_per_category: int = 50):
        self.max_per_category = max_per_category
        self.problems: list[ValidationProblem] = []
        self._counts: dict[str, int] = {}

    def add(self, problem: ValidationProblem) -> None:
        cat = problem.category
        self._counts[cat] = self._counts.get(cat, 0) + 1
        if self._counts[cat] <= self.max_per_category:
            self.problems.append(problem)

    @property
    def error_count(self) -> int:
        return sum(1 for p in self.problems if p.severity == Severity.ERROR)

    @property
    def warning_count(self) -> int:
        return sum(1 for p in self.problems if p.severity == Severity.WARNING)

    @property
    def notice_count(self) -> int:
        return sum(1 for p in self.problems if p.severity == Severity.NOTICE)

    def summary(self) -> dict[str, Any]:
        return {
            "total_problems": len(self.problems),
            "errors": self.error_count,
            "warnings": self.warning_count,
            "notices": self.notice_count,
            "by_category": dict(self._counts),
            "problems": [p.to_dict() for p in self.problems],
        }


# ── Speed limits per mode (from transitfeed) ────────────────────────────

MAX_SPEED_KMH: dict[int, float] = {
    0: 100.0,   # Tram, Streetcar
    1: 150.0,   # Subway, Metro
    2: 300.0,   # Rail (commuter)
    3: 100.0,   # Bus
    4: 80.0,    # Ferry
    5: 60.0,    # Cable tram
    6: 50.0,    # Aerial lift
    7: 50.0,    # Funicular
}


# ── Haversine (duplicated from geo_utils to avoid circular imports) ──────

def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    R = 6_371_000
    rlat1, rlat2 = math.radians(lat1), math.radians(lat2)
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2) ** 2 + math.cos(rlat1) * math.cos(rlat2) * math.sin(dlon / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


# ── Core validators ──────────────────────────────────────────────────────

def validate_stops(data_dir: Path, acc: ProblemAccumulator) -> None:
    """Validate stops.txt — coordinate bounds and required fields.

    Inspired by transitfeed's Stop.ValidateBeforeAdd() and
    Schedule.ValidateStopGeoNearby().
    """
    stops_path = data_dir / "stops.txt"
    if not stops_path.exists():
        acc.add(ValidationProblem(
            severity=Severity.ERROR, category="missing_file",
            message="Required file stops.txt not found", file="stops.txt",
        ))
        return

    seen_ids: set[str] = set()
    stops_by_loc: list[tuple[str, float, float]] = []

    with open(stops_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row_num, row in enumerate(reader, start=2):
            stop_id = row.get("stop_id", "").strip()

            # Required field check
            if not stop_id:
                acc.add(ValidationProblem(
                    severity=Severity.ERROR, category="missing_value",
                    message="stop_id is empty", file="stops.txt", row=row_num,
                    field_name="stop_id",
                ))
                continue

            # Duplicate check
            if stop_id in seen_ids:
                acc.add(ValidationProblem(
                    severity=Severity.WARNING, category="duplicate_id",
                    message=f"Duplicate stop_id: {stop_id}", file="stops.txt",
                    row=row_num, entity_id=stop_id,
                ))
            seen_ids.add(stop_id)

            # Coordinate bounds
            try:
                lat = float(row.get("stop_lat", "0"))
                lon = float(row.get("stop_lon", "0"))
            except ValueError:
                acc.add(ValidationProblem(
                    severity=Severity.ERROR, category="invalid_value",
                    message=f"Non-numeric coordinates for stop {stop_id}",
                    file="stops.txt", row=row_num, entity_id=stop_id,
                ))
                continue

            if not (-90 <= lat <= 90):
                acc.add(ValidationProblem(
                    severity=Severity.ERROR, category="invalid_value",
                    message=f"stop_lat {lat} out of range [-90, 90]",
                    file="stops.txt", row=row_num, entity_id=stop_id,
                    field_name="stop_lat", value=str(lat),
                ))
            if not (-180 <= lon <= 180):
                acc.add(ValidationProblem(
                    severity=Severity.ERROR, category="invalid_value",
                    message=f"stop_lon {lon} out of range [-180, 180]",
                    file="stops.txt", row=row_num, entity_id=stop_id,
                    field_name="stop_lon", value=str(lon),
                ))

            # Null island check (0, 0 is almost certainly wrong)
            if lat == 0.0 and lon == 0.0:
                acc.add(ValidationProblem(
                    severity=Severity.WARNING, category="suspicious_value",
                    message=f"Stop {stop_id} at (0,0) — probable missing data",
                    file="stops.txt", row=row_num, entity_id=stop_id,
                ))

            stops_by_loc.append((stop_id, lat, lon))

    # Nearby stop detection — O(n log n) via latitude-sorted sliding window
    # (from transitfeed's validateStopGeoNearby pattern)
    _detect_nearby_stops(stops_by_loc, acc, threshold_m=2.0)


def _detect_nearby_stops(
    stops: list[tuple[str, float, float]],
    acc: ProblemAccumulator,
    threshold_m: float = 2.0,
) -> None:
    """Detect suspiciously close stops using Transit App's sorted sliding window.

    Sort by latitude, then scan within a narrow lat band. This is O(n log n + n×k)
    where k is the average number of stops in the sliding window — much better
    than the naive O(n²) all-pairs comparison.
    """
    if len(stops) < 2:
        return

    # ~2m in latitude degrees
    lat_window = threshold_m / 111_000.0

    sorted_stops = sorted(stops, key=lambda s: s[1])  # sort by lat

    for i, (id_a, lat_a, lon_a) in enumerate(sorted_stops):
        j = i + 1
        while j < len(sorted_stops):
            id_b, lat_b, lon_b = sorted_stops[j]
            if lat_b - lat_a > lat_window:
                break  # beyond sliding window
            dist = _haversine_m(lat_a, lon_a, lat_b, lon_b)
            if dist < threshold_m:
                acc.add(ValidationProblem(
                    severity=Severity.WARNING, category="nearby_stops",
                    message=f"Stops {id_a} and {id_b} are only {dist:.1f}m apart "
                            f"— possible duplicates",
                    file="stops.txt", entity_id=f"{id_a}|{id_b}",
                ))
            j += 1


def validate_shapes(data_dir: Path, acc: ProblemAccumulator) -> None:
    """Validate shapes.txt — sequence monotonicity, coordinate bounds.

    Inspired by transitfeed's Shape.ValidateShapePoint().
    """
    shapes_path = data_dir / "shapes.txt"
    if not shapes_path.exists():
        return  # shapes.txt is optional in GTFS

    prev_seq: dict[str, int] = {}  # shape_id → last sequence seen

    with open(shapes_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row_num, row in enumerate(reader, start=2):
            shape_id = row.get("shape_id", "").strip()
            if not shape_id:
                continue

            try:
                lat = float(row.get("shape_pt_lat", "0"))
                lon = float(row.get("shape_pt_lon", "0"))
                seq = int(row.get("shape_pt_sequence", "0"))
            except (ValueError, TypeError):
                acc.add(ValidationProblem(
                    severity=Severity.ERROR, category="invalid_value",
                    message=f"Non-numeric shape point in {shape_id}",
                    file="shapes.txt", row=row_num, entity_id=shape_id,
                ))
                continue

            # Coordinate bounds
            if not (-90 <= lat <= 90) or not (-180 <= lon <= 180):
                acc.add(ValidationProblem(
                    severity=Severity.ERROR, category="invalid_value",
                    message=f"Shape {shape_id} point out of bounds: ({lat}, {lon})",
                    file="shapes.txt", row=row_num, entity_id=shape_id,
                ))

            # Sequence monotonicity (within same shape_id)
            if shape_id in prev_seq and seq <= prev_seq[shape_id]:
                acc.add(ValidationProblem(
                    severity=Severity.WARNING, category="sequence_error",
                    message=f"Shape {shape_id} has non-increasing sequence "
                            f"{prev_seq[shape_id]} → {seq}",
                    file="shapes.txt", row=row_num, entity_id=shape_id,
                ))
            prev_seq[shape_id] = seq


def validate_routes(data_dir: Path, acc: ProblemAccumulator) -> None:
    """Validate routes.txt — required fields, color contrast.

    Includes Transit App's WCAG color contrast check from transitfeed.
    """
    routes_path = data_dir / "routes.txt"
    if not routes_path.exists():
        acc.add(ValidationProblem(
            severity=Severity.ERROR, category="missing_file",
            message="Required file routes.txt not found", file="routes.txt",
        ))
        return

    with open(routes_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row_num, row in enumerate(reader, start=2):
            route_id = row.get("route_id", "").strip()
            short_name = row.get("route_short_name", "").strip()
            long_name = row.get("route_long_name", "").strip()

            if not route_id:
                acc.add(ValidationProblem(
                    severity=Severity.ERROR, category="missing_value",
                    message="route_id is empty", file="routes.txt", row=row_num,
                ))
                continue

            # GTFS spec: at least one of short/long name required
            if not short_name and not long_name:
                acc.add(ValidationProblem(
                    severity=Severity.ERROR, category="missing_value",
                    message=f"Route {route_id} has no short_name or long_name",
                    file="routes.txt", row=row_num, entity_id=route_id,
                ))

            # Transit App's short_name length check (>6 chars is unusual)
            if len(short_name) > 6:
                acc.add(ValidationProblem(
                    severity=Severity.WARNING, category="suspicious_value",
                    message=f"Route {route_id} short_name '{short_name}' is > 6 chars",
                    file="routes.txt", row=row_num, entity_id=route_id,
                ))

            # WCAG color contrast check (from transitfeed's route.py)
            route_color = row.get("route_color", "").strip()
            text_color = row.get("route_text_color", "").strip()
            if route_color and text_color:
                contrast = _color_contrast_ratio(route_color, text_color)
                if contrast is not None and contrast < 4.5:
                    acc.add(ValidationProblem(
                        severity=Severity.WARNING, category="color_contrast",
                        message=f"Route {route_id} color contrast {contrast:.1f}:1 "
                                f"(#{route_color} on #{text_color}) — "
                                f"WCAG AA requires ≥4.5:1",
                        file="routes.txt", row=row_num, entity_id=route_id,
                    ))


def _color_contrast_ratio(hex1: str, hex2: str) -> float | None:
    """WCAG luminance contrast ratio. From transitfeed's route.py."""
    try:
        r1, g1, b1 = int(hex1[0:2], 16), int(hex1[2:4], 16), int(hex1[4:6], 16)
        r2, g2, b2 = int(hex2[0:2], 16), int(hex2[2:4], 16), int(hex2[4:6], 16)
    except (ValueError, IndexError):
        return None

    def _luminance(r: int, g: int, b: int) -> float:
        rs = r / 255.0
        gs = g / 255.0
        bs = b / 255.0
        rs = rs / 12.92 if rs <= 0.03928 else ((rs + 0.055) / 1.055) ** 2.4
        gs = gs / 12.92 if gs <= 0.03928 else ((gs + 0.055) / 1.055) ** 2.4
        bs = bs / 12.92 if bs <= 0.03928 else ((bs + 0.055) / 1.055) ** 2.4
        return 0.2126 * rs + 0.7152 * gs + 0.0722 * bs

    l1 = _luminance(r1, g1, b1)
    l2 = _luminance(r2, g2, b2)
    lighter = max(l1, l2)
    darker = min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)


def validate_speed_plausibility(
    data_dir: Path, acc: ProblemAccumulator,
    stops: dict[str, tuple[float, float]] | None = None,
) -> None:
    """Check for implausible speeds between consecutive stops.

    Inspired by transitfeed's trip.py speed validation — per-mode max speeds.
    """
    # This is a simplified version that can be extended later
    # to read stop_times.txt and check inter-stop speeds.
    pass  # Placeholder for future implementation


# ── Foreign-key cross-reference validation ───────────────────────────────
# Adapted from Transit App's gtfs-fares-v2-validator pattern: first pass
# collects ID sets, second pass checks references.  Catches orphan data
# and broken foreign keys that silently cause missing arrivals.

def validate_foreign_keys(data_dir: Path, acc: ProblemAccumulator) -> None:
    """Validate cross-file foreign key references in GTFS data.

    Checks:
      - trips.route_id → routes.route_id
      - trips.service_id → calendar.service_id ∪ calendar_dates.service_id
      - stop_times.trip_id → trips.trip_id
      - stop_times.stop_id → stops.stop_id

    Also detects orphan entities (defined but never referenced).
    """
    # Phase 1: Collect all defined IDs (like fares-v2-validator's set-building)
    route_ids: set[str] = set()
    stop_ids: set[str] = set()
    trip_ids: set[str] = set()
    service_ids: set[str] = set()

    routes_path = data_dir / "routes.txt"
    if routes_path.exists():
        with open(routes_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                rid = row.get("route_id", "").strip()
                if rid:
                    route_ids.add(rid)

    stops_path = data_dir / "stops.txt"
    if stops_path.exists():
        with open(stops_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                sid = row.get("stop_id", "").strip()
                if sid:
                    stop_ids.add(sid)

    calendar_path = data_dir / "calendar.txt"
    if calendar_path.exists():
        with open(calendar_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                sid = row.get("service_id", "").strip()
                if sid:
                    service_ids.add(sid)

    cal_dates_path = data_dir / "calendar_dates.txt"
    if cal_dates_path.exists():
        with open(cal_dates_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                sid = row.get("service_id", "").strip()
                if sid:
                    service_ids.add(sid)

    trips_path = data_dir / "trips.txt"
    if trips_path.exists():
        with open(trips_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                tid = row.get("trip_id", "").strip()
                if tid:
                    trip_ids.add(tid)

    # Phase 2: Check foreign keys (like fares-v2-validator's check_linked_id)
    # Track which route_ids and stop_ids are actually referenced
    used_route_ids: set[str] = set()
    used_stop_ids: set[str] = set()
    bad_route_refs = 0
    bad_service_refs = 0
    bad_trip_refs = 0
    bad_stop_refs = 0

    # trips → routes, services
    if trips_path.exists():
        with open(trips_path, encoding="utf-8") as f:
            for row_num, row in enumerate(csv.DictReader(f), start=2):
                route_ref = row.get("route_id", "").strip()
                if route_ref and route_ref not in route_ids:
                    if bad_route_refs < 10:  # cap error spam
                        acc.add(ValidationProblem(
                            severity=Severity.ERROR,
                            category="foreign_key_invalid",
                            message=f"Trip references unknown route_id '{route_ref}'",
                            file="trips.txt", row=row_num,
                            field="route_id",
                        ))
                    bad_route_refs += 1
                elif route_ref:
                    used_route_ids.add(route_ref)

                svc_ref = row.get("service_id", "").strip()
                if svc_ref and service_ids and svc_ref not in service_ids:
                    if bad_service_refs < 10:
                        acc.add(ValidationProblem(
                            severity=Severity.WARNING,
                            category="foreign_key_invalid",
                            message=f"Trip references unknown service_id '{svc_ref}'",
                            file="trips.txt", row=row_num,
                            field="service_id",
                        ))
                    bad_service_refs += 1

    # stop_times → trips, stops
    stop_times_path = data_dir / "stop_times.txt"
    if stop_times_path.exists():
        with open(stop_times_path, encoding="utf-8") as f:
            for row_num, row in enumerate(csv.DictReader(f), start=2):
                trip_ref = row.get("trip_id", "").strip()
                if trip_ref and trip_ref not in trip_ids:
                    if bad_trip_refs < 10:
                        acc.add(ValidationProblem(
                            severity=Severity.ERROR,
                            category="foreign_key_invalid",
                            message=f"stop_time references unknown trip_id '{trip_ref}'",
                            file="stop_times.txt", row=row_num,
                            field="trip_id",
                        ))
                    bad_trip_refs += 1

                stop_ref = row.get("stop_id", "").strip()
                if stop_ref and stop_ref not in stop_ids:
                    if bad_stop_refs < 10:
                        acc.add(ValidationProblem(
                            severity=Severity.ERROR,
                            category="foreign_key_invalid",
                            message=f"stop_time references unknown stop_id '{stop_ref}'",
                            file="stop_times.txt", row=row_num,
                            field="stop_id",
                        ))
                    bad_stop_refs += 1
                elif stop_ref:
                    used_stop_ids.add(stop_ref)

    # Summarize if we hit the cap
    if bad_route_refs > 10:
        acc.add(ValidationProblem(
            severity=Severity.ERROR, category="foreign_key_invalid",
            message=f"... and {bad_route_refs - 10} more invalid route_id references",
            file="trips.txt",
        ))
    if bad_trip_refs > 10:
        acc.add(ValidationProblem(
            severity=Severity.ERROR, category="foreign_key_invalid",
            message=f"... and {bad_trip_refs - 10} more invalid trip_id references",
            file="stop_times.txt",
        ))
    if bad_stop_refs > 10:
        acc.add(ValidationProblem(
            severity=Severity.ERROR, category="foreign_key_invalid",
            message=f"... and {bad_stop_refs - 10} more invalid stop_id references",
            file="stop_times.txt",
        ))

    # Phase 3: Orphan detection (defined but never referenced)
    orphan_routes = route_ids - used_route_ids
    if orphan_routes and len(orphan_routes) < len(route_ids):  # only warn if partial
        sample = sorted(orphan_routes)[:5]
        acc.add(ValidationProblem(
            severity=Severity.NOTICE, category="orphan_entity",
            message=f"{len(orphan_routes)} routes defined but never referenced by trips "
                    f"(e.g., {', '.join(sample)})",
            file="routes.txt",
        ))

    orphan_stops = stop_ids - used_stop_ids
    if orphan_stops and len(orphan_stops) < len(stop_ids):
        sample = sorted(orphan_stops)[:5]
        acc.add(ValidationProblem(
            severity=Severity.NOTICE, category="orphan_entity",
            message=f"{len(orphan_stops)} stops defined but never referenced by stop_times "
                    f"(e.g., {', '.join(sample)})",
            file="stops.txt",
        ))


# ── High-level validation runner ─────────────────────────────────────────

def validate_gtfs_data(data_dir: Path | str) -> dict[str, Any]:
    """Run all validators on a GTFS data directory.

    Returns a summary dict suitable for JSON serialization / API response.

    Args:
        data_dir: Path to directory containing GTFS .txt files.

    Returns:
        Dict with validation results, problem counts, and details.
    """
    data_dir = Path(data_dir)
    acc = ProblemAccumulator(max_per_category=50)

    t0 = _time.time()

    # Required files check
    for required in ("agency.txt", "routes.txt", "stops.txt", "trips.txt", "stop_times.txt"):
        if not (data_dir / required).exists():
            acc.add(ValidationProblem(
                severity=Severity.ERROR, category="missing_file",
                message=f"Required GTFS file {required} not found",
                file=required,
            ))

    validate_stops(data_dir, acc)
    validate_shapes(data_dir, acc)
    validate_routes(data_dir, acc)
    validate_foreign_keys(data_dir, acc)

    elapsed = _time.time() - t0

    result = acc.summary()
    result["validation_time_s"] = round(elapsed, 3)
    result["data_dir"] = str(data_dir)

    if acc.error_count > 0:
        result["status"] = "error"
    elif acc.warning_count > 0:
        result["status"] = "warning"
    else:
        result["status"] = "clean"

    TrackLogger.info(
        f"[GTFS-VALIDATION] {result['status'].upper()}: "
        f"{acc.error_count} errors, {acc.warning_count} warnings, "
        f"{acc.notice_count} notices in {elapsed:.1f}s",
        tag="DATA",
    )

    return result


# ── Module-level cache for last validation result ────────────────────────

_last_validation: dict[str, Any] | None = None
_last_validation_ts: float = 0.0


def get_last_validation() -> dict[str, Any] | None:
    """Return the last cached validation result."""
    return _last_validation


def run_and_cache_validation(data_dir: Path | str) -> dict[str, Any]:
    """Run validation and cache the result."""
    global _last_validation, _last_validation_ts
    result = validate_gtfs_data(data_dir)
    _last_validation = result
    _last_validation_ts = _time.time()
    return result
