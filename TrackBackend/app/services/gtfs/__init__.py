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

# Re-export the public API for convenient imports
from app.services.gtfs.gtfs_types import (  # noqa: F401
    GTFSTime,
    GTFSDate,
    LatLon,
    RouteType,
    LocationType,
    PickupType,
    DropOffType,
    ExceptionType,
    TransferType,
    DirectionId,
    WheelchairAccessible,
    BikesAllowed,
    ContinuousPickup,
    ContinuousDropOff,
    Timepoint,
    serialize,
)

from app.services.gtfs.gtfs_entities import (  # noqa: F401
    Entity,
    EntityTable,
    GroupedTable,
    FieldSpec,
    Agency,
    Calendar,
    CalendarDate,
    Route,
    Stop,
    StopTime,
    Trip,
    Shape,
    Transfer,
    FeedInfo,
    Frequency,
    get_entity_registry,
)

from app.services.gtfs.gtfs_loader import (  # noqa: F401
    GTFSFeed,
    load_feed,
    load_stops,
    load_shapes,
    load_routes,
    load_trips,
    LoadProblem,
    Severity,
)
