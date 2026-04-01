"""
Track GTFS Package — typed schema loading, realtime parsing, and data pipeline.

Quick start::

    from app.services.gtfs import GTFSFeed, Stop, Route, Trip, GTFSTime

    feed = GTFSFeed.load("app/data/subway/regular_GTFS")
    for route in feed.routes.values():
        print(route.route_id, route.display_name, route.route_color)

Modules:
    gtfs_types       – Typed primitives (GTFSTime, GTFSDate, LatLon, enums)
    gtfs_entities    – Entity base class + 11 GTFS entity definitions
    gtfs_loader      – GTFSFeed container, CSV loader, FK validation
    gtfs_parser      – iOS static bundle generation (route polylines, stations)
    gtfs_refresh     – SQLite schedule DB builder + periodic refresh
    gtfs_validator   – Advanced GTFS quality checks (WCAG, orphans, nearby stops)
    realtime_parser  – GTFS-RT protobuf → Pydantic models (arrivals, alerts, elevators)
    data_loader      – GTFS archive download from Supabase / Docker volumes
"""

from __future__ import annotations

from app.services.gtfs.gtfs_entities import (  # noqa: F401
    Agency,
    Calendar,
    CalendarDate,
    Entity,
    EntityTable,
    FeedInfo,
    FieldSpec,
    Frequency,
    GroupedTable,
    Route,
    Shape,
    Stop,
    StopTime,
    Transfer,
    Trip,
    get_entity_registry,
)
from app.services.gtfs.gtfs_loader import (  # noqa: F401
    GTFSFeed,
    LoadProblem,
    Severity,
    load_feed,
    load_routes,
    load_shapes,
    load_stops,
    load_trips,
)

# Re-export the public API for convenient imports
from app.services.gtfs.gtfs_types import (  # noqa: F401
    BikesAllowed,
    ContinuousDropOff,
    ContinuousPickup,
    DirectionId,
    DropOffType,
    ExceptionType,
    GTFSDate,
    GTFSTime,
    LatLon,
    LocationType,
    PickupType,
    RouteType,
    Timepoint,
    TransferType,
    WheelchairAccessible,
    serialize,
)
