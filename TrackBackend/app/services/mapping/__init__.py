"""Transit mapping services.

Namespaces
----------
shared/
    coords   – Binary packing, haversine distance, shape quality helpers
    geometry – Low-level geometric primitives (closest point, cut, similarity)

subway/
    shapes   – Route shapes and station data (sourced from GTFS)
    corridor – Topological multi-lane offset pipeline for map rendering
    quality  – Polyline quality metrics and deviation diagnostics

bus/
    routes   – Bus route polylines from MTA open data API (auto-updated)
    stops    – Bus stop locations from MTA open data API (auto-updated)

rail/
    shapes   – LIRR and Metro-North route shapes and stop data (GTFS)

Priority rule
-------------
Always prefer the open-data API source over GTFS for bus geometry —
the MTA updates those datasets with each bundle so your shapes stay fresh
without a GTFS redeploy.
"""

from __future__ import annotations
