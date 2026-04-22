"""Service for loading user context from Supabase.

Fetches ``profiles``, ``user_settings``, and ``trip_configurations`` in
parallel using the service-role key.  Results are assembled into a
:class:`~app.models.user.UserContext` that route handlers use to personalise
responses without requiring additional client-side parameters.

Usage
-----
::

    from app.services.user_service import load_user_context

    @router.get("/nearby/grouped")
    async def nearby(user: AuthUser | None = Depends(optional_user)):
        ctx = await load_user_context(user) if user else None
        radius = ctx.effective_search_radius if ctx else default_radius
        ...

The service degrades gracefully: if Supabase is unavailable or a row is
missing, it returns ``UserContext`` with ``None`` sub-objects and callers
fall back to server defaults.
"""

from __future__ import annotations

import asyncio
import os
import uuid
from functools import lru_cache

import httpx

from app.auth.user import AuthUser
from app.models.user import TripConfiguration, UserContext, UserProfile, UserSettings
from app.utils.logger import TrackLogger

# ── Supabase connection ───────────────────────────────────────────────────────

def _supabase_url() -> str:
    return os.environ.get("SUPABASE_URL", "").rstrip("/")


def _service_key() -> str:
    return (
        os.environ.get("SUPABASE_SERVICE_KEY")
        or os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        or ""
    )


@lru_cache(maxsize=1)
def _get_client() -> httpx.AsyncClient:
    """Return a shared async httpx client for Supabase REST calls."""
    return httpx.AsyncClient(
        base_url=_supabase_url(),
        headers={
            "apikey": _service_key(),
            "Authorization": f"Bearer {_service_key()}",
            "Accept": "application/json",
        },
        timeout=5.0,
    )


# ── Individual fetchers ───────────────────────────────────────────────────────

async def _fetch_profile(user_id: uuid.UUID) -> UserProfile | None:
    """Fetch the user's profile row from Supabase."""
    try:
        client = _get_client()
        r = await client.get(
            "/rest/v1/profiles",
            params={
                "id": f"eq.{user_id}",
                "select": (
                    "id,email,apple_user_id,full_name,given_name,family_name,"
                    "username,avatar_url,preferred_theme,notifications_enabled,"
                    "created_at,updated_at,last_login_at"
                ),
                "limit": "1",
            },
        )
        r.raise_for_status()
        rows = r.json()
        if not rows:
            return None
        row = rows[0]
        return UserProfile(
            user_id=user_id,
            email=row.get("email"),
            apple_user_id=row.get("apple_user_id"),
            full_name=row.get("full_name"),
            given_name=row.get("given_name"),
            family_name=row.get("family_name"),
            username=row.get("username"),
            avatar_url=row.get("avatar_url"),
            preferred_theme=row.get("preferred_theme", "system"),
            notifications_enabled=row.get("notifications_enabled", True),
            created_at=row.get("created_at"),
            updated_at=row.get("updated_at"),
            last_login_at=row.get("last_login_at"),
        )
    except Exception as exc:
        TrackLogger.warning(f"[USER_SVC] profile fetch failed for {user_id}: {exc}", tag="USER_SVC")
        return None


async def _fetch_settings(user_id: uuid.UUID) -> UserSettings | None:
    """Fetch the user's app-settings row from Supabase."""
    try:
        client = _get_client()
        r = await client.get(
            "/rest/v1/user_settings",
            params={
                "user_id": f"eq.{user_id}",
                "select": (
                    "user_id,preferred_theme,distance_unit,"
                    "near_you_radius_meters,farther_away_radius_meters,"
                    "much_farther_away_radius_meters,show_system_map,"
                    "subway_line_offset_meters,drag_to_search,"
                    "haptics_enabled,auto_refresh_enabled,notifications_enabled"
                ),
                "limit": "1",
            },
        )
        r.raise_for_status()
        rows = r.json()
        if not rows:
            return None
        row = rows[0]
        return UserSettings(
            user_id=user_id,
            preferred_theme=row.get("preferred_theme", "system"),
            distance_unit=row.get("distance_unit", "mi"),
            near_you_radius_meters=float(row.get("near_you_radius_meters") or 2414),
            farther_away_radius_meters=float(row.get("farther_away_radius_meters") or 4023),
            much_farther_away_radius_meters=float(row.get("much_farther_away_radius_meters") or 8047),
            show_system_map=bool(row.get("show_system_map", True)),
            subway_line_offset_meters=float(row.get("subway_line_offset_meters") or 12),
            drag_to_search=bool(row.get("drag_to_search", False)),
            haptics_enabled=bool(row.get("haptics_enabled", True)),
            auto_refresh_enabled=bool(row.get("auto_refresh_enabled", True)),
            notifications_enabled=bool(row.get("notifications_enabled", True)),
        )
    except Exception as exc:
        TrackLogger.warning(f"[USER_SVC] settings fetch failed for {user_id}: {exc}", tag="USER_SVC")
        return None


async def _fetch_trip_config(user_id: uuid.UUID) -> TripConfiguration | None:
    """Fetch the user's trip-planning configuration row from Supabase."""
    try:
        client = _get_client()
        r = await client.get(
            "/rest/v1/trip_configurations",
            params={
                "user_id": f"eq.{user_id}",
                "select": (
                    "user_id,priority,mode_subway,mode_bus,"
                    "mode_lirr,mode_mnr,accessibility_priority,walk_preference"
                ),
                "limit": "1",
            },
        )
        r.raise_for_status()
        rows = r.json()
        if not rows:
            return None
        row = rows[0]
        return TripConfiguration(
            user_id=user_id,
            priority=row.get("priority", "quick"),
            mode_subway=bool(row.get("mode_subway", True)),
            mode_bus=bool(row.get("mode_bus", True)),
            mode_lirr=bool(row.get("mode_lirr", False)),
            mode_mnr=bool(row.get("mode_mnr", False)),
            accessibility_priority=bool(row.get("accessibility_priority", False)),
            walk_preference=float(row.get("walk_preference") or 0.5),
        )
    except Exception as exc:
        TrackLogger.warning(f"[USER_SVC] trip_config fetch failed for {user_id}: {exc}", tag="USER_SVC")
        return None


# ── Public API ────────────────────────────────────────────────────────────────

async def load_user_context(user: AuthUser) -> UserContext:
    """Fetch all three user rows in parallel and return a :class:`UserContext`.

    Never raises — missing rows or Supabase errors degrade to ``None``
    sub-objects so callers always get a valid ``UserContext`` back.
    """
    profile, settings, trip_config = await asyncio.gather(
        _fetch_profile(user.user_id),
        _fetch_settings(user.user_id),
        _fetch_trip_config(user.user_id),
        return_exceptions=False,
    )
    return UserContext(
        user_id=user.user_id,
        profile=profile,
        settings=settings,
        trip_config=trip_config,
    )
