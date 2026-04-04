"""Bus mapping services — sourced from MTA open data, not GTFS.

The MTA publishes bus route shapes and stop locations on data.ny.gov and
refreshes them automatically with every schedule bundle.  These modules
consume those live APIs so geometry stays current without a GTFS redeploy.

Modules
-------
routes
    Route polylines from the MTA Bus Routes dataset (h2wf-afav).
    Fetches all in-effect shapes, picks the best representative per
    route + direction, and caches the index to disk.

stops
    Stop locations from the MTA Bus Stops dataset (2ucp-7wg5).
    Fetches all revenue stops with lat/lon, name, and route membership,
    and caches the index to disk.
"""

from __future__ import annotations
