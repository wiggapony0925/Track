"""Shared geometry helpers used by subway_shapes.py and commuter_rail_shapes.py.
Extracted to eliminate copy-paste duplication between those two modules."""

from __future__ import annotations

import math
import struct
from typing import NamedTuple

_EARTH_RADIUS_KM = 6371.0
_SHAPE_MAX_SEGMENT_KM = 300.0  # reject shapes with implausibly large jumps


class ShapePoint(NamedTuple):
    """A single (lat, lon, sequence) point from GTFS shapes.txt."""

    lat: float
    lon: float
    sequence: int


def pack_coords(points: list[ShapePoint]) -> bytes:
    """Pack sorted ShapePoints into compact float64 bytes (16 bytes/point).

    Stores (lat, lon) pairs as little-endian float64 (double).  Use
    unpack_coords() to decode.  float64 preserves full GTFS precision
    (~15 significant digits) instead of float32's ~7 digits (±0.6 m jitter).
    """
    if not points:
        return b""
    return struct.pack(
        f"<{len(points) * 2}d",
        *[v for p in points for v in (p.lat, p.lon)],
    )


def unpack_coords(buf: bytes) -> list[tuple[float, float]]:
    """Unpack compact bytes back to [(lat, lon), ...] list."""
    if not buf:
        return []
    n = len(buf) // 16  # 8 bytes per double × 2 doubles per point
    vals = struct.unpack(f"<{n * 2}d", buf)
    return [(vals[i], vals[i + 1]) for i in range(0, len(vals), 2)]


def unpack_point_set(buf: bytes, decimals: int = 6) -> set[tuple[float, float]]:
    """Unpack to a set of rounded (lat, lon) tuples — used for deduplication."""
    if not buf:
        return set()
    n = len(buf) // 16
    vals = struct.unpack(f"<{n * 2}d", buf)
    return {
        (round(vals[i], decimals), round(vals[i + 1], decimals))
        for i in range(0, len(vals), 2)
    }


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Return the great-circle distance in kilometres between two WGS-84 points."""
    d_lat = math.radians(lat2 - lat1)
    d_lon = math.radians(lon2 - lon1)
    a = (
        math.sin(d_lat / 2) ** 2
        + math.cos(math.radians(lat1))
        * math.cos(math.radians(lat2))
        * math.sin(d_lon / 2) ** 2
    )
    return 2 * _EARTH_RADIUS_KM * math.asin(math.sqrt(a))


def shape_passes_quality(
    shape_id: str,
    pts: list[ShapePoint],
    max_segment_km: float = _SHAPE_MAX_SEGMENT_KM,
) -> bool:
    """Return False if the shape contains a (0, 0) origin point or a segment
    longer than *max_segment_km*.

    Both conditions indicate corrupt or placeholder GTFS data that would
    produce incorrect map polylines.
    """
    for pt in pts:
        if pt.lat == 0.0 and pt.lon == 0.0:
            return False
    for i in range(len(pts) - 1):
        dist = haversine_km(pts[i].lat, pts[i].lon, pts[i + 1].lat, pts[i + 1].lon)
        if dist > max_segment_km:
            return False
    return True


def stop_too_far_from_shape(
    stop_lat: float,
    stop_lon: float,
    shape_pts: list[ShapePoint],
    max_dist_km: float = 0.1,
) -> bool:
    """Return True if a stop is farther than *max_dist_km* from the polyline.

    Mirrors ``StopTooFarFromShapeCheck`` from transitland-lib's
    ``ext/bestpractices/too_far_from_shape.go`` (default threshold 100 m).
    Useful as a data-quality guard when loading GTFS shapes: stops placed
    more than ~100 m from their route polyline indicate mismatched or
    incorrect shape data.

    Args:
        stop_lat:    Stop latitude (WGS-84).
        stop_lon:    Stop longitude (WGS-84).
        shape_pts:   Route polyline as a list of :class:`ShapePoint`.
        max_dist_km: Distance threshold in kilometres (default 0.1 = 100 m).

    Returns:
        True  — stop is farther than *max_dist_km* (suspicious / bad data).
        False — stop is within the expected proximity of the shape.
    """
    # Local import to avoid a hard circular dependency at module load time.
    from app.services.mapping.geometry_utils import (
        line_closest_point,
    )

    if len(shape_pts) < 2:
        return False

    line = [(p.lat, p.lon) for p in shape_pts]
    closest, _, _ = line_closest_point(line, (stop_lat, stop_lon))
    dist_km = haversine_km(stop_lat, stop_lon, closest[0], closest[1])
    return dist_km > max_dist_km
