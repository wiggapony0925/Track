#
# corridor_pipeline.py  —  v3.2 arc-based parallel offsets
# TrackBackend
#
# 5-phase pipeline:
#   Phase 1 – Trunk Merge:      Pool same-colour routes, unify into continuous paths
#   Phase 2 – Corridor Detect:  Find where different trunk groups share track
#   Phase 3 – Arc Offset:       Densify → arc-offset → despike → RDP-simplify
#   Phase 4 – Export:           Reproject to WGS84, encode polylines
#   Phase 5 – Stop Snap:        Snap GTFS stops onto offset paths
#
# ═══════════════════════════════════════════════════════════════════════════════
# ARCHITECTURE CHANGE (v3.1 → v3.2)
#
#   v1  Used Shapely offset_curve() → EKG spikes, bowties, Columbus Circle bubble
#   v2  Unified skeleton from ALL 23 routes → 1 124 edges, 397 tiny fragments
#       (avg 5 pts each), catastrophic fragmentation, 361 edges with zero routes.
#   v3  Trunk-group level offsets → 11 groups, ~25-35 continuous polylines,
#       each with ~50-350 points.
#   v3.1 Per-route GTFS preservation — transfer trunk offsets via nearest-neighbour.
#   v3.2 Arc-based offsets — circular arc segments at bends maintain constant
#       perpendicular distance.  Lines sharing a corridor never overlap at turns.
#       Also: vertex densification, cosine-blended corridor transitions,
#       and post-offset Douglas-Peucker simplification.
#
# KEY INSIGHT: the iOS client renders ONE polyline per trunk colour group (not
# per route).  Routes A/C/E are all blue and get merged into one polyline by
# MapSystemViewModel.computeFlattenedPolylines().  The server only needs to
# produce parallel offsets between *different colour groups* that share track.
#
# Running routes in the *same* trunk group on the *same* track is correct —
# the client expects overlapping same-colour polylines and unifies them.
# ═══════════════════════════════════════════════════════════════════════════════

from __future__ import annotations

import math
from collections import defaultdict
from typing import NamedTuple

from pyproj import Transformer
from shapely.geometry import LineString, Point
from shapely import STRtree

from app.utils.logger import TrackLogger
from app.utils.polyline_utils import decode_polyline, encode_polyline


# ═══════════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════════

# Perpendicular distance between adjacent trunk groups in a corridor (meters
# in EPSG:3857).  40 EPSG:3857-m ≈ 30.5 real metres at NYC latitude 40.7°.
# Tuned so parallel lines are visually distinct from zoom 13 upwards;
# at zoom 10-12 the iOS client supplements with pixel-space lineOffset.
LANE_WIDTH: float = 40.0

# Two trunk paths closer than this are considered to share a corridor.
# 25 m is tight enough to exclude adjacent streets (Roosevelt Ave vs
# Queens Blvd = ~30-50 m apart) while catching true shared tunnels where
# GPS traces of different trunks run within ~10 m of each other.
CORRIDOR_DETECT_DIST: float = 25.0

# Minimum |dot product| of travel directions for two trunk paths to be
# considered parallel.  cos(45°) ≈ 0.707.  Tightened from 0.574 to
# reduce false positives from streets that cross at moderate angles.
CORRIDOR_ALIGN_MIN: float = 0.707

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
DESPIKE_MIN_ANGLE_DEG: float = 25.0
DESPIKE_MAX_EXCURSION: float = 0.6

# Minimum path length (meters) to include in output.
MIN_PATH_LENGTH: float = 50.0

# Maximum gap between endpoint of two segments for merge (meters).
MERGE_GAP_M: float = 50.0

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
# while preserving the smooth curve shape.
RDP_TOLERANCE: float = 2.0


# ═══════════════════════════════════════════════════════════════════════════════
# MTA trunk groups (must match iOS MapSystemViewModel.trunkGroups)
# ═══════════════════════════════════════════════════════════════════════════════

