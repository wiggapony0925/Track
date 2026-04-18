"""
Canonical brand-color and planner-default loader.

Every transit color and planner constant lives in ``config/brand_colors.json``
and ``config/planner_defaults.json`` at the repo root.  This module loads them
once at import time so the rest of the backend never has to hardcode hex values
or duplicate planner defaults.

Usage::

    from app.utils.brand import SUBWAY_COLORS, BUS_COLORS, PLANNER_DEFAULTS
    color = SUBWAY_COLORS.get("A", MODE_DEFAULTS["subway"])
    bus_color = BUS_COLORS.get("limited", BUS_COLORS["_default"])
"""

from __future__ import annotations

import json
import logging
import os
import ssl
import time
import urllib.request
from pathlib import Path
from typing import Any

from app.config import get_settings

_log = logging.getLogger("track.brand")

_MTA_COLORS_API = get_settings().urls.mta_colors_api
_SYNC_STALE_SECONDS = 7 * 24 * 3600  # refresh if JSON is older than 7 days


def _config_candidates() -> list[Path]:
    """Return config directories in priority order.

    Supports both the full monorepo layout (repo-root ``config/``) and the
    standalone backend Docker layout where only ``TrackBackend/`` is copied
    into the image.
    """
    explicit = os.environ.get("TRACK_CONFIG_DIR", "").strip()
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit))

    here = Path(__file__).resolve()
    candidates.extend(
        [
            here.parents[3] / "config",  # repo root: Track/config
            here.parents[2] / "config",  # standalone backend: TrackBackend/config
            Path.cwd() / "config",
        ]
    )

    unique: list[Path] = []
    seen: set[Path] = set()
    for candidate in candidates:
        if candidate not in seen:
            unique.append(candidate)
            seen.add(candidate)
    return unique


def _resolve_config_path(filename: str) -> Path | None:
    for config_dir in _config_candidates():
        candidate = config_dir / filename
        if candidate.exists():
            return candidate
    return None


def _try_sync_from_api(colors_path: Path) -> None:
    """Best-effort: fetch latest MTA colors and overwrite the JSON file.

    Only runs if the file is older than ``_SYNC_STALE_SECONDS`` (7 days)
    or missing.  Failures are silently logged — the existing JSON is the
    fallback, so the app always starts.
    """
    try:
        if colors_path.exists():
            age = time.time() - colors_path.stat().st_mtime
            if age < _SYNC_STALE_SECONDS:
                return  # fresh enough
        # Import the sync script and run the build logic
        import importlib.util
        sync_script = Path(__file__).resolve().parents[3] / "scripts" / "sync_mta_colors.py"
        if not sync_script.exists():
            return
        spec = importlib.util.spec_from_file_location("sync_mta_colors", sync_script)
        if spec is None or spec.loader is None:
            return
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        existing = json.loads(colors_path.read_text()) if colors_path.exists() else {}
        rows = mod.fetch_mta_colors()
        if not rows:
            _log.debug("🎨 MTA color sync skipped: API returned 0 rows")
            return
        brand = mod.build_brand_colors(rows, existing)
        # Sanity-check: never overwrite a good file with fewer subway entries
        new_subway = brand.get("subway", {})
        old_subway = existing.get("subway", {})
        if len(new_subway) < len(old_subway) and len(old_subway) > 0:
            _log.warning(
                "🎨 MTA color sync produced fewer subway entries (%d vs %d); keeping existing file",
                len(new_subway),
                len(old_subway),
            )
            return
        colors_path.parent.mkdir(parents=True, exist_ok=True)
        colors_path.write_text(json.dumps(brand, indent=2, ensure_ascii=False) + "\n")
        _log.info("🎨 MTA brand colors synced from API (%d entries)", len(rows))
    except Exception as exc:
        _log.debug("🎨 MTA color sync skipped: %s", exc)


# ── colours ──────────────────────────────────────────────────────────

_colors_path = _resolve_config_path("brand_colors.json")

# Best-effort auto-sync from MTA Open Data API
if _colors_path is not None:
    _try_sync_from_api(_colors_path)
    _colors: dict[str, Any] = json.loads(_colors_path.read_text())
else:
    _log.info(
        "🎨 brand_colors.json not found in %s; using built-in brand fallbacks",
        ", ".join(str(path) for path in _config_candidates()),
    )
    _colors = {}

_FALLBACK_SUBWAY_COLORS: dict[str, str] = {
    "1": "#D82233",
    "2": "#D82233",
    "3": "#D82233",
    "4": "#009952",
    "5": "#009952",
    "5X": "#009952",
    "6": "#009952",
    "6X": "#009952",
    "7": "#9A38A1",
    "7X": "#9A38A1",
    "A": "#0062CF",
    "B": "#EB6800",
    "C": "#0062CF",
    "D": "#EB6800",
    "E": "#0062CF",
    "F": "#EB6800",
    "FS": "#7C858C",
    "FX": "#EB6800",
    "G": "#799534",
    "GS": "#7C858C",
    "H": "#7C858C",
    "J": "#8E5C33",
    "L": "#7C858C",
    "M": "#EB6800",
    "N": "#F6BC26",
    "Q": "#F6BC26",
    "R": "#F6BC26",
    "S": "#7C858C",
    "SI": "#08179C",
    "SIR": "#08179C",
    "SR": "#7C858C",
    "T": "#008EB7",
    "W": "#F6BC26",
    "Z": "#8E5C33",
}

