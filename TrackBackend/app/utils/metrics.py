"""Prometheus metrics for Track backend observability.

Uses prometheus-fastapi-instrumentator for automatic HTTP request metrics
(latency histograms, request counts, response sizes) plus custom counters
and gauges for transit-specific signals.

Metrics endpoint: GET /metrics (Prometheus scrape target)

Key metrics exposed:
• track_http_*               — auto-instrumented request latency, count, size
• track_feed_refresh_total   — GTFS-RT feed refresh attempts by line/status
• track_feed_refresh_seconds — feed refresh latency histogram
• track_ml_predictions_total — delay predictions by source (model|heuristic)
• track_weather_category     — current weather (gauge with label)
• track_cache_hits_total     — cache hit/miss/stale counters by layer
• track_warmup_complete      — 1 when server is fully warmed up."""

from __future__ import annotations

from prometheus_client import Counter, Gauge, Histogram, Info
from prometheus_fastapi_instrumentator import Instrumentator

# ── Auto-instrumented HTTP metrics ────────────────────────────────────────
# This creates: http_request_duration_seconds, http_requests_total,
# http_request_size_bytes, http_response_size_bytes.
instrumentator = Instrumentator(
    should_group_status_codes=True,
    should_ignore_untemplated=True,
    should_respect_env_var=False,
    excluded_handlers=["/metrics", "/health"],
    env_var_name="ENABLE_METRICS",
    inprogress_name="track_http_requests_inprogress",
    inprogress_labels=True,
)


# ── Custom metrics ────────────────────────────────────────────────────────

# Feed refresh metrics
FEED_REFRESH_TOTAL = Counter(
    "track_feed_refresh_total",
    "Total GTFS-RT feed refresh attempts",
    ["line", "status"],  # status: ok | error
)

FEED_REFRESH_DURATION = Histogram(
    "track_feed_refresh_seconds",
    "Time spent refreshing a single GTFS-RT feed",
    ["line"],
    buckets=[0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0],
)

# ML prediction metrics
ML_PREDICTIONS_TOTAL = Counter(
    "track_ml_predictions_total",
    "Total delay predictions made",
    ["source", "mode"],  # source: model|heuristic|l1_hit|l2_hit|disabled
)

ML_PREDICTION_FACTOR = Histogram(
    "track_ml_prediction_factor",
    "Distribution of delay factors returned by the ML model",
    ["mode"],
    buckets=[0.9, 0.95, 1.0, 1.05, 1.1, 1.15, 1.2, 1.3, 1.5, 2.0],
)

# Weather
WEATHER_CATEGORY = Gauge(
    "track_weather_category",
    "Current weather category (0=clear, 1=rain, 2=snow)",
)

WEATHER_FETCH_TOTAL = Counter(
    "track_weather_fetch_total",
    "Weather API fetch attempts",
    ["status"],  # ok | error
)

# Cache metrics
CACHE_OPERATIONS = Counter(
    "track_cache_operations_total",
    "Cache operations by layer and result",
    ["layer", "result"],  # layer: l1|redis|mta_feed  result: hit|miss|stale|error
)

# Server state
WARMUP_COMPLETE = Gauge(
    "track_warmup_complete",
    "1 when initial feed warmup is done and server is healthy",
)

ACTIVE_FEEDS = Gauge(
    "track_active_feeds",
    "Number of currently-cached transit feeds",
)

# GTFS refresh
GTFS_REFRESH_TOTAL = Counter(
    "track_gtfs_refresh_total",
    "GTFS static data refresh attempts",
    ["status"],  # ok | error | skipped
)

GTFS_REFRESH_DURATION = Histogram(
    "track_gtfs_refresh_seconds",
    "Time spent checking/downloading GTFS static data",
    buckets=[1, 5, 10, 30, 60, 120, 300, 600],
)

# App info
APP_INFO = Info(
    "track_app",
    "Track backend application info",
)


def setup_metrics(app) -> None:
    """Instrument a FastAPI app with Prometheus metrics.

    Call once during startup (main.py).  Creates the /metrics endpoint.
    """
    APP_INFO.info(
        {
            "version": "1.0.0",
            "name": "Track API",
        }
    )

    instrumentator.instrument(app).expose(
        app,
        endpoint="/metrics",
        include_in_schema=True,
        tags=["monitoring"],
    )
