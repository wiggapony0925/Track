"""Geometric line operations for GTFS shape processing.

Python translation of the core algorithms from transitland-lib's
``tlxy/cut.go``:

- ``segment_closest_point``   — project a point onto a line segment
- ``line_closest_point``      — find the nearest point on a polyline
- ``cut_between_points``      — extract a sub-segment between two stops

All distance math uses Haversine so results are geographically correct
even over the length of LIRR / MNR branches (~150 km).

Typical usage example:

    from app.services.mapping.shared.geometry import cut_between_points
    segment = cut_between_points(shape_coords, stop_a_coords, stop_b_coords)
"""

from __future__ import annotations

import math
from typing import NamedTuple

_EARTH_RADIUS_KM = 6371.0


# ---------------------------------------------------------------------------
# Internal types
# ---------------------------------------------------------------------------


class _Point(NamedTuple):
    lat: float
    lon: float


def _haversine_km(a: _Point, b: _Point) -> float:
    """Return great-circle distance in km between two WGS-84 points."""
    d_lat = math.radians(b.lat - a.lat)
    d_lon = math.radians(b.lon - a.lon)
    h = (
        math.sin(d_lat / 2) ** 2
        + math.cos(math.radians(a.lat))
        * math.cos(math.radians(b.lat))
        * math.sin(d_lon / 2) ** 2
    )
    return 2 * _EARTH_RADIUS_KM * math.asin(math.sqrt(h))


