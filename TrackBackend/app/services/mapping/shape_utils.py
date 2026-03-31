#
# shape_utils.py
# TrackBackend
#
# Shared geometry helpers used by subway_shapes.py and commuter_rail_shapes.py.
# Extracted to eliminate copy-paste duplication between those two modules.
#

from __future__ import annotations

import struct
from typing import NamedTuple


class ShapePoint(NamedTuple):
    """A single (lat, lon, sequence) point from GTFS shapes.txt."""

    lat: float
    lon: float
    sequence: int


def pack_coords(points: list[ShapePoint]) -> bytes:
    """Pack sorted ShapePoints into compact float32 bytes (8 bytes/point).

    Stores (lat, lon) pairs as little-endian float32.  Use unpack_coords()
    to decode.  For 347K points this saves ~48 MB vs NamedTuple storage.
    """
    if not points:
        return b""
    return struct.pack(
        f"<{len(points) * 2}f",
        *[v for p in points for v in (p.lat, p.lon)],
    )


def unpack_coords(buf: bytes) -> list[tuple[float, float]]:
    """Unpack compact bytes back to [(lat, lon), ...] list."""
    if not buf:
        return []
    n = len(buf) // 8  # 4 bytes per float × 2 floats per point
    vals = struct.unpack(f"<{n * 2}f", buf)
    return [(vals[i], vals[i + 1]) for i in range(0, len(vals), 2)]


def unpack_point_set(buf: bytes, decimals: int = 5) -> set[tuple[float, float]]:
    """Unpack to a set of rounded (lat, lon) tuples — used for deduplication."""
    if not buf:
        return set()
    n = len(buf) // 8
    vals = struct.unpack(f"<{n * 2}f", buf)
    return {
        (round(vals[i], decimals), round(vals[i + 1], decimals))
        for i in range(0, len(vals), 2)
    }
