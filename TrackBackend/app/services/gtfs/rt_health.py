"""GTFS-RT feed health monitoring.

Computes per-route coverage statistics comparing the set of *currently
scheduled active trips* (from transit_schedule.db) against the trips
present in the latest RT protobuf feed.

This is a Python translation of the core idea in transitland-lib's
``rt/stats.go`` (``TripUpdateStats`` / ``VehiclePositionStats``).

Typical usage example:

    from app.services.gtfs.rt_health import get_rt_coverage
    coverage = await get_rt_coverage()
"""

from __future__ import annotations

import datetime
import sqlite3
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from google.transit import gtfs_realtime_pb2  # type: ignore[import-untyped]

from app.clients.mta_client import fetch_protobuf
from app.config import get_feed_url
from app.services.gtfs.service_calendar import ServiceCalendar, load_service_calendar
from app.utils.logger import TrackLogger

# Module-level calendar cache — loaded lazily on first health-check call
# and reused for the lifetime of the process.  Invalidated via
# _invalidate_service_calendar() which gtfs_refresh calls after a rebuild.
_service_cal: ServiceCalendar | None = None


def _get_service_calendar() -> ServiceCalendar:
    """Return the module-level :class:`ServiceCalendar`, loading it on demand."""
    global _service_cal
    if _service_cal is None:
        _service_cal = load_service_calendar()
    return _service_cal


def _invalidate_service_calendar() -> None:
    """Force a reload of the service calendar on the next health-check call.

    Call this after gtfs_refresh rebuilds transit_schedule.db so that the
    new calendar data is picked up without a process restart.
    """
    global _service_cal
    _service_cal = None

_DATA_DIR = Path(__file__).resolve().parent.parent.parent / "data"
_DB_PATH = _DATA_DIR / "transit_schedule.db"

# Seconds of slack: a trip is "active now" if it has a departure within
# this many seconds of the current wall-clock time.
_ACTIVE_WINDOW_SECS = 3600  # ±1 hour

# Lines to health-check (representative feed letter per feed group).
_MONITORED_LINES = ["1", "A", "B", "J", "L", "N", "G", "7", "SI"]


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class RouteCoverage:
    """RT coverage statistics for a single route."""

    route_id: str
    scheduled_trip_count: int = 0
    rt_matched_count: int = 0
    rt_only_count: int = 0  # trips in RT but not in schedule

    @property
    def coverage_pct(self) -> float:
        """Fraction of scheduled trips that appear in the RT feed (0–100)."""
        if self.scheduled_trip_count == 0:
            return 100.0
        return round(100.0 * self.rt_matched_count / self.scheduled_trip_count, 1)


@dataclass
class FeedHealth:
    """Aggregated health for one RT feed endpoint."""

    feed_url: str
    header_timestamp: int = 0
    entity_count: int = 0
    is_stale: bool = False
    age_secs: int = 0
    routes: list[RouteCoverage] = field(default_factory=list)

    @property
    def overall_coverage_pct(self) -> float:
        """Mean route coverage across all routes with scheduled trips."""
        active = [r for r in self.routes if r.scheduled_trip_count > 0]
        if not active:
            return 100.0
        return round(sum(r.coverage_pct for r in active) / len(active), 1)


# ---------------------------------------------------------------------------
# Schedule helpers
# ---------------------------------------------------------------------------


