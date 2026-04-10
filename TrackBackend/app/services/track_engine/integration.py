"""Backend singleton wiring for engine state and remote C++ routing."""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path

from .domain import (
    CalendarEvent,
    LocationInput,
    PlanRequest,
)
from .service import TrackEngineService

_REPO_ROOT = Path(__file__).resolve().parents[4]
_DEFAULT_SCHEDULE_DB = _REPO_ROOT / "TrackBackend" / "app" / "data" / "transit_schedule.db"
_DEFAULT_STATE_DB = _REPO_ROOT / "TrackBackend" / "app" / "data" / "track_engine_state.db"


@lru_cache(maxsize=1)
def get_engine_service() -> TrackEngineService:
    """Return the singleton TrackEngine service used by the backend."""

    schedule_db = Path(os.environ.get("TRACK_ENGINE_SCHEDULE_DB", _DEFAULT_SCHEDULE_DB))
    state_db = Path(os.environ.get("TRACK_ENGINE_STATE_DB", _DEFAULT_STATE_DB))
    return TrackEngineService(schedule_db=schedule_db, state_db=state_db)


def reset_engine_service() -> None:
    """Test helper to rebuild the singleton after env changes."""

    get_engine_service.cache_clear()


__all__ = [
    "CalendarEvent",
    "LocationInput",
    "PlanRequest",
    "TrackEngineService",
    "get_engine_service",
    "reset_engine_service",
]
