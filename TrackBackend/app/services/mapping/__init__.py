"""
Geometry engine — polyline processing, offset corridors, and shape generation.

Modules:
    corridor_pipeline      – Topological subway corridor offsets for map rendering
    subway_shapes          – Subway route geometry + station enrichment
    commuter_rail_shapes   – LIRR / Metro-North route geometry
    polyline_quality       – Quality metrics and deviation analysis
    shape_utils            – Compact binary packing for GTFS shape coordinates
"""

__all__ = [
    "corridor_pipeline",
    "subway_shapes",
    "commuter_rail_shapes",
    "polyline_quality",
    "shape_utils",
]