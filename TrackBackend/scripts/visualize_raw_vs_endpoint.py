#!/usr/bin/env python3
"""Visualize raw GTFS vs what the API endpoints actually serve to iOS.

3-panel comparison:
  LEFT:   Raw GTFS shapes.txt (what MTA publishes)
  CENTER: Per-route overlays from /subway/shapes/all  → lines[] (densified + simplified)
  RIGHT:  Trunk polylines from /subway/shapes/all → trunk_polylines[] (merged + offset)

This runs the *exact* same build function the endpoint uses, so the output
matches production 1:1.
"""

from __future__ import annotations

import csv
import sys
from collections import defaultdict
from pathlib import Path

_BACKEND = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_BACKEND))

import matplotlib.pyplot as plt
import matplotlib.patches as mpatches

from app.utils.polyline_utils import decode_polyline, encode_polyline

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

# Route-level colours (for per-route panel)
ROUTE_COLOR: dict[str, str] = {}
for gi, group in enumerate(TRUNK_GROUPS):
    for rid in group:
        ROUTE_COLOR[rid] = TRUNK_COLORS.get(gi, "#999")


# ─── Bounding box: Midtown Manhattan ────────────────────────────────────────
BBOX_LAT = (40.747, 40.770)
BBOX_LON = (-73.997, -73.975)

LANDMARKS = [
    (-73.9857, 40.7580, "Times Sq"),
    (-73.9876, 40.7505, "Herald Sq"),
    (-73.9819, 40.7681, "Columbus\nCircle"),
    (-73.9777, 40.7527, "Grand\nCentral"),
    (-73.9934, 40.7503, "Penn\nStation"),
]


def clip_to_bbox(coords: list[tuple[float, float]]) -> list[list[tuple[float, float]]]:
    """Clip a polyline to the bounding box, returning (lon, lat) segments."""
    segments: list[list[tuple[float, float]]] = []
    current: list[tuple[float, float]] = []
    for lat, lon in coords:
        if BBOX_LAT[0] <= lat <= BBOX_LAT[1] and BBOX_LON[0] <= lon <= BBOX_LON[1]:
            current.append((lon, lat))
        else:
            if len(current) >= 2:
                segments.append(current)
            current = []
    if len(current) >= 2:
        segments.append(current)
    return segments


def style_ax(ax, title):
    ax.set_title(title, fontsize=11, fontweight="bold", pad=8)
    ax.set_facecolor("#f5f5f5")
    ax.set_xlim(BBOX_LON[0], BBOX_LON[1])
    ax.set_ylim(BBOX_LAT[0], BBOX_LAT[1])
    ax.set_aspect("equal")
    ax.tick_params(labelsize=6)
    ax.grid(True, alpha=0.15, linewidth=0.4)
    for x, y, label in LANDMARKS:
        ax.annotate(
            label, xy=(x, y), fontsize=6, fontweight="bold", ha="center", va="bottom",
            bbox=dict(boxstyle="round,pad=0.2", fc="white", ec="gray", alpha=0.8),
        )


def load_raw_shapes() -> dict[str, list[tuple[float, float]]]:
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


# ─── Panel 1: Raw GTFS shapes ───────────────────────────────────────────────

def plot_raw(ax, shapes, trips):
    style_ax(ax, "① Raw GTFS shapes.txt")
    plotted: set[str] = set()
    for rid in sorted(ROUTE_TO_TRUNK):
        color = ROUTE_COLOR.get(rid, "#999")
        for sid in trips.get(rid, set()):
            if sid in plotted:
                continue
            plotted.add(sid)
            coords = shapes.get(sid)
            if not coords:
                continue
            for seg in clip_to_bbox(coords):
                xs, ys = zip(*seg)
                ax.plot(xs, ys, color=color, linewidth=2.0, alpha=0.7, solid_capstyle="round")
    # count lines through bbox
    n = sum(1 for rid in ROUTE_TO_TRUNK for sid in trips.get(rid, set())
            if shapes.get(sid) and clip_to_bbox(shapes[sid]))
    ax.text(0.02, 0.02, f"{n} shape segments", transform=ax.transAxes,
            fontsize=7, color="gray", va="bottom")


# ─── Panels 2 & 3: Build via the real endpoint function ─────────────────────

def build_api_response():
    """Run the exact same _build_shapes_all_sync that the /subway/shapes/all endpoint uses."""
    print("  Building corridor pipeline (same as /subway/shapes/all)...")
    from app.routers.subway import _build_shapes_all_sync
    resp = _build_shapes_all_sync()
    return resp


def plot_per_route(ax, resp):
    """Panel 2: per-route overlays (resp.lines) — what the client gets before trunk merge."""
    style_ax(ax, "② Per-Route Overlays\n(lines[] from endpoint)")
    n_segs = 0
    for overlay in resp.lines:
        color = overlay.color_hex
        for enc in overlay.polylines:
            coords = decode_polyline(enc)
            for seg in clip_to_bbox(coords):
                xs, ys = zip(*seg)
                ax.plot(xs, ys, color=color, linewidth=2.0, alpha=0.7, solid_capstyle="round")
                n_segs += 1
    ax.text(0.02, 0.02, f"{n_segs} polyline segments", transform=ax.transAxes,
            fontsize=7, color="gray", va="bottom")


def plot_trunk(ax, resp):
    """Panel 3: trunk polylines (resp.trunk_polylines) — merged + offset."""
    style_ax(ax, "③ Trunk Polylines\n(trunk_polylines[] from endpoint)")
    n_segs = 0
    for tp in resp.trunk_polylines:
        color = tp.color_hex
        for enc in tp.polylines:
            coords = decode_polyline(enc)
            for seg in clip_to_bbox(coords):
                xs, ys = zip(*seg)
                ax.plot(xs, ys, color=color, linewidth=2.5, alpha=0.85, solid_capstyle="round")
                n_segs += 1
    ax.text(0.02, 0.02, f"{n_segs} trunk segments", transform=ax.transAxes,
            fontsize=7, color="gray", va="bottom")


def add_legend(fig):
    labels = ["1/2/3", "4/5/6", "7", "A/C/E", "B/D/F/M", "G", "J/Z", "L", "N/Q/R/W"]
    patches = [mpatches.Patch(color=TRUNK_COLORS[i], label=l, alpha=0.85)
               for i, l in enumerate(labels)]
    fig.legend(handles=patches, loc="lower center", ncol=len(patches),
               fontsize=8, frameon=True, fancybox=True, bbox_to_anchor=(0.5, 0.01))


def main():
    print("Loading raw GTFS shapes...")
    shapes = load_raw_shapes()
    trips = load_trips()
    print(f"  {len(shapes)} shapes, {len(trips)} routes")

    resp = build_api_response()
    print(f"  {len(resp.lines)} per-route overlays, {len(resp.trunk_polylines)} trunk groups")

    fig, (ax1, ax2, ax3) = plt.subplots(1, 3, figsize=(24, 10))

    plot_raw(ax1, shapes, trips)
    plot_per_route(ax2, resp)
    plot_trunk(ax3, resp)

    fig.suptitle(
        "Track: Raw GTFS → Per-Route Endpoint → Trunk Polylines  (Midtown crop)",
        fontsize=15, fontweight="bold", y=0.97,
    )
    add_legend(fig)
    plt.tight_layout(rect=[0, 0.05, 1, 0.94])

    out = _BACKEND / "scripts" / "raw_vs_endpoint.png"
    fig.savefig(out, dpi=200, bbox_inches="tight")
    print(f"\n✅  Saved to {out}")
    plt.show()


if __name__ == "__main__":
    main()
