"""
Transit Utilities
Algorithms for mapping route IDs to colors, feed groups, and display properties.

All brand-color lookups delegate to ``app.utils.brand`` which reads from the
single source of truth at ``config/brand_colors.json``.
"""

from __future__ import annotations

from app.utils.brand import (
    SUBWAY_COLORS,
    LIRR_COLORS,
    MNR_COLORS,
    MODE_DEFAULTS,
    subway_color,
    lirr_color,
    mnr_color,
    mode_color,
)

_DEFAULT_ROUTE_COLOR = MODE_DEFAULTS.get("walk", "#808183")
_SHUTTLE_COLOR = SUBWAY_COLORS.get("S", "#7C858C")

# ── LIRR / MNR display-name → brand key mapping ─────────────────────

_LIRR_BRANCH_NAMES: dict[str, str] = {
    "Babylon Branch": "babylon",
    "Belmont Park Branch": "belmont_park",
    "City Terminal Zone": "city_terminal_zone",
    "Far Rockaway Branch": "far_rockaway",
    "Hempstead Branch": "hempstead",
    "Long Beach Branch": "long_beach",
    "Montauk Branch": "montauk",
    "Oyster Bay Branch": "oyster_bay",
    "Port Jefferson Branch": "port_jefferson",
    "Port Washington Branch": "port_washington",
    "Ronkonkoma Branch": "ronkonkoma",
    "West Hempstead Branch": "west_hempstead",
    "Greenport Branch": "greenport",
}

_MNR_BRANCH_NAMES: dict[str, str] = {
    "Harlem Line": "harlem",
    "Hudson Line": "hudson",
    "New Haven Line": "new_haven",
    "Pascack Valley Line": "pascack_valley",
    "Port Jervis Line": "port_jervis",
}

# GTFS numeric route_id → brand-key mapping
_LIRR_ID_TO_BRANCH: dict[str, str] = {
    "1": "babylon",
    "2": "hempstead",
    "3": "oyster_bay",
    "4": "ronkonkoma",
    "5": "montauk",
    "6": "long_beach",
    "7": "far_rockaway",
    "8": "west_hempstead",
    "9": "port_washington",
    "10": "port_jefferson",
    "11": "belmont_park",
    "12": "city_terminal_zone",
    "13": "greenport",
}

_MNR_ID_TO_BRANCH: dict[str, str] = {
    "1": "hudson",
    "2": "harlem",
    "3": "new_haven",
    "4": "new_haven",  # New Canaan
    "5": "new_haven",  # Danbury
    "6": "new_haven",  # Waterbury
}


def clean_route_id(line_id: str) -> str:
    """Standardize a route ID by removing brackets, whitespace, and converting to uppercase."""
    if not line_id:
        return ""
    return line_id.strip().upper().replace("<", "").replace(">", "")


def resolve_subway_feed_key(line_id: str) -> str | None:
    """Algorithmically map a subway Line ID to its corresponding URL key in settings.json."""
    line_id = clean_route_id(line_id)
    if not line_id:
        return None

    # 1. Numbered Lines (1, 2, 3, 4, 5, 6, 7) + 42nd St Shuttle (GS)
    # all live in the primary 'gtfs' feed.
    if line_id[0].isdigit() or line_id == "GS":
        return "subway_123456"

    # 2. Map lettered lines and shuttles to their respective feeds
    feed_groups = {
        "subway_ace": {"A", "C", "E", "SR", "H"},  # Eighth Ave + Rockaway
        "subway_bdfm": {"B", "D", "F", "FX", "M", "FS"},  # Sixth Ave + Franklin
        "subway_nqrw": {"N", "Q", "R", "W"},  # Broadway
        "subway_jz": {"J", "Z"},  # Nassau St
        "subway_l": {"L"},  # Canarsie
        "subway_g": {"G"},  # Crosstown
        "subway_si": {"SI"},  # Staten Island
    }

    for key, members in feed_groups.items():
        if line_id in members:
            return key

    return None


def get_subway_color(line_id: str) -> str:
    """Return the official MTA hex color for a subway line, LIRR branch, or MNR line.

    All colors are sourced from ``config/brand_colors.json`` via
    :mod:`app.utils.brand`.
    """
    if not line_id:
        return _DEFAULT_ROUTE_COLOR

    # 0. Check full display-name rail branches FIRST (before clean strips spaces)
    if line_id in _LIRR_BRANCH_NAMES:
        return lirr_color(_LIRR_BRANCH_NAMES[line_id])
    if line_id in _MNR_BRANCH_NAMES:
        return mnr_color(_MNR_BRANCH_NAMES[line_id])
    if line_id == "Staten Island Railway":
        return SUBWAY_COLORS.get("SI", "#008EB7")

    line_id = clean_route_id(line_id)
    if not line_id:
        return _DEFAULT_ROUTE_COLOR

    # 1. Direct subway lookup (covers all numbered, lettered, shuttles, SIR)
    if line_id in SUBWAY_COLORS:
        return SUBWAY_COLORS[line_id]

    # 2. Prefixed rail IDs (LIRR_1, MNR_1 …)
    if line_id.startswith("LIRR_"):
        branch = _LIRR_ID_TO_BRANCH.get(line_id[5:])
        return lirr_color(branch)
    if line_id.startswith("MNR_"):
        branch = _MNR_ID_TO_BRANCH.get(line_id[4:])
        return mnr_color(branch)

    # 3. High numeric IDs (≥ 10) are LIRR branches
    if line_id.isdigit():
        lid = int(line_id)
        if lid >= 10 and str(lid) in _LIRR_ID_TO_BRANCH:
            return lirr_color(_LIRR_ID_TO_BRANCH[str(lid)])

    # 4. Generic rail / airtrain fallback
    if any(k in line_id for k in ("LIRR", "MNR", "METRO-NORTH", "PATH", "AIRTRAIN")):
        return lirr_color()  # brand blue

    return _SHUTTLE_COLOR  # Fallback for unknown routes


def get_all_subway_lines() -> list[str]:
    """Returns a clean list of all official subway lines for the system map."""
    return [
        "1",
        "2",
        "3",
        "4",
        "5",
        "6",
        "6X",
        "7",
        "7X",
        "A",
        "C",
        "E",
        "B",
        "D",
        "F",
        "FX",
        "M",
        "G",
        "J",
        "Z",
        "L",
        "N",
        "Q",
        "R",
        "W",
        "GS",
        "FS",
        "SR",
        "SI",
    ]
