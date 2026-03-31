"""
User-facing transit logic — schedules, station lookup, and alert boosting.

Modules:
    alert_service      – Per-route alert severity boost for arrival ranking
    schedule_service   – GTFS schedule queries (departures, calendar resolution)
    station_lookup     – Spatial nearest-stop queries for nearby endpoints
"""

__all__ = [
    "alert_service",
    "schedule_service",
    "station_lookup",
]