def _active_trip_ids(route_id: str, now: int) -> set[str]:
    """Return trip_ids from transit_schedule.db that are active around *now*.

    A trip is considered active when it has at least one departure within
    ``_ACTIVE_WINDOW_SECS`` seconds of *now* AND its service_id is active
    today according to the GTFS calendar + calendar_dates exceptions.

    The service_id check (via :class:`ServiceCalendar`) mirrors
    transitland-lib's ``service.IsActive`` and fixes a previous deficiency
    where holiday / special service IDs were not correctly filtered.
    """
    if not _DB_PATH.exists():
        return set()

    # Convert Unix timestamp to HH:MM:SS window
    def _secs_to_hms(s: int) -> str:
        h, rem = divmod(s % 86400, 3600)
        m, sec = divmod(rem, 60)
        return f"{h:02d}:{m:02d}:{sec:02d}"

    window_start = _secs_to_hms(now - _ACTIVE_WINDOW_SECS)
    window_end = _secs_to_hms(now + _ACTIVE_WINDOW_SECS)
    today = datetime.date.today()
    cal = _get_service_calendar()

    try:
        conn = sqlite3.connect(f"file:{_DB_PATH}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        # Fetch both trip_id and service_id so we can filter by calendar.
        query = """
            SELECT DISTINCT t.trip_id, t.service_id
            FROM trips t
            JOIN stop_times st ON t.trip_id = st.trip_id
            WHERE t.route_id = ?
              AND st.departure_time BETWEEN ? AND ?
        """
        rows = conn.execute(
            query, (route_id, window_start, window_end)
        ).fetchall()
        conn.close()
        return {
            row["trip_id"]
            for row in rows
            if cal.is_active(row["service_id"], today)
        }
    except Exception as exc:
        TrackLogger.warning(
            f"[RT-HEALTH] Could not query active trips for {route_id}: {exc}",
            tag="RT",
        )
        return set()


# ---------------------------------------------------------------------------
# Core computation
# ---------------------------------------------------------------------------


def _compute_feed_health(
    feed_url: str,
    raw: bytes,
    scheduled_by_route: dict[str, set[str]],
) -> FeedHealth:
    """Parse *raw* GT-RT bytes and compute coverage vs *scheduled_by_route*."""
    now = int(time.time())

    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(raw)

    header_ts = feed.header.timestamp
    age = now - header_ts if header_ts > 0 else -1
    is_stale = age > 300 if age >= 0 else False

    health = FeedHealth(
        feed_url=feed_url,
        header_timestamp=header_ts,
        entity_count=len(feed.entity),
        is_stale=is_stale,
        age_secs=max(age, 0),
    )

    # Collect RT trip IDs per route
    rt_trips_by_route: dict[str, set[str]] = {}
    for entity in feed.entity:
        if not entity.HasField("trip_update"):
            continue
        tu = entity.trip_update
        route_id = tu.trip.route_id
        trip_id = tu.trip.trip_id
        if route_id and trip_id:
            rt_trips_by_route.setdefault(route_id, set()).add(trip_id)

    # Build RouteCoverage for every route that has scheduled trips or RT data
    all_routes = set(scheduled_by_route) | set(rt_trips_by_route)
    for route_id in sorted(all_routes):
        sched = scheduled_by_route.get(route_id, set())
        rt = rt_trips_by_route.get(route_id, set())
        cov = RouteCoverage(
            route_id=route_id,
            scheduled_trip_count=len(sched),
            rt_matched_count=len(sched & rt),
            rt_only_count=len(rt - sched),
        )
        health.routes.append(cov)

    return health


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def get_rt_coverage(
    line_ids: list[str] | None = None,
) -> list[FeedHealth]:
    """Fetch each monitored RT feed and return coverage statistics.

    Args:
        line_ids: List of route/line identifiers to check.  Defaults to
                  ``_MONITORED_LINES`` which covers one feed per subway
                  group.

    Returns:
        One ``FeedHealth`` entry per unique feed URL.
    """
    import asyncio

    targets = line_ids or _MONITORED_LINES
    now = int(time.time())

    # Deduplicate: multiple line_ids can map to the same feed URL
    url_to_lines: dict[str, list[str]] = {}
    for lid in targets:
        url = get_feed_url(lid)
        if url:
            url_to_lines.setdefault(url, []).append(lid)

    results: list[FeedHealth] = []

    async def _check_one(url: str, lines: list[str]) -> FeedHealth | None:
        try:
            raw = await fetch_protobuf(url)
        except Exception as exc:
            TrackLogger.warning(
                f"[RT-HEALTH] Could not fetch {url}: {exc}", tag="RT"
            )
            return None

        # Collect scheduled trips for all routes served by this feed
        scheduled_by_route: dict[str, set[str]] = {}
        for lid in lines:
            trip_set = _active_trip_ids(lid, now)
            if trip_set:
                scheduled_by_route[lid] = trip_set

        return _compute_feed_health(url, raw, scheduled_by_route)

    tasks = [_check_one(url, lines) for url, lines in url_to_lines.items()]
    outcomes: list[Any] = await asyncio.gather(*tasks, return_exceptions=True)

    for outcome in outcomes:
        if isinstance(outcome, FeedHealth):
            results.append(outcome)
        elif isinstance(outcome, Exception):
            TrackLogger.warning(
                f"[RT-HEALTH] Feed check raised: {outcome}", tag="RT"
            )

    return results


async def get_rt_health_summary() -> dict[str, Any]:
    """Return a JSON-serialisable health summary suitable for ``/health/rt``.

    Returns:
        A dict with keys ``feeds``, ``overall_coverage_pct``, and ``checked_at``.
    """
    feeds = await get_rt_coverage()
    return {
        "checked_at": int(time.time()),
        "overall_coverage_pct": (
            round(sum(f.overall_coverage_pct for f in feeds) / len(feeds), 1)
            if feeds
            else 0.0
        ),
        "feeds": [
            {
                "url": f.feed_url,
                "header_timestamp": f.header_timestamp,
                "age_secs": f.age_secs,
                "is_stale": f.is_stale,
                "entity_count": f.entity_count,
                "overall_coverage_pct": f.overall_coverage_pct,
                "routes": [
                    {
                        "route_id": r.route_id,
                        "scheduled": r.scheduled_trip_count,
                        "rt_matched": r.rt_matched_count,
                        "rt_only": r.rt_only_count,
                        "coverage_pct": r.coverage_pct,
                    }
                    for r in f.routes
                ],
            }
            for f in feeds
        ],
    }
