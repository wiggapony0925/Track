"""Commuter rail mapping services (LIRR and Metro-North Railroad).

Modules
-------
shapes
    Parses LIRR and MNR GTFS feeds to produce per-line route shapes,
    stop sequences, and direction headsigns.  Shared helper functions
    normalise the two agencies into the same CommuterRoute / CommuterStop
    model so callers do not need to care which agency owns a line.
"""

from __future__ import annotations
