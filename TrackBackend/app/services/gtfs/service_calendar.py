"""GTFS service calendar: resolves whether a service_id runs on a given date.

Python translation of ``service/service.go`` from transitland-lib:
https://github.com/interline-io/transitland-lib/blob/main/service/service.go

The key addition is handling ``calendar_dates`` exceptions, which override
the base weekday schedule.  The existing ``route_headways.py`` and
``rt_health.py`` modules only used the base weekday flags; by calling
:func:`load_service_calendar` they now correctly answer "does this subway
service run on a holiday?" and "is today a Sunday-schedule Saturday?".

Typical usage example:

    from app.services.gtfs.service_calendar import load_service_calendar
    cal = load_service_calendar()
    today = datetime.date.today()
    if cal.is_active("WKD_20241215", today):
        ...
"""

from __future__ import annotations

import datetime
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path

from app.utils.logger import TrackLogger

_DB_PATH = (
    Path(__file__).resolve().parent.parent.parent / "data" / "transit_schedule.db"
)

# Map calendar column name → Python weekday int (Monday=0 … Sunday=6).
_DOW_COLUMNS: tuple[str, ...] = (
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
)


def _parse_gtfs_date(s: str) -> datetime.date | None:
    """Parse a GTFS date string (YYYYMMDD, stored as TEXT) to a date.

    Args:
        s: Date string in 8-digit ``YYYYMMDD`` format, possibly with dashes.

    Returns:
        Parsed :class:`datetime.date` or ``None`` on parse failure.
    """
    clean = s.replace("-", "").strip() if s else ""
    if len(clean) != 8:
        return None
    try:
        return datetime.date(int(clean[:4]), int(clean[4:6]), int(clean[6:]))
    except ValueError:
        return None


@dataclass
class ServiceCalendar:
    """Resolved GTFS calendar data enabling O(1) ``is_active`` queries.

    Combines ``calendar.txt`` base schedules with ``calendar_dates.txt``
    exceptions exactly as specified in the GTFS reference and mirrored by
    transitland-lib's ``service.IsActive``.

    Attributes:
        _dow_sets: service_id → set of Python weekday ints (0=Monday) on
            which the service runs according to ``calendar.txt``.
        _start_dates: service_id → start_date from ``calendar.txt``.
        _end_dates: service_id → end_date from ``calendar.txt``.
        _exceptions: service_id → {YYYYMMDD: exception_type} from
            ``calendar_dates.txt`` (1 = added, 2 = removed).
    """

    _dow_sets: dict[str, set[int]] = field(default_factory=dict)
    _start_dates: dict[str, datetime.date] = field(default_factory=dict)
    _end_dates: dict[str, datetime.date] = field(default_factory=dict)
    _exceptions: dict[str, dict[str, int]] = field(default_factory=dict)

    def is_active(self, service_id: str, d: datetime.date) -> bool:
        """Return True if *service_id* operates on date *d*.

        Implements the same three-step logic as transitland-lib's
        ``service.IsActive``:

        1. Check ``calendar_dates`` exceptions first (they override the
           base schedule — exception_type 1 = added, 2 = removed).
        2. Verify the date is within the ``[start_date, end_date]`` window
           from ``calendar.txt``.
        3. Check the weekday flag for the day-of-week of *d*.

        Args:
            service_id: GTFS service_id string (e.g. ``"WKD_20241215"``).
            d: Calendar date to test.

        Returns:
            True if the service is scheduled to run on *d*.
        """
        date_str = d.strftime("%Y%m%d")
        exc = self._exceptions.get(service_id, {}).get(date_str)
        if exc is not None:
            return exc == 1

        start = self._start_dates.get(service_id)
        if start is not None and d < start:
            return False

        end = self._end_dates.get(service_id)
        if end is not None and d > end:
            return False

        return d.weekday() in self._dow_sets.get(service_id, set())

    @property
    def service_count(self) -> int:
        """Total number of service_ids tracked (calendar + calendar_dates)."""
        all_ids = set(self._dow_sets) | set(self._exceptions)
        return len(all_ids)


def load_service_calendar(db_path: Path | None = None) -> ServiceCalendar:
    """Load the full service calendar from ``transit_schedule.db``.

    Reads ``calendar`` and ``calendar_dates`` tables and returns a
    :class:`ServiceCalendar` that answers ``is_active()`` queries in O(1).

    Args:
        db_path: Override the default DB path.  Primarily for tests.

    Returns:
        A populated :class:`ServiceCalendar`.  Returns an empty instance if
        the database does not exist or cannot be opened.
    """
    path = db_path or _DB_PATH
    if not path.exists():
        TrackLogger.warning(
            f"[SERVICE-CAL] DB not found at {path}", tag="GTFS"
        )
        return ServiceCalendar()

    cal = ServiceCalendar()
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row

        # ── calendar.txt rows ─────────────────────────────────────────────
        for row in conn.execute(
            "SELECT service_id, start_date, end_date, "
            "monday, tuesday, wednesday, thursday, "
            "friday, saturday, sunday "
            "FROM calendar"
        ):
            sid: str = row["service_id"]
            dow_set: set[int] = set()
            for i, col in enumerate(_DOW_COLUMNS):
                if row[col] == 1:
                    dow_set.add(i)
            if dow_set:
                cal._dow_sets[sid] = dow_set
            start = _parse_gtfs_date(row["start_date"] or "")
            if start is not None:
                cal._start_dates[sid] = start
            end = _parse_gtfs_date(row["end_date"] or "")
            if end is not None:
                cal._end_dates[sid] = end

        # ── calendar_dates.txt exceptions ────────────────────────────────
        for row in conn.execute(
            "SELECT service_id, date, exception_type FROM calendar_dates"
        ):
            sid = str(row["service_id"])
            # Normalize YYYYMMDD (could be stored with or without dashes)
            date_str = str(row["date"]).replace("-", "").strip()
            if len(date_str) == 8:
                cal._exceptions.setdefault(sid, {})[date_str] = int(
                    row["exception_type"]
                )

        conn.close()
    except Exception as exc:
        TrackLogger.warning(
            f"[SERVICE-CAL] Failed to load calendar: {exc}", tag="GTFS"
        )
        return ServiceCalendar()

    TrackLogger.info(
        f"[SERVICE-CAL] Loaded {cal.service_count} service_ids", tag="GTFS"
    )
    return cal