def _lerp(a: _Point, b: _Point, t: float) -> _Point:
    """Linear interpolation between two points at fraction *t* ∈ [0, 1]."""
    return _Point(
        lat=a.lat + t * (b.lat - a.lat),
        lon=a.lon + t * (b.lon - a.lon),
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def segment_closest_point(
    a: tuple[float, float],
    b: tuple[float, float],
    p: tuple[float, float],
) -> tuple[tuple[float, float], float]:
    """Project *p* onto the segment A→B and return ``(closest_point, distance_km)``.

    If the perpendicular projection falls outside the segment, the nearest
    endpoint is returned instead (clamped).

    Args:
        a: Segment start as ``(lat, lon)``.
        b: Segment end as ``(lat, lon)``.
        p: Query point as ``(lat, lon)``.

    Returns:
        A tuple ``(closest_point, distance_km)`` where *closest_point* is
        ``(lat, lon)`` and *distance_km* is the Haversine distance from *p*.
    """
    pa = _Point(*a)
    pb = _Point(*b)
    pp = _Point(*p)

    dx = pb.lat - pa.lat
    dy = pb.lon - pa.lon
    seg_len_sq = dx * dx + dy * dy

    if seg_len_sq == 0.0:
        # Degenerate segment (a == b)
        closest = pa
    else:
        # Project pp onto the line defined by pa→pb
        t = ((pp.lat - pa.lat) * dx + (pp.lon - pa.lon) * dy) / seg_len_sq
        t = max(0.0, min(1.0, t))
        closest = _lerp(pa, pb, t)

    return (closest.lat, closest.lon), _haversine_km(pp, closest)


def line_closest_point(
    line: list[tuple[float, float]],
    point: tuple[float, float],
) -> tuple[tuple[float, float], int, float]:
    """Find the nearest point on a polyline to *point*.

    Args:
        line:  Ordered list of ``(lat, lon)`` vertices.
        point: Query point as ``(lat, lon)``.

    Returns:
        A 3-tuple ``(closest_point, segment_index, position_fraction)`` where:

        - *closest_point* — ``(lat, lon)`` of the nearest point on the line.
        - *segment_index* — 0-based index of the segment containing the point.
        - *position_fraction* — value in ``[0.0, 1.0]`` representing how far
          along the *entire* line the closest point lies (useful for ordering
          stops along a route).

    Raises:
        ValueError: If *line* has fewer than two vertices.
    """
    if len(line) < 2:
        raise ValueError("line must have at least two vertices")

    best_pt: tuple[float, float] = line[0]
    best_seg: int = 0
    best_dist = math.inf

    for i in range(len(line) - 1):
        pt, dist = segment_closest_point(line[i], line[i + 1], point)
        if dist < best_dist:
            best_dist = dist
            best_pt = pt
            best_seg = i

    # Compute a normalised position (0 → start of line, 1 → end of line)
    # by accumulated Haversine distance so the fraction is arc-length based.
    total_len = sum(
        _haversine_km(_Point(*line[j]), _Point(*line[j + 1]))
        for j in range(len(line) - 1)
    )
    if total_len == 0.0:
        return best_pt, best_seg, 0.0

    dist_to_seg = sum(
        _haversine_km(_Point(*line[j]), _Point(*line[j + 1]))
        for j in range(best_seg)
    )
    seg_len = _haversine_km(_Point(*line[best_seg]), _Point(*line[best_seg + 1]))
    # Sub-segment fraction within the best segment
    if seg_len > 0.0:
        dx_s = line[best_seg + 1][0] - line[best_seg][0]
        dy_s = line[best_seg + 1][1] - line[best_seg][1]
        denom = dx_s * dx_s + dy_s * dy_s
        if denom > 0.0:
            t_seg = (
                (best_pt[0] - line[best_seg][0]) * dx_s
                + (best_pt[1] - line[best_seg][1]) * dy_s
            ) / denom
            t_seg = max(0.0, min(1.0, t_seg))
        else:
            t_seg = 0.0
    else:
        t_seg = 0.0

    fraction = (dist_to_seg + t_seg * seg_len) / total_len
    return best_pt, best_seg, fraction


def cut_between_points(
    line: list[tuple[float, float]],
    from_pt: tuple[float, float],
    to_pt: tuple[float, float],
) -> list[tuple[float, float]]:
    """Extract the sub-segment of *line* between the projections of *from_pt*
    and *to_pt*.

    Useful for clipping a full route shape to just the portion between two
    stops — e.g. to highlight the active segment on the Live Activity map.

    The start point of the search for *to_pt* begins at the segment of
    *from_pt* so that ordering is preserved on routes that loop back.

    Args:
        line:     Full route polyline as ``[(lat, lon), ...]``.
        from_pt:  Origin stop coordinates ``(lat, lon)``.
        to_pt:    Destination stop coordinates ``(lat, lon)``.

    Returns:
        Clipped polyline as ``[(lat, lon), ...]``.  If *from_pt* is after
        *to_pt* on the line the result will be empty.
    """
    if len(line) < 2:
        return list(line)

    _, from_seg, _ = line_closest_point(line, from_pt)
    from_closest, _ = segment_closest_point(line[from_seg], line[from_seg + 1], from_pt)

    # Search for to_pt starting from from_seg so ordering is maintained
    to_seg = from_seg
    to_best_dist = math.inf
    to_closest: tuple[float, float] = from_closest

    for i in range(from_seg, len(line) - 1):
        pt, dist = segment_closest_point(line[i], line[i + 1], to_pt)
        if dist < to_best_dist:
            to_best_dist = dist
            to_closest = pt
            to_seg = i

    if to_seg < from_seg:
        return []

    result: list[tuple[float, float]] = [from_closest]
    # Add all vertices strictly between the two segments
    for i in range(from_seg + 1, to_seg + 1):
        result.append(line[i])
    if to_seg > from_seg:
        result.append(to_closest)
    else:
        # Both projections fall on the same segment — just use the two points
        result = [from_closest, to_closest]

    return result


def line_relative_positions(
    line: list[tuple[float, float]],
    points: list[tuple[float, float]],
) -> list[float]:
    """Return arc-length fraction (0.0–1.0) for each point along *line*.

    For each query point, projects it onto the nearest segment of *line*
    and returns its normalised arc-length position.  Values are in the
    same order as *points*.

    Mirrors ``tlxy.LineRelativePositions`` from transitland-lib.
    Useful for ordering stops along a route and computing how far along a
    trip a vehicle has progressed.

    Args:
        line:   Route shape as ``[(lat, lon), ...]``.
        points: Query points as ``[(lat, lon), ...]``.

    Returns:
        List of fractions in ``[0.0, 1.0]``, parallel to *points*.

    Raises:
        ValueError: If *line* has fewer than two vertices.
    """
    return [line_closest_point(line, p)[2] for p in points]


def line_similarity(
    a: list[tuple[float, float]],
    b: list[tuple[float, float]],
) -> float:
    """RMSD-like similarity metric (km) between two polylines.

    For each point in *a*, finds the distance to its closest projection
    on *b*, then returns the root mean square of those distances.  Lower
    values mean more similar alignments.

    Mirrors ``tlxy.LineSimilarity`` from transitland-lib.  Useful for
    deduplicating shapes in Track's corridor pipeline: two shapes with an
    RMS distance < 0.05 km are likely the same physical track.

    Args:
        a: First polyline as ``[(lat, lon), ...]``.
        b: Second polyline as ``[(lat, lon), ...]``.

    Returns:
        RMS distance in km.  Returns ``0.0`` if *a* is empty.

    Raises:
        ValueError: If *b* has fewer than two vertices.
    """
    if not a:
        return 0.0
    distances = [
        _haversine_km(
            _Point(*p),
            _Point(*line_closest_point(b, p)[0]),
        )
        for p in a
    ]
    mean_sq = sum(d * d for d in distances) / len(distances)
    return math.sqrt(mean_sq)
