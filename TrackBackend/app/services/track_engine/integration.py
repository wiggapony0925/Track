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
_RENDER_DATA_DIR = Path("/app/app/data")


def _resolve_db_path(
    env_key: str,
    *,
    default_path: Path,
    render_filename: str,
) -> Path:
    configured = os.environ.get(env_key, "").strip()
    configured_path = Path(configured) if configured else None
    render_path = _RENDER_DATA_DIR / render_filename

    if configured_path is not None and configured_path.exists():
        return configured_path
    if render_path.exists():
        return render_path
    if configured_path is not None:
        return configured_path
    return default_path


@lru_cache(maxsize=1)
def get_engine_service() -> TrackEngineService:
    """Return the singleton TrackEngine service used by the backend."""

    schedule_db = _resolve_db_path(
        "TRACK_ENGINE_SCHEDULE_DB",
        default_path=_DEFAULT_SCHEDULE_DB,
        render_filename="transit_schedule.db",
    )
    state_db = _resolve_db_path(
        "TRACK_ENGINE_STATE_DB",
        default_path=_DEFAULT_STATE_DB,
        render_filename="track_engine_state.db",
    )
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
