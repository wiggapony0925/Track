"""Subway and Staten Island Railway mapping services.

Modules
-------
shapes
    Loads route shapes, direction headsigns, service types, and
    station enrichment from the GTFS static feed.

corridor
    Topological multi-lane offset pipeline: clusters parallel GTFS
    shape variants into a single corridor spine, offsets each route
    to its own lane, despiked and Catmull-Rom smoothed for rendering.

quality
    Polyline quality snapshot: measures gap size, station attachment,
    neighbour-delta, and rendering fidelity at multiple zoom levels.
"""

from __future__ import annotations
