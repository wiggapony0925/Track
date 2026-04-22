"""Pydantic models representing user data fetched from Supabase.

These models are used when the backend needs to personalise a response beyond
what the JWT alone provides.  The JWT gives us ``user_id`` for free
(no DB hit).  The models below are populated on-demand from Supabase
using the service-role key when a route needs richer context.

Tables mapped
-------------
* ``profiles``            → :class:`UserProfile`
* ``user_settings``       → :class:`UserSettings`
* ``trip_configurations`` → :class:`TripConfiguration`

Combined view
-------------
* :class:`UserContext` — the full picture a route handler receives when it
  calls :func:`app.services.user_service.load_user_context`.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field


# ── Profile ───────────────────────────────────────────────────────────────────


class UserProfile(BaseModel):
    """Row from the ``public.profiles`` table.

    Populated from Apple Sign-In data on first login and may be partially
    absent (e.g. Apple private-relay users who hide their email).

    ``auth.users`` internal fields (encrypted_password, confirmation_token,
    recovery_token, phone_change_*, etc.) are deliberately excluded — those
    are Supabase-internal and must never be exposed via the API.  The JWT
    already provides everything identity-related (user_id, email, role).
    """

    user_id: uuid.UUID = Field(..., description="Primary key — matches auth.users.id.")
    email: str | None = Field(None, description="Email address. May be absent for Apple private-relay.")
    apple_user_id: str | None = Field(None, description="Apple's stable user identifier (provided on first Sign-In only).")
    full_name: str | None = Field(None, description="Full display name from Apple Sign-In.")
    given_name: str | None = Field(None, description="First name.")
    family_name: str | None = Field(None, description="Last name.")
    username: str | None = Field(None, description="Optional custom username.")
    avatar_url: str | None = Field(None, description="Optional avatar image URL.")
    preferred_theme: str = Field("system", description="'system', 'light', or 'dark'.")
    notifications_enabled: bool = Field(True, description="Push notifications opt-in.")
    created_at: datetime | None = Field(None, description="When the profile row was created.")
    updated_at: datetime | None = Field(None, description="When the profile was last updated.")
    last_login_at: datetime | None = Field(None, description="Most recent login timestamp.")


# ── App / map settings ────────────────────────────────────────────────────────


class UserSettings(BaseModel):
    """Row from the ``user_settings`` table.

    Controls search radius, map display, and general app behaviour.
    A default row is auto-created by a Supabase trigger when a new user
    signs up, so this will always exist for authenticated users.
    """

    user_id: uuid.UUID = Field(..., description="References auth.users.id.")

    # Appearance
    preferred_theme: str = Field("system", description="'system', 'light', or 'dark'.")
    distance_unit: str = Field("mi", description="'mi' or 'km'.")

    # Transit search radii (meters) — used to personalise /nearby/grouped
    near_you_radius_meters: float = Field(2414.0, description="~1.5 mi — default nearby search radius.")
    farther_away_radius_meters: float = Field(4023.0, description="~2.5 mi.")
    much_farther_away_radius_meters: float = Field(8047.0, description="~5.0 mi.")

    # Map & display
    show_system_map: bool = Field(True, description="Show full transit system map overlay.")
    subway_line_offset_meters: float = Field(12.0, description="Visual spread between co-located subway lines.")
    drag_to_search: bool = Field(False, description="Pan map to explore transit at another location.")

    # General behaviour
    haptics_enabled: bool = Field(True, description="Haptic feedback on interactions.")
    auto_refresh_enabled: bool = Field(True, description="Auto-refresh transit data on timer.")
    notifications_enabled: bool = Field(True, description="Push notifications opt-in.")


# ── Trip-planning preferences ─────────────────────────────────────────────────


class TripConfiguration(BaseModel):
    """Row from the ``trip_configurations`` table.

    Controls which transit modes are enabled, routing priority, and how far the
    user is willing to walk.  Used to seed ``/engine/plan`` and ``/engine/go``
    defaults when the iOS client does not supply explicit overrides.
    """

    user_id: uuid.UUID = Field(..., description="References auth.users.id.")

    # Routing priority: 'quick' | 'fewer_transfers' | 'less_walking'
    priority: str = Field("quick", description="Trip optimisation strategy.")

    # Enabled transit modes
    mode_subway: bool = Field(True, description="Include subway routes.")
    mode_bus: bool = Field(True, description="Include bus routes.")
    mode_lirr: bool = Field(False, description="Include LIRR routes.")
    mode_mnr: bool = Field(False, description="Include Metro-North routes.")

    # Accessibility & walking
    accessibility_priority: bool = Field(False, description="Prefer ADA-accessible routes.")
    walk_preference: float = Field(
        0.5,
        ge=0.0,
        le=1.0,
        description=(
            "0.0 → minimal walking (~400 m max), "
            "0.5 → default (~1200 m), "
            "1.0 → willing to walk further (~2400 m)."
        ),
    )

    @property
    def enabled_modes(self) -> list[str]:
        """Return the list of enabled mode strings for engine requests."""
        modes: list[str] = []
        if self.mode_subway:
            modes.append("subway")
        if self.mode_bus:
            modes.append("bus")
        if self.mode_lirr:
            modes.append("lirr")
        if self.mode_mnr:
            modes.append("mnr")
        return modes

    @property
    def max_origin_walk_meters(self) -> int:
        """Walking distance from origin mapped from the 0–1 preference slider."""
        return int(400 + self.walk_preference * 2000)

    @property
    def max_destination_walk_meters(self) -> int:
        """Walking distance to destination mapped from the 0–1 preference slider."""
        return int(300 + self.walk_preference * 1700)

    @property
    def max_transfer_walk_meters(self) -> int:
        """Maximum transfer walking distance mapped from the 0–1 preference slider."""
        return int(150 + self.walk_preference * 450)

    @property
    def max_transfers(self) -> int:
        """Maximum transit transfers based on the routing priority."""
        return 1 if self.priority == "fewer_transfers" else 2


# ── Combined context ──────────────────────────────────────────────────────────


class UserContext(BaseModel):
    """Full personalisation context for a request.

    Assembled by :func:`app.services.user_service.load_user_context` from
    the three Supabase tables above.  All fields are optional so that partial
    data (e.g. settings row not yet created) degrades gracefully to defaults.

    Route handlers receive this via an injectable dependency and use it to
    personalise search radii, enabled modes, and recommendations without any
    client-side parameter overhead.
    """

    user_id: uuid.UUID = Field(..., description="Verified user UUID from JWT.")
    profile: UserProfile | None = Field(None, description="Profile data. None if not yet created.")
    settings: UserSettings | None = Field(None, description="App settings. None falls back to server defaults.")
    trip_config: TripConfiguration | None = Field(None, description="Trip planning prefs. None falls back to server defaults.")

    @property
    def effective_search_radius(self) -> int:
        """Return the user's preferred nearby search radius in meters, or the server default."""
        if self.settings:
            return int(self.settings.near_you_radius_meters)
        return 800  # server default

    @property
    def effective_modes(self) -> list[str] | None:
        """Return enabled transit modes from trip config, or None (all modes)."""
        if self.trip_config:
            modes = self.trip_config.enabled_modes
            return modes if modes else None
        return None
