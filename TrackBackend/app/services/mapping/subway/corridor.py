"""corridor_pipeline.py  —  v3.2 arc-based parallel offsets

5-phase pipeline:
Phase 1 – Trunk Merge:      Pool same-colour routes, unify into continuous paths
Phase 2 – Corridor Detect:  Find where different trunk groups share track
Phase 3 – Arc Offset:       Densify → arc-offset → despike → RDP-simplify
Phase 4 – Export:           Reproject to WGS84, encode polylines
Phase 5 – Stop Snap:        Snap GTFS stops onto offset paths

═══════════════════════════════════════════════════════════════════════════════
ARCHITECTURE CHANGE (v3.1 → v3.2)

v1  Used Shapely offset_curve() → EKG spikes, bowties, Columbus Circle bubble
v2  Unified skeleton from ALL 23 routes → 1 124 edges, 397 tiny fragments
(avg 5 pts each), catastrophic fragmentation, 361 edges with zero routes.
v3  Trunk-group level offsets → 11 groups, ~25-35 continuous polylines,
each with ~50-350 points.
v3.1 Per-route GTFS preservation — transfer trunk offsets via nearest-neighbour.
v3.2 Arc-based offsets — circular arc segments at bends maintain constant
perpendicular distance.  Lines sharing a corridor never overlap at turns.
Also: vertex densification, cosine-blended corridor transitions,
and post-offset Douglas-Peucker simplification.

KEY INSIGHT: the iOS client renders ONE polyline per trunk colour group (not
per route).  Routes A/C/E are all blue and get merged into one polyline by
MapSystemViewModel.computeFlattenedPolylines().  The server only needs to
produce parallel offsets between *different colour groups* that share track.

Running routes in the *same* trunk group on the *same* track is correct —
the client expects overlapping same-colour polylines and unifies them.
═══════════════════════════════════════════════════════════════════════════════."""

from __future__ import annotations

import math
from collections import defaultdict
from itertools import permutations
from typing import TYPE_CHECKING, NamedTuple

from pyproj import Transformer
from shapely import STRtree
from shapely.geometry import LineString, Point
from shapely.ops import substring

from app.utils.logger import TrackLogger
from app.utils.polyline_utils import decode_polyline, encode_polyline

if TYPE_CHECKING:
    from app.models import SubwayLineOverlay

# ═══════════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════════

# Perpendicular distance between adjacent trunk groups in a corridor (meters
# in EPSG:3857).  40 EPSG:3857-m ≈ 30.5 real metres at NYC latitude 40.7°.
# Tuned so parallel lines are visually distinct from zoom 13 upwards;
# at zoom 10-12 the iOS client supplements with pixel-space lineOffset.
LANE_WIDTH: float = 40.0

# Two trunk paths closer than this are considered to share a corridor.
# 35 m catches true shared tunnels (GPS traces within ~10-30 m) while
# still excluding most adjacent streets.  CPW/6th-Ave A vs D shapes
# measured at ~28-32 m apart — the previous 25 m threshold missed them.
CORRIDOR_DETECT_DIST: float = 35.0

# Minimum |dot product| of travel directions for two trunk paths to be
# considered parallel.  cos(45°) ≈ 0.707.  Tightened from 0.574 to
# reduce false positives from streets that cross at moderate angles.
CORRIDOR_ALIGN_MIN: float = 0.707

# Ignore tiny side-to-side differences when inferring lane ordering.
# GTFS / agency shapes on the same corridor often wobble by 1-2 m even
# when the trains are really co-located, so we only accept stronger
# lateral evidence when deciding which trunk should stay left/right.
LANE_ORDER_SIGNIFICANCE: float = 2.0

# Exhaustive ordering search stays cheap for typical NYC shared-corridor
# sets (2-5 trunks).  Fall back to the global score ordering for larger
# sets to avoid factorial blowups.
MAX_LANE_ORDER_SOLVER_SIZE: int = 7

# Maximum number of consecutive zero-offset vertices allowed inside a
# corridor before gap-filling kicks in.  Closes detection holes where a
# few vertices slip through the proximity / alignment filters.
CORRIDOR_GAP_MAX: int = 20

# Number of vertices over which to smooth offset transitions at corridor
# entry/exit points.  Prevents abrupt lateral jumps.
BLEND_WINDOW: int = 8

# Miter join clamp (same as v2).  Prevents spikes at acute corners.
MITER_CLAMP: float = 2.0

# Despike thresholds.
# Minimum angle (deg) between the back-vector and forward-vector at a
# vertex.  With angle = 180° - path_turn_deg:
#   45° threshold removes vertices where path turns sharper than 135°.
# This covers switchbacks and re-snap artefacts while keeping the
# genuine ~90-120° curves that occur at station approach geometry.
DESPIKE_MIN_ANGLE_DEG: float = 45.0
# Maximum cross-track excursion ratio (excursion / chord_len^2).
# 0.40 removes vertices that deviate more than ~22° from the chord
# while keeping smooth station curves.
DESPIKE_MAX_EXCURSION: float = 0.40

# Minimum path length (meters) to include in output.
MIN_PATH_LENGTH: float = 50.0

# Maximum gap between endpoint of two segments for merge (meters).
# Increased from 50 → 100 m to bridge coverage gaps in dense junctions
# (e.g. 47-50 St Rockefeller Center where GTFS shape coordinates for
# different BDFM routes can have small position offsets between them).
MERGE_GAP_M: float = 100.0

# Maximum distance for snapping a stop onto an offset path (meters).
STOP_SNAP_DIST: float = 150.0

# Maximum distance (meters) for snapping a trunk polyline vertex
# onto a station node.  If the nearest point on the polyline is
# within this radius, a vertex is inserted/moved to route the
# polyline through the station coordinate.
STATION_SNAP_DIST: float = 250.0

# ── Arc-based offset constants (v3.2) ────────────────────────────────────────
# These replace miter-join offsets with circular arc segments at bends,
# producing Transit-app-quality parallel lines that never overlap at turns.

# Maximum spacing between vertices before densification (meters).
# Shorter segments → smoother offset curves at bends.
DENSIFY_MAX_SPACING: float = 15.0

# Minimum turning angle (degrees) at a vertex before arc subdivision.
# Below this threshold, a simple averaged normal is used (= near-straight).
ARC_MIN_ANGLE_DEG: float = 5.0

# Maximum number of arc points to insert at a single bend vertex.
# Prevents point explosion at very sharp U-turns.
ARC_MAX_POINTS: int = 8

# Douglas-Peucker tolerance (meters) for post-offset simplification.
# Removes redundant vertices added by densification + arc subdivision
# while preserving the smooth curve shape.  Reduced from 2.0 → 1.5 m
# to retain more detail at sharp bends (e.g. Columbus Circle, DeKalb).
RDP_TOLERANCE: float = 1.5


# ═══════════════════════════════════════════════════════════════════════════════
# MTA trunk groups (must match iOS MapSystemViewModel.trunkGroups)
# ═══════════════════════════════════════════════════════════════════════════════

TRUNK_GROUPS: list[list[str]] = [
    ["1", "2", "3"],  # 0: Red — 7th Ave / Broadway
    ["4", "5", "6", "6X"],  # 1: Green — Lexington Ave
    ["7", "7X"],  # 2: Purple — Flushing
    ["A", "C", "E"],  # 3: Blue — 8th Ave
    ["B", "D", "F", "FX", "M"],  # 4: Orange — 6th Ave
    ["G"],  # 5: Lime Green — Crosstown
    ["J", "Z"],  # 6: Brown — Nassau St
    ["L"],  # 7: Gray — 14th St / Canarsie
    ["N", "Q", "R", "W"],  # 8: Yellow — Broadway BMT
    ["GS"],  # 9: 42nd St Shuttle (Grand Central ↔ Times Sq)
    ["SI"],  # 10: Staten Island Railway
    ["FS"],  # 11: Franklin Ave Shuttle
    ["H"],  # 12: Rockaway Park Shuttle
]

ROUTE_TO_TRUNK: dict[str, int] = {}
for _gi, _group in enumerate(TRUNK_GROUPS):
    for _rid in _group:
        ROUTE_TO_TRUNK[_rid] = _gi


# ═══════════════════════════════════════════════════════════════════════════════
# Projectors (WGS84 ↔ Web Mercator)
# ═══════════════════════════════════════════════════════════════════════════════

_to_meters = Transformer.from_crs("EPSG:4326", "EPSG:3857", always_xy=True)
_to_wgs84 = Transformer.from_crs("EPSG:3857", "EPSG:4326", always_xy=True)


