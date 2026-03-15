#
# polyline_utils.py
# TrackBackend
#
# Shared Google-encoded polyline encode/decode utilities.
# Eliminates duplication across subway.py, lirr.py, mnr.py, bus_client.py.
#

from __future__ import annotations


def decode_polyline(encoded: str) -> list[tuple[float, float]]:
    """Decode a Google-encoded polyline into [(lat, lon), ...].

    Time complexity: O(n) where n is the length of the encoded string.
    """
    coords: list[tuple[float, float]] = []
    i, lat, lng = 0, 0, 0
    while i < len(encoded):
        for is_lng in (False, True):
            shift, result = 0, 0
            while True:
                b = ord(encoded[i]) - 63
                i += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            delta = ~(result >> 1) if (result & 1) else (result >> 1)
            if is_lng:
                lng += delta
            else:
                lat += delta
        coords.append((lat / 1e5, lng / 1e5))
    return coords


def encode_polyline(coords: list[tuple[float, float]]) -> str:
    """Encode [(lat, lon), ...] into a Google-encoded polyline string.

    Time complexity: O(n) where n is the number of coordinate pairs.
    """
    result: list[str] = []
    prev_lat, prev_lng = 0, 0
    for lat, lng in coords:
        lat_e5 = round(lat * 1e5)
        lng_e5 = round(lng * 1e5)
        _encode_value(lat_e5 - prev_lat, result)
        _encode_value(lng_e5 - prev_lng, result)
        prev_lat, prev_lng = lat_e5, lng_e5
    return "".join(result)


def _encode_value(value: int, result: list[str]) -> None:
    """Encode a single signed value into Google polyline encoding."""
    v = ~(value << 1) if value < 0 else (value << 1)
    while v >= 0x20:
        result.append(chr(((v & 0x1F) | 0x20) + 63))
        v >>= 5
    result.append(chr(v + 63))


import math as _math

# ── WGS-84 degree-to-metre constant ─────────────────────────────────────
_DEG_LAT_M = 111_320.0          # 1° latitude ≈ 111.32 km everywhere


def _deg_lon_m(lat: float) -> float:
    """Metres per degree of longitude at the given *lat*."""
    return _DEG_LAT_M * _math.cos(_math.radians(lat))


def _wgs84_dist(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Cheap planar distance (metres) between two (lat, lon) points.

    Uses the average latitude of *a* and *b* for the longitude scaling
    so the result is correct at any latitude — not just NYC.
    """
    dlat = (b[0] - a[0]) * _DEG_LAT_M
    dlon = (b[1] - a[1]) * _deg_lon_m((a[0] + b[0]) * 0.5)
    return _math.sqrt(dlat * dlat + dlon * dlon)


def densify_wgs84(
    coords: list[tuple[float, float]],
    max_spacing_m: float = 100.0,
) -> list[tuple[float, float]]:
    """Linearly interpolate points into segments longer than *max_spacing_m*.

    Operates in WGS-84 (lat, lon) — no reprojection needed.  This
    prevents client-side Catmull-Rom smoothing from bowing outward
    between sparse GTFS vertices (e.g. 600 m gaps on the 7 train's
    straight elevated section above Roosevelt Ave).
    """
    if len(coords) < 2:
        return list(coords)

    result: list[tuple[float, float]] = [coords[0]]
    for i in range(1, len(coords)):
        prev = coords[i - 1]
        curr = coords[i]
        dist = _wgs84_dist(prev, curr)

        if dist > max_spacing_m:
            n_sub = int(_math.ceil(dist / max_spacing_m))
            for j in range(1, n_sub):
                t = j / n_sub
                result.append((
                    prev[0] + t * (curr[0] - prev[0]),
                    prev[1] + t * (curr[1] - prev[1]),
                ))
        result.append(curr)

    return result


def simplify_polyline(
    coords: list[tuple[float, float]], tolerance: float = 0.0001
) -> list[tuple[float, float]]:
    """Ramer-Douglas-Peucker polyline simplification.

    Removes intermediate points that lie within *tolerance* degrees of the
    line segment between their neighbours.  A tolerance of 0.00005° ≈ 5.5 m
    at NYC latitude — visually identical on mobile zoom levels but cuts the
    point count by 40−60 % after densification.
    """
    if len(coords) <= 2:
        return coords

    first = coords[0]
    last = coords[-1]
    max_dist = 0.0
    max_idx = 0

    dx = last[1] - first[1]
    dy = last[0] - first[0]
    line_len_sq = dx * dx + dy * dy

    for i in range(1, len(coords) - 1):
        if line_len_sq == 0:
            dist = ((coords[i][0] - first[0]) ** 2 + (coords[i][1] - first[1]) ** 2) ** 0.5
        else:
            t = max(0, min(1, ((coords[i][1] - first[1]) * dx + (coords[i][0] - first[0]) * dy) / line_len_sq))
            proj_lat = first[0] + t * dy
            proj_lon = first[1] + t * dx
            dist = ((coords[i][0] - proj_lat) ** 2 + (coords[i][1] - proj_lon) ** 2) ** 0.5
        if dist > max_dist:
            max_dist = dist
            max_idx = i

    if max_dist > tolerance:
        left = simplify_polyline(coords[: max_idx + 1], tolerance)
        right = simplify_polyline(coords[max_idx:], tolerance)
        return left[:-1] + right
    else:
        return [first, last]
