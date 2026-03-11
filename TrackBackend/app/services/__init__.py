"""
Service layer — subdivided by domain.

Sub-packages:
    services.gtfs/      Data ingestion, cleaning, refresh (GTFS pipeline)
    services.mapping/   Geometry engine (corridor pipeline, shapes)
    services.transit/   User-facing transit logic (schedules, stations, alerts)

External API clients live in ``app.clients/``.
"""
