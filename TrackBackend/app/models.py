#
# models.py
# TrackBackend
#
# Pydantic schemas for the JSON responses returned to the iOS app.
#

from __future__ import annotations

from pydantic import BaseModel


class TrackArrival(BaseModel):
    """A single upcoming train arrival at a station."""

    station: str
    direction: str
    minutes_away: int
    status: str = "On Time"


class TransitAlert(BaseModel):
    """A critical service alert."""

    route_id: str | None = None
    title: str
    description: str
    severity: str


class ElevatorStatus(BaseModel):
    """An elevator or escalator that is currently out of service."""

    station: str
    equipment_type: str
    description: str
    outage_since: str | None = None
