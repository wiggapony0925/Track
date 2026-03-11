#
# cache_config.py
# TrackBackend
#
# ══════════════════════════════════════════════════════════════════
# SINGLE SOURCE OF TRUTH for every cache TTL, size, and concurrency
# limit across the entire backend.
#
# Values are loaded from the "cache" section of settings.json when
# present; otherwise the defaults below are used.
#
# Edit settings.json (production-friendly) OR this file (dev) to
# tune caching — no need to hunt through bus_client / mta_client.
# ══════════════════════════════════════════════════════════════════
#
# Data freshness tiers:
#
#   STATIC   — shapes, stops, routes, stations.  Rarely change.
#              Cache for hours/days.  Safe to serve stale for a week.
#
#   LIVE     — GTFS-RT subway feeds, SIRI bus arrivals/vehicles.
#              Cache for seconds.  Shared across all users so one
#              upstream fetch serves thousands of concurrent requests.
#
#   NEARBY   — OBA stops-for-location.  Semi-static (bus stops don't
#              move) but keyed by GPS grid, so moderate TTL.
#

from __future__ import annotations

import json
from pathlib import Path

_SETTINGS_PATH = Path(__file__).resolve().parent.parent / "settings.json"


def _load_cache_overrides() -> dict:
    """Load the optional ``cache`` section from settings.json."""
    try:
        raw = json.loads(_SETTINGS_PATH.read_text(encoding="utf-8"))
        return raw.get("cache", {})
    except Exception:
        # settings.json missing or malformed — use built-in defaults
        import logging as _logging
        _logging.getLogger("track").warning(
            "Failed to load cache overrides from settings.json, using defaults",
            extra={"tag": "CONFIG"},
        )
        return {}


_ovr = _load_cache_overrides()


# ┌─────────────────────────────────────────────────────┐
# │  SUBWAY / LIRR / MNR  (mta_client.py)              │
# │  Protobuf GTFS-RT feeds — 9 distinct URLs total     │
# └─────────────────────────────────────────────────────┘

MTA_FEED_TTL_SECONDS: float = _ovr.get("mta_feed_ttl", 12.0)
MTA_CACHE_MAX_SIZE: int = _ovr.get("mta_cache_max_size", 128)
MTA_UPSTREAM_CONCURRENCY: int = _ovr.get("mta_upstream_concurrency", 32)


# ┌─────────────────────────────────────────────────────┐
# │  BUS — SIRI Real-Time Arrivals  (bus_client.py)     │
# │  Per-stop stop-monitoring calls — the #1 bottleneck  │
# └─────────────────────────────────────────────────────┘

BUS_ARRIVALS_FRESH_TTL: float = _ovr.get("bus_arrivals_fresh_ttl", 12.0)
BUS_ARRIVALS_STALE_TTL: float = _ovr.get("bus_arrivals_stale_ttl", 25.0)
BUS_ARRIVALS_MAX_SIZE: int = _ovr.get("bus_arrivals_max_size", 500)
BUS_MAX_SIRI_STOPS: int = _ovr.get("bus_max_siri_stops", 80)


# ┌─────────────────────────────────────────────────────┐
# │  BUS — SIRI Vehicle Positions                       │
# │  Live bus GPS dots on the map                       │
# └─────────────────────────────────────────────────────┘

BUS_VEHICLES_FRESH_TTL: float = _ovr.get("bus_vehicles_fresh_ttl", 6.0)
BUS_VEHICLES_STALE_TTL: float = _ovr.get("bus_vehicles_stale_ttl", 30.0)
BUS_VEHICLES_MAX_SIZE: int = _ovr.get("bus_vehicles_max_size", 400)


# ┌─────────────────────────────────────────────────────┐
# │  BUS — OBA Static / Semi-Static                     │
# │  Stops, routes, shapes — change rarely              │
# └─────────────────────────────────────────────────────┘

BUS_STOPS_FRESH_TTL: float = _ovr.get("bus_stops_fresh_ttl", 600.0)
BUS_STOPS_STALE_TTL: float = _ovr.get("bus_stops_stale_ttl", 86400.0)
BUS_STOPS_MAX_SIZE: int = _ovr.get("bus_stops_max_size", 400)

BUS_ROUTE_SHAPE_FRESH_TTL: float = _ovr.get("bus_route_shape_fresh_ttl", 21600.0)
BUS_ROUTE_SHAPE_STALE_TTL: float = _ovr.get("bus_route_shape_stale_ttl", 604800.0)
BUS_ROUTE_SHAPE_MAX_SIZE: int = _ovr.get("bus_route_shape_max_size", 400)

BUS_ROUTES_FRESH_TTL: float = _ovr.get("bus_routes_fresh_ttl", 3600.0)
BUS_ROUTES_STALE_TTL: float = _ovr.get("bus_routes_stale_ttl", 86400.0)
BUS_ROUTES_MAX_SIZE: int = _ovr.get("bus_routes_max_size", 10)

BUS_NEARBY_STOPS_TTL: float = _ovr.get("bus_nearby_stops_ttl", 300.0)
BUS_NEARBY_STOPS_MAX_SIZE: int = _ovr.get("bus_nearby_stops_max_size", 200)


# ┌─────────────────────────────────────────────────────┐
# │  BUS — Circuit Breakers & Concurrency               │
# └─────────────────────────────────────────────────────┘

SIRI_FAIL_THRESHOLD: int = _ovr.get("siri_fail_threshold", 3)
SIRI_CIRCUIT_COOLDOWN: float = _ovr.get("siri_circuit_cooldown", 300.0)
OBA_AUTH_COOLDOWN: float = _ovr.get("oba_auth_cooldown", 60.0)
BUS_UPSTREAM_CONCURRENCY: int = _ovr.get("bus_upstream_concurrency", 64)

REDIS_KEY_PREFIX: str = "track:bus"


# ┌─────────────────────────────────────────────────────┐
# │  /nearby/grouped — Response-Level Cache             │
# │  Cache the fully-assembled grouped response so      │
# │  repeat requests skip ALL upstream + processing.    │
# └─────────────────────────────────────────────────────┘

NEARBY_RESPONSE_FRESH_TTL: float = _ovr.get("nearby_response_fresh_ttl", 10.0)
NEARBY_RESPONSE_STALE_TTL: float = _ovr.get("nearby_response_stale_ttl", 20.0)
NEARBY_RESPONSE_MAX_SIZE: int = _ovr.get("nearby_response_max_size", 400)
# 4 decimals ≈ 11m grid cells (was 3 ≈ 111m — too coarse, causing
# users on cell boundaries to get stops from the wrong neighbourhood).
NEARBY_GPS_DECIMALS: int = _ovr.get("nearby_gps_decimals", 4)


# ┌─────────────────────────────────────────────────────┐
# │  /predict/delay  — Delay Factor Cache               │
# │  Cache key: route_id + hour + dow + weather + mode  │
# │  Same conditions → same factor → serve all users    │
# │  from one computation. TTL = 1 hour because the     │
# │  contextual factors (rush hour, weather bucket) are │
# │  stable within a single hour window.                │
# └─────────────────────────────────────────────────────┘

PREDICT_FACTOR_TTL: float = _ovr.get("predict_factor_ttl", 3600.0)   # 1 hour
PREDICT_FACTOR_MAX_SIZE: int = _ovr.get("predict_factor_max_size", 512)
