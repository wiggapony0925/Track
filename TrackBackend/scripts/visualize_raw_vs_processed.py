#!/usr/bin/env python3
"""Visualize raw GTFS shapes vs corridor-pipeline processed shapes.

Shows side-by-side comparison of:
  LEFT:  Raw GTFS shapes.txt geometry (overlapping, single-line)
  RIGHT: Corridor-pipeline output (parallel offsets, junction fillets, trunk merge)

Focus area: Midtown Manhattan (Times Sq / Herald Sq / Columbus Circle)
where multiple trunk groups share corridor space.
"""

from __future__ import annotations

import csv
import math
import sys
from collections import defaultdict
from pathlib import Path

# Add the backend root to sys.path so we can import app modules
_BACKEND = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_BACKEND))

import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.collections import LineCollection

from app.utils.polyline_utils import decode_polyline

# ─── MTA trunk colour palette ───────────────────────────────────────────────
TRUNK_COLORS: dict[int, str] = {
    0: "#EE352E",   # Red (1/2/3)
    1: "#00933C",   # Green (4/5/6)
    2: "#B933AD",   # Purple (7)
    3: "#0039A6",   # Blue (A/C/E)
    4: "#FF6319",   # Orange (B/D/F/M)
    5: "#6CBE45",   # Lime (G)
    6: "#996633",   # Brown (J/Z)
    7: "#A7A9AC",   # Gray (L)
    8: "#FCCC0A",   # Yellow (N/Q/R/W)
    9: "#808183",   # Shuttle
    10: "#003DA5",  # SIR
    11: "#999999",  # Franklin
    12: "#999999",  # Rockaway
}

TRUNK_GROUPS: list[list[str]] = [
    ["1", "2", "3"],
    ["4", "5", "6", "6X"],
    ["7", "7X"],
    ["A", "C", "E"],
    ["B", "D", "F", "FX", "M"],
    ["G"],
    ["J", "Z"],
    ["L"],
    ["N", "Q", "R", "W"],
    ["GS"],
    ["SI"],
    ["FS"],
    ["H"],
]

ROUTE_TO_TRUNK: dict[str, int] = {}
for gi, group in enumerate(TRUNK_GROUPS):
    for rid in group:
        ROUTE_TO_TRUNK[rid] = gi


# ─── Bounding box: Midtown Manhattan (W 30th to W 60th, 5th to 10th Ave) ──
# This area has heavy corridor overlap: 1/2/3, A/C/E, B/D/F/M, N/Q/R/W, 7
BBOX_LAT = (40.747, 40.770)   # ~30th to ~60th St
BBOX_LON = (-73.997, -73.975)  # ~10th to ~5th Ave


