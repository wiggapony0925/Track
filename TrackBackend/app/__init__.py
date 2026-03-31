"""
Track Backend — FastAPI proxy for the Track NYC Transit iOS app.

Packages:
    clients   – External API clients (MTA, bus, weather, Redis)
    ml        – Machine learning models (delay prediction, recency correction)
    models    – Pydantic response schemas
    providers – Transit provider registry (multi-region)
    routers   – FastAPI route handlers (subway, bus, lirr, mnr, nearby …)
    services  – Data pipeline, geometry engine, and transit business logic
    utils     – Shared helpers (logging, geo, polyline, transit colors, metrics)
"""

__version__ = "1.0.0"
