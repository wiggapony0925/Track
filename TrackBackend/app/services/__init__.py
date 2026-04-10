"""
Service layer — subdivided by domain.

Sub-packages:
    services.gtfs/      GTFS pipeline — schema parser, realtime feed, refresh, data loader
    services.mapping/   Geometry engine — corridor offsets, subway/rail shapes, polyline QA
    services.track_engine/  Trip-planning state, search, recommendations, and C++ engine integration
    services.transit/   User-facing transit logic — schedules, station lookup, alert boosting

External API clients live in ``app.clients/``.
"""
