#
# geo_utils.py
# TrackBackend
#
# Shared geographic and time utilities.
# Deduplicates haversine (bus_client + station_lookup) and
# minutes_until (data_cleaner + rail_client).
#

from __future__ import annotations

import math
import time as _time

METERS_PER_DEG_LAT = 111_000.0


def meters_per_deg_lon(lat: float) -> float:
    """Metres per degree of longitude at the given *lat*.

    Works for any latitude — not tied to a specific region.
    """
    return 111_320.0 * math.cos(math.radians(lat))


# Backward-compatible alias (NYC ~40.76°N).  New code should call
# ``meters_per_deg_lon(lat)`` or use the provider's ``meters_per_deg_lon``.
METERS_PER_DEG_LON_NYC = meters_per_deg_lon(40.758)  # ≈ 84_370


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Haversine distance in meters between two lat/lon points.

    Time complexity: O(1).
    """
    R = 6_371_000
    rlat1, rlat2 = math.radians(lat1), math.radians(lat2)
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (
        math.sin(dlat / 2) ** 2
        + math.cos(rlat1) * math.cos(rlat2) * math.sin(dlon / 2) ** 2
    )
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def bounding_box_degrees(
    radius_m: float, center_lat: float = 40.758
) -> tuple[float, float]:
    """Return (lat_delta, lon_delta) in degrees for a bounding box.

    *center_lat* determines the longitude scaling.  Defaults to NYC
    for backward compatibility — new callers should pass an explicit
    latitude (or use ``provider.region_center_lat``).
    """
    lat_delta = radius_m / METERS_PER_DEG_LAT
    lon_delta = radius_m / meters_per_deg_lon(center_lat)
    return lat_delta, lon_delta


def minutes_until(epoch_s: int) -> int:
    """Return whole minutes from now until *epoch_s* (clamped to 0)."""
    diff = epoch_s - int(_time.time())
    return max(0, diff // 60)


# ── Point-to-segment distance on a sphere ────────────────────────────────
# Adapted from Transit App's py-gtfs-loader LatLon.distance_to_segment().
# https://github.com/TransitApp/py-gtfs-loader/blob/main/gtfs_loader/lat_lon.py
#
# Uses cross-track / along-track projection on the great-circle through
# the segment endpoints.  Returns meters.

_EARTH_R = 6_371_009.0  # mean Earth radius (same as Transit App)


def point_to_segment_distance_m(
    px: float, py: float,
    ax: float, ay: float,
    bx: float, by: float,
) -> float:
    """Distance in meters from point P to line segment A→B on the Earth.

    All arguments in **degrees** (lat, lon).

    Implements the same spherical geometry algorithm as Transit App's
    ``LatLon.distance_to_segment()`` from py-gtfs-loader:

       1. Compute cross-track distance (perpendicular to great-circle A→B)
       2. Compute along-track distance to find closest point on A→B
       3. If closest point lies between A and B, return distance to it
       4. Otherwise return min(dist(P, A), dist(P, B))

    This is significantly more accurate than the flat-earth approximation
    for segments > 1km, and only ~2× slower than the flat version.
    """
    sin, cos, asin, acos, atan2, sqrt, radians = (
        math.sin, math.cos, math.asin, math.acos, math.atan2, math.sqrt, math.radians,
    )

    # Convert to radians
    p_lat, p_lon = radians(px), radians(py)
    a_lat, a_lon = radians(ax), radians(ay)
    b_lat, b_lon = radians(bx), radians(by)

    # Angular distance A→P and A→B
    d_ap = _angular_dist(a_lat, a_lon, p_lat, p_lon)
    d_ab = _angular_dist(a_lat, a_lon, b_lat, b_lon)
    d_bp = _angular_dist(b_lat, b_lon, p_lat, p_lon)

    if d_ab < 1e-12:
        # A and B are the same point
        return _EARTH_R * d_ap

    # Bearing A→P and A→B
    t_ap = atan2(
        sin(p_lon - a_lon) * cos(p_lat),
        cos(a_lat) * sin(p_lat) - sin(a_lat) * cos(p_lat) * cos(p_lon - a_lon),
    )
    t_ab = atan2(
        sin(b_lon - a_lon) * cos(b_lat),
        cos(a_lat) * sin(b_lat) - sin(a_lat) * cos(b_lat) * cos(b_lon - a_lon),
    )

    # Cross-track angular distance
    d_cross = asin(sin(d_ap) * sin(t_ap - t_ab))

    # Along-track angular distance
    cos_d_cross = cos(d_cross)
    if abs(cos_d_cross) < 1e-15:
        cos_d_cross = 1e-15
    d_along = acos(cos(d_ap) / cos_d_cross)

    # If along-track falls within segment, compute precise closest point distance
    if 0 < d_along < d_ab:
        # Reconstruct closest point on A→B
        lx_lat = asin(
            sin(a_lat) * cos(d_along) + cos(a_lat) * sin(d_along) * cos(t_ab)
        )
        lx_lon = a_lon + atan2(
            sin(t_ab) * sin(d_along) * cos(a_lat),
            cos(d_along) - sin(a_lat) * sin(lx_lat),
        )
        d_lx_p = _angular_dist(lx_lat, lx_lon, p_lat, p_lon)

        # Verify closest point is actually closer than both endpoints
        if d_lx_p < d_ap and d_lx_p < d_bp:
            return _EARTH_R * d_lx_p

    # Closest point is one of the endpoints
    return _EARTH_R * min(d_ap, d_bp)


def _angular_dist(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Haversine angular distance (radians). Inputs already in radians."""
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * math.asin(math.sqrt(a))


