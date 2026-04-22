"""Service-variant taxonomy for transit arrivals.

Every arrival is classified into a typed :class:`ServiceVariant` so the
client can render consistent pills (Local / Limited / Express / SBS /
Super Express / Shuttle / Unknown) regardless of mode.

This module is the single source of truth for the variant enum.  It
*wraps* the existing free-form classifiers in
:mod:`app.routers.nearby` (``_classify_bus_service_type``,
``_is_express_service``) and normalises their string output into the
typed enum.

Design notes
------------
- Pure-logic module with no I/O so it can be unit-tested in isolation
  and imported from anywhere (router, services, ML pipeline) without
  causing circular imports.
- Subway routes have only two relevant variants in the live MTA feed
  today: LOCAL and EXPRESS (express variants 6X / 7X / FX).  The
  Manhattan-bound express segments of A/B/D/2-5/N/Q are NOT promoted
  to EXPRESS at the route-card level because the *route* is express,
  not a *variant of* a local route — those stay LOCAL so pills don't
  appear redundantly.  Per-arrival ``is_express`` still reflects the
  real-time pattern when the feed reports it.
- SHUTTLE covers the GS (42 St shuttle), H (Rockaway shuttle), and FS
  (Franklin Av shuttle).
"""

from __future__ import annotations

from enum import Enum
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from app.models import NearbyTransitArrival


class ServiceVariant(str, Enum):
    """Normalised service variant for a transit arrival.

    Values are the lowercase token used in the JSON payload.  iOS
    decodes them straight into a matching Swift enum.
    """

    LOCAL = "local"
    LIMITED = "limited"
    EXPRESS = "express"
    SBS = "sbs"
    SUPER_EXPRESS = "super_express"
    SHUTTLE = "shuttle"
    UNKNOWN = "unknown"


# Subway routes that are *shuttles* (not full lines).  Used to short-
# circuit the classifier before the express check.
_SUBWAY_SHUTTLES: frozenset[str] = frozenset({"GS", "H", "FS"})

# Subway route IDs whose presence in an arrival means the variant is
# explicitly EXPRESS (these are dedicated express variants of a local
# parent route — 6 ↔ 6X, 7 ↔ 7X, F ↔ FX).
_SUBWAY_EXPRESS_VARIANTS: frozenset[str] = frozenset({"6X", "7X", "FX"})


def _normalise_subway_route(route_id: str | None) -> str:
    """Return the bare display form of a subway route id (uppercase)."""
    if not route_id:
        return ""
    name = route_id.upper().strip()
    # Strip any agency prefix that might have leaked through.
    for prefix in ("MTA NYCT_", "MTA BUS_", "MTABC_"):
        if name.startswith(prefix):
            name = name[len(prefix):]
            break
    return name


# Map free-form bus service strings (as produced by
# ``_classify_bus_service_type``) to the typed enum.  Lowercase keys.
_BUS_TYPE_TO_VARIANT: dict[str, ServiceVariant] = {
    "local": ServiceVariant.LOCAL,
    "limited": ServiceVariant.LIMITED,
    "local / limited": ServiceVariant.LIMITED,
    "select bus service": ServiceVariant.SBS,
    "sbs": ServiceVariant.SBS,
    "express": ServiceVariant.EXPRESS,
    "super express": ServiceVariant.SUPER_EXPRESS,
    "shuttle": ServiceVariant.SHUTTLE,
    "school": ServiceVariant.LOCAL,  # School trips are functionally local
}


def _classify_bus_variant(
    bus_service_type: str | None,
    headsign: str | None,
) -> ServiceVariant:
    """Bus-mode classifier.

    Prefers the structured ``bus_service_type`` field when available;
    falls back to scanning the headsign for ``LIMITED`` / ``LTD`` /
    ``SUPER EXPRESS`` keywords.
    """
    if bus_service_type:
        key = bus_service_type.strip().lower()
        if key in _BUS_TYPE_TO_VARIANT:
            base = _BUS_TYPE_TO_VARIANT[key]
        else:
            base = ServiceVariant.UNKNOWN
    else:
        base = ServiceVariant.LOCAL

    # Headsign overrides:  a Local route that has a "LIMITED" headsign
    # for this particular trip is actually running limited service.
    if headsign:
        upper = headsign.upper()
        if "SUPER EXPRESS" in upper:
            return ServiceVariant.SUPER_EXPRESS
        if base == ServiceVariant.LOCAL and (
            upper.startswith(("LIMITED ", "LTD ")) or " LIMITED " in upper
        ):
            return ServiceVariant.LIMITED

    return base


def _classify_subway_variant(route_id: str | None) -> ServiceVariant:
    """Subway-mode classifier — uses the route_id only."""
    name = _normalise_subway_route(route_id)
    if not name:
        return ServiceVariant.UNKNOWN
    if name in _SUBWAY_SHUTTLES:
        return ServiceVariant.SHUTTLE
    if name in _SUBWAY_EXPRESS_VARIANTS:
        return ServiceVariant.EXPRESS
    return ServiceVariant.LOCAL


def classify_variant(arrival: "NearbyTransitArrival") -> ServiceVariant:
    """Classify a single arrival into its service variant.

    Args:
        arrival: A populated :class:`NearbyTransitArrival`.  The
            ``mode``, ``route_id``, ``bus_service_type`` and
            ``destination`` fields are inspected.

    Returns:
        The :class:`ServiceVariant` for this arrival.  Never raises.
    """
    mode = (arrival.mode or "").strip().lower()
    if mode == "subway":
        return _classify_subway_variant(arrival.route_id)
    if mode == "bus":
        return _classify_bus_variant(arrival.bus_service_type, arrival.destination)
    if mode in {"lirr", "mnr"}:
        # Commuter rail has no local/express distinction at the arrival
        # level — the Peak/Off-Peak signal is captured separately.
        return ServiceVariant.LOCAL
    return ServiceVariant.UNKNOWN


def derive_display_label(
    variant: ServiceVariant,
    arrival: "NearbyTransitArrival",
) -> str | None:
    """Return an optional override string for the variant pill.

    Most variants render fine using the enum's default display text on
    the client.  This hook lets the backend supply a richer label for
    edge cases the enum can't capture — e.g. an Express bus operating
    a "SUPER EXPRESS" trip where the headsign carries useful context
    ("Super Express via Madison Av").

    Returns ``None`` when the default enum label is sufficient.
    """
    headsign = (arrival.destination or "").strip()
    if not headsign:
        return None

    upper = headsign.upper()
    if variant == ServiceVariant.SUPER_EXPRESS and "VIA" in upper:
        # Surface the "via X" suffix for super-express buses so the
        # rider knows which corridor the trip uses.
        idx = upper.find("VIA")
        suffix = headsign[idx:].strip()
        if suffix:
            return f"Super Express {suffix}"
    return None


__all__ = [
    "ServiceVariant",
    "classify_variant",
    "derive_display_label",
]