def project_to_meters(coords: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Convert [(lat, lon), …] → [(x_m, y_m), …] in EPSG:3857."""
    return [_to_meters.transform(lon, lat) for lat, lon in coords]


def project_to_wgs84(coords: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Convert [(x_m, y_m), …] → [(lat, lon), …] in WGS84."""
    return [tuple(reversed(_to_wgs84.transform(x, y))) for x, y in coords]


# ═══════════════════════════════════════════════════════════════════════════════
# Geometry helpers
# ═══════════════════════════════════════════════════════════════════════════════


def _point_dist(a: tuple[float, float], b: tuple[float, float]) -> float:
    dx = a[0] - b[0]
    dy = a[1] - b[1]
    return math.sqrt(dx * dx + dy * dy)


def _unit_normal(
    p0: tuple[float, float], p1: tuple[float, float]
) -> tuple[float, float]:
    """Left-hand perpendicular unit normal of the segment p0→p1."""
    dx = p1[0] - p0[0]
    dy = p1[1] - p0[1]
    length = math.sqrt(dx * dx + dy * dy)
    if length < 1e-10:
        return (0.0, 0.0)
    return (-dy / length, dx / length)


def _local_direction(
    coords: list[tuple[float, float]],
    idx: int,
) -> tuple[float, float]:
    """Unit direction vector at vertex *idx* (averaged from adjacent segments)."""
    n = len(coords)
    if n < 2:
        return (1.0, 0.0)

    if idx == 0:
        ax, ay = coords[1][0] - coords[0][0], coords[1][1] - coords[0][1]
    elif idx >= n - 1:
        ax = coords[n - 1][0] - coords[n - 2][0]
        ay = coords[n - 1][1] - coords[n - 2][1]
    else:
        ax = coords[idx + 1][0] - coords[idx - 1][0]
        ay = coords[idx + 1][1] - coords[idx - 1][1]

    length = math.sqrt(ax * ax + ay * ay)
    if length < 1e-10:
        return (1.0, 0.0)
    return (ax / length, ay / length)


def _direction_at_distance(path: LineString, dist: float) -> tuple[float, float]:
    """Unit direction of *path* at *dist* metres along it."""
    length = path.length
    d_fwd = min(dist + 10.0, length)
    d_bwd = max(dist - 10.0, 0.0)
    p_fwd = path.interpolate(d_fwd)
    p_bwd = path.interpolate(d_bwd)
    dx = p_fwd.x - p_bwd.x
    dy = p_fwd.y - p_bwd.y
    mag = math.sqrt(dx * dx + dy * dy)
    if mag < 1e-10:
        return (1.0, 0.0)
    return (dx / mag, dy / mag)


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1 — Trunk Merge (grid-based coverage dedup)
# ═══════════════════════════════════════════════════════════════════════════════
#
# DESIGN: Within each trunk group all routes share the same physical tracks.
# Instead of unary_union (which shatters lines at every intersection of
# slightly-different GPS traces → 47 fragments for A/C/E), we use a
# coverage-grid approach identical to the iOS unifyTrainPolylines():
#
# 1. Sort all polylines by length (longest → trunk baseline).
# 2. Seed a spatial grid from the trunk.
# 3. For each subsequent polyline:
#    >90% covered → skip (near-duplicate).
#    <15% covered → keep whole (unique corridor).
#    Otherwise  → extract only uncovered branch stubs.
# 4. Chain-merge nearby endpoints.
#
# Result: 1-5 continuous polylines per trunk group (not 35-57 fragments).

# Grid cell size in EPSG:3857 metres.  ~100 m Mercator ≈ 76 real metres
# at NYC latitude.  Two GPS traces of the same track (10-30 m apart) land
# in the same or adjacent cells.
_GRID_CELL_M: float = 100.0

# Minimum run length (in vertices) for an uncovered section to count as a
# genuine branch stub.  Short uncovered runs (5-12 pts) are GPS drift.
_MIN_BRANCH_RUN: int = 8

# Maximum snap distance (meters) when connecting a stub extension point
# back to the trunk baseline.  Prevents teleporting to a distant trunk
# point when the nearest trunk coord is actually kilometres away.
_MAX_SNAP_DIST_M: float = 200.0

# When extending a branch run into the "covered" zone, keep extending
# as long as the branch coordinate is farther than this from the actual
# trunk LineString.  This captures the convergence zone where grid cells
# overlap but the physical paths haven't yet merged (e.g. Lefferts Blvd
# branch running parallel to Far Rockaway within 200m grid proximity but
# serving different stations 300-500m apart).
_BRANCH_MERGE_DIST_M: float = 50.0

# Maximum number of extra vertices to include beyond the uncovered run
# when doing distance-based extension.  Must be large enough that the
# backward extension can reach the junction where a branch diverges from
# the shared trunk.  E.g. the E train diverges from the 8th Ave trunk
# at 42nd St — the uncovered run starts ~500 vertices later in Queens,
# so we need ≥500 vertices of backward extension.  2000 covers ~60 km
# of GTFS geometry at typical density, far more than any NYC branch.
_BRANCH_EXTEND_MAX: int = 2000

# Maximum gap (meters) allowed between consecutive vertices in a branch
# stub.  Stubs with jumps exceeding this are considered corrupted and
# discarded.  Set high enough to allow natural GTFS sparsity (tunnels,
# water crossings can have 1-5 km between encoded points) while still
# catching teleport artifacts from bad snaps.
_MAX_STUB_GAP_M: float = 6000.0

# ── Branch stem injection ──
# Length (meters) of trunk baseline to prepend/append at branch junctions
# so that branch stubs visually overlap the trunk and appear connected.
_STEM_LENGTH_M: float = 1500.0

# Maximum distance (meters) from a branch endpoint to the trunk baseline
# for stem injection to activate.  If the branch end is farther than this,
# it's not a junction — it's the branch's free terminal.
# Raised from 500 → 800 to catch stubs (like Lefferts Blvd) that are
# 395-800m from the baseline after distance-based extension.
_STEM_SNAP_DIST_M: float = 800.0

# Fallback: if raw Euclidean distance exceeds _STEM_SNAP_DIST_M but the
# *projected* distance along the baseline is within this threshold, still
# inject a stem.  Handles curved baselines where geometric distance is
# large but the actual track proximity is small.
_STEM_PROJ_FALLBACK_M: float = 200.0


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1.5 — Topological Station Snapping
# ═══════════════════════════════════════════════════════════════════════════════
#
# Forces trunk polylines to route through their associated station
# coordinates.  Raw GTFS shapes are simplified geometric traces that
# may approximate but not precisely intersect station positions;
# this step "attracts" the nearest polyline vertex (or inserts one)
# so that the rendered track visually passes through every stop.
# Without this, routes like the 7 train can appear to bypass their
# own stations on the map.


def _snap_paths_to_stations(
    trunk_paths: dict[int, list[LineString]],
) -> dict[int, list[LineString]]:
    """Snap trunk polylines through their associated station coordinates.

    For each trunk group:
    1. Collect all stations whose routes belong to this trunk.
    2. Project station coords to EPSG:3857.
    3. For each station, find the nearest point on the trunk's LineStrings.
    4. If within STATION_SNAP_DIST, insert a vertex at the station's
       projected position so the polyline routes cleanly through the stop.

    Returns a new dict with the same structure as *trunk_paths* but with
    station-snapped geometries.
    """
    from app.services.mapping.subway.shapes import get_all_subway_stations

    raw_stations = get_all_subway_stations()
    if not raw_stations:
        return trunk_paths

    # Build trunk_idx → list of (x_m, y_m) station positions
    trunk_stations: dict[int, list[tuple[float, float]]] = defaultdict(list)
    for station in raw_stations:
        routes = station.get("routes", [])
        lat, lon = station["lat"], station["lon"]
        try:
            x, y = _to_meters.transform(lon, lat)
        except Exception:
            continue
        seen_trunks: set[int] = set()
        for rid in routes:
            tidx = ROUTE_TO_TRUNK.get(rid)
            if tidx is not None and tidx not in seen_trunks:
                trunk_stations[tidx].append((x, y))
                seen_trunks.add(tidx)

    result: dict[int, list[LineString]] = {}
    total_snapped = 0

    for trunk_idx, paths in trunk_paths.items():
        stations_m = trunk_stations.get(trunk_idx, [])
        if not stations_m:
            result[trunk_idx] = paths
            continue

        snapped_paths: list[LineString] = []
        for path in paths:
            coords = list(path.coords)
            # For each station, find the closest segment on this path and
            # insert the station coordinate as a new vertex.
            snap_insertions: list[tuple[float, float, float]] = []
            #   (linear_position_along_path, station_x, station_y)

            for sx, sy in stations_m:
                spt = Point(sx, sy)
                dist = path.distance(spt)
                if dist > STATION_SNAP_DIST:
                    continue
                # Linear position along the path where the station projects
                proj_dist = path.project(spt)
                snap_insertions.append((proj_dist, sx, sy))

            if not snap_insertions:
                snapped_paths.append(path)
                continue

            # Sort insertions by position along the path
            snap_insertions.sort(key=lambda t: t[0])

            # Rebuild the coordinate list, inserting station vertices
            # at the correct linear positions.
            new_coords: list[tuple[float, float]] = []
            cum_dist = 0.0
            snap_idx = 0  # pointer into snap_insertions

            for i in range(len(coords)):
                # Distance from start to this vertex
                if i > 0:
                    cum_dist += _point_dist(coords[i - 1], coords[i])

                # Insert any station vertices that fall between the
                # previous vertex and this one.
                while snap_idx < len(snap_insertions):
                    s_dist, sx, sy = snap_insertions[snap_idx]
                    if s_dist <= cum_dist + 1e-3:
                        # Avoid duplicating if very close to an existing vertex
                        if (
                            not new_coords
                            or _point_dist(new_coords[-1], (sx, sy)) > 2.0
                        ):
                            new_coords.append((sx, sy))
                            total_snapped += 1
                        snap_idx += 1
                    else:
                        break

                new_coords.append(coords[i])

            # Append any remaining stations past the last vertex
            while snap_idx < len(snap_insertions):
                _, sx, sy = snap_insertions[snap_idx]
                if _point_dist(new_coords[-1], (sx, sy)) > 2.0:
                    new_coords.append((sx, sy))
                    total_snapped += 1
                snap_idx += 1

            if len(new_coords) >= 2:
                snapped_paths.append(LineString(new_coords))
            else:
                snapped_paths.append(path)

        result[trunk_idx] = snapped_paths

    TrackLogger.info(
        f"[StationSnap] Inserted {total_snapped} station vertices across "
        f"{len(trunk_paths)} trunk groups"
    )
    return result


def _normalize_path_direction(path: LineString) -> LineString:
    """Ensure a polyline runs south→north (or west→east for E-W lines).

    This guarantees that MapLibre's ``lineOffset`` (perpendicular to draw
    direction) pushes parallel trunk lines in consistent geographic
    directions across all trunk groups sharing a corridor.
    """
    coords = list(path.coords)
    if len(coords) < 2:
        return path

    # Use WGS84 endpoints to decide orientation
    try:
        start_lon, start_lat = _to_wgs84.transform(coords[0][0], coords[0][1])
        end_lon, end_lat = _to_wgs84.transform(coords[-1][0], coords[-1][1])
    except Exception:
        return path

    lat_span = abs(end_lat - start_lat)
    lon_span = abs(end_lon - start_lon)

    if lat_span >= lon_span:
        # Predominantly north-south: ensure south→north (start_lat < end_lat)
        if start_lat > end_lat:
            return LineString(list(reversed(coords)))
    else:
        # Predominantly east-west: ensure west→east (start_lon < end_lon)
        if start_lon > end_lon:
            return LineString(list(reversed(coords)))

    return path


def _group_and_merge_trunks(
    overlays: list,
) -> dict[int, list[LineString]]:
    """Pool all routes by trunk, project to meters, dedup into trunk + branches.

    Uses grid-based coverage detection (same approach as iOS
    unifyTrainPolylines) to deduplicate overlapping same-track routes
    and extract genuine branch stubs.  Produces 1-5 continuous polylines
    per trunk group.

    Returns: dict[trunk_idx → list[LineString in EPSG:3857]].
    """
    trunk_lines: dict[int, list[LineString]] = defaultdict(list)

    for overlay in overlays:
        trunk_idx = ROUTE_TO_TRUNK.get(overlay.route_id)
        if trunk_idx is None:
            continue
        for enc in overlay.polylines:
            coords = decode_polyline(enc)
            if len(coords) < 2:
                continue
            try:
                projected = project_to_meters(coords)
                line = LineString(projected)
                if line.length >= MIN_PATH_LENGTH:
                    trunk_lines[trunk_idx].append(line)
            except Exception:
                continue

    trunk_paths: dict[int, list[LineString]] = {}

    for trunk_idx, lines in trunk_lines.items():
        if not lines:
            continue

        if len(lines) == 1:
            trunk_paths[trunk_idx] = lines
            continue

        unified = _unify_via_grid(lines)
        if unified:
            trunk_paths[trunk_idx] = unified
        else:
            trunk_paths[trunk_idx] = [max(lines, key=lambda ls: ls.length)]

    return trunk_paths


def _unify_via_grid(
    lines: list[LineString],
) -> list[LineString]:
    """Deduplicate overlapping LineStrings using a spatial coverage grid.

    Mirrors the iOS unifyTrainPolylines algorithm:
    - Longest line seeds the grid (= trunk baseline).
    - Subsequent lines checked for coverage ratio.
    - Branch stubs extracted from partially-covered lines.
    """
    sorted_lines = sorted(lines, key=lambda ls: ls.length, reverse=True)

    # ── Spatial grid ──
    grid: set[tuple[int, int]] = set()

    def _cell(x: float, y: float) -> tuple[int, int]:
        return (math.floor(x / _GRID_CELL_M), math.floor(y / _GRID_CELL_M))

    def _add_line(line: LineString) -> None:
        for x, y in line.coords:
            grid.add(_cell(x, y))

    def _is_covered(x: float, y: float) -> bool:
        cx, cy = _cell(x, y)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                if (cx + dx, cy + dy) in grid:
                    return True
        return False

    def _is_near(x: float, y: float) -> bool:
        """Wider check (±2 cells ≈ 200 m) for branch validation.

        Reduced from ±4 (~400 m) to avoid falsely rejecting genuine
        branches that run parallel to the trunk within a few hundred
        metres (e.g. A-train Lefferts Blvd spur alongside Far Rockaway).
        """
        cx, cy = _cell(x, y)
        for dx in range(-2, 3):
            for dy in range(-2, 3):
                if (cx + dx, cy + dy) in grid:
                    return True
        return False

    def _run_diverges_from_trunk(
        coords: list[tuple[float, float]],
        r_start: int,
        r_end: int,
        baseline: LineString,
    ) -> bool:
        """Return True if the uncovered run heads in a significantly
        different direction than the trunk at the branch point.

        A genuine branch diverges by > 30° from the trunk direction.
        An express/local corridor variant runs in roughly the same direction.
        """
        run_len = r_end - r_start + 1
        if run_len < 4:
            return False

        # Run heading: from start to a point ~25% into the run
        quarter = max(1, run_len // 4)
        sx, sy = coords[r_start]
        qx, qy = coords[r_start + quarter]
        rdx, rdy = qx - sx, qy - sy
        run_mag = math.sqrt(rdx * rdx + rdy * rdy)
        if run_mag < 10.0:
            return False

        # Trunk heading at the branch point
        proj_dist = baseline.project(Point(sx, sy))
        epsilon = min(200.0, baseline.length * 0.05)
        p1 = baseline.interpolate(max(0.0, proj_dist - epsilon))
        p2 = baseline.interpolate(min(baseline.length, proj_dist + epsilon))
        tdx, tdy = p2.x - p1.x, p2.y - p1.y
        trunk_mag = math.sqrt(tdx * tdx + tdy * tdy)
        if trunk_mag < 10.0:
            return False

        # Cosine of angle between run and trunk headings
        dot = (rdx * tdx + rdy * tdy) / (run_mag * trunk_mag)
        dot = max(-1.0, min(1.0, dot))
        # > cos(30°) ≈ 0.866 → nearly parallel → corridor variant
        # We also accept anti-parallel (|dot| check) as diverging
        return abs(dot) < 0.866

    # Seed with the longest polyline (trunk baseline)
    kept: list[LineString] = [sorted_lines[0]]
    _add_line(sorted_lines[0])

    trunk_coords = list(sorted_lines[0].coords)
    trunk_baseline = sorted_lines[0]

    for seg_line in sorted_lines[1:]:
        coords = list(seg_line.coords)
        n = len(coords)
        if n < 2:
            continue

        # Coverage check
        covered = [_is_covered(x, y) for x, y in coords]
        covered_count = sum(covered)
        ratio = covered_count / n

        # <15% covered → unique corridor, keep whole
        if ratio < 0.15:
            kept.append(seg_line)
            _add_line(seg_line)
            continue

        # Partial or high overlap → extract uncovered branch stubs.
        # NOTE: we do NOT skip >90%-covered lines.  A line can be 93%
        # covered and still have a genuine 7% branch (e.g. A train's
        # Lefferts Blvd spur or Rockaway Park branch).  Instead,
        # we always look for uncovered runs and extract them.
        #
        # For high-coverage lines (>85%), require longer minimum runs
        # to avoid extracting GPS drift as false branches.
        min_run = _MIN_BRANCH_RUN if ratio <= 0.85 else max(_MIN_BRANCH_RUN, 20)

        runs: list[tuple[int, int]] = []
        run_start: int | None = None

        for i in range(n):
            if not covered[i]:
                if run_start is None:
                    run_start = i
            else:
                if run_start is not None:
                    if i - run_start >= min_run:
                        runs.append((run_start, i - 1))
                    run_start = None

        if run_start is not None and n - run_start >= min_run:
            runs.append((run_start, n - 1))

        if not runs:
            continue

        for r_start, r_end in runs:
            # Branch validation: reject corridor variants (express/local
            # parallels) but keep genuine branches (diverging spurs).
            #
            # A run is a "corridor variant" if:
            #   1. Its start, middle, AND end are all near the existing
            #      grid (within ±200 m), AND
            #   2. Its heading does NOT diverge > 30° from the trunk at
            #      the branch point.
            #
            # If the run diverges in direction, it's a genuine branch
            # even if it runs nearby (e.g. Lefferts Blvd A train spur
            # parallel to Far Rockaway within 250 m).
            r_mid = (r_start + r_end) // 2
            run_len = r_end - r_start + 1
            all_near = (
                _is_near(*coords[r_start])
                and _is_near(*coords[r_mid])
                and _is_near(*coords[r_end])
            )
            if (
                all_near
                and run_len >= 20
                and not _run_diverges_from_trunk(coords, r_start, r_end, trunk_baseline)
            ):
                # Only reject as a corridor variant if the run is long
                # enough (≥ 20 vertices) to represent genuine parallel
                # express/local service.  Short near-runs (< 20 pts)
                # are more likely coverage gaps in the trunk grid —
                # e.g. the missing BDFM segment before 47-50 St
                # Rockefeller Center — and should be kept.
                continue  # corridor variant — skip

            # Extend into covered zone using distance-based approach.
            # Instead of a fixed ±5 vertices, keep extending along the
            # original shape as long as the actual distance to the trunk
            # baseline is > _BRANCH_MERGE_DIST_M.  This captures the
            # convergence zone where grid cells overlap but the physical
            # paths haven't merged yet (e.g. Lefferts running parallel
            # to Far Rockaway within grid proximity but 300-500m apart
            # at the station level).
            ext_start = r_start
            ext_end = r_end

            # Extend backward (toward-trunk direction at run start)
            extend_count = 0
            while ext_start > 0 and extend_count < _BRANCH_EXTEND_MAX:
                prev = ext_start - 1
                d = trunk_baseline.distance(Point(coords[prev]))
                if d < _BRANCH_MERGE_DIST_M:
                    break
                ext_start = prev
                extend_count += 1

            # Extend forward (toward-trunk direction at run end)
            extend_count = 0
            while ext_end < n - 1 and extend_count < _BRANCH_EXTEND_MAX:
                nxt = ext_end + 1
                d = trunk_baseline.distance(Point(coords[nxt]))
                if d < _BRANCH_MERGE_DIST_M:
                    break
                ext_end = nxt
                extend_count += 1

            # Always include a few trunk-overlap vertices at each end
            # so the stem injection has a clean junction point.
            ext_start = max(0, ext_start - 3)
            ext_end = min(n - 1, ext_end + 3)

            snap_limit_sq = _MAX_SNAP_DIST_M**2

            stub_coords: list[tuple[float, float]] = []
            for j in range(ext_start, ext_end + 1):
                if covered[j] and trunk_coords:
                    # In the extension zone, snap only the LAST few
                    # vertices (closest to trunk) to ensure a clean
                    # junction.  The rest use original branch coordinates
                    # to avoid zigzag bowties from trunk snapping.
                    if j <= ext_start + 2 or j >= ext_end - 2:
                        # Near the boundaries: distance-bounded snap
                        px, py = coords[j]
                        best_dist = float("inf")
                        best_pt: tuple[float, float] | None = None
                        for tx, ty in trunk_coords:
                            d = (tx - px) ** 2 + (ty - py) ** 2
                            if d < best_dist:
                                best_dist = d
                                best_pt = (tx, ty)
                        if best_pt is not None and best_dist <= snap_limit_sq:
                            stub_coords.append(best_pt)
                        else:
                            stub_coords.append(coords[j])
                    else:
                        # Interior covered vertices: use original branch
                        # coordinates to preserve the branch's actual path
                        stub_coords.append(coords[j])
                else:
                    stub_coords.append(coords[j])

            if len(stub_coords) >= 2:
                stub_line = LineString(stub_coords)
                if stub_line.length >= MIN_PATH_LENGTH:
                    # Validate: reject stubs with huge internal jumps
                    # that indicate a corrupted snap or bad geometry.
                    valid = _validate_stub(stub_coords)
                    if valid:
                        kept.append(stub_line)
                        _add_line(stub_line)

    # Inject trunk stems FIRST — each branch's junction endpoint is
    # connected to the baseline (or another already-connected branch)
    # before chain-merge runs.
    #
    # Critical ordering: if chain-merge runs first, it can join two
    # branch stubs (e.g. C + E) at their Manhattan junction endpoints,
    # creating a single long path whose terminal endpoints are both in
    # the outer boroughs — far from the baseline.  Stem injection then
    # fails because neither endpoint is close to anything connected.
    # By stemming first, each stub gets its junction wired to the
    # baseline individually.
    stemmed = _inject_trunk_stems(kept)

    # Chain-merge nearby endpoints for cleanup (naturally-connected
    # segments whose stems overlap or whose endpoints touch).
    merged = _chain_merge(stemmed, MERGE_GAP_M)

    # ── Safety net: remove self-intersecting loops ──
    # Stem injection + chain merge can create paths that cross themselves
    # (e.g. 7/7X express overlay near Hudson Yards).  Detect and cut loops
    # so exported polylines never contain visual backtracks.
    return _remove_self_intersections(merged)


def _remove_self_intersections(
    segments: list[LineString],
) -> list[LineString]:
    """Remove self-intersecting loops from polyline segments.

    A self-intersecting LineString has a portion that backtracks through
    previously-traversed territory, creating a visible loop.  This
    happens when ``_inject_trunk_stems`` prepends/appends trunk baseline
    in a direction antiparallel to the branch stub.

    Strategy: walk the coordinate list tracking visited grid cells.
    When a cell is revisited, the segment between the first and last
    visit is a candidate loop.  If the loop's net displacement is small
    relative to its arc length (i.e. it goes somewhere and comes back),
    cut it out.  Keep the longer non-looping portion.
    """
    result: list[LineString] = []

    for ls in segments:
        if ls.is_simple:
            result.append(ls)
            continue

        coords = list(ls.coords)
        if len(coords) < 4:
            result.append(ls)
            continue

        # Use a spatial grid to find where the path revisits itself.
        # Cell size ~100 m — fine enough to detect loops without false
        # positives from parallel tracks 200+ m apart.
        cell_size = 100.0

        def _cell(x: float, y: float, _cs: float = cell_size) -> tuple[int, int]:
            return (math.floor(x / _cs), math.floor(y / _cs))

        # Record first and last index that visits each cell
        first_visit: dict[tuple[int, int], int] = {}
        last_visit: dict[tuple[int, int], int] = {}
        for i, (x, y) in enumerate(coords):
            cell = _cell(x, y)
            if cell not in first_visit:
                first_visit[cell] = i
            last_visit[cell] = i

        # Find the widest revisit gap (longest loop)
        best_gap = 0
        loop_start = -1
        loop_end = -1
        n_coords = len(coords)
        for cell, fi in first_visit.items():
            li = last_visit[cell]
            gap = li - fi
            if gap > best_gap and gap >= 3:
                # Safety: never remove more than 40% of the path —
                # large "loops" are usually real route geometry
                # (e.g. M train's downtown loop, N/Q through lower
                # Manhattan) misidentified by the coarse grid.
                if gap > n_coords * 0.40:
                    continue
                # Verify it's a real loop: net displacement should be
                # small relative to the arc length of the gap.
                sx, sy = coords[fi]
                ex, ey = coords[li]
                net = math.sqrt((ex - sx) ** 2 + (ey - sy) ** 2)
                # Sum of segment lengths in the gap
                arc = 0.0
                for j in range(fi, li):
                    dx = coords[j + 1][0] - coords[j][0]
                    dy = coords[j + 1][1] - coords[j][1]
                    arc += math.sqrt(dx * dx + dy * dy)
                # A genuine loop has net displacement < 30% of arc length
                # Also cap at 5 km — anything longer is real track geometry
                if arc > 0 and net / arc < 0.30 and arc < 5000.0:
                    best_gap = gap
                    loop_start = fi
                    loop_end = li

        if loop_start >= 0 and loop_end > loop_start:
            # Cut the loop: keep [0..loop_start] + [loop_end..end]
            before = coords[: loop_start + 1]
            after = coords[loop_end:]
            cleaned = before + after
            TrackLogger.info(
                f"[SelfIntersect] Removed loop at indices "
                f"{loop_start}-{loop_end} ({loop_end - loop_start} vertices)"
            )
            if len(cleaned) >= 2:
                result.append(LineString(cleaned))
            else:
                result.append(ls)
        else:
            # No clear loop found — keep as-is
            result.append(ls)

    return result


def _inject_trunk_stems(
    segments: list[LineString],
) -> list[LineString]:
    """Ensure every branch stub visually connects to the trunk baseline.

    Branch stubs fork from the *middle* of the trunk path, so their
    endpoints are far from the trunk's endpoints.  MapLibre draws each
    polyline independently — without geometric overlap at the junction,
    branches appear as floating disconnected lines.

    **Iterative multi-target approach** (v2, 2026-03):
    Instead of only checking each branch against the baseline, we process
    branches nearest-first and check against ALL already-connected
    segments.  This builds a tree rather than a star — branches can
    connect through other branches, not just the root baseline.

    This is critical for trunk groups like A/C/E where the C and E
    branches diverge from the shared 8th Ave trunk but their extracted
    stubs might connect to each other or to an intermediate branch
    rather than directly to the A-train baseline.
    """
    if len(segments) <= 1:
        return segments

    # Build list of connected reference lines and pending branches.
    connected: list[LineString] = [segments[0]]  # baseline always connected
    pending: list[LineString] = []
    for seg in segments[1:]:
        if len(seg.coords) >= 2:
            pending.append(seg)

    def _find_best_anchor(
        pt: Point,
    ) -> tuple[LineString | None, float]:
        """Find the closest connected segment to a point."""
        best_line: LineString | None = None
        best_dist = float("inf")
        for ref in connected:
            d = ref.distance(pt)
            if d < best_dist:
                best_dist = d
                best_line = ref
        return best_line, best_dist

    def _should_inject(dist: float, pt: Point, anchor: LineString) -> bool:
        if dist < _STEM_SNAP_DIST_M:
            return True
        proj_pt = anchor.interpolate(anchor.project(pt))
        return pt.distance(proj_pt) < _STEM_PROJ_FALLBACK_M

    stems_injected = 0
    max_passes = len(pending) + 1  # safety bound

    for _pass in range(max_passes):
        if not pending:
            break

        # Sort pending by closest distance to ANY connected segment
        # (nearest-first processing builds the tree outward).
        scored: list[tuple[float, int, LineString]] = []
        for idx, stub in enumerate(pending):
            start_pt = Point(stub.coords[0])
            end_pt = Point(stub.coords[-1])
            _, d_start = _find_best_anchor(start_pt)
            _, d_end = _find_best_anchor(end_pt)
            scored.append((min(d_start, d_end), idx, stub))
        scored.sort(key=lambda t: t[0])

        made_progress = False
        still_pending: list[LineString] = []

        for _, _, stub in scored:
            stub_coords = list(stub.coords)
            start_pt = Point(stub_coords[0])
            end_pt = Point(stub_coords[-1])

            anchor_start, d_start = _find_best_anchor(start_pt)
            anchor_end, d_end = _find_best_anchor(end_pt)

            prepend_stem: list[tuple[float, float]] = []
            append_stem: list[tuple[float, float]] = []

            if anchor_start and _should_inject(d_start, start_pt, anchor_start):
                proj = anchor_start.project(start_pt)
                stem_begin = max(0.0, proj - _STEM_LENGTH_M)
                try:
                    seg = substring(anchor_start, stem_begin, proj)
                    seg_coords = list(seg.coords)
                    if len(seg_coords) >= 2:
                        snap_pt = anchor_start.interpolate(proj)
                        stub_coords[0] = (snap_pt.x, snap_pt.y)
                        # ── Backtrack guard ──
                        # Check if the stem direction at the junction is
                        # compatible with the stub direction.  If antiparallel
                        # (dot < 0), the path would U-turn → try the other
                        # direction along the anchor.
                        if len(stub_coords) >= 2 and len(seg_coords) >= 2:
                            stem_dx = seg_coords[-1][0] - seg_coords[-2][0]
                            stem_dy = seg_coords[-1][1] - seg_coords[-2][1]
                            stub_dx = stub_coords[1][0] - stub_coords[0][0]
                            stub_dy = stub_coords[1][1] - stub_coords[0][1]
                            dot = stem_dx * stub_dx + stem_dy * stub_dy
                            if dot < 0:
                                # Antiparallel → try stem in other direction
                                stem_end_alt = min(
                                    anchor_start.length, proj + _STEM_LENGTH_M
                                )
                                if stem_end_alt - proj > 50.0:
                                    seg_alt = substring(
                                        anchor_start, proj, stem_end_alt
                                    )
                                    alt_coords = list(reversed(seg_alt.coords))
                                    if len(alt_coords) >= 2:
                                        seg_coords = alt_coords
                                else:
                                    seg_coords = []  # skip stem
                        if seg_coords and len(seg_coords) >= 2:
                            prepend_stem = seg_coords
                        # else: skip — stem would create a backtrack
                except Exception as exc:
                    TrackLogger.warning(f"[BranchStem] Prepend failed: {exc}")

            if anchor_end and _should_inject(d_end, end_pt, anchor_end):
                proj = anchor_end.project(end_pt)
                stem_finish = min(anchor_end.length, proj + _STEM_LENGTH_M)
                try:
                    seg = substring(anchor_end, proj, stem_finish)
                    seg_coords = list(seg.coords)
                    if len(seg_coords) >= 2:
                        snap_pt = anchor_end.interpolate(proj)
                        stub_coords[-1] = (snap_pt.x, snap_pt.y)
                        # ── Backtrack guard (append side) ──
                        if len(stub_coords) >= 2 and len(seg_coords) >= 2:
                            stub_dx = stub_coords[-1][0] - stub_coords[-2][0]
                            stub_dy = stub_coords[-1][1] - stub_coords[-2][1]
                            stem_dx = seg_coords[1][0] - seg_coords[0][0]
                            stem_dy = seg_coords[1][1] - seg_coords[0][1]
                            dot = stub_dx * stem_dx + stub_dy * stem_dy
                            if dot < 0:
                                # Antiparallel → try stem in other direction
                                stem_begin_alt = max(0.0, proj - _STEM_LENGTH_M)
                                if proj - stem_begin_alt > 50.0:
                                    seg_alt = substring(
                                        anchor_end, stem_begin_alt, proj
                                    )
                                    alt_coords = list(reversed(seg_alt.coords))
                                    if len(alt_coords) >= 2:
                                        seg_coords = alt_coords
                                else:
                                    seg_coords = []  # skip stem
                        if seg_coords and len(seg_coords) >= 2:
                            append_stem = seg_coords
                        # else: skip — stem would create a backtrack
                except Exception as exc:
                    TrackLogger.warning(f"[BranchStem] Append failed: {exc}")

            # Build the connected branch
            final_coords = prepend_stem + stub_coords + append_stem

            # Remove near-duplicate consecutive vertices from splicing
            deduped: list[tuple[float, float]] = [final_coords[0]]
            for c in final_coords[1:]:
                if _point_dist(deduped[-1], c) > 2.0:
                    deduped.append(c)

            if prepend_stem or append_stem:
                stems_injected += 1
                made_progress = True
                if len(deduped) >= 2:
                    new_line = LineString(deduped)
                    connected.append(new_line)
                else:
                    connected.append(stub)
            else:
                # ── Interior-crossing detection ──
                # When NEITHER endpoint is near a connected segment, the
                # path may still cross through the baseline in its interior
                # (e.g. the merged C+E stub traverses the 8th Ave trunk
                # in Midtown while both endpoints are in the outer
                # boroughs).  Find the closest interior vertex and split.
                best_interior_d = float("inf")
                best_interior_idx = -1
                best_interior_anchor: LineString | None = None
                for vi in range(1, len(stub_coords) - 1):
                    vpt = Point(stub_coords[vi])
                    for ref in connected:
                        d = ref.distance(vpt)
                        if d < best_interior_d:
                            best_interior_d = d
                            best_interior_idx = vi
                            best_interior_anchor = ref

                if (
                    best_interior_anchor is not None
                    and best_interior_d < _STEM_SNAP_DIST_M
                ):
                    # Split into two halves at the interior crossing
                    split_pt = Point(stub_coords[best_interior_idx])
                    proj = best_interior_anchor.project(split_pt)
                    snap_pt = best_interior_anchor.interpolate(proj)
                    snap_coord = (snap_pt.x, snap_pt.y)

                    half_a = stub_coords[: best_interior_idx + 1]
                    half_b = stub_coords[best_interior_idx:]
                    # Snap the split vertex to the baseline projection
                    half_a[-1] = snap_coord
                    half_b[0] = snap_coord

                    # Create short stem segments at the split point
                    stem_before = max(0.0, proj - _STEM_LENGTH_M)
                    stem_after = min(best_interior_anchor.length, proj + _STEM_LENGTH_M)

                    for half in (half_a, half_b):
                        if len(half) < 2:
                            continue
                        # Determine which end is the split end
                        # (first vertex of half_b, last vertex of half_a)
                        h_prepend: list[tuple[float, float]] = []
                        h_append: list[tuple[float, float]] = []
                        try:
                            if half is half_a:
                                seg = substring(best_interior_anchor, proj, stem_after)
                                seg_c = list(seg.coords)
                                if len(seg_c) >= 2:
                                    h_append = seg_c
                            else:
                                seg = substring(best_interior_anchor, stem_before, proj)
                                seg_c = list(seg.coords)
                                if len(seg_c) >= 2:
                                    h_prepend = seg_c
                        except Exception:
                            pass

                        final = h_prepend + half + h_append
                        dd: list[tuple[float, float]] = [final[0]]
                        for c in final[1:]:
                            if _point_dist(dd[-1], c) > 2.0:
                                dd.append(c)
                        if len(dd) >= 2:
                            connected.append(LineString(dd))

                    stems_injected += 1
                    made_progress = True
                else:
                    # Truly disconnected — keep for next iteration
                    still_pending.append(stub)

        pending = still_pending
        if not made_progress:
            break  # no new connections, stop iterating

    # Any remaining disconnected stubs are kept as-is (their geometry
    # is still valid, just not visually joined to the trunk).
    if pending:
        TrackLogger.warning(
            f"[BranchStem] {len(pending)} branch stubs remain disconnected"
        )
        connected.extend(pending)

    if stems_injected:
        TrackLogger.info(
            f"[BranchStem] Injected trunk stems for {stems_injected}/{len(segments)-1} branch stubs"
        )

    return connected


def _validate_stub(coords: list[tuple[float, float]]) -> bool:
    """Reject branch stubs that contain implausibly large jumps.

    A jump > _MAX_STUB_GAP_M between consecutive vertices indicates that
    the snap-to-trunk created a teleport or the raw GTFS geometry has a
    water crossing / tunnel leap that shouldn't appear as a stub.
    """
    for i in range(1, len(coords)):
        dx = coords[i][0] - coords[i - 1][0]
        dy = coords[i][1] - coords[i - 1][1]
        if dx * dx + dy * dy > _MAX_STUB_GAP_M**2:
            return False
    return True


def _chain_merge(
    segments: list[LineString],
    tolerance: float,
) -> list[LineString]:
    """Greedy endpoint-proximity merge of LineString fragments."""
    if len(segments) <= 1:
        return list(segments)

    chains: list[list[tuple[float, float]]] = [
        list(s.coords) for s in segments if len(s.coords) >= 2
    ]

    changed = True
    while changed:
        changed = False
        i = 0
        while i < len(chains):
            j = i + 1
            while j < len(chains):
                merged = _try_join(chains[i], chains[j], tolerance)
                if merged is not None:
                    chains[i] = merged
                    chains.pop(j)
                    changed = True
                else:
                    j += 1
            i += 1

    return [LineString(c) for c in chains if len(c) >= 2]


def _try_join(
    a: list[tuple[float, float]],
    b: list[tuple[float, float]],
    tol: float,
) -> list[tuple[float, float]] | None:
    """Try to join two coordinate lists via their endpoints."""
    if _point_dist(a[-1], b[0]) <= tol:
        return a + b[1:]
    if _point_dist(a[-1], b[-1]) <= tol:
        return a + list(reversed(b))[1:]
    if _point_dist(a[0], b[-1]) <= tol:
        return b + a[1:]
    if _point_dist(a[0], b[0]) <= tol:
        return list(reversed(b)) + a[1:]
    return None


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2 — Corridor Detection & Per-Vertex Offset Computation
# ═══════════════════════════════════════════════════════════════════════════════


class _TrunkPathInfo(NamedTuple):
    trunk_idx: int
    path_idx: int
    path: LineString


class _NeighborObservation(NamedTuple):
    trunk_idx: int
    distance: float
    signed_lateral: float


def _collect_neighbor_observations(
    pt: Point,
    dir_i: tuple[float, float],
    trunk_idx: int,
    tree: STRtree,
    all_infos: list[_TrunkPathInfo],
) -> dict[int, _NeighborObservation]:
    """Collect best nearby corridor candidates for a single vertex.

    Returns one observation per neighboring trunk, keeping the closest
    matching path fragment and the signed lateral displacement of that
    fragment relative to the current path direction.
    """
    observations: dict[int, _NeighborObservation] = {}
    left_normal = (-dir_i[1], dir_i[0])

    candidate_indices = tree.query(pt.buffer(CORRIDOR_DETECT_DIST))
    for ci in candidate_indices:
        info = all_infos[ci]
        if info.trunk_idx == trunk_idx:
            continue

        dist_to_path = info.path.distance(pt)
        if dist_to_path >= CORRIDOR_DETECT_DIST:
            continue

        proj = info.path.project(pt)
        dir_j = _direction_at_distance(info.path, proj)
        dot = abs(dir_i[0] * dir_j[0] + dir_i[1] * dir_j[1])
        if dot < CORRIDOR_ALIGN_MIN:
            continue

        nearest = info.path.interpolate(proj)
        vx = nearest.x - pt.x
        vy = nearest.y - pt.y
        signed_lateral = vx * left_normal[0] + vy * left_normal[1]

        best = observations.get(info.trunk_idx)
        if (
            best is None
            or dist_to_path < best.distance
            or (
                abs(dist_to_path - best.distance) < 1e-6
                and abs(signed_lateral) > abs(best.signed_lateral)
            )
        ):
            observations[info.trunk_idx] = _NeighborObservation(
                trunk_idx=info.trunk_idx,
                distance=dist_to_path,
                signed_lateral=signed_lateral,
            )

    return observations


def _compute_lane_order_preferences(
    validated_neighbors: dict[
        int, dict[int, dict[int, dict[int, _NeighborObservation]]]
    ],
) -> dict[int, dict[int, float]]:
    """Aggregate pairwise left/right preferences from corridor observations."""
    pairwise: defaultdict[int, defaultdict[int, float]] = defaultdict(
        lambda: defaultdict(float)
    )
    evidence_count = 0

    for trunk_idx, path_data in validated_neighbors.items():
        for vertex_data in path_data.values():
            for neighbors in vertex_data.values():
                for neighbor_idx, observation in neighbors.items():
                    signed = observation.signed_lateral
                    if abs(signed) < LANE_ORDER_SIGNIFICANCE:
                        continue

                    # Reward clearer geometric separation a bit more than
                    # barely-above-threshold votes, but keep all weights in
                    # the same rough range so long corridors dominate.
                    weight = (
                        1.0
                        + min(abs(signed), CORRIDOR_DETECT_DIST) / CORRIDOR_DETECT_DIST
                    )
                    if signed > 0.0:
                        pairwise[neighbor_idx][trunk_idx] += weight
                    else:
                        pairwise[trunk_idx][neighbor_idx] += weight
                    evidence_count += 1

    if evidence_count:
        TrackLogger.info(
            f"[LaneOrder] Collected {evidence_count} pairwise side observations"
        )

    return {trunk: dict(targets) for trunk, targets in pairwise.items()}


def _compute_lane_order_scores(
    pairwise_preferences: dict[int, dict[int, float]],
    trunks: set[int] | None = None,
) -> dict[int, float]:
    """Collapse pairwise preferences into a deterministic global left/right score."""
    members = set(trunks or ())
    members.update(pairwise_preferences.keys())
    for targets in pairwise_preferences.values():
        members.update(targets.keys())

    scores: dict[int, float] = {}
    for trunk_idx in members:
        left_votes = sum(pairwise_preferences.get(trunk_idx, {}).values())
        right_votes = 0.0
        for targets in pairwise_preferences.values():
            right_votes += targets.get(trunk_idx, 0.0)
        scores[trunk_idx] = left_votes - right_votes

    return scores


def _lane_order_penalty(
    order: tuple[int, ...],
    pairwise_preferences: dict[int, dict[int, float]],
) -> float:
    """Penalty for a candidate left→right order.

    Any preference saying "B should be left of A" becomes a penalty if the
    candidate order places A before B.
    """
    penalty = 0.0
    for idx, left_trunk in enumerate(order):
        for right_trunk in order[idx + 1 :]:
            penalty += pairwise_preferences.get(right_trunk, {}).get(left_trunk, 0.0)
    return penalty


def _solve_lane_order(
    trunks: set[int],
    pairwise_preferences: dict[int, dict[int, float]],
    global_scores: dict[int, float],
    cache: dict[tuple[int, ...], tuple[int, ...]] | None = None,
) -> tuple[int, ...]:
    """Find the best deterministic left→right order for a shared corridor set."""
    key = tuple(sorted(trunks))
    if cache is not None and key in cache:
        return cache[key]

    if len(key) <= 1:
        if cache is not None:
            cache[key] = key
        return key

    baseline = tuple(sorted(key, key=lambda t: (-global_scores.get(t, 0.0), t)))
    if len(key) > MAX_LANE_ORDER_SOLVER_SIZE:
        if cache is not None:
            cache[key] = baseline
        return baseline

    baseline_rank = {trunk_idx: idx for idx, trunk_idx in enumerate(baseline)}
    best_order = baseline
    best_penalty = _lane_order_penalty(best_order, pairwise_preferences)
    best_deviation = 0

    for perm in permutations(baseline):
        penalty = _lane_order_penalty(perm, pairwise_preferences)
        deviation = sum(
            abs(idx - baseline_rank[trunk_idx]) for idx, trunk_idx in enumerate(perm)
        )

        if penalty < best_penalty - 1e-6:
            best_order = perm
            best_penalty = penalty
            best_deviation = deviation
            continue

        if abs(penalty - best_penalty) <= 1e-6 and (
            deviation < best_deviation
            or (deviation == best_deviation and perm < best_order)
        ):
            best_order = perm
            best_deviation = deviation

    if cache is not None:
        cache[key] = best_order
    return best_order


def _compute_corridor_offsets(
    trunk_paths: dict[int, list[LineString]],
) -> dict[int, dict[int, list[float]]]:
    """Detect shared corridors and compute per-vertex perpendicular offsets.

    Also populates ``_corridor_neighbors_cache`` — a dict mapping each
    trunk index to the set of trunk indices it shares a corridor with.

    Algorithm:
    1. Index all trunk paths in a spatial tree.
    2. For each vertex of each trunk path, query the tree for nearby paths
       from *other* trunk groups.
    3. If another trunk path is within CORRIDOR_DETECT_DIST and running in the
       same direction (alignment > 0.707), this vertex is in a shared corridor.
    4. Use locally-validated side-of-track evidence to solve a stable
       left→right lane order for each shared corridor set.
    5. Compute offset = (lane − centre) × LANE_WIDTH.
    6. Smooth the per-vertex offsets with a moving-average window to eliminate
       jitter from marginal proximity detections.

    Returns: dict[trunk_idx → dict[path_idx → list[float per vertex]]].
    """
    # Build flat list + spatial index
    all_infos: list[_TrunkPathInfo] = []
    all_geoms: list[LineString] = []
    for trunk_idx, paths in trunk_paths.items():
        for path_idx, path in enumerate(paths):
            all_infos.append(_TrunkPathInfo(trunk_idx, path_idx, path))
            all_geoms.append(path)

    if not all_geoms:
        return {}

    tree = STRtree(all_geoms)

    # Reset corridor-neighbor graph — rebuilt below from validated detections.
    global _corridor_neighbors_cache
    _corridor_neighbors_cache = {}

    validated_neighbors: dict[
        int, dict[int, dict[int, dict[int, _NeighborObservation]]]
    ] = {}
    path_lengths: dict[int, dict[int, int]] = {}

    # Pass 1: detect nearby trunks and keep the best lateral observation
    # for each neighboring trunk at each vertex.
    for trunk_idx, paths in trunk_paths.items():
        per_path_validated: dict[int, dict[int, dict[int, _NeighborObservation]]] = {}
        per_path_lengths: dict[int, int] = {}

        for path_idx, path in enumerate(paths):
            coords = list(path.coords)
            n = len(coords)
            per_path_lengths[path_idx] = n
            per_vertex_neighbors: dict[int, dict[int, _NeighborObservation]] = {}

            for i in range(n):
                pt = Point(coords[i])
                dir_i = _local_direction(coords, i)
                observations = _collect_neighbor_observations(
                    pt=pt,
                    dir_i=dir_i,
                    trunk_idx=trunk_idx,
                    tree=tree,
                    all_infos=all_infos,
                )
                if observations:
                    per_vertex_neighbors[i] = observations

            # Local density filter: only keep neighbors that are present in
            # enough nearby vertices to represent a real shared corridor.
            LOCAL_WINDOW = 60
            LOCAL_MIN_HITS = 8

            detected_trunks_all: set[int] = set()
            for vneighbors in per_vertex_neighbors.values():
                detected_trunks_all.update(vneighbors.keys())

            trunk_local_valid: dict[int, list[bool]] = {}
            for neighbor_trunk in detected_trunks_all:
                detections = [
                    neighbor_trunk in per_vertex_neighbors.get(i, {}) for i in range(n)
                ]

                half = LOCAL_WINDOW // 2
                valid = [False] * n
                win_sum = sum(1 for d in detections[: min(half, n)] if d)
                for i in range(n):
                    right = i + half
                    if right < n and detections[right]:
                        win_sum += 1
                    left = i - half - 1
                    if left >= 0 and detections[left]:
                        win_sum -= 1
                    if win_sum >= LOCAL_MIN_HITS:
                        valid[i] = True

                trunk_local_valid[neighbor_trunk] = valid

            validated_vertex_neighbors: dict[int, dict[int, _NeighborObservation]] = {}
            for i, neighbors in per_vertex_neighbors.items():
                filtered_neighbors = {
                    neighbor_trunk: observation
                    for neighbor_trunk, observation in neighbors.items()
                    if trunk_local_valid.get(neighbor_trunk, [False] * n)[i]
                }
                if filtered_neighbors:
                    validated_vertex_neighbors[i] = filtered_neighbors

            per_path_validated[path_idx] = validated_vertex_neighbors

        validated_neighbors[trunk_idx] = per_path_validated
        path_lengths[trunk_idx] = per_path_lengths

    pairwise_preferences = _compute_lane_order_preferences(validated_neighbors)
    global_scores = _compute_lane_order_scores(
        pairwise_preferences,
        set(trunk_paths.keys()),
    )
    lane_order_cache: dict[tuple[int, ...], tuple[int, ...]] = {}

    results: dict[int, dict[int, list[float]]] = {}

    # Pass 2: solve per-corridor lane orders and assign per-vertex offsets.
    for trunk_idx, paths in trunk_paths.items():
        path_offsets: dict[int, list[float]] = {}

        for path_idx, path in enumerate(paths):
            n = path_lengths.get(trunk_idx, {}).get(path_idx, len(path.coords))
            raw_offsets: list[float] = [0.0] * n
            vertex_neighbors = validated_neighbors.get(trunk_idx, {}).get(path_idx, {})

            for i, neighbors in vertex_neighbors.items():
                corridor_trunks = set(neighbors.keys())
                if not corridor_trunks:
                    continue

                # Track corridor neighbor relationships (bidirectional)
                _corridor_neighbors_cache.setdefault(trunk_idx, set()).update(
                    corridor_trunks
                )
                for ft in corridor_trunks:
                    _corridor_neighbors_cache.setdefault(ft, set()).add(trunk_idx)

                ordered_trunks = _solve_lane_order(
                    corridor_trunks | {trunk_idx},
                    pairwise_preferences,
                    global_scores,
                    cache=lane_order_cache,
                )
                lane = ordered_trunks.index(trunk_idx)
                n_lanes = len(ordered_trunks)
                centre = (n_lanes - 1) / 2.0
                raw_offsets[i] = (lane - centre) * LANE_WIDTH

            # Smooth offset transitions
            filled = _fill_corridor_gaps(raw_offsets)
            path_offsets[path_idx] = _smooth_offsets(filled)

        results[trunk_idx] = path_offsets

    if lane_order_cache:
        TrackLogger.info(
            f"[LaneOrder] Solved {len(lane_order_cache)} shared corridor order sets"
        )

    # Log summary
    corridors_found = 0
    for _t, pd in results.items():
        for _, offs in pd.items():
            if any(abs(o) > 0.01 for o in offs):
                corridors_found += 1
    TrackLogger.info(
        f"[Corridor] Detected corridors in {corridors_found} trunk-path segments "
        f"across {len(results)} trunk groups"
    )

    return results


def _fill_corridor_gaps(raw: list[float]) -> list[float]:
    """Close short zero-offset gaps inside corridors.

    When per-vertex proximity/alignment checks miss a handful of consecutive
    vertices inside what is clearly a continuous shared corridor, this
    function fills those gaps with linearly-interpolated offsets so the
    parallel lines don't snap back together for a few metres then separate
    again.

    Only gaps of `CORRIDOR_GAP_MAX` or fewer consecutive zero-offset
    vertices that lie BETWEEN two non-zero-offset runs are filled.
    """
    n = len(raw)
    if n < 3:
        return list(raw)

    result = list(raw)

    # Identify runs of zero and non-zero offsets
    i = 0
    while i < n:
        # Skip non-zero run
        if abs(raw[i]) > 0.01:
            i += 1
            continue

        # Start of a zero run
        gap_start = i
        while i < n and abs(raw[i]) <= 0.01:
            i += 1
        gap_end = i  # exclusive

        gap_len = gap_end - gap_start

        # Only fill if gap is short and bordered by non-zero offsets
        if gap_len > CORRIDOR_GAP_MAX:
            continue
        if gap_start == 0 or gap_end >= n:
            continue

        left_val = raw[gap_start - 1]
        right_val = raw[gap_end]

        # Only fill if the bordering offsets have the same sign
        # (= same corridor context, not a corridor transition)
        if left_val * right_val <= 0:
            continue

        # Cosine interpolation across the gap (smoother entry/exit
        # than linear — eliminates abrupt lateral velocity changes)
        for j in range(gap_start, gap_end):
            t = (j - gap_start + 1) / (gap_len + 1)
            s = (1.0 - math.cos(t * math.pi)) / 2.0
            result[j] = left_val * (1.0 - s) + right_val * s

    return result


def _smooth_offsets(raw: list[float]) -> list[float]:
    """Moving-average smooth of per-vertex offsets.

    Preserves the first and last values.  Eliminates jitter from marginal
    proximity detections at corridor boundaries.
    """
    n = len(raw)
    if n <= BLEND_WINDOW * 2:
        return list(raw)

    smoothed = list(raw)
    half = BLEND_WINDOW // 2

    for i in range(half, n - half):
        total = 0.0
        for k in range(i - half, i + half + 1):
            total += raw[k]
        smoothed[i] = total / (half * 2 + 1)

    return smoothed


# ═══════════════════════════════════════════════════════════════════════════════
# WGS-84 Junction-Aware Fillet  (exported polyline smoothing)
#
# Replaces sharp vertices in WGS84, degree-space polylines with circular arc
# segments.  Matches the iOS circularArcFillet() algorithm exactly so the
# backend-produced smoothing is pixel-identical to what the client used to do.
#
# Applied to trunk export polylines AFTER project_to_wgs84() and BEFORE
# encode_polyline() — the client can then skip all geometry processing and
# just render.
# ═══════════════════════════════════════════════════════════════════════════════


def _remove_near_duplicates_wgs84(
    coords: list[tuple[float, float]],
    min_spacing: float = 0.00004,
) -> list[tuple[float, float]]:
    """Remove near-duplicate points (micro-clusters from station-snap).

    Works in WGS84 degree space.  Coords are (lat, lon) tuples.
    """
    if len(coords) < 2:
        return list(coords)
    result = [coords[0]]
    for i in range(1, len(coords)):
        dlat = coords[i][0] - result[-1][0]
        dlon = coords[i][1] - result[-1][1]
        if math.sqrt(dlat * dlat + dlon * dlon) >= min_spacing:
            result.append(coords[i])
    # Always keep the last point
    if len(result) >= 2 and result[-1] != coords[-1]:
        result.append(coords[-1])
    elif len(result) < 2:
        return list(coords)
    return result


def _junction_fillet_wgs84(
    coords: list[tuple[float, float]],
    lane_offset: float = 0.0,
    angle_threshold: float = 10.0,
    base_radius_deg: float = 0.00045,
    scale_factor: float = 0.00030,
    arc_points: int = 16,
) -> list[tuple[float, float]]:
    """Apply circular-arc fillet to vertices with sharp turns.

    Port of the iOS ``junctionAwareFillet`` + ``circularArcFillet`` functions.
    Works in WGS84 degree space.  Coords are (lat, lon) tuples where
    lat ↔ y-axis and lon ↔ x-axis.

    Parameters match the iOS call-site defaults used in
    ``computeFlattenedPolylinesAsync()``.
    """
    if len(coords) < 3:
        return list(coords)

    n = len(coords)
    cos_threshold = math.cos(math.radians(angle_threshold))
    R = max(base_radius_deg, abs(lane_offset) * scale_factor)

    # ── Pass 1: ideal tangent distance for every interior vertex ──
    edge_len = [0.0] * (n - 1)
    for i in range(n - 1):
        dx = coords[i + 1][1] - coords[i][1]  # longitude (x)
        dy = coords[i + 1][0] - coords[i][0]  # latitude  (y)
        edge_len[i] = math.sqrt(dx * dx + dy * dy)

    tangent_dist = [0.0] * n
    tan_half = [0.0] * n
    needs_fillet = [False] * n

    for i in range(1, n - 1):
        len1, len2 = edge_len[i - 1], edge_len[i]
        if len1 < 1e-10 or len2 < 1e-10:
            continue

        prev, curr, nxt = coords[i - 1], coords[i], coords[i + 1]
        dx1 = curr[1] - prev[1]
        dy1 = curr[0] - prev[0]
        dx2 = nxt[1] - curr[1]
        dy2 = nxt[0] - curr[0]

        dot = (dx1 * dx2 + dy1 * dy2) / (len1 * len2)
        if dot > cos_threshold:
            continue

        clamped_dot = max(-0.9999, min(0.9999, dot))
        turn_angle = math.acos(clamped_dot)
        half_angle = (math.pi - turn_angle) / 2.0
        if half_angle < 1e-6:
            continue

        th = math.tan(half_angle)
        if th < 1e-10:
            continue

        ideal_dist = R / th
        solo_clamped = min(ideal_dist, 0.40 * min(len1, len2))
        tangent_dist[i] = solo_clamped
        tan_half[i] = th
        needs_fillet[i] = True

    # ── Pass 1.5: budget adjacent fillets so they never overlap ──
    for e in range(n - 1):
        want_left = tangent_dist[e] if needs_fillet[e] else 0.0
        want_right = tangent_dist[e + 1] if needs_fillet[e + 1] else 0.0
        total = want_left + want_right
        if total <= edge_len[e] * 0.90:
            continue
        budget = edge_len[e] * 0.90
        scale = budget / total if total > 0 else 0.0
        if needs_fillet[e]:
            tangent_dist[e] = want_left * scale
        if needs_fillet[e + 1]:
            tangent_dist[e + 1] = want_right * scale

    # ── Pass 2: emit arc geometry ──
    result: list[tuple[float, float]] = [coords[0]]

    for i in range(1, n - 1):
        if not needs_fillet[i]:
            result.append(coords[i])
            continue

        prev, curr, nxt = coords[i - 1], coords[i], coords[i + 1]
        # x = longitude (index 1), y = latitude (index 0)
        dx1 = curr[1] - prev[1]
        dy1 = curr[0] - prev[0]
        dx2 = nxt[1] - curr[1]
        dy2 = nxt[0] - curr[0]

        len1 = edge_len[i - 1]
        len2 = edge_len[i]

        budgeted_dist = tangent_dist[i]
        effective_r = budgeted_dist * tan_half[i]

        if effective_r < 1e-10 or budgeted_dist < 1e-10:
            result.append(curr)
            continue

        u1x = dx1 / len1
        u1y = dy1 / len1
        u2x = dx2 / len2
        u2y = dy2 / len2

        # Tangent points A, D
        a_lon = curr[1] - u1x * budgeted_dist
        a_lat = curr[0] - u1y * budgeted_dist
        d_lon = curr[1] + u2x * budgeted_dist
        d_lat = curr[0] + u2y * budgeted_dist

        cross = u1x * u2y - u1y * u2x

        if cross > 0:
            perp_x, perp_y = -u1y, u1x
        else:
            perp_x, perp_y = u1y, -u1x

        c_lon = a_lon + perp_x * effective_r
        c_lat = a_lat + perp_y * effective_r

        start_angle = math.atan2(a_lat - c_lat, a_lon - c_lon)
        end_angle = math.atan2(d_lat - c_lat, d_lon - c_lon)

        sweep = end_angle - start_angle
        if cross > 0:
            if sweep > 0:
                sweep -= 2.0 * math.pi
        else:
            if sweep < 0:
                sweep += 2.0 * math.pi

        # Safety: skip arcs that sweep > 180° (near-reversal)
        if abs(sweep) > math.pi:
            result.append(curr)
            continue

        for step in range(arc_points + 1):
            t = step / arc_points
            angle = start_angle + t * sweep
            p_lon = c_lon + effective_r * math.cos(angle)
            p_lat = c_lat + effective_r * math.sin(angle)
            result.append((p_lat, p_lon))

    result.append(coords[-1])
    return result


# ═══════════════════════════════════════════════════════════════════════════════
# Trunk Crossing Detection
#
# Detects where polylines from different trunk groups physically cross
# (not run parallel in corridors).  Crossing points are exported so the
# client can render casing breaks — making it visually clear which line
# passes over which at intersections.
# ═══════════════════════════════════════════════════════════════════════════════


def _crossing_angle_at(
    path_a: LineString,
    path_b: LineString,
    point,
    epsilon: float = 15.0,
) -> float:
    """Compute crossing angle (0–90°) between two paths at an intersection point."""

    dist_a = path_a.project(point)
    p_a1 = path_a.interpolate(max(0, dist_a - epsilon))
    p_a2 = path_a.interpolate(min(path_a.length, dist_a + epsilon))

    dist_b = path_b.project(point)
    p_b1 = path_b.interpolate(max(0, dist_b - epsilon))
    p_b2 = path_b.interpolate(min(path_b.length, dist_b + epsilon))

    dx_a = p_a2.x - p_a1.x
    dy_a = p_a2.y - p_a1.y
    dx_b = p_b2.x - p_b1.x
    dy_b = p_b2.y - p_b1.y

    len_a = math.sqrt(dx_a**2 + dy_a**2)
    len_b = math.sqrt(dx_b**2 + dy_b**2)
    if len_a < 1e-6 or len_b < 1e-6:
        return 0.0

    dot = (dx_a * dx_b + dy_a * dy_b) / (len_a * len_b)
    angle_rad = math.acos(min(1.0, max(-1.0, abs(dot))))
    return math.degrees(angle_rad)


def _detect_trunk_crossings(
    min_crossing_angle: float = 25.0,
) -> list[dict]:
    """Detect crossing points between different trunk groups.

    Uses projected meter-space LineStrings from the pipeline cache.
    Returns a list of dicts:
      [{"lat": float, "lng": float, "trunk_indices": [int, int]}, ...]

    Only includes crossings where the angle between the two polylines
    exceeds *min_crossing_angle* degrees — filtering out near-parallel
    corridor overlaps.
    """
    from shapely.geometry import MultiPoint as _MPt
    from shapely.geometry import Point as _Pt

    raw_paths = _trunk_raw_paths_cache
    if not raw_paths:
        return []

    trunk_indices = sorted(raw_paths.keys())
    crossings: list[dict] = []
    seen_cells: set[tuple[int, int, int]] = set()  # (ti, tj, grid_cell) dedup

    for i_pos, ti in enumerate(trunk_indices):
        for tj in trunk_indices[i_pos + 1 :]:
            for path_i in raw_paths[ti]:
                for path_j in raw_paths[tj]:
                    try:
                        ix = path_i.intersection(path_j)
                    except Exception:
                        continue

                    if ix.is_empty:
                        continue

                    # Only Point / MultiPoint — LineString means parallel overlap
                    if isinstance(ix, _Pt):
                        pts = [ix]
                    elif isinstance(ix, _MPt):
                        pts = list(ix.geoms)
                    else:
                        continue

                    for pt in pts:
                        # Grid-cell dedup (~100 m granularity)
                        cell = (ti, tj, int(pt.x // 100) * 10000 + int(pt.y // 100))
                        if cell in seen_cells:
                            continue
                        seen_cells.add(cell)

                        angle = _crossing_angle_at(path_i, path_j, pt)
                        if angle < min_crossing_angle:
                            continue

                        wgs_pt = project_to_wgs84([(pt.x, pt.y)])[0]
                        crossings.append(
                            {
                                "lat": round(wgs_pt[0], 6),
                                "lng": round(wgs_pt[1], 6),
                                "trunk_indices": sorted([ti, tj]),
                            }
                        )

    TrackLogger.info(f"[Crossings] Detected {len(crossings)} trunk crossing points")
    return crossings


# ═══════════════════════════════════════════════════════════════════════════════
# Arc-Based Offset Engine (v3.2)
#
# Transit-app-quality parallel lines: circular arc segments at every bend
# maintain constant perpendicular distance from the reference path.
#
# Pipeline:  densify → arc-offset → despike → RDP-simplify
# ═══════════════════════════════════════════════════════════════════════════════


def _densify_with_offsets(
    coords: list[tuple[float, float]],
    offsets: list[float],
    max_spacing: float = DENSIFY_MAX_SPACING,
) -> tuple[list[tuple[float, float]], list[float]]:
    """Subdivide long segments, linearly interpolating offsets for new vertices.

    Denser vertices produce smoother arc-based offsets at curves.  Without
    densification, a single 200 m segment turning 30° would get ONE arc
    point; after densification into 13 × 15 m segments, the same curve
    gets 13 gently-angled arc points.
    """
    if len(coords) < 2:
        return list(coords), list(offsets)

    result_c: list[tuple[float, float]] = [coords[0]]
    result_o: list[float] = [offsets[0] if offsets else 0.0]

    for i in range(1, len(coords)):
        prev_c = coords[i - 1]
        curr_c = coords[i]
        prev_o = offsets[i - 1] if i - 1 < len(offsets) else 0.0
        curr_o = offsets[i] if i < len(offsets) else 0.0

        dist = _point_dist(prev_c, curr_c)

        if dist > max_spacing:
            n_sub = math.ceil(dist / max_spacing)
            for j in range(1, n_sub):
                t = j / n_sub
                result_c.append(
                    (
                        prev_c[0] + t * (curr_c[0] - prev_c[0]),
                        prev_c[1] + t * (curr_c[1] - prev_c[1]),
                    )
                )
                result_o.append(prev_o + t * (curr_o - prev_o))

        result_c.append(curr_c)
        result_o.append(curr_o)

    return result_c, result_o


def _apply_arc_offset(
    coords: list[tuple[float, float]],
    offsets: list[float],
) -> list[tuple[float, float]]:
    """Offset each vertex with circular arc interpolation at bends.

    Unlike miter joins (which squeeze parallel lines together at acute
    angles and need clamping), this inserts circular arc segments at
    turning points to maintain constant perpendicular distance from the
    original path.

    On the OUTSIDE of a curve, the offset path is longer — arc points
    fill in the extra distance.  On the INSIDE, a clamped miter point
    suffices (the path is shorter).

    This produces Transit-app-quality parallel lines that never overlap
    at turns.
    """
    n = len(coords)
    if n < 2:
        return list(coords)

    # Per-segment left-hand unit normals
    seg_normals: list[tuple[float, float]] = []
    for i in range(n - 1):
        seg_normals.append(_unit_normal(coords[i], coords[i + 1]))

    min_angle_rad = math.radians(ARC_MIN_ANGLE_DEG)
    result: list[tuple[float, float]] = []

    for i in range(n):
        offset = offsets[i] if i < len(offsets) else 0.0

        if abs(offset) < 0.01:
            result.append(coords[i])
            continue

        cx, cy = coords[i]

        # ── Endpoints: simple normal offset ──
        if i == 0:
            nx, ny = seg_normals[0]
            result.append((cx + nx * offset, cy + ny * offset))
            continue
        if i == n - 1:
            nx, ny = seg_normals[-1]
            result.append((cx + nx * offset, cy + ny * offset))
            continue

        # ── Interior vertex: compute turning angle ──
        n1x, n1y = seg_normals[i - 1]  # incoming segment normal
        n2x, n2y = seg_normals[i]  # outgoing segment normal

        dot = max(-1.0, min(1.0, n1x * n2x + n1y * n2y))
        cross = n1x * n2y - n1y * n2x
        angle = math.acos(dot)  # always in [0, π]

        # Small angle → averaged normal (nearly straight segment)
        if angle < min_angle_rad:
            mx = n1x + n2x
            my = n1y + n2y
            mlen = math.sqrt(mx * mx + my * my)
            if mlen > 1e-10:
                mx /= mlen
                my /= mlen
            result.append((cx + mx * offset, cy + my * offset))
            continue

        # Determine if we are on the OUTSIDE of the curve.
        # cross > 0 → left turn (normals rotate CCW).
        # offset > 0 → left side.
        # sign(cross) == sign(offset) → outside of curve.
        is_outside = (cross * offset) > 0

        if is_outside:
            # OUTSIDE: insert circular arc points to maintain constant
            # perpendicular distance.  Arc is centred at the original
            # vertex with radius = |offset|.
            angle1 = math.atan2(n1y, n1x)
            angle2 = math.atan2(n2y, n2x)

            # Angular sweep matching the turn direction
            sweep = angle2 - angle1
            if sweep > math.pi:
                sweep -= 2.0 * math.pi
            elif sweep < -math.pi:
                sweep += 2.0 * math.pi

            n_arc = min(
                ARC_MAX_POINTS,
                max(2, math.ceil(abs(sweep) / math.radians(10))),
            )

            for j in range(n_arc + 1):
                t = j / n_arc
                a = angle1 + t * sweep
                result.append(
                    (
                        cx + offset * math.cos(a),
                        cy + offset * math.sin(a),
                    )
                )
        else:
            # INSIDE: clamped miter join (path is shorter on inside).
            mx = n1x + n2x
            my = n1y + n2y
            mlen = math.sqrt(mx * mx + my * my)

            if mlen > 1e-10:
                mx /= mlen
                my /= mlen
                miter_dot = mx * n1x + my * n1y
                if abs(miter_dot) > 0.01:
                    scale = min(1.0 / abs(miter_dot), MITER_CLAMP)
                else:
                    scale = MITER_CLAMP
                # Extra safety: don't let the inside offset pull the
                # point past the original vertex position.
                scale = min(scale, 1.0 + 0.5 * (1.0 - dot))
                nx = mx * scale
                ny = my * scale
            else:
                nx, ny = seg_normals[i - 1]

            result.append((cx + nx * offset, cy + ny * offset))

    return result


def _rdp_simplify(
    coords: list[tuple[float, float]],
    tolerance: float = RDP_TOLERANCE,
) -> list[tuple[float, float]]:
    """Douglas-Peucker simplification via Shapely.

    Removes redundant vertices added by densification + arc subdivision
    while preserving curve shape within *tolerance* metres.
    """
    if len(coords) <= 2:
        return list(coords)
    line = LineString(coords)
    simplified = line.simplify(tolerance, preserve_topology=False)
    out = list(simplified.coords)
    return out if len(out) >= 2 else list(coords)


def _despike_coords(
    coords: list[tuple[float, float]],
    min_angle_deg: float | None = None,
) -> list[tuple[float, float]]:
    """Remove spike vertices (switchbacks and excursions).

    Args:
        coords: List of (x, y) coordinate tuples.
        min_angle_deg: Override for the minimum angle threshold (degrees).
            Uses DESPIKE_MIN_ANGLE_DEG (25°) when None.
    """
    if len(coords) <= 3:
        return coords

    min_angle_rad = math.radians(
        min_angle_deg if min_angle_deg is not None else DESPIKE_MIN_ANGLE_DEG
    )
    keep: list[tuple[float, float]] = [coords[0]]

    for i in range(1, len(coords) - 1):
        prev, curr, nxt = coords[i - 1], coords[i], coords[i + 1]

        ax, ay = prev[0] - curr[0], prev[1] - curr[1]
        bx, by = nxt[0] - curr[0], nxt[1] - curr[1]
        a_len = math.sqrt(ax * ax + ay * ay)
        b_len = math.sqrt(bx * bx + by * by)

        if a_len < 1e-10 or b_len < 1e-10:
            continue

        cos_angle = max(-1.0, min(1.0, (ax * bx + ay * by) / (a_len * b_len)))
        if math.acos(cos_angle) < min_angle_rad:
            continue

        chord_dx = nxt[0] - prev[0]
        chord_dy = nxt[1] - prev[1]
        chord_len = math.sqrt(chord_dx * chord_dx + chord_dy * chord_dy)
        if chord_len > 1e-6:
            cross = abs(chord_dx * (prev[1] - curr[1]) - chord_dy * (prev[0] - curr[0]))
            if cross / chord_len / chord_len > DESPIKE_MAX_EXCURSION:
                continue

        keep.append(curr)

    keep.append(coords[-1])
    return keep if len(keep) >= 2 else coords


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 4 — Export: Reproject + Encode
# ═══════════════════════════════════════════════════════════════════════════════


def _export_trunk_paths(
    trunk_offset_paths: dict[int, list[LineString]],
) -> dict[int, list[str]]:
    """Reproject each trunk's offset paths to WGS84 and encode as polylines."""
    trunk_encoded: dict[int, list[str]] = {}

    for trunk_idx, paths in trunk_offset_paths.items():
        encoded: list[str] = []
        for path in paths:
            coords_m = list(path.coords)
            if len(coords_m) < 2:
                continue
            try:
                coords_wgs = project_to_wgs84(coords_m)
                encoded.append(encode_polyline(coords_wgs))
            except Exception:
                continue
        if encoded:
            trunk_encoded[trunk_idx] = encoded

    return trunk_encoded


def _transfer_offsets_to_route(
    coords_m: list[tuple[float, float]],
    rep_paths: list[LineString],
    offset_map: dict[int, list[float]],
) -> list[float]:
    """Transfer corridor offsets from trunk representative paths to a route.

    For each vertex in the route's EPSG:3857 polyline, finds the closest
    vertex on the trunk representative paths that has a non-zero offset
    and copies that offset value.  Route vertices far from any non-zero
    offset receive zero (= no displacement from raw GTFS position).

    This allows the pipeline to detect corridors on merged trunk paths
    but apply offsets to each route's original GTFS coordinates, preserving
    geographic accuracy while still producing parallel-lane rendering.
    """
    n = len(coords_m)
    offsets = [0.0] * n

    # Build flat list of (x, y, offset) for all non-zero-offset rep vertices.
    # Zero-offset vertices can be skipped — the default is already 0.
    ref_points: list[tuple[float, float, float]] = []
    for path_idx, rep_path in enumerate(rep_paths):
        per_vertex = offset_map.get(path_idx, [])
        if not per_vertex:
            continue
        rep_coords = list(rep_path.coords)
        for vi, (x, y) in enumerate(rep_coords):
            o = per_vertex[vi] if vi < len(per_vertex) else 0.0
            if abs(o) > 0.01:
                ref_points.append((x, y, o))

    if not ref_points:
        return offsets

    # Maximum distance (squared) to transfer an offset.
    # Route vertices beyond this from any ref point keep offset = 0.
    max_transfer_dist_sq = (CORRIDOR_DETECT_DIST * 3) ** 2

    for vi in range(n):
        x, y = coords_m[vi]
        best_dist_sq = float("inf")
        best_offset = 0.0

        for rx, ry, ro in ref_points:
            dx = x - rx
            dy = y - ry
            dist_sq = dx * dx + dy * dy
            if dist_sq < best_dist_sq:
                best_dist_sq = dist_sq
                best_offset = ro

        if best_dist_sq <= max_transfer_dist_sq:
            offsets[vi] = best_offset

    # Smooth transitions at corridor edges
    return _smooth_offsets(offsets)


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5 — Stop Processing: Snap GTFS stops onto offset lines
# ═══════════════════════════════════════════════════════════════════════════════

_processed_stops_cache: list[dict] | None = None
_trunk_offset_paths_cache: dict[int, list[LineString]] | None = None
_trunk_raw_paths_cache: dict[int, list[LineString]] | None = None
_vertex_offsets_cache: dict[int, dict[int, list[float]]] | None = None
_corridor_neighbors_cache: dict[int, set[int]] = {}
_all_trunk_lane_offsets_cache: dict[int, float] | None = None

# Pipeline result-level cache — avoids re-running the full 60-90s corridor
# pipeline on every call to apply_topological_offsets().  Populated on the
# first call (or during startup pre-warming) and reused for all subsequent
# calls in this process.  Invalidated only on process restart (deploy).
_pipeline_result_cache: list | None = None

_EXPORT_LANE_OFFSET_STEP: float = 0.50
_EXPORT_LANE_OFFSET_EPSILON: float = 0.20
_EXPORT_TRANSITION_MAX_POINTS: int = 20
_EXPORT_TRANSITION_MAX_LENGTH_M: float = 700.0  # EPSG:3857 units (~530m real)
_EXPORT_Y_TRANSITION_MIN_POINTS: int = 5
_EXPORT_RUN_LENDER_MIN_POINTS: int = 2


class _VisualOffsetRun(NamedTuple):
    start: int
    end: int
    offset: float


def _quantise_visual_lane_offset(offset_m: float) -> float:
    """Map a local physical corridor offset into client lineOffset units.

    A one-lane separation should differ by ~1.0 in client space so adjacent
    rendered fills stay touching without collapsing. Raw corridor offsets are
    multiples of ``LANE_WIDTH / 2`` or ``LANE_WIDTH`` depending on corridor
    width, so dividing by ``LANE_WIDTH`` yields the correct lane-step scale:

      2 trunks  -> -0.5 / +0.5
      3 trunks  -> -1.0 / 0.0 / +1.0
      4 trunks  -> -1.5 / -0.5 / +0.5 / +1.5
    """
    visual = offset_m / LANE_WIDTH
    if abs(visual) < _EXPORT_LANE_OFFSET_EPSILON:
        return 0.0
    return round(visual / _EXPORT_LANE_OFFSET_STEP) * _EXPORT_LANE_OFFSET_STEP


def _is_visual_transition_offset_value(offset: float) -> bool:
    magnitude = abs(offset)
    if magnitude < 1e-9:
        return False
    is_quarter_multiple = abs(round(magnitude * 4.0) - (magnitude * 4.0)) < 1e-9
    is_whole_lane_multiple = abs(round(magnitude) - magnitude) < 1e-9
    return is_quarter_multiple and not is_whole_lane_multiple


def _build_visual_offset_runs(offsets: list[float]) -> list[_VisualOffsetRun]:
    if not offsets:
        return []

    runs: list[_VisualOffsetRun] = []
    start_idx = 0
    current = offsets[0]

    for idx in range(1, len(offsets)):
        if offsets[idx] == current:
            continue
        runs.append(_VisualOffsetRun(start=start_idx, end=idx, offset=current))
        start_idx = idx
        current = offsets[idx]

    runs.append(_VisualOffsetRun(start=start_idx, end=len(offsets), offset=current))
    return runs


def _visual_offset_run_length_m(
    coords_m: list[tuple[float, float]],
    run: _VisualOffsetRun,
) -> float:
    if run.end - run.start <= 1:
        return 0.0

    length = 0.0
    for idx in range(run.start + 1, min(run.end, len(coords_m))):
        length += _point_dist(coords_m[idx - 1], coords_m[idx])
    return length


def _is_visual_y_transition(
    prev_offset: float, current_offset: float, next_offset: float
) -> bool:
    """True when a run is the visible half-lane fan-out step in a Y split."""
    if abs(current_offset) < 1e-9:
        return False

    non_zero_signs = {
        1 if value > 0 else -1
        for value in (prev_offset, current_offset, next_offset)
        if abs(value) > 1e-9
    }
    if len(non_zero_signs) > 1:
        return False

    prev_abs = abs(prev_offset)
    current_abs = abs(current_offset)
    next_abs = abs(next_offset)
    abs_monotonic = (
        prev_abs < current_abs < next_abs or prev_abs > current_abs > next_abs
    )
    if not abs_monotonic:
        return False

    # Preserve only the meaningful half-lane transition steps (0.5, 1.5, …).
    doubled = current_abs * 2.0
    is_half_lane_multiple = abs(round(doubled) - doubled) < 1e-9
    is_whole_lane_multiple = abs(round(current_abs) - current_abs) < 1e-9
    return is_half_lane_multiple and not is_whole_lane_multiple


def _transition_chain_length(
    runs: list[_VisualOffsetRun],
    center_idx: int,
) -> int:
    """Return the length of the monotonic same-sign offset chain around a run."""
    if center_idx < 0 or center_idx >= len(runs):
        return 0

    current = runs[center_idx]
    if abs(current.offset) < 1e-9:
        return 0

    sign = 1 if current.offset > 0 else -1
    chain_length = 1

    last_abs = abs(current.offset)
    for idx in range(center_idx - 1, -1, -1):
        candidate = runs[idx]
        if abs(candidate.offset) > 1e-9:
            candidate_sign = 1 if candidate.offset > 0 else -1
            if candidate_sign != sign:
                break
        candidate_abs = abs(candidate.offset)
        if candidate_abs >= last_abs - 1e-9:
            break
        if last_abs - candidate_abs > 0.5 + 1e-9:
            break
        chain_length += 1
        last_abs = candidate_abs

    last_abs = abs(current.offset)
    for idx in range(center_idx + 1, len(runs)):
        candidate = runs[idx]
        if abs(candidate.offset) > 1e-9:
            candidate_sign = 1 if candidate.offset > 0 else -1
            if candidate_sign != sign:
                break
        candidate_abs = abs(candidate.offset)
        if candidate_abs <= last_abs + 1e-9:
            break
        if candidate_abs - last_abs > 0.5 + 1e-9:
            break
        chain_length += 1
        last_abs = candidate_abs

    return chain_length


def _should_preserve_visual_transition_run(
    runs: list[_VisualOffsetRun],
    idx: int,
) -> bool:
    if idx <= 0 or idx >= len(runs) - 1:
        return False

    prev_run = runs[idx - 1]
    current_run = runs[idx]
    next_run = runs[idx + 1]

    if not _is_visual_y_transition(
        prev_run.offset,
        current_run.offset,
        next_run.offset,
    ):
        current_abs = abs(current_run.offset)
        if abs(current_run.offset) < 1e-9:
            return False

        non_zero_signs = {
            1 if value > 0 else -1
            for value in (prev_run.offset, current_run.offset, next_run.offset)
            if abs(value) > 1e-9
        }
        if len(non_zero_signs) > 1:
            return False

        prev_abs = abs(prev_run.offset)
        next_abs = abs(next_run.offset)
        abs_monotonic = (
            prev_abs < current_abs < next_abs or prev_abs > current_abs > next_abs
        )
        if not abs_monotonic:
            return False

        doubled = current_abs * 2.0
        quadrupled = current_abs * 4.0
        is_half_lane_multiple = abs(round(doubled) - doubled) < 1e-9
        is_quarter_multiple = abs(round(quadrupled) - quadrupled) < 1e-9
        is_whole_lane_multiple = abs(round(current_abs) - current_abs) < 1e-9
        if is_whole_lane_multiple or not is_quarter_multiple or is_half_lane_multiple:
            return False

        return _transition_chain_length(runs, idx) >= 4

    return True


# Safety cap for iterative expansion/stabilization loops.  Each iteration
# grows exactly one run, so convergence is bounded by the number of runs.
# 500 iterations covers even the densest trunk paths (12 groups × ~40
# runs each) with generous headroom.  Without this cap, pathological
# geometry can cause the export to hang for minutes on Render's 1 CPU.
_EXPORT_ITERATION_CAP: int = 500


def _expand_visual_y_transition_runs(visual_offsets: list[float]) -> list[float]:
    """Give Y-split fan-out runs enough vertices to render as a visible taper."""
    if len(visual_offsets) < 5:
        return list(visual_offsets)

    expanded = list(visual_offsets)
    _iter = 0

    while _iter < _EXPORT_ITERATION_CAP:
        _iter += 1
        runs = _build_visual_offset_runs(expanded)
        changed = False

        for idx in range(1, len(runs) - 1):
            prev_run = runs[idx - 1]
            current_run = runs[idx]
            next_run = runs[idx + 1]

            if not _should_preserve_visual_transition_run(runs, idx):
                continue

            point_count = current_run.end - current_run.start
            if point_count >= _EXPORT_Y_TRANSITION_MIN_POINTS:
                continue

            left_available = max(
                0,
                (current_run.start - prev_run.start) - _EXPORT_RUN_LENDER_MIN_POINTS,
            )
            right_available = max(
                0,
                (next_run.end - current_run.end) - _EXPORT_RUN_LENDER_MIN_POINTS,
            )
            if left_available <= 0 and right_available <= 0:
                continue

            needed_points = _EXPORT_Y_TRANSITION_MIN_POINTS - point_count
            left_take = min(left_available, (needed_points + 1) // 2)
            right_take = min(right_available, needed_points - left_take)

            remaining = needed_points - left_take - right_take
            if remaining > 0 and left_available > left_take:
                extra_left = min(left_available - left_take, remaining)
                left_take += extra_left
                remaining -= extra_left
            if remaining > 0 and right_available > right_take:
                right_take += min(right_available - right_take, remaining)

            if left_take <= 0 and right_take <= 0:
                continue

            for vertex_idx in range(current_run.start - left_take, current_run.start):
                expanded[vertex_idx] = current_run.offset
            for vertex_idx in range(current_run.end, current_run.end + right_take):
                expanded[vertex_idx] = current_run.offset

            changed = True
            break

        if not changed:
            return expanded

    # Iteration cap reached — return best effort so far.
    return expanded


def _stabilize_visual_lane_offsets(
    coords_m: list[tuple[float, float]],
    visual_offsets: list[float],
) -> list[float]:
    """Absorb very short offset runs so client lineOffset changes stay readable."""
    if len(visual_offsets) < 4:
        return list(visual_offsets)

    stabilized = list(visual_offsets)
    _iter = 0

    while _iter < _EXPORT_ITERATION_CAP:
        _iter += 1
        runs = _build_visual_offset_runs(stabilized)
        changed = False

        for idx in range(1, len(runs) - 1):
            prev_run = runs[idx - 1]
            current_run = runs[idx]
            next_run = runs[idx + 1]

            point_count = current_run.end - current_run.start
            run_length_m = _visual_offset_run_length_m(coords_m, current_run)
            if (
                point_count > _EXPORT_TRANSITION_MAX_POINTS
                and run_length_m > _EXPORT_TRANSITION_MAX_LENGTH_M
            ):
                continue

            if _should_preserve_visual_transition_run(runs, idx):
                continue

            offsets = (prev_run.offset, current_run.offset, next_run.offset)
            if min(offsets) < 0.0 < max(offsets):
                continue

            prev_length = _visual_offset_run_length_m(coords_m, prev_run)
            next_length = _visual_offset_run_length_m(coords_m, next_run)
            replacement = min(
                (prev_run.offset, next_run.offset),
                key=lambda candidate: (
                    abs(candidate - current_run.offset),
                    -(prev_length if candidate == prev_run.offset else next_length),
                    -abs(candidate),
                ),
            )

            if abs(replacement - current_run.offset) < 1e-9:
                continue

            for vertex_idx in range(current_run.start, current_run.end):
                stabilized[vertex_idx] = replacement
            changed = True
            break

        if not changed:
            return stabilized

    # Iteration cap reached — return best effort so far.
    return stabilized


def _segment_export_path_by_lane_offset(
    coords_m: list[tuple[float, float]],
    offsets_m: list[float],
) -> list[tuple[list[tuple[float, float]], float]]:
    """Split a raw trunk path into local-offset segments for client rendering."""
    if len(coords_m) < 2:
        return []

    if len(offsets_m) < len(coords_m):
        offsets_m = offsets_m + [0.0] * (len(coords_m) - len(offsets_m))
    elif len(offsets_m) > len(coords_m):
        offsets_m = offsets_m[: len(coords_m)]

    visual_offsets = [_quantise_visual_lane_offset(value) for value in offsets_m]
    visual_offsets = _expand_visual_y_transition_runs(visual_offsets)
    visual_offsets = _stabilize_visual_lane_offsets(coords_m, visual_offsets)
    visual_offsets = _expand_visual_y_transition_runs(visual_offsets)
    segments: list[tuple[list[tuple[float, float]], float]] = []

    start_idx = 0
    current_offset = visual_offsets[0]

    for idx in range(1, len(coords_m)):
        next_offset = visual_offsets[idx]
        if next_offset == current_offset:
            continue

        segment_coords = coords_m[start_idx : idx + 1]
        if len(segment_coords) >= 2:
            segments.append((segment_coords, current_offset))
        start_idx = idx
        current_offset = next_offset

    final_coords = coords_m[start_idx:]
    if len(final_coords) >= 2:
        segments.append((final_coords, current_offset))

    if not segments:
        return [(coords_m, 0.0)]

    merged: list[tuple[list[tuple[float, float]], float]] = []
    for coords, lane_offset in segments:
        if not merged:
            merged.append((coords, lane_offset))
            continue

        prev_coords, prev_offset = merged[-1]
        # Smooth tiny transition runs back into the neighbouring segment so
        # the client doesn't render dozens of one-hop offset features.
        seg_len = sum(
            _point_dist(coords[i], coords[i + 1])
            for i in range(len(coords) - 1)
        ) if len(coords) >= 2 else 0.0
        if (
            (len(coords) <= 3 or seg_len < 200.0)
            and abs(prev_offset - lane_offset) <= _EXPORT_LANE_OFFSET_STEP * 2
        ):
            merged[-1] = (prev_coords + coords[1:], prev_offset)
            continue

        merged.append((coords, lane_offset))

    # ── Second pass: absorb any remaining micro-fragments (< 120m) into
    # their longer neighbour.  Walk backwards so absorbed indices stay
    # valid.  This catches fragments that couldn't merge in the forward
    # pass because the preceding segment was also short.
    _ABSORB_THRESHOLD_M: float = 700.0  # EPSG:3857 units (~530m real at NYC lat)
    changed = True
    while changed:
        changed = False
        for idx in range(len(merged) - 1, -1, -1):
            c, _o = merged[idx]
            seg_len = (
                sum(_point_dist(c[i], c[i + 1]) for i in range(len(c) - 1))
                if len(c) >= 2 else 0.0
            )
            if seg_len >= _ABSORB_THRESHOLD_M:
                continue
            # Absorb into whichever neighbour is longer
            left = merged[idx - 1] if idx > 0 else None
            right = merged[idx + 1] if idx < len(merged) - 1 else None
            if left is None and right is None:
                continue
            left_len = (
                sum(_point_dist(left[0][i], left[0][i + 1])
                    for i in range(len(left[0]) - 1))
                if left and len(left[0]) >= 2 else 0.0
            )
            right_len = (
                sum(_point_dist(right[0][i], right[0][i + 1])
                    for i in range(len(right[0]) - 1))
                if right and len(right[0]) >= 2 else 0.0
            )
            if left and (right is None or left_len >= right_len):
                merged[idx - 1] = (left[0] + c[1:], left[1])
                merged.pop(idx)
                changed = True
                break
            if right:
                merged[idx + 1] = (c + right[0][1:], right[1])
                merged.pop(idx)
                changed = True
                break

    # ── Third pass: sandwich collapse ──
    # If segment[i] sits between two segments sharing the SAME offset and
    # the middle segment is < 800m, absorb it into the left neighbour.
    # This eliminates "offset oscillation" patterns like +0.5 → +1.0 → +0.5.
    _SANDWICH_THRESHOLD_M: float = 2600.0  # EPSG:3857 units (~2000m real at NYC lat)
    sandwich_changed = True
    while sandwich_changed:
        sandwich_changed = False
        for idx in range(1, len(merged) - 1):
            left_c, left_o = merged[idx - 1]
            mid_c, mid_o = merged[idx]
            right_c, right_o = merged[idx + 1]
            if abs(left_o - right_o) > 1e-9:
                continue  # neighbours don't share offset
            if abs(mid_o - left_o) < 1e-9:
                continue  # already same offset
            mid_len = (
                sum(_point_dist(mid_c[i], mid_c[i + 1])
                    for i in range(len(mid_c) - 1))
                if len(mid_c) >= 2 else 0.0
            )
            if mid_len >= _SANDWICH_THRESHOLD_M:
                continue
            # Absorb into left, then merge right into left
            merged[idx - 1] = (left_c + mid_c[1:] + right_c[1:], left_o)
            merged.pop(idx + 1)
            merged.pop(idx)
            sandwich_changed = True
            break

    return merged


def get_processed_stops() -> list[dict]:
    """Return the most recently computed snapped stop positions.

    If the corridor pipeline hasn't run yet (cache empty), fall back to
    raw GTFS positions so the ``/subway/stations/processed`` endpoint
    always returns usable data regardless of call order.
    """
    if _processed_stops_cache:
        return _processed_stops_cache

    # ── Fallback: raw GTFS positions (no snapping) ──
    from app.services.mapping.subway.shapes import get_all_subway_stations

    raw_stations = get_all_subway_stations()
    if not raw_stations:
        return []

    results: list[dict] = []
    for station in raw_stations:
        routes = station.get("routes", [])
        lat = station["lat"]
        lon = station["lon"]
        trunk_groups: set[int] = set()
        positions: list[dict] = []
        for rid in routes:
            positions.append({"route_id": rid, "lat": lat, "lon": lon})
            trunk = ROUTE_TO_TRUNK.get(rid)
            if trunk is not None:
                trunk_groups.add(trunk)
        if not positions:
            positions.append(
                {"route_id": routes[0] if routes else "", "lat": lat, "lon": lon}
            )
        results.append(
            {
                "station_id": station["id"],
                "name": station["name"],
                "is_transfer": len(trunk_groups) >= 2,
                "positions": positions,
            }
        )
    TrackLogger.info(
        f"[StopSnap] Cache empty — returned {len(results)} raw GTFS positions"
    )
    return results


def _compute_trunk_lane_offset_raw(trunk_idx: int) -> float:
    """Compute a raw per-trunk lane offset factor (before separation enforcement).

    Uses the cached per-vertex corridor offsets to determine the average
    perpendicular displacement sign & magnitude for this trunk group.
    Returns a float in the range [-2.5, +2.5] that the iOS client
    multiplies by a zoom-dependent factor for ``lineOffset``.

    Trunks with no corridor participation get 0.0 (no pixel offset needed).
    """
    offsets = _vertex_offsets_cache
    if not offsets or trunk_idx not in offsets:
        return 0.0

    path_offsets = offsets[trunk_idx]
    total = 0.0
    count = 0
    for per_vertex in path_offsets.values():
        for o in per_vertex:
            if abs(o) > 0.01:
                total += o
                count += 1

    if count == 0:
        return 0.0

    # Normalise average offset to a -2.5..+2.5 range.
    avg = total / count
    # LANE_WIDTH is the physical offset unit; map avg to ±2.5 pixel units
    normalised = (avg / LANE_WIDTH) * 2.5
    return max(-2.5, min(2.5, normalised))


def _compute_all_trunk_lane_offsets() -> dict[int, float]:
    """Compute lane_offset for every trunk with minimum-separation enforcement.

    1. Compute raw averaged offsets for each trunk (via _compute_trunk_lane_offset_raw).
    2. Sort trunks by raw offset.
    3. Greedy forward pass: for each trunk, if any preceding corridor-neighbor
       is closer than MIN_TRUNK_DELTA, push this trunk right.
    4. Re-centre around 0 and clamp to ±2.5.

    This guarantees that any two trunks sharing a corridor segment differ by
    at least MIN_TRUNK_DELTA in the final offset, preventing visual overlap
    at maximum zoom regardless of how many lines share a corridor (3–5+).
    """
    MIN_TRUNK_DELTA = 1.0  # min offset gap between corridor neighbors

    offsets = _vertex_offsets_cache
    if not offsets:
        return {}

    # Step 1: raw offsets
    raw: dict[int, float] = {}
    for trunk_idx in offsets:
        raw[trunk_idx] = _compute_trunk_lane_offset_raw(trunk_idx)

    neighbors = _corridor_neighbors_cache

    # Step 2: sort by raw offset (ascending)
    sorted_trunks = sorted(raw.keys(), key=lambda t: raw[t])

    # Step 3: greedy forward pass — enforce minimum separation
    placed: dict[int, float] = {}
    for ti in sorted_trunks:
        val = raw[ti]
        ti_nbrs = neighbors.get(ti, set())
        # Find the highest placed offset among corridor neighbors
        max_nbr_offset: float | None = None
        for prev_t, prev_val in placed.items():
            if prev_t in ti_nbrs and (
                max_nbr_offset is None or prev_val > max_nbr_offset
            ):
                max_nbr_offset = prev_val
        if max_nbr_offset is not None:
            min_required = max_nbr_offset + MIN_TRUNK_DELTA
            if val < min_required:
                val = min_required
        placed[ti] = val

    # Step 4: re-centre around 0
    if placed:
        vals = list(placed.values())
        centre = (min(vals) + max(vals)) / 2.0
        for t in placed:
            placed[t] -= centre

    # Step 5: scale to fit within ±2.5 if needed
    if placed:
        max_abs = max(abs(v) for v in placed.values()) or 1.0
        if max_abs > 2.5:
            scale = 2.5 / max_abs
            for t in placed:
                placed[t] *= scale

    TrackLogger.info(
        f"[LaneOffset] Separated offsets (min Δ={MIN_TRUNK_DELTA}): "
        + ", ".join(
            f"{'/'.join(TRUNK_GROUPS[t])}={placed[t]:+.3f}"
            for t in sorted(placed, key=lambda x: placed[x])
        )
    )

    return placed


def get_trunk_polylines() -> list[dict]:
    """Export trunk-level merged+offset polylines for the system map.

    Returns a list of dicts, one per trunk group that has geometry:
      { "trunk_index": int, "color_hex": str, "route_ids": [str],
        "polylines": [str], "lane_offset": float }

    ``lane_offset`` is a signed float indicating the trunk's perpendicular
    offset direction for pixel-space separation at low zoom levels.  The
    iOS client multiplies this by a zoom-interpolated factor and passes it
    to MapLibre's ``lineOffset`` paint property so parallel trunk groups
    remain visually distinct even when the geographic offset (metres) is
    sub-pixel.

    These are the authoritative polylines for the system map — each trunk
    group produces ONE set of continuous polylines (trunk + branch stubs).

    **v4 (2026-03)**:  We now export the *original* (non-offset) geometry
    that passes through station positions.  Visual parallel separation in
    corridors is handled entirely by MapLibre's pixel-space ``lineOffset``
    property (driven by ``lane_offset``).  This guarantees polylines touch
    their station dots at every zoom level.
    """
    from app.routers.subway import get_subway_color

    # Use raw (non-offset) trunk paths so lines pass through stations.
    # Fall back to offset paths if raw cache isn't populated yet.
    raw_paths = _trunk_raw_paths_cache
    paths = raw_paths or _trunk_offset_paths_cache
    if not paths:
        return []

    # Export cleanup should not undo station attachment. Despiking the raw
    # geometry is still useful, but a few near-terminal station vertices can
    # be removed as "nearly colinear" unless we snap the cleaned result back
    # through station nodes before encoding.
    export_paths: dict[int, list[tuple[LineString, float]]] = {}

    if raw_paths is not None:
        for trunk_idx, line_strings in raw_paths.items():
            segmented_lines: list[tuple[LineString, float]] = []
            offset_map = (_vertex_offsets_cache or {}).get(trunk_idx, {})
            for path_idx, ls in enumerate(line_strings):
                coords_m = list(ls.coords)
                if len(coords_m) < 2:
                    continue
                offsets_m = offset_map.get(path_idx, [0.0] * len(coords_m))
                for segment_coords, lane_offset in _segment_export_path_by_lane_offset(
                    coords_m, offsets_m
                ):
                    if len(segment_coords) < 2:
                        continue
                    segmented_lines.append((LineString(segment_coords), lane_offset))

            if segmented_lines:
                export_paths[trunk_idx] = segmented_lines
    else:
        for trunk_idx, line_strings in paths.items():
            export_paths[trunk_idx] = [
                (ls, 0.0) for ls in line_strings if len(ls.coords) >= 2
            ]

    if raw_paths is not None and export_paths:
        try:
            snap_inputs = {
                trunk_idx: [line for line, _ in items]
                for trunk_idx, items in export_paths.items()
            }
            snapped = _snap_paths_to_stations(snap_inputs)
            for trunk_idx, items in list(export_paths.items()):
                snapped_lines = snapped.get(trunk_idx, [])
                if len(snapped_lines) != len(items):
                    continue
                export_paths[trunk_idx] = [
                    (snapped_line, lane_offset)
                    for snapped_line, (_, lane_offset) in zip(
                        snapped_lines, items, strict=False
                    )
                    if len(snapped_line.coords) >= 2
                ]
        except Exception as exc:
            TrackLogger.warning(
                f"[TrunkExport] Station re-snap failed after cleanup: {exc}"
            )

    # Pre-compute all trunk offsets with minimum-separation enforcement.
    global _all_trunk_lane_offsets_cache
    _all_trunk_lane_offsets_cache = _compute_all_trunk_lane_offsets()
    separated_offsets = _all_trunk_lane_offsets_cache

    result: list[dict] = []
    for trunk_idx, line_strings in export_paths.items():
        if trunk_idx < 0 or trunk_idx >= len(TRUNK_GROUPS):
            continue
        group = TRUNK_GROUPS[trunk_idx]
        color = get_subway_color(group[0])

        encoded: list[str] = []
        polyline_lane_offsets: list[float] = []
        # Process each segment, collecting WGS84 coords for stitching.
        wgs_segments: list[tuple[list[tuple[float, float]], float]] = []
        for ls, local_lane_offset in line_strings:
            coords_m = list(ls.coords)
            if len(coords_m) < 2:
                continue

            # Skip degenerate polylines with near-zero physical length.
            # These are artefacts of corridor offset segmentation where
            # a handful of vertices collapse to the same point.
            total_m = sum(
                _point_dist(coords_m[i], coords_m[i + 1])
                for i in range(len(coords_m) - 1)
            )
            if total_m < 10.0:
                continue

            try:
                coords_wgs = project_to_wgs84(coords_m)
                # v5: Server-side fillet — client no longer needs to
                # process geometry at all (decode → render).
                coords_wgs = _remove_near_duplicates_wgs84(coords_wgs)
                # v6: Remove backtrack artefacts introduced by station
                # re-snap.  Snapping can create micro-reversals where a
                # vertex is placed slightly "behind" the path's direction
                # of travel.  These survive into the export and cause
                # MapLibre's line-offset to momentarily flip sides,
                # producing a zig-zag / scribble effect on the rendered
                # trunk (most visible on the 1/2/3 red line near Sugar
                # Hill and the N/Q/R/W yellow trunk in Yorkville).
                if len(coords_wgs) >= 3:
                    coords_wgs = _despike_coords(coords_wgs)
                if len(coords_wgs) >= 3:
                    coords_wgs = _junction_fillet_wgs84(
                        coords_wgs,
                        lane_offset=local_lane_offset,
                        angle_threshold=10.0,
                        base_radius_deg=0.00045,
                        scale_factor=0.00030,
                        arc_points=16,
                    )
                wgs_segments.append((coords_wgs, local_lane_offset))
            except Exception:
                continue

        # ── Stitch consecutive segment endpoints ──
        # After fillet, consecutive segments from the same raw trunk path
        # may have drifted at the split point.  Snap them back together
        # so the client renders a seamless polyline chain.
        _STITCH_THRESHOLD_DEG = 0.003  # ~330m at NYC latitude
        for i in range(1, len(wgs_segments)):
            prev_coords, _ = wgs_segments[i - 1]
            curr_coords, _ = wgs_segments[i]
            if not prev_coords or not curr_coords:
                continue
            prev_end = prev_coords[-1]
            curr_start = curr_coords[0]
            dlat = abs(prev_end[0] - curr_start[0])
            dlon = abs(prev_end[1] - curr_start[1])
            if dlat < _STITCH_THRESHOLD_DEG and dlon < _STITCH_THRESHOLD_DEG:
                # Average the two points and snap both to the midpoint
                mid = (
                    (prev_end[0] + curr_start[0]) / 2.0,
                    (prev_end[1] + curr_start[1]) / 2.0,
                )
                prev_coords[-1] = mid
                curr_coords[0] = mid

        for coords_wgs, local_lane_offset in wgs_segments:
            encoded.append(encode_polyline(coords_wgs))
            polyline_lane_offsets.append(local_lane_offset)

        if encoded:
            result.append(
                {
                    "trunk_index": trunk_idx,
                    "color_hex": color,
                    "route_ids": group,
                    "polylines": encoded,
                    "lane_offset": separated_offsets.get(trunk_idx, 0.0),
                    "polyline_lane_offsets": polyline_lane_offsets,
                }
            )

    return result


def get_trunk_crossings() -> list[dict]:
    """Export trunk crossing points for client casing-break rendering.

    Returns a list of dicts:
      [{"lat": float, "lng": float, "trunk_indices": [int, int]}, ...]

    Each entry represents a point where two different trunk groups cross
    at a significant angle (>25°).  The client uses these to introduce
    small gaps in the CASING layer of the lower-z-order trunk, creating
    a visual over/under effect at intersections.
    """
    return _detect_trunk_crossings()


def _process_stop_positions(
    trunk_offset_paths: dict[int, list[LineString]],
) -> list[dict]:
    """Build stop position data using raw MTA station coordinates.

    Station coordinates are ground truth from the MTA — they never move.
    The polyline is responsible for routing through stations (handled by
    Phase 1.5 ``_snap_paths_to_stations``).  This function only classifies
    transfer hubs based on which trunk groups serve each station.
    """
    from app.services.mapping.subway.shapes import get_all_subway_stations

    raw_stations = get_all_subway_stations()
    if not raw_stations:
        return []

    results: list[dict] = []

    for station in raw_stations:
        station_id: str = station["id"]
        name: str = station["name"]
        routes: list[str] = station.get("routes", [])
        lat: float = station["lat"]
        lon: float = station["lon"]

        positions: list[dict] = []
        trunk_groups_seen: set[int] = set()

        for rid in routes:
            trunk = ROUTE_TO_TRUNK.get(rid)
            if trunk is not None:
                trunk_groups_seen.add(trunk)
            # Always use the exact MTA-provided coordinate.
            positions.append({"route_id": rid, "lat": lat, "lon": lon})

        if not positions:
            positions.append(
                {
                    "route_id": routes[0] if routes else "",
                    "lat": lat,
                    "lon": lon,
                }
            )

        results.append(
            {
                "station_id": station_id,
                "name": name,
                "is_transfer": len(trunk_groups_seen) >= 2,
                "positions": positions,
            }
        )

    TrackLogger.info(
        f"[StopProcess] Processed {len(results)} stations "
        f"({sum(1 for r in results if r['is_transfer'])} transfer hubs) "
        f"— all positions use raw MTA coordinates"
    )
    return results


# ═══════════════════════════════════════════════════════════════════════════════
# MAIN ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════


def apply_topological_offsets(
    overlays: list,
) -> list:
    """Top-level entry point: trunk-group parallel offset pipeline.

    Input:  list of SubwayLineOverlay (route_id, color_hex, polylines[encoded])
    Output: list of SubwayLineOverlay with properly offset polylines.

    The pipeline takes 60-90s on 1 CPU (Standard plan).  Results are
    cached in ``_pipeline_result_cache`` so subsequent calls return
    instantly.  The cache is populated either by startup pre-warming
    or by the first user request to ``/subway/shapes/all``.
    """
    global _pipeline_result_cache

    if not overlays:
        return overlays

    # Return cached result if available — avoids 60-90s recomputation.
    if _pipeline_result_cache is not None:
        TrackLogger.info(
            f"[Pipeline] Returning cached result ({len(_pipeline_result_cache)} overlays)"
        )
        return _pipeline_result_cache

    TrackLogger.info(
        f"[Pipeline] Starting trunk-group offset pipeline for "
        f"{len(overlays)} overlays"
    )

    # ── Phase 1: Group by trunk and merge ──
    trunk_paths = _group_and_merge_trunks(overlays)

    if not trunk_paths:
        TrackLogger.warning("[Pipeline] No trunk paths — returning originals")
        return overlays

    total_paths = sum(len(p) for p in trunk_paths.values())
    total_pts = sum(
        sum(len(path.coords) for path in paths) for paths in trunk_paths.values()
    )
    TrackLogger.info(
        f"[Pipeline] Phase 1 — {len(trunk_paths)} trunk groups, "
        f"{total_paths} paths, {total_pts} total vertices"
    )

    # ── Phase 1.5: Topological station snapping ──
    # Force trunk polylines through station coordinate nodes so
    # rendered tracks visually pass through every associated stop.
    try:
        trunk_paths = _snap_paths_to_stations(trunk_paths)
    except Exception as exc:
        TrackLogger.warning(f"[Pipeline] Phase 1.5 (Station snap) failed: {exc}")

    # Normalize polyline direction (south→north / west→east) so that
    # MapLibre lineOffset pushes parallel trunks in consistent directions.
    for trunk_idx in list(trunk_paths.keys()):
        trunk_paths[trunk_idx] = [
            _normalize_path_direction(p) for p in trunk_paths[trunk_idx]
        ]

    # ── Phase 2: Detect corridors and compute per-vertex offsets ──
    try:
        vertex_offsets = _compute_corridor_offsets(trunk_paths)
    except Exception as exc:
        TrackLogger.error(
            f"[Pipeline] Phase 2 (Corridor detect) failed: {exc}", exc_info=True
        )
        vertex_offsets = {}

    # ── Phase 3: Apply arc-based offsets (v3.2) ──
    #
    # Pipeline per path: densify → arc-offset → despike → RDP-simplify.
    # Circular arc segments at bends maintain constant perpendicular
    # distance — lines that share a corridor never overlap at turns.
    trunk_offset_paths: dict[int, list[LineString]] = {}

    for trunk_idx, paths in trunk_paths.items():
        offset_map = vertex_offsets.get(trunk_idx, {})
        offset_paths: list[LineString] = []

        for path_idx, path in enumerate(paths):
            coords = list(path.coords)
            per_vertex = offset_map.get(path_idx, [0.0] * len(coords))

            # Pad or trim offsets to match coord count
            if len(per_vertex) < len(coords):
                per_vertex.extend([0.0] * (len(coords) - len(per_vertex)))
            elif len(per_vertex) > len(coords):
                per_vertex = per_vertex[: len(coords)]

            has_offset = any(abs(o) > 0.01 for o in per_vertex)

            if has_offset:
                # Densify → arc-offset → despike → simplify
                dense_c, dense_o = _densify_with_offsets(coords, per_vertex)
                displaced = _apply_arc_offset(dense_c, dense_o)
                cleaned = _despike_coords(displaced)
                cleaned = _rdp_simplify(cleaned)
            else:
                # No corridor overlap — pass through unmodified
                cleaned = coords

            if len(cleaned) >= 2:
                offset_paths.append(LineString(cleaned))

        if offset_paths:
            trunk_offset_paths[trunk_idx] = offset_paths

    # ── Phase 5: Stop processing ──
    global _processed_stops_cache, _trunk_offset_paths_cache, _trunk_raw_paths_cache, _vertex_offsets_cache, _all_trunk_lane_offsets_cache
    _trunk_offset_paths_cache = trunk_offset_paths
    _trunk_raw_paths_cache = (
        trunk_paths  # Pre-offset geometry (passes through stations)
    )
    _vertex_offsets_cache = vertex_offsets
    _all_trunk_lane_offsets_cache = (
        None  # Reset — will be computed on first call to get_trunk_polylines
    )
    try:
        # v4 fix: snap stop positions onto the RAW (pre-offset) trunk paths
        # — the same geometry exported by get_trunk_polylines().  Previously
        # this used trunk_offset_paths which are displaced 30-40 m by corridor
        # lane offsets, causing station dots to float off the rendered lines.
        _processed_stops_cache = _process_stop_positions(trunk_paths)
    except Exception as exc:
        TrackLogger.warning(f"[Pipeline] Phase 5 (Stop snap) failed: {exc}")
        _processed_stops_cache = None

    # ── Phase 4: Per-route export (v4 — no geographic offset) ──
    #
    # v4: we no longer apply geographic offsets to per-route polylines.
    # All corridor separation is handled client-side via MapLibre's
    # pixel-space ``lineOffset`` property.  This ensures every route's
    # polylines pass through their station positions at all zoom levels.
    #
    # The ``lane_offset`` value (computed from vertex_offsets) still drives
    # pixel-space separation on the system map.  Per-route detail views
    # use the raw GTFS geometry directly.
    #
    # Keeping the original GTFS coordinates also eliminates:
    #   - EKG zigzag spikes (from double miter amplification)
    #   - Polyline-stop drift at high zoom
    #   - Cross-avenue contamination at corridor boundaries
    result: list[SubwayLineOverlay] = []

    for overlay in overlays:
        # Return every overlay with its original polylines unmodified.
        result.append(overlay)

    total_polys = sum(len(o.polylines) for o in result)
    TrackLogger.info(
        f"[Pipeline] Complete: {len(trunk_paths)} trunks, "
        f"{total_polys} total polylines (per-route raw GTFS preserved)"
    )

    _pipeline_result_cache = result
    return result
