#
# corridor_pipeline.py  —  v3 trunk‑group parallel offsets
# TrackBackend
#
# 5‑phase pipeline:
#   Phase 1 – Trunk Merge:      Pool same‑color routes, unify into continuous paths
#   Phase 2 – Corridor Detect:  Find where different trunk groups share track
#   Phase 3 – Offset Compute:   Per‑vertex perpendicular offsets in shared corridors
#   Phase 4 – Export:           Reproject to WGS84, encode polylines
#   Phase 5 – Stop Snap:        Snap GTFS stops onto offset paths
#
# ═══════════════════════════════════════════════════════════════════════════════
# ARCHITECTURE CHANGE (v2 → v3)
#
#   v1  Used Shapely offset_curve() → EKG spikes, bowties, Columbus Circle bubble
#   v2  Unified skeleton from ALL 23 routes → 1 124 edges, 397 tiny fragments
#       (avg 5 pts each), catastrophic fragmentation, 361 edges with zero routes.
#   v3  Trunk-group level offsets → 11 groups, ~25-35 continuous polylines,
#       each with ~50-350 points.
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
# in EPSG:3857 ≈ 9.1 real meters at NYC latitude 40.7°).
LANE_WIDTH: float = 12.0

# Two trunk paths closer than this are considered to share a corridor.
# 40 m catches both directions of one avenue (~30 m) with margin,
# without merging adjacent avenues (~250 m apart).
CORRIDOR_DETECT_DIST: float = 40.0

# Minimum |dot product| of travel directions for two trunk paths to be
# considered parallel.  cos(45°) ≈ 0.707.
CORRIDOR_ALIGN_MIN: float = 0.707

# Number of vertices over which to smooth offset transitions at corridor
# entry/exit points.  Prevents abrupt lateral jumps.
BLEND_WINDOW: int = 5

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

        # >90% covered → near-duplicate, skip
        if ratio > 0.90:
            continue

        # <15% covered → unique corridor, keep whole
        if ratio < 0.15:
            kept.append(seg_line)
            _add_line(seg_line)
            continue

        # Partial overlap → extract uncovered branch stubs
        runs: list[tuple[int, int]] = []
        run_start: int | None = None

        for i in range(n):
            if not covered[i]:
                if run_start is None:
                    run_start = i
            else:
                if run_start is not None:
                    if i - run_start >= _MIN_BRANCH_RUN:
                        runs.append((run_start, i - 1))
                    run_start = None

        if run_start is not None and n - run_start >= _MIN_BRANCH_RUN:
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
            # Snap extension points to nearest trunk coordinate.
            ext_start = max(0, r_start - 5)
            ext_end = min(n - 1, r_end + 5)

            stub_coords: list[tuple[float, float]] = []
            for j in range(ext_start, ext_end + 1):
                if covered[j] and trunk_coords:
                    # Snap to nearest trunk point
                    px, py = coords[j]
                    best_dist = float("inf")
                    best_pt = coords[j]
                    for tx, ty in trunk_coords:
                        d = (tx - px) ** 2 + (ty - py) ** 2
                        if d < best_dist:
                            best_dist = d
                            best_pt = (tx, ty)
                    stub_coords.append(best_pt)
                else:
                    stub_coords.append(coords[j])

            if len(stub_coords) >= 2:
                stub_line = LineString(stub_coords)
                if stub_line.length >= MIN_PATH_LENGTH:
                    kept.append(stub_line)
                    _add_line(stub_line)

    # Chain-merge nearby endpoints
    return _chain_merge(kept, MERGE_GAP_M)


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

            for i in range(n):
                pt = Point(coords[i])
                dir_i = _local_direction(coords, i)

                # Query spatial index for nearby paths
                nearby_trunks: set[int] = set()
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
                    all_trunks = sorted(nearby_trunks | {trunk_idx})
                    lane = all_trunks.index(trunk_idx)
                    n_lanes = len(all_trunks)
                    centre = (n_lanes - 1) / 2.0
                    raw_offsets[i] = (lane - centre) * LANE_WIDTH

            # Smooth offset transitions
            path_offsets[path_idx] = _smooth_offsets(raw_offsets)

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
# Phase 3 — Apply Perpendicular Offsets
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


# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5 — Stop Processing: Snap GTFS stops onto offset lines
# ═══════════════════════════════════════════════════════════════════════════════

_processed_stops_cache: list[dict] | None = None


def get_processed_stops() -> list[dict]:
    """Return the most recently computed snapped stop positions."""
    return _processed_stops_cache or []


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

    # ── Phase 2: Detect corridors and compute per-vertex offsets ──
    try:
        vertex_offsets = _compute_corridor_offsets(trunk_paths)
    except Exception as exc:
        TrackLogger.error(
            f"[Pipeline] Phase 2 (Corridor detect) failed: {exc}", exc_info=True
        )
        vertex_offsets = {}

    # ── Phase 3: Apply perpendicular offsets ──
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
                displaced = _apply_perpendicular_offset(coords, per_vertex)
                cleaned = _despike_coords(displaced)
            else:
                # No corridor overlap — pass through unmodified
                cleaned = coords

            if len(cleaned) >= 2:
                offset_paths.append(LineString(cleaned))

        if offset_paths:
            trunk_offset_paths[trunk_idx] = offset_paths

    # ── Phase 5: Stop processing ──
    global _processed_stops_cache
    try:
        _processed_stops_cache = _process_stop_positions(trunk_offset_paths)
    except Exception as exc:
        TrackLogger.warning(
            f"[Pipeline] Phase 5 (Stop snap) failed: {exc}"
        )
        _processed_stops_cache = None

    # ── Phase 4: Export ──
    trunk_encoded = _export_trunk_paths(trunk_offset_paths)

    # ── Build output overlays ──
    # Each route gets its trunk group's polylines.  iOS deduplicates
    # same-colour overlaps via unifyTrainPolylines(), so duplicates
    # between routes in the same trunk group are harmless.
    result: list[SubwayLineOverlay] = []
    for overlay in overlays:
        trunk_idx = ROUTE_TO_TRUNK.get(overlay.route_id)
        if trunk_idx is not None and trunk_idx in trunk_encoded:
            result.append(SubwayLineOverlay(
                route_id=overlay.route_id,
                color_hex=overlay.color_hex,
                polylines=trunk_encoded[trunk_idx],
            ))
        else:
            # Unknown route or no paths — return original
            result.append(overlay)

    processed_trunks = len(trunk_encoded)
    total_polys = sum(len(o.polylines) for o in result)
    TrackLogger.info(
        f"[Pipeline] Complete: {processed_trunks}/{len(trunk_paths)} trunks, "
        f"{total_polys} total polylines"
    )

    return result
