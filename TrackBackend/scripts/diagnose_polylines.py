#!/usr/bin/env python3
"""Comprehensive diagnostic: what the user actually sees on the system map.

Generates a multi-panel figure:
  Panel 1 — Full NYC system map with ALL trunk polylines (color-coded)
  Panel 2 — Gap analysis: red dots where consecutive polyline endpoints don't connect
  Panel 3 — Fragmentation heatmap: short segments, isolated stubs
  Panel 4 — Station connectivity: stations overlaid, unserved stations highlighted

Plus a detailed text report of every gap, short segment, and issue.
"""

from __future__ import annotations

import csv
import math
import sys
from collections import defaultdict
from pathlib import Path

_BACKEND = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_BACKEND))

import matplotlib
matplotlib.use("Agg")  # Non-interactive — save only, no GUI
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.collections import LineCollection
import numpy as np

from app.utils.polyline_utils import decode_polyline

# ── MTA colour palette ──────────────────────────────────────────────────────
TRUNK_COLORS: dict[int, str] = {
    0: "#EE352E",   1: "#00933C",   2: "#B933AD",   3: "#0039A6",
    4: "#FF6319",   5: "#6CBE45",   6: "#996633",   7: "#A7A9AC",
    8: "#FCCC0A",   9: "#808183",  10: "#003DA5",  11: "#999999",
    12: "#999999",
}
TRUNK_LABELS: dict[int, str] = {
    0: "1/2/3", 1: "4/5/6", 2: "7", 3: "A/C/E", 4: "B/D/F/M",
    5: "G", 6: "J/Z", 7: "L", 8: "N/Q/R/W", 9: "GS",
    10: "SI", 11: "FS", 12: "H",
}
TRUNK_GROUPS: list[list[str]] = [
    ["1","2","3"], ["4","5","6","6X"], ["7","7X"], ["A","C","E"],
    ["B","D","F","FX","M"], ["G"], ["J","Z"], ["L"],
    ["N","Q","R","W"], ["GS"], ["SI"], ["FS"], ["H"],
]
ROUTE_TO_TRUNK: dict[str, int] = {}
for gi, grp in enumerate(TRUNK_GROUPS):
    for r in grp:
        ROUTE_TO_TRUNK[r] = gi

# ── Haversine helper ────────────────────────────────────────────────────────
def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    R = 6_371_000.0
    rlat1, rlat2, rlon1, rlon2 = map(math.radians, (lat1, lat2, lon1, lon2))
    dlat = rlat2 - rlat1
    dlon = rlon2 - rlon1
    a = math.sin(dlat/2)**2 + math.cos(rlat1)*math.cos(rlat2)*math.sin(dlon/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))

def polyline_length_m(coords: list[tuple[float, float]]) -> float:
    total = 0.0
    for i in range(len(coords)-1):
        total += haversine_m(coords[i][0], coords[i][1], coords[i+1][0], coords[i+1][1])
    return total


# ── Build pipeline output ───────────────────────────────────────────────────
def build_api_response():
    print("Running _build_shapes_all_sync() (same as /subway/shapes/all) ...")
    from app.routers.subway import _build_shapes_all_sync
    resp = _build_shapes_all_sync()
    return resp