def load_raw_shapes() -> dict[str, list[tuple[float, float]]]:
    """Load raw GTFS shapes.txt into shape_id -> [(lat, lon), ...]."""
    shapes_path = _BACKEND / "app" / "data" / "shapes.txt"
    raw: dict[str, list[tuple[int, float, float]]] = defaultdict(list)

    with open(shapes_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            sid = row.get("shape_id", "").strip()
            if not sid:
                continue
            try:
                lat = float(row["shape_pt_lat"])
                lon = float(row["shape_pt_lon"])
                seq = int(row["shape_pt_sequence"])
            except (ValueError, KeyError):
                continue
            raw[sid].append((seq, lat, lon))

    result: dict[str, list[tuple[float, float]]] = {}
    for sid, pts in raw.items():
        pts.sort(key=lambda p: p[0])
        result[sid] = [(lat, lon) for _, lat, lon in pts]
    return result


def load_trips() -> dict[str, set[str]]:
    """Load trips.txt to get route_id -> {shape_ids}."""
    trips_path = _BACKEND / "app" / "data" / "trips.txt"
    mapping: dict[str, set[str]] = defaultdict(set)
    with open(trips_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rid = row.get("route_id", "").strip()
            sid = row.get("shape_id", "").strip()
            if rid and sid:
                mapping[rid].add(sid)
    return dict(mapping)


def clip_to_bbox(
    coords: list[tuple[float, float]],
) -> list[list[tuple[float, float]]]:
    """Clip a polyline to the bounding box, returning segments that are inside."""
    segments: list[list[tuple[float, float]]] = []
    current: list[tuple[float, float]] = []

    for lat, lon in coords:
        inside = (BBOX_LAT[0] <= lat <= BBOX_LAT[1] and
                  BBOX_LON[0] <= lon <= BBOX_LON[1])
        if inside:
            current.append((lon, lat))  # matplotlib uses (x=lon, y=lat)
        else:
            if len(current) >= 2:
                segments.append(current)
            current = []

    if len(current) >= 2:
        segments.append(current)

    return segments


def plot_raw_shapes(ax, shapes, trips):
    """Plot raw GTFS shapes coloured by trunk group."""
    ax.set_title("Raw GTFS shapes.txt", fontsize=14, fontweight="bold", pad=10)
    ax.set_facecolor("#f5f5f5")

    route_ids = set()
    for rid in ROUTE_TO_TRUNK:
        if rid in trips:
            route_ids.add(rid)

    plotted_shapes: set[str] = set()
    for rid in sorted(route_ids):
        trunk = ROUTE_TO_TRUNK[rid]
        color = TRUNK_COLORS.get(trunk, "#999999")
        for sid in trips.get(rid, set()):
            if sid in plotted_shapes:
                continue
            plotted_shapes.add(sid)
            coords = shapes.get(sid)
            if not coords:
                continue
            for seg in clip_to_bbox(coords):
                xs = [p[0] for p in seg]
                ys = [p[1] for p in seg]
                ax.plot(xs, ys, color=color, linewidth=2.0, alpha=0.7, solid_capstyle="round")


def plot_processed_shapes(ax):
    """Plot corridor-pipeline processed shapes (trunk polylines with offsets)."""
    ax.set_title("Corridor Pipeline Output", fontsize=14, fontweight="bold", pad=10)
    ax.set_facecolor("#f5f5f5")

    # Import and run the pipeline
    from app.services.mapping.corridor_pipeline import get_trunk_polylines

    trunks = get_trunk_polylines()

    for trunk_data in trunks:
        trunk_idx = trunk_data["trunk_index"]
        color = TRUNK_COLORS.get(trunk_idx, "#999999")
        polylines = trunk_data.get("polylines", [])
        lane_offset = trunk_data.get("lane_offset", 0.0)

        for encoded in polylines:
            coords = decode_polyline(encoded)  # [(lat, lon), ...]
            for seg in clip_to_bbox(coords):
                xs = [p[0] for p in seg]
                ys = [p[1] for p in seg]
                ax.plot(xs, ys, color=color, linewidth=2.0, alpha=0.85,
                        solid_capstyle="round")


def add_legend(fig):
    """Add a trunk-group colour legend."""
    trunk_labels = [
        "1/2/3", "4/5/6", "7", "A/C/E", "B/D/F/M",
        "G", "J/Z", "L", "N/Q/R/W", "Shuttle", "SIR"
    ]
    patches = []
    for i, label in enumerate(trunk_labels):
        if i in TRUNK_COLORS:
            patches.append(mpatches.Patch(
                color=TRUNK_COLORS[i], label=label, alpha=0.85
            ))
    fig.legend(
        handles=patches, loc="lower center", ncol=6,
        fontsize=9, frameon=True, fancybox=True,
        bbox_to_anchor=(0.5, 0.01)
    )


def main():
    print("Loading raw GTFS shapes...")
    shapes = load_raw_shapes()
    trips = load_trips()
    print(f"  {len(shapes)} shapes, {len(trips)} routes")

    print("Running corridor pipeline (this may take a moment)...")

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(18, 12))

    # LEFT: raw shapes
    plot_raw_shapes(ax1, shapes, trips)

    # RIGHT: processed shapes
    plot_processed_shapes(ax2)

    # Sync axes
    for ax in (ax1, ax2):
        ax.set_xlim(BBOX_LON[0], BBOX_LON[1])
        ax.set_ylim(BBOX_LAT[0], BBOX_LAT[1])
        ax.set_aspect("equal")
        ax.tick_params(labelsize=7)
        ax.grid(True, alpha=0.2, linewidth=0.5)

    # Annotations
    annotations = [
        (-73.9857, 40.7580, "Times Sq"),
        (-73.9876, 40.7505, "Herald Sq"),
        (-73.9819, 40.7681, "Columbus\nCircle"),
        (-73.9777, 40.7527, "Grand\nCentral"),
        (-73.9934, 40.7503, "Penn\nStation"),
    ]
    for ax in (ax1, ax2):
        for x, y, label in annotations:
            ax.annotate(
                label, xy=(x, y), fontsize=7, fontweight="bold",
                ha="center", va="bottom",
                bbox=dict(boxstyle="round,pad=0.2", fc="white", ec="gray", alpha=0.8),
            )

    fig.suptitle(
        "Track Subway Map: Raw GTFS vs Corridor Pipeline",
        fontsize=16, fontweight="bold", y=0.97
    )

    add_legend(fig)
    plt.tight_layout(rect=[0, 0.05, 1, 0.95])

    out_path = _BACKEND / "scripts" / "raw_vs_processed.png"
    fig.savefig(out_path, dpi=200, bbox_inches="tight")
    print(f"\n✅  Saved to {out_path}")
    plt.show()


if __name__ == "__main__":
    main()