# ── Douglas-Peucker polyline simplification ──────────────────────────────
# Inspired by Transit App's use of simplify-js and transitfeed's shape
# handling.  Reduces polyline point count by 60-80% with minimal visual
# error, dramatically shrinking API payloads.
#
# Uses perpendicular distance in meters for the tolerance check so the
# algorithm works correctly at any zoom / latitude.

def simplify_polyline(
    points: list[tuple[float, float]],
    tolerance_m: float = 5.0,
) -> list[tuple[float, float]]:
    """Simplify a polyline using the Ramer-Douglas-Peucker algorithm.

    Args:
        points: List of (lat, lon) tuples in degrees.
        tolerance_m: Maximum allowed perpendicular distance in meters.
                     5m is a good default for subway/bus routes — visually
                     imperceptible at typical map zoom levels while reducing
                     point count by 60-80%.

    Returns:
        Simplified list of (lat, lon) tuples.

    Uses proper spherical point-to-segment distance from Transit App's
    ``LatLon.distance_to_segment()`` algorithm for accuracy on long segments.
    """
    if len(points) <= 2:
        return list(points)

    # Find the point with maximum distance from the line A→B
    a = points[0]
    b = points[-1]
    max_dist = 0.0
    max_idx = 0

    for i in range(1, len(points) - 1):
        p = points[i]
        d = point_to_segment_distance_m(p[0], p[1], a[0], a[1], b[0], b[1])
        if d > max_dist:
            max_dist = d
            max_idx = i

    if max_dist > tolerance_m:
        # Recursively simplify both halves
        left = simplify_polyline(points[:max_idx + 1], tolerance_m)
        right = simplify_polyline(points[max_idx:], tolerance_m)
        return left[:-1] + right
    else:
        # All intermediate points are within tolerance — keep only endpoints
        return [a, b]


# ── Shape similarity (modified Hausdorff distance) ───────────────────────
# Adapted from Transit App's GTFS-blocks-to-transfers shape_similarity.py.
# https://github.com/TransitApp/GTFS-blocks-to-transfers
#
# Uses modified Hausdorff distance at the 80th percentile for robust shape
# comparison.  Useful for detecting duplicate routes/branches.