def load_stations() -> list[dict]:
    """Load raw station data from GTFS stops.txt."""
    stops_path = _BACKEND / "app" / "data" / "stops.txt"
    stations = []
    with open(stops_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            sid = row.get("stop_id", "").strip()
            name = row.get("stop_name", "").strip()
            try:
                lat = float(row["stop_lat"])
                lon = float(row["stop_lon"])
            except (ValueError, KeyError):
                continue
            # Only parent stations (no N/S suffixes for now)
            if sid and lat and lon:
                stations.append({"id": sid, "name": name, "lat": lat, "lon": lon})
    return stations


# ── Analysis ────────────────────────────────────────────────────────────────
class TrunkAnalysis:
    def __init__(self, trunk_idx: int, color: str, route_ids: list[str],
                 decoded_polylines: list[list[tuple[float, float]]],
                 lane_offset: float, polyline_lane_offsets: list[float]):
        self.trunk_idx = trunk_idx
        self.color = color
        self.route_ids = route_ids
        self.polylines = decoded_polylines  # list of [(lat, lon), ...]
        self.lane_offset = lane_offset
        self.polyline_lane_offsets = polyline_lane_offsets
        # Computed
        self.gaps: list[dict] = []
        self.short_segments: list[dict] = []
        self.total_length_km = 0.0
        self.point_count = 0

    def analyse(self):
        # Compute total length and point count
        for i, poly in enumerate(self.polylines):
            length_m = polyline_length_m(poly)
            self.total_length_km += length_m / 1000.0
            self.point_count += len(poly)

            # Short segments < 200m are suspicious fragmentation
            if length_m < 200 and len(poly) < 10:
                self.short_segments.append({
                    "poly_idx": i, "length_m": length_m, "points": len(poly),
                    "start": poly[0], "end": poly[-1],
                })

        # Gap analysis: for each pair of polyline endpoints, find the
        # nearest endpoint of another polyline. If no endpoint is within
        # a threshold, that's a gap.
        endpoints = []
        for i, poly in enumerate(self.polylines):
            endpoints.append((i, "start", poly[0]))
            endpoints.append((i, "end", poly[-1]))

        GAP_THRESHOLD_M = 100  # endpoints > 100m apart = gap
        NEAR_THRESHOLD_M = 500  # only look within 500m

        for i, poly in enumerate(self.polylines):
            for tag, pt in [("start", poly[0]), ("end", poly[-1])]:
                # Find nearest endpoint from a DIFFERENT polyline
                best_dist = float("inf")
                best_other = None
                for j, other_tag, other_pt in endpoints:
                    if j == i:
                        continue
                    d = haversine_m(pt[0], pt[1], other_pt[0], other_pt[1])
                    if d < best_dist:
                        best_dist = d
                        best_other = (j, other_tag, other_pt)

                if best_dist > GAP_THRESHOLD_M and best_dist < NEAR_THRESHOLD_M:
                    self.gaps.append({
                        "poly_idx": i, "endpoint": tag, "pt": pt,
                        "nearest_poly": best_other[0] if best_other else -1,
                        "nearest_tag": best_other[1] if best_other else "",
                        "nearest_pt": best_other[2] if best_other else (0,0),
                        "dist_m": best_dist,
                    })


# ── Plotting ────────────────────────────────────────────────────────────────
# Full NYC bounding box
NYC_LAT = (40.49, 40.92)
NYC_LON = (-74.27, -73.68)

# Tighter Manhattan-centric view for detail panels
MAN_LAT = (40.68, 40.82)
MAN_LON = (-74.04, -73.90)


def style_ax(ax, title: str, bbox_lat=NYC_LAT, bbox_lon=NYC_LON, bg="#f0f0f0"):
    ax.set_title(title, fontsize=10, fontweight="bold", pad=8)
    ax.set_facecolor(bg)
    ax.set_xlim(bbox_lon)
    ax.set_ylim(bbox_lat)
    ax.set_aspect("equal")
    ax.tick_params(labelsize=5)
    ax.grid(True, alpha=0.12, linewidth=0.3)


def plot_system_map(ax, analyses: list[TrunkAnalysis]):
    """Panel 1: Full NYC system — all trunk polylines."""
    style_ax(ax, "① System Map — All Trunk Polylines\n(what the user sees)")

    for ta in analyses:
        for poly in ta.polylines:
            lons = [p[1] for p in poly]
            lats = [p[0] for p in poly]
            ax.plot(lons, lats, color=ta.color, linewidth=1.8, alpha=0.8,
                    solid_capstyle="round")

    total_polys = sum(len(ta.polylines) for ta in analyses)
    total_km = sum(ta.total_length_km for ta in analyses)
    ax.text(0.02, 0.02,
            f"{len(analyses)} trunk groups\n{total_polys} polylines\n{total_km:.1f} km total",
            transform=ax.transAxes, fontsize=7, color="#333", va="bottom",
            bbox=dict(fc="white", ec="gray", alpha=0.8, pad=2))


def plot_gaps(ax, analyses: list[TrunkAnalysis]):
    """Panel 2: Gap analysis — highlight disconnected endpoints."""
    style_ax(ax, "② Gap Analysis — Disconnected Endpoints\n(red = gap > 100m between endpoints)",
             bbox_lat=MAN_LAT, bbox_lon=MAN_LON)

    # Background: draw trunk polylines faded
    for ta in analyses:
        for poly in ta.polylines:
            lons = [p[1] for p in poly]
            lats = [p[0] for p in poly]
            ax.plot(lons, lats, color=ta.color, linewidth=1.0, alpha=0.25, solid_capstyle="round")

    # Highlight gaps
    total_gaps = 0
    for ta in analyses:
        for gap in ta.gaps:
            pt = gap["pt"]
            npt = gap["nearest_pt"]
            # Only show gaps in the view
            if MAN_LAT[0] <= pt[0] <= MAN_LAT[1] and MAN_LON[0] <= pt[1] <= MAN_LON[1]:
                ax.plot(pt[1], pt[0], 'ro', markersize=5, alpha=0.9, zorder=10)
                # Draw dashed line to nearest endpoint
                ax.plot([pt[1], npt[1]], [pt[0], npt[0]], 'r--',
                        linewidth=0.8, alpha=0.6, zorder=9)
                ax.annotate(f"{gap['dist_m']:.0f}m", xy=(pt[1], pt[0]),
                           fontsize=4, color="red", alpha=0.8,
                           xytext=(3, 3), textcoords="offset points")
                total_gaps += 1

    # Mark ALL polyline endpoints (green = connected, red = gap)
    for ta in analyses:
        for poly in ta.polylines:
            for pt in [poly[0], poly[-1]]:
                if MAN_LAT[0] <= pt[0] <= MAN_LAT[1] and MAN_LON[0] <= pt[1] <= MAN_LON[1]:
                    ax.plot(pt[1], pt[0], 'o', color=ta.color, markersize=2.5,
                            alpha=0.5, zorder=5, markeredgecolor="black",
                            markeredgewidth=0.3)

    ax.text(0.02, 0.02, f"{total_gaps} gaps in view",
            transform=ax.transAxes, fontsize=7, color="red", va="bottom",
            bbox=dict(fc="white", ec="gray", alpha=0.8, pad=2))


def plot_fragmentation(ax, analyses: list[TrunkAnalysis]):
    """Panel 3: Short segments + fragmentation."""
    style_ax(ax, "③ Fragmentation — Short Segments < 200m\n(orange = short, thicker = shorter)",
             bbox_lat=MAN_LAT, bbox_lon=MAN_LON, bg="#f8f4f0")

    # Background
    for ta in analyses:
        for poly in ta.polylines:
            lons = [p[1] for p in poly]
            lats = [p[0] for p in poly]
            ax.plot(lons, lats, color=ta.color, linewidth=0.8, alpha=0.2, solid_capstyle="round")

    # Highlight short segments
    total_short = 0
    for ta in analyses:
        for seg in ta.short_segments:
            poly = ta.polylines[seg["poly_idx"]]
            lons = [p[1] for p in poly]
            lats = [p[0] for p in poly]
            mid = poly[len(poly)//2]
            if MAN_LAT[0] <= mid[0] <= MAN_LAT[1] and MAN_LON[0] <= mid[1] <= MAN_LON[1]:
                # Width proportional to how short it is
                w = max(2, min(6, (200 - seg["length_m"]) / 30))
                ax.plot(lons, lats, color="#ff6600", linewidth=w, alpha=0.85, zorder=10,
                        solid_capstyle="round")
                ax.annotate(f"{seg['length_m']:.0f}m", xy=(mid[1], mid[0]),
                           fontsize=4, color="#cc4400", alpha=0.9,
                           xytext=(3, 3), textcoords="offset points")
                total_short += 1

    # Per-trunk segment count histogram as inset text
    seg_counts = []
    for ta in analyses:
        if ta.polylines:
            seg_counts.append(f"{TRUNK_LABELS[ta.trunk_idx]}: {len(ta.polylines)} segs")

    ax.text(0.02, 0.02, f"{total_short} short segments in view\n" + "\n".join(seg_counts[:6]),
            transform=ax.transAxes, fontsize=5.5, color="#333", va="bottom",
            family="monospace", bbox=dict(fc="white", ec="gray", alpha=0.8, pad=2))


def plot_stations(ax, analyses: list[TrunkAnalysis], stations: list[dict]):
    """Panel 4: Station connectivity — are polylines near stations?"""
    style_ax(ax, "④ Station Connectivity\n(red × = station > 80m from nearest polyline)",
             bbox_lat=MAN_LAT, bbox_lon=MAN_LON, bg="#f0f4f0")

    # Draw trunk polylines
    for ta in analyses:
        for poly in ta.polylines:
            lons = [p[1] for p in poly]
            lats = [p[0] for p in poly]
            ax.plot(lons, lats, color=ta.color, linewidth=1.2, alpha=0.5, solid_capstyle="round")

    # Build a spatial lookup: all polyline vertices by trunk
    # For each station, find nearest polyline vertex
    all_vertices: list[tuple[float, float, int]] = []  # (lat, lon, trunk_idx)
    for ta in analyses:
        for poly in ta.polylines:
            for pt in poly:
                all_vertices.append((pt[0], pt[1], ta.trunk_idx))

    vertex_arr = np.array([(v[0], v[1]) for v in all_vertices]) if all_vertices else np.empty((0,2))
    vertex_trunks = [v[2] for v in all_vertices]

    STATION_THRESHOLD_M = 80
    far_stations = []
    near_stations = []

    # Filter stations to view
    view_stations = [s for s in stations
                     if MAN_LAT[0] <= s["lat"] <= MAN_LAT[1]
                     and MAN_LON[0] <= s["lon"] <= MAN_LON[1]
                     and not s["id"].endswith("N") and not s["id"].endswith("S")]

    for st in view_stations:
        if len(vertex_arr) == 0:
            far_stations.append(st)
            continue
        # Quick distance check using approximate meters
        dlat = (vertex_arr[:, 0] - st["lat"]) * 111_320
        dlon = (vertex_arr[:, 1] - st["lon"]) * 111_320 * math.cos(math.radians(st["lat"]))
        dists = np.sqrt(dlat**2 + dlon**2)
        min_dist = float(np.min(dists))

        if min_dist > STATION_THRESHOLD_M:
            far_stations.append({**st, "min_dist_m": min_dist})
        else:
            near_stations.append(st)

    # Plot near stations as small green dots
    for s in near_stations:
        ax.plot(s["lon"], s["lat"], 'o', color="green", markersize=2, alpha=0.5, zorder=5)

    # Plot far stations as red X markers
    for s in far_stations:
        ax.plot(s["lon"], s["lat"], 'x', color="red", markersize=5, markeredgewidth=1.2,
                alpha=0.9, zorder=10)
        dist_str = f"{s.get('min_dist_m', '?'):.0f}m" if isinstance(s.get('min_dist_m'), float) else "?"
        ax.annotate(f"{s['name']}\n{dist_str}", xy=(s["lon"], s["lat"]),
                   fontsize=3.5, color="red", alpha=0.8,
                   xytext=(4, 4), textcoords="offset points")

    ax.text(0.02, 0.02,
            f"{len(near_stations)} stations connected (< {STATION_THRESHOLD_M}m)\n"
            f"{len(far_stations)} stations FAR from polylines",
            transform=ax.transAxes, fontsize=7, va="bottom",
            color="red" if far_stations else "green",
            bbox=dict(fc="white", ec="gray", alpha=0.8, pad=2))


def print_report(analyses: list[TrunkAnalysis]):
    """Print detailed text report."""
    print("\n" + "="*72)
    print("POLYLINE DIAGNOSTIC REPORT")
    print("="*72)

    total_polys = 0
    total_pts = 0
    total_km = 0.0
    total_gaps = 0
    total_short = 0

    for ta in analyses:
        label = TRUNK_LABELS[ta.trunk_idx]
        n = len(ta.polylines)
        total_polys += n
        total_pts += ta.point_count
        total_km += ta.total_length_km
        total_gaps += len(ta.gaps)
        total_short += len(ta.short_segments)

        # Segment lengths
        seg_lengths = []
        for poly in ta.polylines:
            seg_lengths.append(polyline_length_m(poly))

        print(f"\n── {label} (trunk {ta.trunk_idx}) ─────────────────────")
        print(f"   Polylines: {n}  |  Points: {ta.point_count}  |  Total: {ta.total_length_km:.1f} km")
        print(f"   Lane offset: {ta.lane_offset:.3f}")
        if seg_lengths:
            print(f"   Segment lengths: min={min(seg_lengths):.0f}m  median={sorted(seg_lengths)[len(seg_lengths)//2]:.0f}m  max={max(seg_lengths):.0f}m")

        if ta.gaps:
            print(f"   ⚠  {len(ta.gaps)} GAPS:")
            for g in sorted(ta.gaps, key=lambda x: -x["dist_m"])[:5]:
                print(f"      poly[{g['poly_idx']}].{g['endpoint']} → poly[{g['nearest_poly']}].{g['nearest_tag']}: {g['dist_m']:.0f}m")

        if ta.short_segments:
            print(f"   ⚠  {len(ta.short_segments)} SHORT SEGMENTS (< 200m):")
            for s in ta.short_segments:
                print(f"      poly[{s['poly_idx']}]: {s['length_m']:.0f}m ({s['points']} pts)")

    print(f"\n{'='*72}")
    print(f"TOTALS: {len(analyses)} trunk groups, {total_polys} polylines, "
          f"{total_pts} points, {total_km:.1f} km")
    print(f"ISSUES: {total_gaps} gaps, {total_short} short segments")
    print(f"{'='*72}\n")


def add_legend(fig, analyses):
    patches = []
    for ta in sorted(analyses, key=lambda x: x.trunk_idx):
        label = f"{TRUNK_LABELS[ta.trunk_idx]} ({len(ta.polylines)} segs)"
        patches.append(mpatches.Patch(color=ta.color, label=label, alpha=0.85))
    fig.legend(handles=patches, loc="lower center", ncol=min(7, len(patches)),
               fontsize=7, frameon=True, fancybox=True, bbox_to_anchor=(0.5, 0.005))


def main():
    resp = build_api_response()
    stations = load_stations()
    print(f"Loaded {len(stations)} stations from stops.txt")

    # Build analyses
    analyses: list[TrunkAnalysis] = []
    for tp in resp.trunk_polylines:
        decoded = []
        for enc in tp.polylines:
            try:
                coords = decode_polyline(enc)
                if len(coords) >= 2:
                    decoded.append(coords)
            except Exception:
                continue
        if decoded:
            ta = TrunkAnalysis(
                trunk_idx=tp.trunk_index,
                color=TRUNK_COLORS.get(tp.trunk_index, "#999"),
                route_ids=tp.route_ids,
                decoded_polylines=decoded,
                lane_offset=tp.lane_offset,
                polyline_lane_offsets=tp.polyline_lane_offsets,
            )
            ta.analyse()
            analyses.append(ta)

    print_report(analyses)

    # ── Plot ─────────────────────────────────────────────────────────────
    fig, axes = plt.subplots(2, 2, figsize=(22, 24))
    ax1, ax2 = axes[0]
    ax3, ax4 = axes[1]

    plot_system_map(ax1, analyses)
    plot_gaps(ax2, analyses)
    plot_fragmentation(ax3, analyses)
    plot_stations(ax4, analyses, stations)

    fig.suptitle(
        "Track Polyline Diagnostic — What The User Actually Sees",
        fontsize=16, fontweight="bold", y=0.98,
    )
    add_legend(fig, analyses)
    plt.tight_layout(rect=[0, 0.04, 1, 0.96])

    out = _BACKEND / "scripts" / "polyline_diagnostic.png"
    fig.savefig(out, dpi=180, bbox_inches="tight")
    print(f"\n✅  Saved diagnostic to {out}")

    # Also save a zoomed Manhattan view of just the system map
    fig2, ax_man = plt.subplots(1, 1, figsize=(14, 16))
    style_ax(ax_man, "Manhattan Close-Up — Trunk Polylines",
             bbox_lat=(40.700, 40.810), bbox_lon=(-74.025, -73.930))
    for ta in analyses:
        for poly in ta.polylines:
            lons = [p[1] for p in poly]
            lats = [p[0] for p in poly]
            ax_man.plot(lons, lats, color=ta.color, linewidth=2.5, alpha=0.85,
                        solid_capstyle="round")
    # Overlay stations
    view_man_stations = [s for s in stations
                         if 40.700 <= s["lat"] <= 40.810
                         and -74.025 <= s["lon"] <= -73.930
                         and not s["id"].endswith("N") and not s["id"].endswith("S")]
    for s in view_man_stations:
        ax_man.plot(s["lon"], s["lat"], 'o', color="white", markersize=3,
                    markeredgecolor="black", markeredgewidth=0.5, alpha=0.7, zorder=5)

    # Add crossing points
    for cp in resp.crossings:
        if 40.700 <= cp.lat <= 40.810 and -74.025 <= cp.lng <= -73.930:
            ax_man.plot(cp.lng, cp.lat, 'x', color="black", markersize=4,
                        markeredgewidth=1.5, alpha=0.6, zorder=8)

    add_legend(fig2, analyses)
    plt.tight_layout(rect=[0, 0.04, 1, 0.97])
    out2 = _BACKEND / "scripts" / "manhattan_closeup.png"
    fig2.savefig(out2, dpi=200, bbox_inches="tight")
    print(f"✅  Saved Manhattan close-up to {out2}")


if __name__ == "__main__":
    main()
