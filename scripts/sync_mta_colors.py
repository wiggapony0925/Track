#!/usr/bin/env python3
"""
Sync MTA brand colors from the official NY Open Data API.

Dataset: "MTA Colors" — https://data.ny.gov/d/3uhz-sej2
API:     https://data.ny.gov/resource/3uhz-sej2.json

This script fetches the latest hex colors published by the MTA and
regenerates ``config/brand_colors.json``.  Sections that are NOT covered
by the API (bus service-type colors, mode_defaults) are preserved from
the existing file.

Run periodically (CI, deploy hook, or manually) so that if the MTA
updates a color you never have to touch code.

Usage:
    python scripts/sync_mta_colors.py          # fetch from API
    python scripts/sync_mta_colors.py --dry-run # preview without writing
    python scripts/sync_mta_colors.py --diff    # show what changed
"""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.request
from pathlib import Path

MTA_COLORS_API = "https://data.ny.gov/resource/3uhz-sej2.json?$limit=200"

REPO_ROOT = Path(__file__).resolve().parents[1]
BRAND_COLORS_PATH = REPO_ROOT / "config" / "brand_colors.json"

# ── Subway group expansion ──────────────────────────────────────────
# The API returns grouped services like "A,C,E" — expand to per-line.
# Express variants (5X, 6X, 7X, FX) inherit the parent color.

_SUBWAY_EXPRESS_VARIANTS: dict[str, list[str]] = {
    "5": ["5X"],
    "6": ["6X"],
    "7": ["7X"],
    "F": ["FX"],
}

# Shuttles that share the S color
_SHUTTLE_ALIASES = ["GS", "FS", "SR", "H"]


def _expand_subway(service: str, hex_color: str) -> dict[str, str]:
    """Expand a grouped subway service string into per-line entries."""
    out: dict[str, str] = {}
    lines = [s.strip() for s in service.split(",")]
    for line in lines:
        out[line] = hex_color
        # Add express variants
        for extra in _SUBWAY_EXPRESS_VARIANTS.get(line, []):
            out[extra] = hex_color
    return out


def _branch_key(service_name: str) -> str:
    """Convert 'Hempstead Branch' → 'hempstead', 'New Haven Line' → 'new_haven'."""
    name = service_name.lower()
    for suffix in (" branch", " line"):
        name = name.replace(suffix, "")
    return name.strip().replace(" ", "_")


def fetch_mta_colors() -> list[dict[str, str]]:
    """Fetch the MTA Colors dataset from the Socrata API."""
    # macOS Python may lack system certs; try certifi, then fallback
    ctx: ssl.SSLContext | None = None
    try:
        import certifi
        ctx = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        ctx = ssl.create_default_context()
        ctx.load_default_certs()

    req = urllib.request.Request(
        MTA_COLORS_API,
        headers={"Accept": "application/json", "User-Agent": "Track/sync_mta_colors"},
    )
    with urllib.request.urlopen(req, timeout=15, context=ctx) as resp:
        return json.loads(resp.read().decode())