TRUNK_GROUPS: list[list[str]] = [
    ["1", "2", "3"],               # 0: Red — 7th Ave / Broadway
    ["4", "5", "6", "6X"],         # 1: Green — Lexington Ave
    ["7", "7X"],                   # 2: Purple — Flushing
    ["A", "C", "E"],              # 3: Blue — 8th Ave
    ["B", "D", "F", "FX", "M"],   # 4: Orange — 6th Ave
    ["G"],                          # 5: Lime Green — Crosstown
    ["J", "Z"],                    # 6: Brown — Nassau St
    ["L"],                          # 7: Gray — 14th St / Canarsie
    ["N", "Q", "R", "W"],         # 8: Yellow — Broadway BMT
    ["S"],                          # 9: Shuttle Gray
    ["SI"],                        # 10: Staten Island Railway
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


def _unit_normal(p0: tuple[float, float], p1: tuple[float, float]) -> tuple[float, float]:
    """Left-hand perpendicular unit normal of the segment p0→p1."""
    dx = p1[0] - p0[0]
    dy = p1[1] - p0[1]
    length = math.sqrt(dx * dx + dy * dy)
    if length < 1e-10:
        return (0.0, 0.0)
    return (-dy / length, dx / length)


def _local_direction(
    coords: list[tuple[float, float]], idx: int,
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

# Maximum gap (meters) allowed between consecutive vertices in a branch
# stub.  Stubs with jumps exceeding this are considered corrupted and
# discarded.  Set high enough to allow natural GTFS sparsity (tunnels,
# water crossings can have 1-5 km between encoded points) while still
# catching teleport artifacts from bad snaps.
_MAX_STUB_GAP_M: float = 6000.0


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
    from app.services.mapping.subway_shapes import get_all_subway_stations

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
                        if not new_coords or _point_dist(new_coords[-1], (sx, sy)) > 2.0:
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
            trunk_paths[trunk_idx] = [max(lines, key=lambda l: l.length)]

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
    sorted_lines = sorted(lines, key=lambda l: l.length, reverse=True)

    # ── Spatial grid ──
    grid: set[tuple[int, int]] = set()

    def _cell(x: float, y: float) -> tuple[int, int]:
        return (int(math.floor(x / _GRID_CELL_M)),
                int(math.floor(y / _GRID_CELL_M)))

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
        """Wider check (±4 cells ≈ 400 m) for branch validation."""
        cx, cy = _cell(x, y)
        for dx in range(-4, 5):
            for dy in range(-4, 5):
                if (cx + dx, cy + dy) in grid:
                    return True
        return False

    # Seed with the longest polyline (trunk baseline)
    kept: list[LineString] = [sorted_lines[0]]
    _add_line(sorted_lines[0])

    trunk_coords = list(sorted_lines[0].coords)

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
            # Branch validation: if start, mid, and end are all near the
            # existing grid, it's a corridor variant (express/local
            # parallel), not a genuine branch.
            r_mid = (r_start + r_end) // 2
            if (_is_near(*coords[r_start]) and
                _is_near(*coords[r_mid]) and
                _is_near(*coords[r_end])):
                continue

            # Extend a few points into covered zone for seamless connection.
            # Snap extension points to nearest trunk coordinate ONLY if
            # a trunk point is within _MAX_SNAP_DIST_M.  Otherwise use
            # the original branch coordinate to avoid teleporting.
            ext_start = max(0, r_start - 5)
            ext_end = min(n - 1, r_end + 5)

            snap_limit_sq = _MAX_SNAP_DIST_M ** 2

            stub_coords: list[tuple[float, float]] = []
            for j in range(ext_start, ext_end + 1):
                if covered[j] and trunk_coords:
                    # Distance-bounded snap to nearest trunk point
                    px, py = coords[j]
                    best_dist = float("inf")
                    best_pt: tuple[float, float] | None = None
                    for tx, ty in trunk_coords:
                        d = (tx - px) ** 2 + (ty - py) ** 2
                        if d < best_dist:
                            best_dist = d
                            best_pt = (tx, ty)
                    # Only snap if within range; otherwise keep original
                    if best_pt is not None and best_dist <= snap_limit_sq:
                        stub_coords.append(best_pt)
                    else:
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

    # Chain-merge nearby endpoints
    return _chain_merge(kept, MERGE_GAP_M)


def _validate_stub(coords: list[tuple[float, float]]) -> bool:
    """Reject branch stubs that contain implausibly large jumps.

    A jump > _MAX_STUB_GAP_M between consecutive vertices indicates that
    the snap-to-trunk created a teleport or the raw GTFS geometry has a
    water crossing / tunnel leap that shouldn't appear as a stub.
    """
    for i in range(1, len(coords)):
        dx = coords[i][0] - coords[i - 1][0]
        dy = coords[i][1] - coords[i - 1][1]
        if dx * dx + dy * dy > _MAX_STUB_GAP_M ** 2:
            return False
    return True


def _chain_merge(
    segments: list[LineString], tolerance: float,
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


def _compute_corridor_offsets(
    trunk_paths: dict[int, list[LineString]],
) -> dict[int, dict[int, list[float]]]:
    """Detect shared corridors and compute per-vertex perpendicular offsets.

    Algorithm:
    1. Index all trunk paths in a spatial tree.
    2. For each vertex of each trunk path, query the tree for nearby paths
       from *other* trunk groups.
    3. If another trunk path is within CORRIDOR_DETECT_DIST and running in the
       same direction (alignment > 0.707), this vertex is in a shared corridor.
    4. Assign a lane position based on canonical trunk order.
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

    results: dict[int, dict[int, list[float]]] = {}

    for trunk_idx, paths in trunk_paths.items():
        path_offsets: dict[int, list[float]] = {}

        for path_idx, path in enumerate(paths):
            coords = list(path.coords)
            n = len(coords)
            raw_offsets: list[float] = [0.0] * n
            per_vertex_trunks: dict[int, set[int]] = {}

            for i in range(n):
                pt = Point(coords[i])
                dir_i = _local_direction(coords, i)
                nearby_trunks: set[int] = set()

                # Query spatial index for nearby paths
                candidate_indices = tree.query(
                    pt.buffer(CORRIDOR_DETECT_DIST)
                )

                for ci in candidate_indices:
                    info = all_infos[ci]
                    if info.trunk_idx == trunk_idx:
                        continue  # Skip own trunk group

                    dist_to_path = info.path.distance(pt)
                    if dist_to_path >= CORRIDOR_DETECT_DIST:
                        continue

                    # Check direction alignment
                    proj = info.path.project(pt)
                    dir_j = _direction_at_distance(info.path, proj)
                    dot = abs(dir_i[0] * dir_j[0] + dir_i[1] * dir_j[1])
                    if dot >= CORRIDOR_ALIGN_MIN:
                        nearby_trunks.add(info.trunk_idx)

                if nearby_trunks:
                    per_vertex_trunks[i] = nearby_trunks

            # ── Local density filter ──
            # A vertex is only offset for a neighbour trunk if that trunk
            # is detected by enough nearby vertices in a sliding window.
            # This prevents a genuine shared corridor in one part of a path
            # (e.g. 7 + N/Q/R/W at Queensboro Plaza) from bleeding offsets
            # into distant vertices where the same trunk happens to pass
            # within CORRIDOR_DETECT_DIST on a completely separate street
            # (e.g. N/Q/R/W on Queens Blvd ~23 m from the 7 on Roosevelt Ave).
            #
            # Window size: 60 vertices ≈ 3-6 km of path.
            # Minimum local hits: 8 of 60 (13%).
            LOCAL_WINDOW = 60
            LOCAL_MIN_HITS = 8

            # First, build per-trunk detection arrays for efficient windowing
            detected_trunks_all: set[int] = set()
            for vtrunks in per_vertex_trunks.values():
                detected_trunks_all.update(vtrunks)

            # For each candidate trunk, build a boolean array of detections
            trunk_local_valid: dict[int, list[bool]] = {}
            for t in detected_trunks_all:
                detections = [
                    (t in per_vertex_trunks.get(i, set()))
                    for i in range(n)
                ]

                # Sliding window: mark vertex i as locally-valid if
                # the window centred on i has >= LOCAL_MIN_HITS detections
                half = LOCAL_WINDOW // 2
                valid = [False] * n

                # Running sum
                win_sum = sum(1 for d in detections[:min(half, n)] if d)
                for i in range(n):
                    # Expand right edge
                    right = i + half
                    if right < n and detections[right]:
                        win_sum += 1
                    # Shrink left edge
                    left = i - half - 1
                    if left >= 0 and detections[left]:
                        win_sum -= 1
                    if win_sum >= LOCAL_MIN_HITS:
                        valid[i] = True

                trunk_local_valid[t] = valid

            # Compute offsets only using locally-validated neighbor trunks
            for i in range(n):
                vtrunks = per_vertex_trunks.get(i)
                if not vtrunks:
                    continue
                # Only keep trunks that are locally dense around this vertex
                filtered = {
                    t for t in vtrunks
                    if trunk_local_valid.get(t, [False] * n)[i]
                }
                if not filtered:
                    continue
                all_trunks = sorted(filtered | {trunk_idx})
                lane = all_trunks.index(trunk_idx)
                n_lanes = len(all_trunks)
                centre = (n_lanes - 1) / 2.0
                raw_offsets[i] = (lane - centre) * LANE_WIDTH

            # Smooth offset transitions
            filled = _fill_corridor_gaps(raw_offsets)
            path_offsets[path_idx] = _smooth_offsets(filled)

        results[trunk_idx] = path_offsets

    # Log summary
    corridors_found = 0
    for t, pd in results.items():
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
            n_sub = int(math.ceil(dist / max_spacing))
            for j in range(1, n_sub):
                t = j / n_sub
                result_c.append((
                    prev_c[0] + t * (curr_c[0] - prev_c[0]),
                    prev_c[1] + t * (curr_c[1] - prev_c[1]),
                ))
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
        n1x, n1y = seg_normals[i - 1]   # incoming segment normal
        n2x, n2y = seg_normals[i]       # outgoing segment normal

        dot = max(-1.0, min(1.0, n1x * n2x + n1y * n2y))
        cross = n1x * n2y - n1y * n2x
        angle = math.acos(dot)          # always in [0, π]

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
                sweep -= 2. * math.pi
            elif sweep < -math.pi:
                sweep += 2. * math.pi

            n_arc = min(
                ARC_MAX_POINTS,
                max(2, int(math.ceil(abs(sweep) / math.radians(10)))),
            )

            for j in range(n_arc + 1):
                t = j / n_arc
                a = angle1 + t * sweep
                result.append((
                    cx + offset * math.cos(a),
                    cy + offset * math.sin(a),
                ))
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


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3 — Apply Perpendicular Offsets  (legacy miter-join, kept for reference)
# ═══════════════════════════════════════════════════════════════════════════════

def _apply_perpendicular_offset(
    coords: list[tuple[float, float]],
    offsets: list[float],
) -> list[tuple[float, float]]:
    """Displace each vertex perpendicular to the path by per-vertex offsets.

    Uses clamped miter joins at interior vertices — same math as v2 but
    applied to trunk-level continuous paths instead of skeleton edge fragments.
    """
    n = len(coords)
    if n < 2:
        return list(coords)

    # Per-segment normals
    seg_normals: list[tuple[float, float]] = []
    for i in range(n - 1):
        seg_normals.append(_unit_normal(coords[i], coords[i + 1]))

    result: list[tuple[float, float]] = []

    for i in range(n):
        offset = offsets[i] if i < len(offsets) else 0.0

        if abs(offset) < 0.01:
            result.append(coords[i])
            continue

        if i == 0:
            nx_, ny = seg_normals[0]
        elif i == n - 1:
            nx_, ny = seg_normals[-1]
        else:
            n1x, n1y = seg_normals[i - 1]
            n2x, n2y = seg_normals[i]
            mx = n1x + n2x
            my = n1y + n2y
            mlen = math.sqrt(mx * mx + my * my)

            if mlen > 1e-10:
                mx /= mlen
                my /= mlen
                dot = mx * n1x + my * n1y
                if abs(dot) > 0.01:
                    scale = min(1.0 / abs(dot), MITER_CLAMP)
                else:
                    scale = MITER_CLAMP
                nx_ = mx * scale
                ny = my * scale
            else:
                nx_, ny = seg_normals[i - 1]

        result.append((
            coords[i][0] + nx_ * offset,
            coords[i][1] + ny * offset,
        ))

    return result


def _despike_coords(
    coords: list[tuple[float, float]],
) -> list[tuple[float, float]]:
    """Remove spike vertices (switchbacks and excursions)."""
    if len(coords) <= 3:
        return coords

    min_angle_rad = math.radians(DESPIKE_MIN_ANGLE_DEG)
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
            cross = abs(
                chord_dx * (prev[1] - curr[1]) - chord_dy * (prev[0] - curr[0])
            )
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
_vertex_offsets_cache: dict[int, dict[int, list[float]]] | None = None


def get_processed_stops() -> list[dict]:
    """Return the most recently computed snapped stop positions."""
    return _processed_stops_cache or []


def _compute_trunk_lane_offset(trunk_idx: int) -> float:
    """Compute a per-trunk lane offset factor for low-zoom pixel separation.

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
    group produces ONE set of continuous polylines (trunk + branch stubs)
    with corridor offsets already applied.  The client should render these
    directly rather than pooling per-route GTFS shapes.
    """
    from app.routers.subway import get_subway_color

    paths = _trunk_offset_paths_cache
    if not paths:
        return []

    result: list[dict] = []
    for trunk_idx, line_strings in paths.items():
        if trunk_idx < 0 or trunk_idx >= len(TRUNK_GROUPS):
            continue
        group = TRUNK_GROUPS[trunk_idx]
        color = get_subway_color(group[0])

        encoded: list[str] = []
        for ls in line_strings:
            coords_m = list(ls.coords)
            if len(coords_m) < 2:
                continue
            try:
                coords_wgs = project_to_wgs84(coords_m)
                encoded.append(encode_polyline(coords_wgs))
            except Exception:
                continue

        if encoded:
            result.append({
                "trunk_index": trunk_idx,
                "color_hex": color,
                "route_ids": group,
                "polylines": encoded,
                "lane_offset": _compute_trunk_lane_offset(trunk_idx),
            })

    return result


def _process_stop_positions(
    trunk_offset_paths: dict[int, list[LineString]],
) -> list[dict]:
    """Snap GTFS stops onto the offset trunk paths.

    For each subway station, projects to EPSG:3857 and snaps onto the
    nearest path of its trunk group.  Classifies transfer hubs.
    """
    from app.services.mapping.subway_shapes import get_all_subway_stations

    raw_stations = get_all_subway_stations()
    if not raw_stations:
        return []

    # Build trunk → spatial-indexed paths
    trunk_geoms: dict[int, list[LineString]] = {}
    for trunk_idx, paths in trunk_offset_paths.items():
        valid = [p for p in paths if p.length >= MIN_PATH_LENGTH]
        if valid:
            trunk_geoms[trunk_idx] = valid

    results: list[dict] = []

    for station in raw_stations:
        station_id: str = station["id"]
        name: str = station["name"]
        routes: list[str] = station.get("routes", [])
        lat: float = station["lat"]
        lon: float = station["lon"]

        try:
            stop_m = _to_meters.transform(lon, lat)
        except Exception:
            continue

        stop_pt = Point(stop_m)
        positions: list[dict] = []
        trunk_groups_seen: set[int] = set()

        # Group station routes by trunk
        route_trunks: dict[int, list[str]] = defaultdict(list)
        for rid in routes:
            trunk = ROUTE_TO_TRUNK.get(rid)
            if trunk is not None:
                route_trunks[trunk].append(rid)

        for trunk_idx, trunk_routes in route_trunks.items():
            paths = trunk_geoms.get(trunk_idx, [])
            if not paths:
                # Fallback: use original position
                for rid in trunk_routes:
                    positions.append({"route_id": rid, "lat": lat, "lon": lon})
                continue

            # Find closest path in this trunk
            best_dist = float("inf")
            best_path: LineString | None = None
            for p in paths:
                d = p.distance(stop_pt)
                if d < best_dist:
                    best_dist = d
                    best_path = p

            if best_path is None or best_dist > STOP_SNAP_DIST:
                for rid in trunk_routes:
                    positions.append({"route_id": rid, "lat": lat, "lon": lon})
                continue

            proj = best_path.project(stop_pt)
            snapped = best_path.interpolate(proj)

            try:
                snap_lon, snap_lat = _to_wgs84.transform(snapped.x, snapped.y)
            except Exception:
                snap_lat, snap_lon = lat, lon

            for rid in trunk_routes:
                positions.append({
                    "route_id": rid,
                    "lat": snap_lat,
                    "lon": snap_lon,
                })

            trunk_groups_seen.add(trunk_idx)

        if not positions:
            positions.append({
                "route_id": routes[0] if routes else "",
                "lat": lat,
                "lon": lon,
            })

        results.append({
            "station_id": station_id,
            "name": name,
            "is_transfer": len(trunk_groups_seen) >= 2,
            "positions": positions,
        })

    TrackLogger.info(
        f"[StopSnap] Processed {len(results)} stations, "
        f"{sum(1 for r in results if r['is_transfer'])} transfer hubs"
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
    """
    from app.models import SubwayLineOverlay

    if not overlays:
        return overlays

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
        sum(len(path.coords) for path in paths)
        for paths in trunk_paths.values()
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
        TrackLogger.warning(
            f"[Pipeline] Phase 1.5 (Station snap) failed: {exc}"
        )

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
    global _processed_stops_cache, _trunk_offset_paths_cache, _vertex_offsets_cache
    _trunk_offset_paths_cache = trunk_offset_paths
    _vertex_offsets_cache = vertex_offsets
    try:
        _processed_stops_cache = _process_stop_positions(trunk_offset_paths)
    except Exception as exc:
        TrackLogger.warning(
            f"[Pipeline] Phase 5 (Stop snap) failed: {exc}"
        )
        _processed_stops_cache = None

    # ── Phase 4: Per-route export with transferred offsets ──
    #
    # KEY CHANGE from v3.0 → v3.1 (Transit-app style):
    #
    # Previously every route in a trunk group got the SAME set of merged
    # polylines.  This destroyed per-route geographic accuracy because
    # the trunk merge replaces coordinates with a single baseline.
    #
    # Now each route keeps its OWN raw GTFS polylines.  Corridor offsets
    # computed on the merged trunk (Phase 1-3) are *transferred* onto
    # the route's raw vertices via nearest-neighbour lookup.  This
    # preserves the original GTFS geographic precision while still
    # producing parallel-lane rendering where different trunk groups
    # share physical track.
    #
    # The iOS client's unifyTrainPolylines() already merges overlapping
    # same-colour polylines from different routes in the same trunk.
    result: list[SubwayLineOverlay] = []

    for overlay in overlays:
        trunk_idx = ROUTE_TO_TRUNK.get(overlay.route_id)
        if trunk_idx is None or trunk_idx not in trunk_paths:
            result.append(overlay)
            continue

        rep_paths = trunk_paths[trunk_idx]
        offset_map = vertex_offsets.get(trunk_idx, {})

        # Fast path: if this trunk has no corridor offsets at all,
        # return the original polylines untouched (no reprojection loss).
        has_any_offset = any(
            any(abs(o) > 0.01 for o in per_v)
            for per_v in offset_map.values()
        )
        if not has_any_offset:
            result.append(overlay)
            continue

        encoded_out: list[str] = []
        for enc in overlay.polylines:
            coords_wgs = decode_polyline(enc)
            if len(coords_wgs) < 2:
                encoded_out.append(enc)
                continue

            try:
                coords_m = project_to_meters(coords_wgs)
            except Exception:
                encoded_out.append(enc)
                continue

            route_line = LineString(coords_m)
            if route_line.length < MIN_PATH_LENGTH:
                # Short segments pass through unchanged
                encoded_out.append(enc)
                continue

            offsets = _transfer_offsets_to_route(coords_m, rep_paths, offset_map)
            route_has_offset = any(abs(o) > 0.01 for o in offsets)

            if route_has_offset:
                # Densify → arc-offset → despike → simplify (v3.2)
                dense_c, dense_o = _densify_with_offsets(coords_m, offsets)
                displaced = _apply_arc_offset(dense_c, dense_o)
                cleaned = _despike_coords(displaced)
                cleaned = _rdp_simplify(cleaned)
                if len(cleaned) >= 2:
                    result_wgs = project_to_wgs84(cleaned)
                    encoded_out.append(encode_polyline(result_wgs))
                else:
                    encoded_out.append(enc)
            else:
                # No offset for this polyline — keep raw GTFS coords
                encoded_out.append(enc)

        result.append(SubwayLineOverlay(
            route_id=overlay.route_id,
            color_hex=overlay.color_hex,
            polylines=encoded_out,
        ))

    total_polys = sum(len(o.polylines) for o in result)
    TrackLogger.info(
        f"[Pipeline] Complete: {len(trunk_paths)} trunks, "
        f"{total_polys} total polylines (per-route raw GTFS preserved)"
    )

    return result
