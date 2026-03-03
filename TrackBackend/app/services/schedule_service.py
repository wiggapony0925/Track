
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from app.models import TrackArrival
from app.services.station_lookup import get_stop_name
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
        """
        if not self.db_path.exists():
            return []

        # Current time in GTFS format HH:MM:SS
        now = datetime.now()
        current_date = now.strftime("%Y%m%d")
        current_time_str = now.strftime("%H:%M:%S")

        conn = self._get_connection()
        try:
            cursor = conn.cursor()
            
            # 1. Find active service_ids for today
            active_services = self._resolve_active_services(cursor, current_date)
            
            if not active_services:
                return []

            # 2. Query stop_times joined with trips to get route and destination info
            route_filter = ""
            route_params: list = []
            if route_id:
                route_filter = "AND t.route_id = ?"
                route_params = [route_id]

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
            
            params = [stop_id] + active_services + route_params + [current_time_str, limit]
            
            cursor.execute(query, params)
            rows = cursor.fetchall()
            
            arrivals = []
            for row in rows:
                r_id, s_id, arr_time, headsign, direction_id, trip_id = row
                
                # Calculate minutes away and timestamp
                minutes, arrival_ts = self._calculate_timing(arr_time)
                
                # Format direction
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
                    trip_id=trip_id
                ))
            
            return arrivals

        except Exception as e:
            TrackLogger.error(f"Schedule query failed: {e}", tag="SCHEDULE")
            return []
        finally:
            conn.close()

    def _calculate_timing(self, gtfs_time: str) -> tuple[int, int]:
        """Parse GTFS time HH:MM:SS and return (minutes_away, arrival_ts)."""
        try:
            h, m, s = map(int, gtfs_time.split(':'))
            days = h // 24
            hours = h % 24
            
            now = datetime.now()
            arrival_dt = now.replace(hour=hours, minute=m, second=s, microsecond=0)
            if days > 0:
                arrival_dt += timedelta(days=days)
            
            ts = int(arrival_dt.timestamp())
            diff = arrival_dt - now
            mins = max(0, int(diff.total_seconds() // 60))
            return mins, ts
        except:
            return 999, 0

# Singleton instance
schedule_service = ScheduleService()