def build_brand_colors(rows: list[dict[str, str]], existing: dict) -> dict:
    """Build the brand_colors.json structure from API rows + existing manual sections."""

    subway: dict[str, str] = {}
    lirr: dict[str, str] = {}
    mnr: dict[str, str] = {}
    sir_color: str | None = None

    for row in rows:
        operator = row.get("operator", "")
        service = row.get("service", "")
        hex_color = row.get("hex_color", "")
        if not hex_color:
            continue

        if operator == "New York City Subway":
            if service == "T":
                # Second Avenue Subway — future line, store separately
                subway["T"] = hex_color
                continue
            expanded = _expand_subway(service, hex_color)
            subway.update(expanded)

        elif operator == "Staten Island Railway":
            sir_color = hex_color
            subway["SI"] = hex_color
            subway["SIR"] = hex_color

        elif operator == "Long Island Rail Road":
            key = _branch_key(service)
            lirr[key] = hex_color

        elif operator == "Metro-North Railroad":
            key = _branch_key(service)
            mnr[key] = hex_color
            # Sub-branches of New Haven share the same color
            if key == "new_haven":
                for sub in ("new_canaan", "danbury", "waterbury"):
                    mnr[sub] = hex_color

    # Add shuttle aliases (all share "S" color)
    if "S" in subway:
        for alias in _SHUTTLE_ALIASES:
            subway[alias] = subway["S"]

    # Add LIRR _brand default (use MTA ISA blue from the API, or fallback)
    lirr_brand = existing.get("commuter_rail", {}).get("lirr", {}).get("_brand")
    if not lirr_brand:
        # Use the most common LIRR color or a sensible default
        lirr_brand = "#0073BF"
    lirr["_brand"] = lirr_brand

    # Also add greenport = ronkonkoma if not in API
    if "greenport" not in lirr and "ronkonkoma" in lirr:
        lirr["greenport"] = lirr["ronkonkoma"]

    # Add MNR _brand default
    mnr_brand = existing.get("commuter_rail", {}).get("mnr", {}).get("_brand")
    if not mnr_brand:
        mnr_brand = "#005A8C"
    mnr["_brand"] = mnr_brand

    # Preserve manual sections from existing file
    bus = existing.get("bus", {
        "local": "#0078C6",
        "limited": "#6E3FA3",
        "local_limited": "#6E3FA3",
        "select_bus_service": "#00B2E3",
        "express": "#3D9B35",
        "school": "#F7931E",
        "_default": "#0078C6",
    })

    subway_text_color = existing.get("subway_text_color", {
        "_default": "#FFFFFF",
        "N": "#000000",
        "Q": "#000000",
        "R": "#000000",
        "W": "#000000",
    })

    mode_defaults = existing.get("mode_defaults", {
        "subway": "#0062CF",
        "bus": "#0078C6",
        "lirr": "#0073BF",
        "mnr": "#005A8C",
        "walk": "#808183",
        "transfer": "#808183",
    })

    # Sort subway keys: numbers first, then letters
    def subway_sort_key(k: str) -> tuple[int, str]:
        if k[0].isdigit():
            return (0, k)
        return (1, k)

    sorted_subway = dict(sorted(subway.items(), key=lambda kv: subway_sort_key(kv[0])))

    return {
        "_version": "1.0.0",
        "_description": (
            "Single source of truth for MTA brand colors. "
            "Subway/LIRR/MNR colors auto-synced from "
            "https://data.ny.gov/resource/3uhz-sej2.json — "
            "run scripts/sync_mta_colors.py to refresh. "
            "Bus and mode_defaults are manually maintained."
        ),
        "_synced_from": MTA_COLORS_API.split("?")[0],
        "subway": sorted_subway,
        "subway_text_color": subway_text_color,
        "bus": bus,
        "commuter_rail": {
            "lirr": dict(sorted(lirr.items())),
            "mnr": dict(sorted(mnr.items())),
        },
        "mode_defaults": mode_defaults,
    }


def diff_json(old: dict, new: dict, prefix: str = "") -> list[str]:
    """Return human-readable lines showing what changed."""
    changes: list[str] = []
    all_keys = sorted(set(list(old.keys()) + list(new.keys())))
    for key in all_keys:
        full_key = f"{prefix}.{key}" if prefix else key
        if key.startswith("_"):
            continue
        old_val = old.get(key)
        new_val = new.get(key)
        if old_val == new_val:
            continue
        if isinstance(old_val, dict) and isinstance(new_val, dict):
            changes.extend(diff_json(old_val, new_val, full_key))
        elif old_val is None:
            changes.append(f"  + {full_key}: {new_val}")
        elif new_val is None:
            changes.append(f"  - {full_key}: {old_val}")
        else:
            changes.append(f"  ~ {full_key}: {old_val} → {new_val}")
    return changes


def main() -> None:
    parser = argparse.ArgumentParser(description="Sync MTA brand colors from Open Data API")
    parser.add_argument("--dry-run", action="store_true", help="Print result without writing")
    parser.add_argument("--diff", action="store_true", help="Show what changed vs existing file")
    args = parser.parse_args()

    # Load existing file (to preserve manual sections)
    existing: dict = {}
    if BRAND_COLORS_PATH.exists():
        existing = json.loads(BRAND_COLORS_PATH.read_text())

    print(f"⬇ Fetching MTA Colors from {MTA_COLORS_API.split('?')[0]} …")
    try:
        rows = fetch_mta_colors()
    except Exception as exc:
        print(f"  ⚠ API fetch failed: {exc}")
        if existing:
            print("  → Keeping existing brand_colors.json as fallback (no changes).")
        else:
            print("  → No existing file to fall back to. Exiting.")
        sys.exit(1)
    print(f"  Got {len(rows)} color entries")

    brand = build_brand_colors(rows, existing)

    subway_count = len([k for k in brand["subway"] if not k.startswith("_")])
    lirr_count = len([k for k in brand["commuter_rail"]["lirr"] if not k.startswith("_")])
    mnr_count = len([k for k in brand["commuter_rail"]["mnr"] if not k.startswith("_")])
    print(f"  Subway: {subway_count} lines, LIRR: {lirr_count} branches, MNR: {mnr_count} lines")

    if args.diff or args.dry_run:
        changes = diff_json(existing, brand)
        if changes:
            print("\nChanges detected:")
            for line in changes:
                print(line)
        else:
            print("\n✓ No changes — colors are up to date.")

    if args.dry_run:
        print("\n(dry-run — not writing file)")
        return

    BRAND_COLORS_PATH.parent.mkdir(parents=True, exist_ok=True)
    BRAND_COLORS_PATH.write_text(
        json.dumps(brand, indent=2, ensure_ascii=False) + "\n"
    )
    print(f"\n✓ Wrote {BRAND_COLORS_PATH.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
