#
# providers/mta/__init__.py
# TrackBackend
#
# MTA New York — Transit provider implementation.
#
# Centralises all MTA-specific constants so they can be swapped out
# when a second provider is added.  Everything that was formerly
# hard-coded as ``85_000``, ``cos(40.7°)``, or ``"MTA NYCT_"`` across
# the codebase is sourced from here.
#

from __future__ import annotations

from app.providers.base import TransitProvider
from app.utils.transit_utils import get_subway_color


class MtaProvider(TransitProvider):
    """MTA (Metropolitan Transportation Authority) — New York region."""

    # ── Identity ──────────────────────────────────────────────────────

    @property
    def provider_id(self) -> str:
        return "mta"

    @property
    def display_name(self) -> str:
        return "MTA New York"

    # ── Geography ─────────────────────────────────────────────────────

    @property
    def region_center_lat(self) -> float:
        return 40.7580  # Times Square

    @property
    def region_center_lon(self) -> float:
        return -73.9855

    @property
    def bounding_box(self) -> tuple[float, float, float, float]:
        # NYC metro area: 5 boroughs + Long Island + lower Hudson Valley
        return (40.40, 42.20, -74.35, -71.70)

    # ── Transit modes ─────────────────────────────────────────────────

    @property
    def modes(self) -> list[str]:
        return ["subway", "bus", "lirr", "mnr"]

    @property
    def agency_prefixes(self) -> list[str]:
        # Ordered longest-first to avoid partial matches
        # (e.g. "MTA NYCT_" before "MTA_")
        return [
            "MTA NYCT_",
            "MTA BUS_",
            "MTABC_",
            "LIRR_",
            "MNR_",
            "MTA_",
        ]

    # ── Route helpers ─────────────────────────────────────────────────

    def get_route_color(self, route_id: str) -> str:
        return get_subway_color(route_id)

    def strip_agency_prefix(self, route_id: str) -> str:
        for prefix in self.agency_prefixes:
            if route_id.startswith(prefix):
                return route_id[len(prefix) :].replace("+", "")
        return route_id.replace("+", "")