_RAW_SUBWAY_COLORS: dict[str, str] = _colors.get("subway", {})
SUBWAY_COLORS: dict[str, str] = {
    **_FALLBACK_SUBWAY_COLORS,
    **_RAW_SUBWAY_COLORS,
}
SUBWAY_TEXT_COLORS: dict[str, str] = _colors.get("subway_text_color", {})
BUS_COLORS: dict[str, str] = _colors.get("bus", {})
LIRR_COLORS: dict[str, str] = _colors.get("commuter_rail", {}).get("lirr", {})
MNR_COLORS: dict[str, str] = _colors.get("commuter_rail", {}).get("mnr", {})
MODE_DEFAULTS: dict[str, str] = _colors.get("mode_defaults", {})

_missing_subway_color_keys = sorted(set(_FALLBACK_SUBWAY_COLORS) - set(_RAW_SUBWAY_COLORS))
if _colors_path is not None and _missing_subway_color_keys:
    _log.warning(
        "🎨 brand_colors.json missing %d subway color entries; using built-in fallback for: %s",
        len(_missing_subway_color_keys),
        ", ".join(_missing_subway_color_keys),
    )

# ── planner defaults ─────────────────────────────────────────────────

_defaults_path = _resolve_config_path("planner_defaults.json")
if _defaults_path is not None:
    PLANNER_DEFAULTS: dict[str, Any] = json.loads(_defaults_path.read_text())
else:
    PLANNER_DEFAULTS = {}

METRO_NORTH_BRANCHES: list[str] = PLANNER_DEFAULTS.get(
    "metro_north_branches", []
)

# ── convenience helpers ──────────────────────────────────────────────


def subway_color(route_id: str) -> str:
    """Return the brand hex for a subway route, e.g. ``'#D82233'``."""
    key = route_id.upper()
    return SUBWAY_COLORS.get(key, MODE_DEFAULTS.get("subway", "#0062CF"))


def bus_color(service_type: str | None = None) -> str:
    """Return the brand hex for a bus service type."""
    if service_type:
        key = service_type.lower().replace(" ", "_").replace("/", "_")
        # "Local / Limited" → "local___limited" — normalise
        key = key.replace("local___limited", "local_limited")
        return BUS_COLORS.get(key, BUS_COLORS.get("_default", "#0078C6"))
    return BUS_COLORS.get("_default", "#0078C6")


def lirr_color(branch: str | None = None) -> str:
    """Return LIRR branch color, falling back to the brand blue."""
    if branch:
        key = branch.lower().replace(" ", "_")
        return LIRR_COLORS.get(key, LIRR_COLORS.get("_brand", "#0073BF"))
    return LIRR_COLORS.get("_brand", "#0073BF")


def mnr_color(branch: str | None = None) -> str:
    """Return MNR branch color, falling back to the brand blue."""
    if branch:
        key = branch.lower().replace(" ", "_")
        return MNR_COLORS.get(key, MNR_COLORS.get("_brand", "#005A8C"))
    return MNR_COLORS.get("_brand", "#005A8C")


def mode_color(mode: str) -> str:
    """Return the default brand color for a transit mode string."""
    return MODE_DEFAULTS.get(mode, "#808183")


# ── text (contrast) colors ───────────────────────────────────────────

_MODE_NAMES: dict[str, str] = {
    "subway": "Subway",
    "bus": "Bus",
    "lirr": "LIRR",
    "mnr": "Metro-North",
    "walk": "Walk",
    "transfer": "Transfer",
}

# All bus brand colors are dark enough for white text.
_BUS_TEXT_DEFAULT = "#FFFFFF"
_WALK_TEXT = "#333333"


def subway_text_color(route_id: str) -> str:
    """Return the text color that contrasts with the subway route color."""
    default = SUBWAY_TEXT_COLORS.get("_default", "#FFFFFF")
    return SUBWAY_TEXT_COLORS.get(route_id.upper(), default)


def text_color_for_route(mode: str, route_id: str | None = None) -> str:
    """Return the accessible text color for any route/mode combination.

    White for most modes; black for N/Q/R/W subway lines (yellow bg).
    """
    if mode == "subway" and route_id:
        return subway_text_color(route_id)
    if mode in ("walk", "transfer"):
        return _WALK_TEXT
    return "#FFFFFF"


def mode_name(mode: str) -> str:
    """Return a human-readable label for a transit mode slug."""
    return _MODE_NAMES.get(mode, mode.title())
