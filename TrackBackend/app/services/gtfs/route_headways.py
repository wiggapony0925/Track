"""Compute scheduled route headways from GTFS static data.

Python translation of transitland-lib's ``ext/builders/route_headway_builder.go``.

For each route × direction × day-of-week category, finds the *busiest stop*
(most departures on a representative service day) and computes the median
inter-departure gap during morning rush (06:00–10:00).  The result is stored
as ``headway_peak_secs`` — the primary "frequency" signal surfaced to iOS.

Day-of-week categories:
- 1 = Weekday (Mon–Fri)
- 6 = Saturday
- 7 = Sunday

Typical usage example:

    from app.services.gtfs.route_headways import compute_route_headways
    headways = compute_route_headways()
    # headways["A"][1][0]  →  HeadwayResult(headway_peak_secs=240, ...)
"""

from __future__ import annotations

import csv
import statistics
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

from app.utils.logger import TrackLogger

_DATA_DIR = Path(__file__).resolve().parent.parent.parent / "data"

# Rush-hour window: 06:00–10:00 local time (seconds since midnight)
_RUSH_START = 6 * 3600   # 21 600
_RUSH_END = 10 * 3600    # 36 000

# Minimum trips in the window before reporting a headway
_MIN_TRIPS = 3


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class HeadwayResult:
    """Computed peak headway for one route / direction / dow_category."""

    route_id: str
    direction_id: int
    dow_category: int   # 1=weekday, 6=Saturday, 7=Sunday
    headway_peak_secs: int
    anchor_stop_id: str
    departure_count: int  # departures from anchor stop in rush window


# ---------------------------------------------------------------------------
# GTFS helpers
# ---------------------------------------------------------------------------


def _hms_to_secs(hms: str) -> int:
    """Convert ``HH:MM:SS`` GTFS time string to seconds since midnight.

    GTFS allows hours ≥ 24 for trips past midnight; this function handles
    those correctly.
    """
    parts = hms.strip().split(":")
    if len(parts) != 3:
        return -1
    try:
        return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
    except ValueError:
        return -1


def _dow_category(date_str: str) -> int | None:
    """Return the day-of-week category (1/6/7) for a YYYYMMDD date string."""
    try:
        import datetime

        d = datetime.date(int(date_str[:4]), int(date_str[4:6]), int(date_str[6:8]))
        wd = d.isoweekday()  # 1=Mon … 7=Sun
        if wd <= 5:
            return 1
        return wd  # 6=Sat, 7=Sun
    except (ValueError, IndexError):
        return None


# ---------------------------------------------------------------------------
# Core computation
# ---------------------------------------------------------------------------


