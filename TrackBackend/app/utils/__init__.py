"""
Shared utility modules for the Track backend.

Re-exports the most commonly used helpers so callers can do::

    from app.utils import TrackLogger
    from app.utils import haversine_m, bounding_box_degrees
    from app.utils import encode_polyline, decode_polyline

Modules:
    cache_registry   – @tracked_cache decorator + bulk cache clearing
    cache_stats      – Hit/miss rate counters for observability
    geo_utils        – Geographic math (haversine, bounding boxes, time helpers)
    logger           – Structured logging (colored console, JSON for Render)
    metrics          – Prometheus counters, gauges, and histograms
    polyline_utils   – Google polyline encoding/decoding, WGS84 densification
    transit_utils    – Route-to-color mapping, feed key resolution
"""

from app.utils.geo_utils import bounding_box_degrees, haversine_m
from app.utils.logger import TrackLogger
from app.utils.polyline_utils import decode_polyline, encode_polyline

__all__ = [
    "TrackLogger",
    "haversine_m",
    "bounding_box_degrees",
    "encode_polyline",
    "decode_polyline",
]
