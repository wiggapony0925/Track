#
# providers/base.py
# TrackBackend
#
# Abstract base class for transit providers.
#
# Every supported transit region (MTA, CTA, WMATA, …) implements this
# interface.  The provider centralises region-specific constants —
# geographic centre, bounding box, agency prefixes, route colours — so
# the rest of the codebase stays region-agnostic.
#

from __future__ import annotations

import math
from abc import ABC, abstractmethod


class TransitProvider(ABC):
    """Abstract base class for a transit agency / region."""

    # ── Identity ──────────────────────────────────────────────────────

    @property
    @abstractmethod
    def provider_id(self) -> str:
        """Short unique key, e.g. ``"mta"``, ``"cta"``, ``"wmata"``."""
        ...

    @property
    @abstractmethod
    def display_name(self) -> str:
        """Human-readable name, e.g. ``"MTA New York"``."""
        ...

    # ── Geography ─────────────────────────────────────────────────────

    @property
    @abstractmethod
    def region_center_lat(self) -> float:
        """Latitude of the region centre (used for geo approximations)."""
        ...

    @property
    @abstractmethod
    def region_center_lon(self) -> float:
        """Longitude of the region centre."""
        ...

    @property
    @abstractmethod
    def bounding_box(self) -> tuple[float, float, float, float]:
        """Service area as ``(min_lat, max_lat, min_lon, max_lon)``."""
        ...

    # ── Derived geo helpers (no override needed) ──────────────────────

    @property
    def cos_lat(self) -> float:
        """Cosine of the region-centre latitude."""
        return math.cos(math.radians(self.region_center_lat))

    @property
    def meters_per_deg_lon(self) -> float:
        """Approximate metres per degree of longitude at region centre."""
        return 111_320.0 * self.cos_lat

    @property
    def meters_per_deg_lat(self) -> float:
        """Approximate metres per degree of latitude (≈ 111.32 km everywhere)."""
        return 111_320.0

    # ── Transit modes ─────────────────────────────────────────────────

    @property
    @abstractmethod
    def modes(self) -> list[str]:
        """Supported transit modes, e.g. ``["subway", "bus", "lirr", "mnr"]``."""
        ...

    @property
    @abstractmethod
    def agency_prefixes(self) -> list[str]:
        """Agency route-ID prefixes, longest first to avoid partial matches."""
        ...

    # ── Route helpers ─────────────────────────────────────────────────

    @abstractmethod
    def get_route_color(self, route_id: str) -> str:
        """Return the hex colour for *route_id*, e.g. ``"#0062CF"``."""
        ...

    @abstractmethod
    def strip_agency_prefix(self, route_id: str) -> str:
        """Remove the agency prefix from a GTFS route/stop ID."""
        ...
