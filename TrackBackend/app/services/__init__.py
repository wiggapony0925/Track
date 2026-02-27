"""
Service layer — data fetching, parsing, and business logic.

Heavy imports are deferred to each module; this file simply documents
the public surface.  Direct imports (e.g. ``from app.services.mta_client
import fetch_protobuf``) remain the preferred style.
"""

__all__ = [
    "alert_service",
    "bus_client",
    "commuter_rail_shapes",
    "data_cleaner",
    "data_loader",
    "gtfs_parser",
    "gtfs_refresh",
    "mta_client",
    "rail_client",
    "schedule_service",
    "station_lookup",
    "subway_shapes",
    "supabase_client",
]
