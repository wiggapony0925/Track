"""
Service layer — data fetching, parsing, and business logic.

Heavy imports are deferred to each module; this file simply documents
the public surface.  Direct imports (e.g. ``from app.services.mta_client
import fetch_protobuf``) remain the preferred style.
"""

__all__ = [
    "bus_client",
    "commuter_rail_shapes",
    "data_cleaner",
    "gtfs_parser",
    "mta_client",
    "rail_client",
    "schedule_service",
    "station_lookup",
    "subway_shapes",
]