def hausdorff_percentile_m(
    shape_a: list[tuple[float, float]],
    shape_b: list[tuple[float, float]],
    percentile: float = 0.8,
) -> float:
    """Modified Hausdorff distance between two shapes at the given percentile.

    For each point in shape_a, finds the minimum distance to any segment in
    shape_b, and vice versa.  Returns the percentile of the combined distances.

    A result < 100m typically means the shapes are "similar" (e.g., one is the
    return trip of the other).

    Args:
        shape_a: List of (lat, lon) tuples.
        shape_b: List of (lat, lon) tuples.
        percentile: Percentile threshold (0.0–1.0). Default 0.8 (80th).

    Returns:
        Distance in meters at the given percentile.
    """
    if len(shape_a) < 2 or len(shape_b) < 2:
        return float("inf")

    distances = _point_to_nearest_segment_distances(shape_a, shape_b)
    distances.extend(_point_to_nearest_segment_distances(shape_b, shape_a))

    return _percentile(distances, percentile)


def _point_to_nearest_segment_distances(
    points: list[tuple[float, float]],
    segments: list[tuple[float, float]],
) -> list[float]:
    """For each point, find the nearest distance to any segment in the other shape."""
    distances: list[float] = []
    for px, py in points:
        d_nearest = float("inf")
        for i in range(len(segments) - 1):
            ax, ay = segments[i]
            bx, by = segments[i + 1]
            d = point_to_segment_distance_m(px, py, ax, ay, bx, by)
            if d < d_nearest:
                d_nearest = d
        distances.append(d_nearest)
    return distances


def _percentile(values: list[float], threshold: float) -> float:
    """NIST interpolation percentile (same formula as Transit App's).

    https://www.itl.nist.gov/div898/handbook/prc/section2/prc262.htm
    """
    if not values:
        return 0.0
    values.sort()
    float_index = threshold * (len(values) + 1)
    index = int(float_index)
    frac = float_index - index

    if index == 0:
        return values[0]
    if index >= len(values):
        return values[-1]

    return values[index - 1] + frac * (values[index] - values[index - 1])


# ── Geofence circle polygon ─────────────────────────────────────────────
# Adapted from Transit App's GTFS-flex-to-GOFS zones.py.
# Creates a circular polygon from a center point + radius — useful for
# "stations within radius" queries and geofence checks without PostGIS.

def geofence_circle(
    lat: float, lon: float,
    radius_m: float = 500.0,
    num_vertices: int = 16,
) -> list[tuple[float, float]]:
    """Create a circular polygon as a list of (lon, lat) tuples (GeoJSON order).

    Uses haversine forward projection for accuracy at any latitude.
    Adapted from Transit App's ``get_circle_polygon()`` + ``offset_circle_vertex()``.

    Args:
        lat: Center latitude in degrees.
        lon: Center longitude in degrees.
        radius_m: Radius in meters (default 500m — typical station walkable area).
        num_vertices: Number of vertices on the circle (default 16).

    Returns:
        A closed ring of (longitude, latitude) tuples suitable for GeoJSON Polygon.
        The first and last points are identical (closed ring per GeoJSON spec).
    """
    sin, cos, asin, atan2, pi, radians, degrees_ = (
        math.sin, math.cos, math.asin, math.atan2, math.pi, math.radians, math.degrees,
    )
    R = 6_371_009.0
    lat_c = radians(lat)
    lon_c = radians(lon)
    d = radius_m / R

    ring: list[tuple[float, float]] = []
    for i in range(num_vertices):
        bearing = -i / num_vertices * 2.0 * pi
        rad_lat = asin(sin(lat_c) * cos(d) + cos(lat_c) * sin(d) * cos(bearing))
        rad_lon = lon_c + atan2(
            sin(bearing) * sin(d) * cos(lat_c),
            cos(d) - sin(lat_c) * sin(rad_lat),
        )
        ring.append((round(degrees_(rad_lon), 10), round(degrees_(rad_lat), 10)))

    ring.append(ring[0])  # close the ring
    return ring