def compute_route_headways(
    gtfs_dir: Path | None = None,
) -> dict[str, dict[int, dict[int, HeadwayResult]]]:
    """Compute peak headways for all routes in a GTFS directory.

    Args:
        gtfs_dir: Path to an extracted GTFS feed directory.  Defaults to
                  the supplemented subway feed in ``app/data/``.

    Returns:
        Nested dict ``route_id → direction_id → dow_category → HeadwayResult``.
        Routes / directions with fewer than ``_MIN_TRIPS`` rush-hour
        departures are omitted.
    """
    base = gtfs_dir or (_DATA_DIR / "subway" / "supplemented_GTFS")

    trips_path = base / "trips.txt"
    stop_times_path = base / "stop_times.txt"
    calendar_dates_path = base / "calendar_dates.txt"
    calendar_path = base / "calendar.txt"

    for p in (trips_path, stop_times_path):
        if not p.exists():
            TrackLogger.warning(
                f"[HEADWAY] Required file not found: {p}", tag="GTFS"
            )
            return {}

    # ── 1. Map service_id → set of dow_categories ───────────────────────
    service_dow: dict[str, set[int]] = defaultdict(set)

    if calendar_path.exists():
        dow_cols = [
            "monday", "tuesday", "wednesday",
            "thursday", "friday", "saturday", "sunday",
        ]
        with open(calendar_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                sid = row.get("service_id", "").strip()
                if not sid:
                    continue
                active_days = [
                    i + 1
                    for i, col in enumerate(dow_cols)
                    if row.get(col, "0").strip() == "1"
                ]
                for d in active_days:
                    cat = 1 if d <= 5 else d  # Mon–Fri → 1, Sat → 6, Sun → 7
                    service_dow[sid].add(cat)

    if calendar_dates_path.exists():
        with open(calendar_dates_path, encoding="utf-8") as f:
            for row in csv.DictReader(f):
                sid = row.get("service_id", "").strip()
                et = row.get("exception_type", "").strip()
                date = row.get("date", "").strip()
                if not sid or et != "1":
                    continue
                cat = _dow_category(date)
                if cat is not None:
                    service_dow[sid].add(cat)

    # ── 2. Map trip_id → (route_id, direction_id, dow_categories) ───────
    trip_info: dict[str, tuple[str, int, set[int]]] = {}
    with open(trips_path, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            tid = row.get("trip_id", "").strip()
            rid = row.get("route_id", "").strip()
            try:
                did = int(row.get("direction_id", "0").strip())
            except ValueError:
                did = 0
            sid = row.get("service_id", "").strip()
            if tid and rid:
                trip_info[tid] = (rid, did, service_dow.get(sid, set()))

    # ── 3. Collect rush-hour departures per route×dir×dow×stop ──────────
    # Structure: route_id → dir → dow_cat → stop_id → [departure_secs]
    departures: dict[
        str, dict[int, dict[int, dict[str, list[int]]]]
    ] = defaultdict(
        lambda: defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    )

    with open(stop_times_path, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            tid = row.get("trip_id", "").strip()
            info = trip_info.get(tid)
            if not info:
                continue
            rid, did, dow_cats = info
            if not dow_cats:
                continue

            dept_str = row.get("departure_time", "").strip()
            stop_id = row.get("stop_id", "").strip()
            if not dept_str or not stop_id:
                continue

            dept_secs = _hms_to_secs(dept_str)
            if dept_secs < 0:
                continue
            if not (_RUSH_START <= dept_secs <= _RUSH_END):
                continue

            for cat in dow_cats:
                departures[rid][did][cat][stop_id].append(dept_secs)

    # ── 4. Compute median headway at the busiest stop per combination ────
    results: dict[str, dict[int, dict[int, HeadwayResult]]] = {}

    for rid, dir_map in departures.items():
        for did, cat_map in dir_map.items():
            for cat, stop_map in cat_map.items():
                # Find the stop with the most departures = "anchor stop"
                anchor_stop, depts = max(
                    stop_map.items(), key=lambda kv: len(kv[1])
                )
                if len(depts) < _MIN_TRIPS:
                    continue

                depts_sorted = sorted(depts)
                gaps = [
                    depts_sorted[i + 1] - depts_sorted[i]
                    for i in range(len(depts_sorted) - 1)
                ]
                if not gaps:
                    continue

                headway_secs = int(statistics.median(gaps))

                result = HeadwayResult(
                    route_id=rid,
                    direction_id=did,
                    dow_category=cat,
                    headway_peak_secs=headway_secs,
                    anchor_stop_id=anchor_stop,
                    departure_count=len(depts),
                )
                results.setdefault(rid, {}).setdefault(did, {})[cat] = result

    TrackLogger.info(
        f"[HEADWAY] Computed headways for {len(results)} routes",
        tag="GTFS",
    )
    return results


def headway_label(headway_secs: int) -> str:
    """Return a human-readable frequency string for display in the iOS app.

    Examples:
        >>> headway_label(240)
        '~4 min'
        >>> headway_label(1800)
        '~30 min'
    """
    mins = headway_secs // 60
    if mins < 1:
        return "< 1 min"
    return f"~{mins} min"
