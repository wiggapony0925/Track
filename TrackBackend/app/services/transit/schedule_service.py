
import asyncio
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from app.models import TrackArrival
from app.services.transit.station_lookup import get_stop_info, get_stop_name
from app.utils.logger import TrackLogger

DB_PATH = Path("app/data/transit_schedule.db")

# Map Python weekday (0=Mon) to GTFS service_id keywords
_WEEKDAY_KEYWORDS = {
    0: "Weekday",   # Monday
    1: "Weekday",   # Tuesday
    2: "Weekday",   # Wednesday
    3: "Weekday",   # Thursday
    4: "Weekday",   # Friday
    5: "Saturday",
    6: "Sunday",
}

class ScheduleService:
    """Service to query static GTFS schedules as a fallback for live data."""
    
    def __init__(self, db_path: Path = DB_PATH):
        self.db_path = db_path

    def _get_connection(self):
        return sqlite3.connect(self.db_path)

    def _resolve_active_services(self, cursor, current_date: str) -> list[str]:
        """
        Resolve active service_ids for today using two strategies:
        1. calendar_dates table (exception_type=1 means added, 2 means removed)
        2. Day-of-week heuristic from service_id naming (e.g. *-Weekday-*, *-Saturday-*)
        
        MTA bus GTFS uses a calendar.txt with weekly patterns, but our DB only
        imported calendar_dates. Named service_ids encode the day-of-week, so we
        use that as a fallback for routes missing from calendar_dates.
        """
        # Strategy 1: Explicitly listed in calendar_dates for today
        cursor.execute(
            "SELECT service_id, exception_type FROM calendar_dates WHERE date = ?",
            (current_date,),
        )
        rows = cursor.fetchall()
        
        added = {r[0] for r in rows if r[1] == 1}    # explicitly running today
        removed = {r[0] for r in rows if r[1] == 2}   # explicitly NOT running today
        
        # Strategy 2: Match service_ids by day-of-week keyword in the name
        now = datetime.now()
        day_keyword = _WEEKDAY_KEYWORDS[now.weekday()]
        
        cursor.execute(
            "SELECT DISTINCT service_id FROM trips WHERE service_id LIKE ?",
            (f"%{day_keyword}%",),
        )
        name_matched = {r[0] for r in cursor.fetchall()}
        
        # Merge: union of both sets, minus any explicitly removed
        active = (added | name_matched) - removed
        
        return list(active)

    def get_scheduled_arrivals(self, stop_id: str, route_id: str | None = None, limit: int = 10) -> list[TrackArrival]:
        """
        Fetch the next scheduled arrivals for a given stop.

        Supports a cross-day window: if today's remaining GTFS service
        doesn't fill ``limit``, a second pass queries tomorrow's service
        so the departure board can show up to ~12 hours ahead.
        """
        if not self.db_path.exists():
            return []

        # Current time in GTFS format HH:MM:SS
        now = datetime.now()
        current_date = now.strftime("%Y%m%d")
        current_time_str = now.strftime("%H:%M:%S")

        tomorrow = now + timedelta(days=1)
        tomorrow_date = tomorrow.strftime("%Y%m%d")

        conn = self._get_connection()
        try:
            cursor = conn.cursor()

            # 1. Find active service_ids for today
            active_services = self._resolve_active_services(cursor, current_date)

            arrivals: list[TrackArrival] = []

            if active_services:
                arrivals = self._query_stop_times(
                    cursor, stop_id, active_services, current_time_str,
                    route_id, limit, day_offset=0,
                )

            # 2. If today didn't fill the limit, query tomorrow's service
            #    (early-morning departures) to extend the window.
            if len(arrivals) < limit:
                tomorrow_services = self._resolve_active_services(
                    cursor, tomorrow_date
                )
                if tomorrow_services:
                    remaining = limit - len(arrivals)
                    next_day = self._query_stop_times(
                        cursor, stop_id, tomorrow_services, "00:00:00",
                        route_id, remaining, day_offset=1,
                    )
                    arrivals.extend(next_day)

            return arrivals

        except Exception as e:
            TrackLogger.error(f"Schedule query failed: {e}", tag="SCHEDULE", exc_info=True)
            return []
        finally:
            conn.close()

    def _query_stop_times(
        self,
        cursor,
        stop_id: str,
        active_services: list[str],
        time_from: str,
        route_id: str | None,
        limit: int,
        *,
        day_offset: int = 0,
    ) -> list[TrackArrival]:
        """Run a single stop_times query and return TrackArrival list.

        ``day_offset`` is 0 for today, 1 for tomorrow — used so that
        ``_calculate_timing`` places tomorrow's ``06:30:00`` correctly
        into the future instead of clamping to 0.
        """
        route_filter = ""
        route_params: list = []
        if route_id:
            # Exact match OR variant with a separator suffix (e.g. S79 → S79+,
            # M1 → M1-SBS) — but NOT unrelated routes (M1 must NOT match M102).
            route_filter = (
                "AND (t.route_id = ? COLLATE NOCASE"
                " OR t.route_id LIKE (? || '+%') COLLATE NOCASE"
                " OR t.route_id LIKE (? || '-%') COLLATE NOCASE"
                " OR t.route_id IN"
                "   (SELECT route_id FROM routes"
                "    WHERE route_short_name = ? COLLATE NOCASE"
                "       OR route_short_name LIKE (? || '-%') COLLATE NOCASE))"
            )
            route_params = [route_id, route_id, route_id, route_id, route_id]

        query = """
            SELECT
                t.route_id,
                st.stop_id,
                st.arrival_time,
                t.trip_headsign,
                t.direction_id,
                t.trip_id
            FROM stop_times st
            JOIN trips t ON st.trip_id = t.trip_id
            WHERE st.stop_id = ?
            AND t.service_id IN ({})
            {}
            AND st.arrival_time >= ?
            GROUP BY t.route_id, st.arrival_time
            ORDER BY st.arrival_time ASC
            LIMIT ?
        """.format(",".join(["?"] * len(active_services)), route_filter)

        params = (
            [stop_id]
            + active_services
            + route_params
            + [time_from, limit]
        )

        cursor.execute(query, params)
        rows = cursor.fetchall()

        arrivals: list[TrackArrival] = []
        for row in rows:
            r_id, s_id, arr_time, headsign, direction_id, trip_id = row

            minutes, arrival_ts = self._calculate_timing(
                arr_time, day_offset=day_offset
            )

            direction = "N" if direction_id == 0 else "S"

            arrivals.append(TrackArrival(
                route_id=r_id,
                station=s_id,
                station_name=get_stop_name(s_id),
                direction=direction,
                destination=headsign,
                minutes_away=minutes,
                arrival_ts=arrival_ts,
                status="Scheduled",
                trip_id=trip_id,
                stop_lat=stop_info.lat if (stop_info := get_stop_info(s_id)) else None,
                stop_lon=stop_info.lon if stop_info else None,
            ))

        return arrivals

    async def get_scheduled_arrivals_async(
        self,
        stop_id: str,
        route_id: str | None = None,
        limit: int = 10,
    ) -> list[TrackArrival]:
        """Async wrapper that runs the blocking SQLite query off the event loop."""
        return await asyncio.to_thread(
            self.get_scheduled_arrivals, stop_id, route_id, limit
        )

    def _calculate_timing(self, gtfs_time: str, *, day_offset: int = 0) -> tuple[int, int]:
        """Parse GTFS time HH:MM:SS and return (minutes_away, arrival_ts).

        Handles GTFS times past midnight (e.g. 25:30:00 = 1:30 AM next day)
        and correctly detects when a normalized time has already passed today.

        ``day_offset`` shifts the base day forward (0 = today, 1 = tomorrow)
        so that tomorrow's "06:30:00" is placed 24 h ahead instead of in the past.
        """
        try:
            h, m, s = map(int, gtfs_time.split(':'))
            days = h // 24
            hours = h % 24
            
            now = datetime.now()
            base = now + timedelta(days=day_offset)
            arrival_dt = base.replace(hour=hours, minute=m, second=s, microsecond=0)
            if days > 0:
                arrival_dt += timedelta(days=days)
            
            # If the normalized time is in the past (e.g. "01:30:00" queried
            # at 02:00 for a trip that started yesterday before midnight), the
            # trip has already departed — clamp to 0 minutes away.
            diff = arrival_dt - now
            ts = int(arrival_dt.timestamp())
            mins = max(0, int(diff.total_seconds() // 60))
            return mins, ts
            return mins, ts
        except (ValueError, TypeError, IndexError) as exc:
            TrackLogger.warning(f"Bad GTFS time '{gtfs_time}': {exc}", tag="SCHEDULE")
            return 999, 0

    def get_headsigns_for_route(
        self,
        route_id: str,
        direction_id: int | None = None,
    ) -> dict[int, str]:
        """Return the most common trip_headsign per direction_id for a route.

        Used to enrich placeholder direction tabs with real terminal names
        instead of generic "Outbound" / "Inbound".

        Returns ``{0: "Jamaica", 1: "Penn Station"}`` style mapping.
        Only directions with a non-empty headsign are included.
        """
        if not self.db_path.exists():
            return {}

        conn = self._get_connection()
        try:
            cursor = conn.cursor()

            dir_filter = ""
            params: list = []

            # Match route_id flexibly (same as _query_stop_times)
            route_filter = (
                "(t.route_id = ? COLLATE NOCASE"
                " OR t.route_id LIKE (? || '+%') COLLATE NOCASE"
                " OR t.route_id LIKE (? || '-%') COLLATE NOCASE"
                " OR t.route_id IN"
                "   (SELECT route_id FROM routes"
                "    WHERE route_short_name = ? COLLATE NOCASE"
                "       OR route_short_name LIKE (? || '-%') COLLATE NOCASE))"
            )
            params = [route_id, route_id, route_id, route_id, route_id]

            if direction_id is not None:
                dir_filter = "AND t.direction_id = ?"
                params.append(direction_id)

            query = f"""
                SELECT t.direction_id, t.trip_headsign, COUNT(*) as cnt
                FROM trips t
                WHERE {route_filter}
                {dir_filter}
                AND t.trip_headsign IS NOT NULL
                AND t.trip_headsign != ''
                GROUP BY t.direction_id, t.trip_headsign
                ORDER BY t.direction_id, cnt DESC
            """

            cursor.execute(query, params)
            rows = cursor.fetchall()

            # Pick the most common headsign per direction_id
            result: dict[int, str] = {}
            for d_id, headsign, _cnt in rows:
                if d_id not in result and headsign and headsign.strip():
                    result[d_id] = headsign.strip()

            return result
        except Exception as e:
            TrackLogger.error(f"Headsign lookup failed for {route_id}: {e}", tag="SCHEDULE")
            return {}
        finally:
            conn.close()

# Singleton instance
schedule_service = ScheduleService()
