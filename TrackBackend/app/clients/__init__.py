"""
External API clients — each module manages its own connection pool.

Modules:
    bus_client      – MTA Bus SIRI feed (routes, stops, vehicles)
    mta_client      – MTA GTFS-RT protobuf fetcher (subway + rail)
    rail_client     – LIRR / Metro-North arrival parsing
    redis_client    – Shared Redis L2 cache layer
    weather_client  – OpenWeather current conditions for ML features
"""

__all__ = [
    "bus_client",
    "mta_client",
    "rail_client",
    "redis_client",
    "weather_client",
]