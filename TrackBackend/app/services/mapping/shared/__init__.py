"""Shared geometric utilities reused across subway, bus, and rail pipelines.

Modules
-------
coords
    Compact binary packing / unpacking of (lat, lon) sequences,
    haversine distance, and shape-quality checks.  Used by every
    pipeline that serialises shapes to disk.

geometry
    Low-level geometric primitives: closest point on a segment or
    polyline, cut-between-points, relative position along a line,
    and line-similarity scoring.
"""

from __future__ import annotations
