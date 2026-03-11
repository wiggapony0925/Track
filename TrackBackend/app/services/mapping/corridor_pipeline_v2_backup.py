#
# corridor_pipeline.py
# TrackBackend
#
# Topological Graph Pipeline for generating parallel subway line offsets.
#
# 5-phase pipeline:
#   Phase 1 – Skeletonization: Build a unified street-level graph from GTFS shapes
#   Phase 2 – Lane Ordering:   Assign globally-consistent lane indices (Hungarian)
#   Phase 3 – Parallel Render: Manual perpendicular vertex offsets (NO offset_curve)
#   Phase 4 – Junction Blend:  Smooth transitions at corridor boundaries
#   Phase 5 – Export:          Reproject to WGS84 + encode polylines
#
# CRITICAL DESIGN DECISIONS (v2 rewrite):
#
# 1. NO Shapely offset_curve().  The original pipeline used offset_curve with
#    join_style="round" which produces self-intersecting bowties on curves,
#    explosive triangular spikes at acute angles, and degenerate geometry
#    at inflection points.  The new Phase 3 computes perpendicular normals
#    at each vertex, applies miter-join offsets with a strict clamp, and
#    does a despike pass — identical math to what the iOS client uses but
#    in meter-space for precision.
#
# 2. NO arc fillets.  The original Phase 4 tried to insert circular arcs at
#    junctions.  The pass-through detection was fragile (broke when route
#    counts changed across an edge boundary) and the arc radius could balloon
#    to 360m, creating the "Columbus Circle bubble."  The new Phase 4 simply
#    blends the offset transition over a short window at corridor boundaries,
#    which is visually superior and geometrically stable.
#
# 3. Tighter tolerances.  SNAP_TOLERANCE 8→5m, ROUTE_MAP_BUFFER 35→15m,
#    MIN_EDGE_LENGTH 25→10m.  The old values caused cross-contamination
#    (A/C/E jumping to 7th Ave) and over-pruning (Brooklyn curves vanishing).
#
# 4. The iOS client must NOT re-apply corridor offsets.  The server now
#    produces correctly-offset polylines; the iOS computeFlattenedPolylines()
#    must skip applyCorridorOffsets() and only do RDP + Catmull-Rom smoothing.
#
# Dependencies: networkx, scipy, shapely, pyproj, numpy
#

from __future__ import annotations

import math
from collections import defaultdict
from typing import NamedTuple

import networkx as nx
import numpy as np
from pyproj import Transformer
from scipy.optimize import linear_sum_assignment
from shapely.geometry import LineString, Point
from shapely.ops import linemerge, unary_union

from app.utils.logger import TrackLogger
from app.utils.polyline_utils import decode_polyline, encode_polyline


# ═══════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════

# Perpendicular distance between adjacent subway lanes (meters).
LANE_WIDTH: float = 12.0

# Tolerance for RDP simplification of input GTFS shapes (meters).
# 3m removes GPS jitter without destroying curve detail.
RDP_TOLERANCE: float = 3.0

# Snapping tolerance for collapsing near-coincident endpoints into shared
# skeleton nodes (meters).  5m catches NB/SB on the same avenue without
# merging adjacent avenues (~250m apart).
SNAP_TOLERANCE: float = 5.0

# Minimum skeleton edge length (meters).  Tiny stubs from GPS noise get
# pruned, but 10m (not 25m) preserves tight curves in Brooklyn/Queens.
MIN_EDGE_LENGTH: float = 10.0

# Minimum GTFS shape length to enter the pipeline (meters).
MIN_MAPPABLE_LENGTH: float = 50.0

# Maximum distance from a sample point to a skeleton edge for the route
# to be considered "traversing" that edge (meters).
# 15m is tight enough to prevent cross-avenue contamination.
ROUTE_MAP_BUFFER: float = 15.0

# Minimum |dot product| for a route to be "running along" an edge.
# cos(45°) ≈ 0.707.  Steeper crossings are overpass/underpass.
CROSSING_ALIGNMENT_MIN: float = 0.707

# Despike: minimum interior angle (degrees).  Vertices sharper than this
# are classified as offset spikes and removed.
DESPIKE_MIN_ANGLE_DEG: float = 25.0

# Despike: max excursion ratio (perp_distance / chord_length).
DESPIKE_MAX_EXCURSION: float = 0.6

# Miter join clamp: max miter scale factor.
# 2.0 prevents the extreme 4x spikes that the old iOS code allowed.
MITER_CLAMP: float = 2.0

# Number of transition points used to blend offset changes at corridor
# boundaries (Phase 4).
BLEND_WINDOW: int = 6


# ═══════════════════════════════════════════════════════════════════════════
# MTA trunk groups (must match iOS MapSystemViewModel.trunkGroups)
# ═══════════════════════════════════════════════════════════════════════════

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


# ═══════════════════════════════════════════════════════════════════════════
# Projectors (WGS84 ↔ Web Mercator)
# ═══════════════════════════════════════════════════════════════════════════

_to_meters = Transformer.from_crs("EPSG:4326", "EPSG:3857", always_xy=True)
_to_wgs84 = Transformer.from_crs("EPSG:3857", "EPSG:4326", always_xy=True)


def project_to_meters(coords: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Convert [(lat, lon), …] → [(x_m, y_m), …] in EPSG:3857."""
    return [_to_meters.transform(lon, lat) for lat, lon in coords]


def project_to_wgs84(coords: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Convert [(x_m, y_m), …] → [(lat, lon), …] in WGS84."""
    return [tuple(reversed(_to_wgs84.transform(x, y))) for x, y in coords]


# ═══════════════════════════════════════════════════════════════════════════
# Data types
# ═══════════════════════════════════════════════════════════════════════════

class RoutePolyline(NamedTuple):
    """A decoded, projected GTFS polyline for one route."""
    route_id: str
    coords_m: list[tuple[float, float]]  # EPSG:3857
    line_m: LineString                    # Shapely geometry in meters


class EdgeRouteInfo(NamedTuple):
    """Lane assignment metadata stored on each networkx edge."""
    route_id: str
    trunk_idx: int
    lane: int  # assigned lane index (0 = leftmost)


# ═══════════════════════════════════════════════════════════════════════════
# Geometry helpers
# ═══════════════════════════════════════════════════════════════════════════

def _point_dist(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Euclidean distance between two 2D points."""
    dx = a[0] - b[0]
    dy = a[1] - b[1]
    return math.sqrt(dx * dx + dy * dy)


def _unit_normal(p0: tuple[float, float], p1: tuple[float, float]) -> tuple[float, float]:
    """Left-hand perpendicular unit normal of the segment p0→p1.

    Returns (nx, ny) such that the normal points to the LEFT of the
    direction of travel.  To offset to the RIGHT, negate the result.
    """
    dx = p1[0] - p0[0]
    dy = p1[1] - p0[1]
    length = math.sqrt(dx * dx + dy * dy)
    if length < 1e-10:
        return (0.0, 0.0)
    # Left-hand normal: rotate 90° CCW → (-dy, dx) / length
    return (-dy / length, dx / length)


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1: Skeletonization — Build the unified topological graph
# ═══════════════════════════════════════════════════════════════════════════

def _build_skeleton(
    route_polylines: list[RoutePolyline],
) -> tuple[nx.Graph, dict[str, list[tuple[int, int]]]]:
    """Phase 1: Extract a topological skeleton from overlapping GTFS shapes.

    1. Simplify each shape with RDP (3m) to remove GPS jitter.
    2. Snap nearby endpoints within SNAP_TOLERANCE.
    3. Merge overlapping lines via unary_union → clean planar graph.
    4. Convert to networkx graph.
    5. Map each route onto skeleton edges via spatial index sampling.
    6. Filter overpass/underpass crossings by alignment angle.

    Returns:
        G: networkx.Graph with node positions and edge geometries.
        route_edges: dict[route_id → list of (u, v) edge keys].
    """
    if not route_polylines:
        return nx.Graph(), {}

    # ── 1a. Simplify all geometries ──
    simplified_lines: list[LineString] = []
    for rp in route_polylines:
        simplified = rp.line_m.simplify(RDP_TOLERANCE, preserve_topology=True)
        if simplified.geom_type == "LineString" and simplified.length >= MIN_MAPPABLE_LENGTH:
            simplified_lines.append(simplified)
        elif simplified.geom_type == "MultiLineString":
            for part in simplified.geoms:
                if part.geom_type == "LineString" and part.length >= MIN_MAPPABLE_LENGTH:
                    simplified_lines.append(part)

    if not simplified_lines:
        return nx.Graph(), {}

    TrackLogger.info(
        f"[Skeleton] Starting with {len(simplified_lines)} simplified line segments"
    )

    # ── 1b. Snap nearby endpoints to shared nodes ──
    endpoints: list[tuple[float, float]] = []
    for line in simplified_lines:
        endpoints.append(line.coords[0])
        endpoints.append(line.coords[-1])

    clusters = _cluster_points(endpoints, SNAP_TOLERANCE)

    snapped_lines: list[LineString] = []
    for line in simplified_lines:
        coords = list(line.coords)
        coords[0] = clusters.get(coords[0], coords[0])
        coords[-1] = clusters.get(coords[-1], coords[-1])
        snapped = LineString(coords)
        if snapped.length >= MIN_EDGE_LENGTH:
            snapped_lines.append(snapped)

    if not snapped_lines:
        return nx.Graph(), {}

    # ── 1c. Build the unified skeleton via unary_union ──
    raw_union = unary_union(snapped_lines)
    if raw_union.is_empty:
        return nx.Graph(), {}

    merged = linemerge(raw_union) if raw_union.geom_type != "LineString" else raw_union

    skeleton_segments: list[LineString] = []
    if merged.geom_type == "LineString":
        skeleton_segments = [merged]
    elif merged.geom_type == "MultiLineString":
        skeleton_segments = [g for g in merged.geoms if g.geom_type == "LineString"]
    elif hasattr(merged, "geoms"):
        skeleton_segments = [g for g in merged.geoms if g.geom_type == "LineString"]

    skeleton_segments = [s for s in skeleton_segments if s.length >= MIN_EDGE_LENGTH]

    if not skeleton_segments:
        return nx.Graph(), {}

    TrackLogger.info(
        f"[Skeleton] Unified skeleton: {len(skeleton_segments)} segments"
    )

    # ── 1d. Build the networkx graph ──
    G = nx.Graph()
    node_id_map: dict[tuple[float, float], int] = {}
    next_node_id = 0

    def _get_node_id(coord: tuple[float, float]) -> int:
        nonlocal next_node_id
        key = (round(coord[0], 0), round(coord[1], 0))
        if key not in node_id_map:
            node_id_map[key] = next_node_id
            G.add_node(next_node_id, pos=coord)
            next_node_id += 1
        return node_id_map[key]

    for seg in skeleton_segments:
        if len(seg.coords) < 2:
            continue
        u = _get_node_id(seg.coords[0])
        v = _get_node_id(seg.coords[-1])
        if u == v:
            continue
        if G.has_edge(u, v):
            existing_len = G[u][v].get("length", 0)
            if seg.length > existing_len:
                G[u][v]["geometry"] = seg
                G[u][v]["length"] = seg.length
        else:
            G.add_edge(u, v, geometry=seg, length=seg.length, routes=set())

    TrackLogger.info(
        f"[Skeleton] Graph: {G.number_of_nodes()} nodes, "
        f"{G.number_of_edges()} edges"
    )

    # ── 1e. Map routes onto skeleton edges via spatial index ──
    route_edges: dict[str, list[tuple[int, int]]] = defaultdict(list)

    from shapely import STRtree
    edge_keys: list[tuple[int, int]] = []
    edge_line_list: list[LineString] = []
    for u, v, data in G.edges(data=True):
        geom = data.get("geometry")
        if geom and not geom.is_empty:
            edge_keys.append((u, v))
            edge_line_list.append(geom)

    if not edge_line_list:
        return G, {}

    strtree = STRtree(edge_line_list)

    # Build route geometries for mapping
    route_geoms: dict[str, list[LineString]] = defaultdict(list)
    for rp in route_polylines:
        simplified = rp.line_m.simplify(RDP_TOLERANCE, preserve_topology=True)
        if simplified.geom_type == "LineString" and simplified.length >= MIN_MAPPABLE_LENGTH:
            route_geoms[rp.route_id].append(simplified)
        elif simplified.geom_type == "MultiLineString":
            for part in simplified.geoms:
                if part.geom_type == "LineString" and part.length >= MIN_MAPPABLE_LENGTH:
                    route_geoms[rp.route_id].append(part)

    for route_id, geoms in route_geoms.items():
        for route_line in geoms:
            sample_spacing = 30.0
            n_samples = max(2, int(route_line.length / sample_spacing))
            sample_points = [
                route_line.interpolate(i * route_line.length / n_samples)
                for i in range(n_samples + 1)
            ]

            edge_votes: dict[tuple[int, int], int] = defaultdict(int)
            for sample_pt in sample_points:
                nearest_idx = strtree.nearest(sample_pt)
                nearest_geom = edge_line_list[nearest_idx]
                dist = nearest_geom.distance(sample_pt)
                if dist < ROUTE_MAP_BUFFER:
                    edge_votes[edge_keys[nearest_idx]] += 1

            for (u, v), votes in edge_votes.items():
                edge_len = G[u][v].get("length", 0)
                expected_samples = max(1, edge_len / sample_spacing)
                coverage_ratio = votes / expected_samples
                if votes >= 2 and coverage_ratio >= 0.20:
                    G[u][v]["routes"].add(route_id)
                    if (u, v) not in route_edges[route_id]:
                        route_edges[route_id].append((u, v))

    # ── 1f. Filter overpass crossings ──
    _filter_crossing_route_mappings(G, route_edges, route_geoms)

    mapped_count = sum(1 for e_data in G.edges(data=True) if e_data[2].get("routes"))
    TrackLogger.info(
        f"[Skeleton] Route mapping: {len(route_edges)} routes mapped, "
        f"{mapped_count}/{G.number_of_edges()} edges have routes"
    )

    return G, dict(route_edges)


def _cluster_points(
    points: list[tuple[float, float]],
    tolerance: float,
) -> dict[tuple[float, float], tuple[float, float]]:
    """Cluster nearby points and return original → centroid mapping.

    Grid-based O(n) approach: points in the same tolerance-sized cell
    (and 8 neighbours) get merged to their centroid.
    """
    cells: dict[tuple[int, int], list[tuple[float, float]]] = defaultdict(list)
    for pt in points:
        cell = (int(pt[0] // tolerance), int(pt[1] // tolerance))
        cells[cell].append(pt)

    point_to_centroid: dict[tuple[float, float], tuple[float, float]] = {}
    processed_cells: set[tuple[int, int]] = set()

    for cell, pts in cells.items():
        if cell in processed_cells:
            continue

        cluster_pts: list[tuple[float, float]] = []
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                neighbour = (cell[0] + di, cell[1] + dj)
                if neighbour in cells:
                    cluster_pts.extend(cells[neighbour])
                    processed_cells.add(neighbour)

        if not cluster_pts:
            continue

        cx = sum(p[0] for p in cluster_pts) / len(cluster_pts)
        cy = sum(p[1] for p in cluster_pts) / len(cluster_pts)
        centroid = (cx, cy)

        for pt in cluster_pts:
            dx = pt[0] - cx
            dy = pt[1] - cy
            if math.sqrt(dx * dx + dy * dy) <= tolerance:
                point_to_centroid[pt] = centroid

    return point_to_centroid


def _filter_crossing_route_mappings(
    G: nx.Graph,
    route_edges: dict[str, list[tuple[int, int]]],
    route_geoms: dict[str, list[LineString]],
) -> None:
    """Remove route→edge mappings where the route crosses at a steep angle.

    A crossing angle > 45° indicates an overpass/underpass, not a route
    running along the edge.  Mutates G and route_edges in-place.
    """
    for route_id, geoms in route_geoms.items():
        if not geoms:
            continue

        edges_to_remove: list[tuple[int, int]] = []

        for u, v in list(route_edges.get(route_id, [])):
            if not G.has_edge(u, v):
                continue
            edge_geom = G[u][v].get("geometry")
            if edge_geom is None or edge_geom.is_empty or len(edge_geom.coords) < 2:
                continue

            ec = list(edge_geom.coords)
            edx = ec[-1][0] - ec[0][0]
            edy = ec[-1][1] - ec[0][1]
            elen = math.sqrt(edx * edx + edy * edy)
            if elen < 1e-6:
                continue
            edx /= elen
            edy /= elen

            best_alignment = 0.0
            for rgeom in geoms:
                edge_mid = edge_geom.interpolate(0.5, normalized=True)
                proj_dist = rgeom.project(edge_mid)
                nearest_pt = rgeom.interpolate(proj_dist)

                if edge_mid.distance(nearest_pt) > ROUTE_MAP_BUFFER * 2:
                    continue

                delta = min(25.0, rgeom.length * 0.1)
                p1 = rgeom.interpolate(max(0, proj_dist - delta))
                p2 = rgeom.interpolate(min(rgeom.length, proj_dist + delta))
                rdx = p2.x - p1.x
                rdy = p2.y - p1.y
                rlen = math.sqrt(rdx * rdx + rdy * rdy)
                if rlen < 1e-6:
                    continue
                rdx /= rlen
                rdy /= rlen

                alignment = abs(edx * rdx + edy * rdy)
                best_alignment = max(best_alignment, alignment)

            if best_alignment < CROSSING_ALIGNMENT_MIN:
                edges_to_remove.append((u, v))

        for eu, ev in edges_to_remove:
            G[eu][ev]["routes"].discard(route_id)
            if (eu, ev) in route_edges.get(route_id, []):
                route_edges[route_id].remove((eu, ev))


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: Global Lane Ordering — Hungarian Algorithm
# ═══════════════════════════════════════════════════════════════════════════

def _compute_lane_assignments(
    G: nx.Graph,
    route_edges: dict[str, list[tuple[int, int]]],
) -> dict[tuple[int, int], dict[str, int]]:
    """Phase 2: Compute globally-consistent lane assignments for every edge.

    For each edge, routes are assigned to lane positions (0 = leftmost)
    using the Hungarian algorithm with penalties for:
      - Deviating from canonical trunk order
      - Swapping lanes between consecutive edges (crossover)
      - Trunk cohesion (same-color lines should be adjacent)
      - Divergence direction (routes splitting left go to left lanes)

    Returns: dict[edge_key → {route_id: lane_index}]
    """
    if not route_edges:
        return {}

    # ── 2a. Canonical ordering: trunk first, then alphabetically ──
    all_routes_in_graph: set[str] = set()
    for routes in route_edges.values():
        for edge in routes:
            u, v = edge
            if G.has_edge(u, v):
                all_routes_in_graph.update(G[u][v].get("routes", set()))

    canonical_order = sorted(
        all_routes_in_graph,
        key=lambda r: (ROUTE_TO_TRUNK.get(r, 99), r),
    )
    route_to_canonical: dict[str, int] = {r: i for i, r in enumerate(canonical_order)}

    # ── 2b. BFS-order edge processing for consistency propagation ──
    edge_lanes: dict[tuple[int, int], dict[str, int]] = {}
    route_last_lane: dict[str, int] = {}

    if G.number_of_nodes() == 0:
        return {}

    start_node = max(G.nodes(), key=lambda n: G.degree(n))
    visited_edges: set[tuple[int, int]] = set()

    for u, v in nx.bfs_edges(G, source=start_node):
        edge_key = (min(u, v), max(u, v))
        if edge_key in visited_edges:
            continue
        visited_edges.add(edge_key)

        routes_on_edge = G[u][v].get("routes", set())
        if not routes_on_edge:
            continue

        route_list = sorted(
            routes_on_edge,
            key=lambda r: route_to_canonical.get(r, 99),
        )
        n = len(route_list)

        if n == 1:
            edge_lanes[edge_key] = {route_list[0]: 0}
            route_last_lane[route_list[0]] = 0
            continue

        # ── Hungarian cost matrix ──
        cost = np.zeros((n, n), dtype=np.float64)

        for i, route in enumerate(route_list):
            trunk_i = ROUTE_TO_TRUNK.get(route, -1)

            for lane in range(n):
                penalty = 0.0

                # Penalty 1: Canonical order deviation
                rank_among_edge_routes = sorted(
                    range(n),
                    key=lambda idx: route_to_canonical.get(route_list[idx], 0),
                )
                ideal_lane = rank_among_edge_routes.index(i)
                penalty += 2.0 * abs(lane - ideal_lane)

                # Penalty 2: Crossover from previous edge
                if route in route_last_lane:
                    prev_lane = route_last_lane[route]
                    penalty += 5.0 * abs(lane - prev_lane)

                # Penalty 3: Divergence direction
                downstream_node = v
                for neighbor in G.neighbors(downstream_node):
                    if neighbor == u:
                        continue
                    neighbor_routes = G.edges[downstream_node, neighbor].get("routes", set())
                    if route in neighbor_routes:
                        edge_geom = G[u][v].get("geometry")
                        next_geom = G.edges[downstream_node, neighbor].get("geometry")
                        if edge_geom and next_geom:
                            diverge = _compute_divergence_side(
                                edge_geom, next_geom, downstream_node, G
                            )
                            if diverge != 0:
                                center = (n - 1) / 2.0
                                if diverge < 0:
                                    penalty += 3.0 * max(0, lane - center)
                                else:
                                    penalty += 3.0 * max(0, center - lane)
                        break

                cost[i][lane] = penalty

        # ── Solve ──
        try:
            row_ind, col_ind = linear_sum_assignment(cost)
            assignment = {}
            for i, lane in zip(row_ind, col_ind):
                assignment[route_list[i]] = lane
                route_last_lane[route_list[i]] = lane
            edge_lanes[edge_key] = assignment
        except Exception:
            assignment = {route_list[i]: i for i in range(n)}
            edge_lanes[edge_key] = assignment

    # Handle disconnected components
    for u, v, data in G.edges(data=True):
        edge_key = (min(u, v), max(u, v))
        if edge_key in edge_lanes:
            continue
        routes_on_edge = data.get("routes", set())
        if routes_on_edge:
            route_list = sorted(
                routes_on_edge,
                key=lambda r: route_to_canonical.get(r, 99),
            )
            edge_lanes[edge_key] = {r: i for i, r in enumerate(route_list)}

    TrackLogger.info(
        f"[LaneOrder] Assigned lanes for {len(edge_lanes)} edges, "
        f"{len(canonical_order)} routes"
    )

    return edge_lanes


def _compute_divergence_side(
    edge_geom: LineString,
    next_geom: LineString,
    node: int,
    G: nx.Graph,
) -> int:
    """Determine if a connecting edge diverges LEFT (-1) or RIGHT (+1).

    Uses cross product of incoming and outgoing directions at the shared node.
    Returns 0 if roughly straight or indeterminate.
    """
    try:
        node_pos = G.nodes[node].get("pos")
        if node_pos is None:
            return 0

        edge_coords = list(edge_geom.coords)
        node_pt = Point(node_pos)

        if node_pt.distance(Point(edge_coords[-1])) < node_pt.distance(Point(edge_coords[0])):
            if len(edge_coords) >= 2:
                dx_in = edge_coords[-1][0] - edge_coords[-2][0]
                dy_in = edge_coords[-1][1] - edge_coords[-2][1]
            else:
                return 0
        else:
            if len(edge_coords) >= 2:
                dx_in = edge_coords[0][0] - edge_coords[1][0]
                dy_in = edge_coords[0][1] - edge_coords[1][1]
            else:
                return 0

        next_coords = list(next_geom.coords)
        if node_pt.distance(Point(next_coords[0])) < node_pt.distance(Point(next_coords[-1])):
            if len(next_coords) >= 2:
                dx_out = next_coords[1][0] - next_coords[0][0]
                dy_out = next_coords[1][1] - next_coords[0][1]
            else:
                return 0
        else:
            if len(next_coords) >= 2:
                dx_out = next_coords[-2][0] - next_coords[-1][0]
                dy_out = next_coords[-2][1] - next_coords[-1][1]
            else:
                return 0

        cross = dx_in * dy_out - dy_in * dx_out
        if abs(cross) < 1e-6:
            return 0
        return -1 if cross > 0 else 1

    except Exception:
        return 0


# ═══════════════════════════════════════════════════════════════════════════
# Phase 3: Parallel Rendering — Manual Perpendicular Vertex Offsets
# ═══════════════════════════════════════════════════════════════════════════
#
# This is the core fix.  The old pipeline used Shapely's offset_curve()
# which produces self-intersecting bowties, explosive spikes, and
# degenerate artifacts.  The new approach:
#
# 1. Chain each route's skeleton edges into continuous paths.
# 2. For each path, concatenate skeleton edge geometries.
# 3. Compute per-vertex perpendicular offset using miter joins.
# 4. Clamp miter scale to prevent spikes.
# 5. Despike any remaining artifacts.
#
# This is mathematically identical to what PolylineUtils.swift does
# (applyCorridorOffsets) but operates in meter-space for precision.

def _render_parallel_offsets(
    G: nx.Graph,
    edge_lanes: dict[tuple[int, int], dict[str, int]],
) -> dict[str, list[LineString]]:
    """Phase 3: Generate offset geometries via manual perpendicular vertex offsets.

    For each route:
    1. Collect skeleton edges, chain into continuous paths.
    2. Compute per-vertex offset distance from lane assignment.
    3. Apply perpendicular offset with clamped miter joins.
    4. Despike the result.

    Returns: dict[route_id → list of offset LineString geometries (EPSG:3857)].
    """
    # ── Collect edges per route ──
    route_edge_map: dict[str, list[tuple[int, int]]] = defaultdict(list)
    for (u, v), assignments in edge_lanes.items():
        for route_id in assignments:
            route_edge_map[route_id].append((u, v))

    route_segments: dict[str, list[LineString]] = defaultdict(list)

    for route_id, edges in route_edge_map.items():
        if not edges:
            continue

        paths = _chain_edges_into_paths(G, edges)

        for path_edges in paths:
            if not path_edges:
                continue

            # ── Stitch skeleton geometry for this path ──
            combined_coords = _stitch_edge_geometries(G, path_edges)
            if not combined_coords or len(combined_coords) < 2:
                continue

            # ── Compute per-vertex offset distances ──
            # For each coord, find which skeleton edge it belongs to and
            # look up the lane assignment to compute the offset.
            per_vertex_offsets = _compute_per_vertex_offsets(
                G, path_edges, edge_lanes, route_id, combined_coords
            )

            # ── Apply perpendicular offset with clamped miter joins ──
            offset_coords = _apply_perpendicular_offset(combined_coords, per_vertex_offsets)

            if offset_coords and len(offset_coords) >= 2:
                # ── Despike ──
                despiked = _despike_coords(offset_coords)
                if despiked and len(despiked) >= 2:
                    route_segments[route_id].append(LineString(despiked))

    return dict(route_segments)


def _compute_per_vertex_offsets(
    G: nx.Graph,
    path_edges: list[tuple[int, int]],
    edge_lanes: dict[tuple[int, int], dict[str, int]],
    route_id: str,
    combined_coords: list[tuple[float, float]],
) -> list[float]:
    """Compute the perpendicular offset distance for each vertex.

    Walks the stitched coordinates and tracks which skeleton edge each
    vertex belongs to, then looks up the lane assignment for that edge.
    """
    n_coords = len(combined_coords)
    offsets = [0.0] * n_coords

    # Build a list of (edge_key, edge_length, offset_for_this_route)
    edge_info: list[tuple[float, float]] = []  # (cumulative_end_dist, offset_m)
    cumulative = 0.0

    for edge in path_edges:
        u, v = edge
        if not G.has_edge(u, v):
            continue
        edge_geom = G[u][v].get("geometry")
        if edge_geom is None:
            continue

        ek = (min(u, v), max(u, v))
        assignments = edge_lanes.get(ek, {})
        n_lanes = len(assignments)
        lane_idx = assignments.get(route_id, 0)
        center = (n_lanes - 1) / 2.0 if n_lanes > 0 else 0.0
        offset_m = (lane_idx - center) * LANE_WIDTH

        cumulative += edge_geom.length
        edge_info.append((cumulative, offset_m))

    if not edge_info:
        return offsets

    # Map each vertex to a cumulative distance along the combined path
    cum_dist = 0.0
    edge_idx = 0
    total_path_len = edge_info[-1][0] if edge_info else 0.0

    for i in range(n_coords):
        if i > 0:
            cum_dist += _point_dist(combined_coords[i - 1], combined_coords[i])

        # Find which edge this vertex belongs to
        while edge_idx < len(edge_info) - 1 and cum_dist > edge_info[edge_idx][0]:
            edge_idx += 1

        offsets[i] = edge_info[edge_idx][1]

    return offsets


def _apply_perpendicular_offset(
    coords: list[tuple[float, float]],
    offsets: list[float],
) -> list[tuple[float, float]]:
    """Apply perpendicular offset to each vertex using clamped miter joins.

    For interior vertices, computes the averaged normal from the two
    adjacent segments, then applies a miter correction (1/dot) clamped
    to MITER_CLAMP to prevent spikes.

    This is the same math as iOS PolylineUtils.applyCorridorOffsets but
    in meter-space with a tighter miter clamp (2.0 vs 4.0).
    """
    n = len(coords)
    if n < 2:
        return list(coords)

    # Compute per-segment unit normals
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
            # Average the normals of adjacent segments (miter join)
            n1x, n1y = seg_normals[i - 1]
            n2x, n2y = seg_normals[i]

            mx = n1x + n2x
            my = n1y + n2y
            mlen = math.sqrt(mx * mx + my * my)

            if mlen > 1e-10:
                mx /= mlen
                my /= mlen

                # Miter correction: 1 / dot(miter, segment_normal)
                dot = mx * n1x + my * n1y
                if abs(dot) > 0.01:
                    miter_scale = min(1.0 / abs(dot), MITER_CLAMP)
                else:
                    miter_scale = MITER_CLAMP

                nx_ = mx * miter_scale
                ny = my * miter_scale
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
    """Remove spike vertices from an offset coordinate list.

    Spikes are vertices with:
    - Interior angle < DESPIKE_MIN_ANGLE_DEG (sharp switchback)
    - Excursion ratio > DESPIKE_MAX_EXCURSION (flew off to infinity)
    """
    if len(coords) <= 3:
        return coords

    min_angle_rad = math.radians(DESPIKE_MIN_ANGLE_DEG)
    keep: list[tuple[float, float]] = [coords[0]]

    for i in range(1, len(coords) - 1):
        prev = coords[i - 1]
        curr = coords[i]
        nxt = coords[i + 1]

        ax = prev[0] - curr[0]
        ay = prev[1] - curr[1]
        bx = nxt[0] - curr[0]
        by = nxt[1] - curr[1]

        a_len = math.sqrt(ax * ax + ay * ay)
        b_len = math.sqrt(bx * bx + by * by)

        if a_len < 1e-10 or b_len < 1e-10:
            continue

        cos_angle = (ax * bx + ay * by) / (a_len * b_len)
        cos_angle = max(-1.0, min(1.0, cos_angle))
        angle = math.acos(cos_angle)

        if angle < min_angle_rad:
            continue  # Drop spike

        # Excursion check
        chord_dx = nxt[0] - prev[0]
        chord_dy = nxt[1] - prev[1]
        chord_len = math.sqrt(chord_dx * chord_dx + chord_dy * chord_dy)
        if chord_len > 1e-6:
            cross = abs(chord_dx * (prev[1] - curr[1]) - chord_dy * (prev[0] - curr[0]))
            perp_dist = cross / chord_len
            if perp_dist / chord_len > DESPIKE_MAX_EXCURSION:
                continue  # Drop — vertex flew off

        keep.append(curr)

    keep.append(coords[-1])

    if len(keep) < 2:
        return coords  # Fallback: return original if too aggressive
    return keep


def _chain_edges_into_paths(
    G: nx.Graph,
    edges: list[tuple[int, int]],
) -> list[list[tuple[int, int]]]:
    """Chain graph edges into continuous paths.

    Given a route's set of skeleton edges, walks the graph to produce
    ordered path(s).  Starts from degree-1 endpoint nodes for clean chains.
    """
    if not edges:
        return []

    adj: dict[int, list[int]] = defaultdict(list)
    edge_set: set[tuple[int, int]] = set()
    for u, v in edges:
        canonical = (min(u, v), max(u, v))
        if canonical not in edge_set:
            edge_set.add(canonical)
            adj[u].append(v)
            adj[v].append(u)

    visited_edges: set[tuple[int, int]] = set()
    paths: list[list[tuple[int, int]]] = []

    node_degree = {n: len(neighbors) for n, neighbors in adj.items()}
    start_nodes = [n for n, d in node_degree.items() if d == 1]
    if not start_nodes:
        start_nodes = list(adj.keys())

    for start in start_nodes:
        path: list[tuple[int, int]] = []
        current = start

        while True:
            found_next = False
            for neighbor in adj.get(current, []):
                ek = (min(current, neighbor), max(current, neighbor))
                if ek not in visited_edges:
                    visited_edges.add(ek)
                    path.append((current, neighbor))
                    current = neighbor
                    found_next = True
                    break
            if not found_next:
                break

        if path:
            paths.append(path)

    return paths


def _stitch_edge_geometries(
    G: nx.Graph,
    path_edges: list[tuple[int, int]],
) -> list[tuple[float, float]]:
    """Concatenate skeleton edge geometries along a path.

    Reverses edges as needed to maintain continuity. Deduplicates
    shared endpoints.
    """
    all_coords: list[tuple[float, float]] = []

    for u, v in path_edges:
        if not G.has_edge(u, v):
            continue
        edge_geom = G[u][v].get("geometry")
        if edge_geom is None or edge_geom.is_empty:
            continue

        coords = list(edge_geom.coords)
        if len(coords) < 2:
            continue

        if all_coords:
            last_pt = all_coords[-1]
            d_start = _point_dist(last_pt, coords[0])
            d_end = _point_dist(last_pt, coords[-1])
            if d_end < d_start:
                coords = coords[::-1]

            if _point_dist(all_coords[-1], coords[0]) < SNAP_TOLERANCE:
                coords = coords[1:]

        all_coords.extend(coords)

    return all_coords


# ═══════════════════════════════════════════════════════════════════════════
# Phase 4: Junction Blending — Smooth Transitions at Corridor Boundaries
# ═══════════════════════════════════════════════════════════════════════════
#
# Instead of the old arc-fillet approach (which created Columbus Circle
# bubbles and required fragile pass-through detection), Phase 4 now
# simply smooths out any abrupt offset transitions.
#
# When a route's offset changes between consecutive skeleton edges
# (e.g., from 12m left to 0m as another line diverges), the transition
# was already computed as a per-vertex step in Phase 3.  Phase 4 applies
# a moving-average blend over BLEND_WINDOW vertices to make this smooth.

def _apply_junction_blending(
    route_segments: dict[str, list[LineString]],
) -> dict[str, list[LineString]]:
    """Phase 4: Smooth junction transitions with moving-average blending.

    For each route's offset geometry, applies a coordinate-level
    moving-average to eliminate any remaining sharp transitions at
    corridor boundaries.
    """
    if not route_segments:
        return route_segments

    smoothed: dict[str, list[LineString]] = {}

    for route_id, segments in route_segments.items():
        smooth_segs: list[LineString] = []
        for seg in segments:
            coords = list(seg.coords)
            if len(coords) < BLEND_WINDOW * 2:
                # Too short to smooth — keep as-is
                smooth_segs.append(seg)
                continue

            # Moving-average smooth (preserving endpoints)
            blended = list(coords)
            half_w = BLEND_WINDOW // 2
            for i in range(half_w, len(coords) - half_w):
                sx, sy = 0.0, 0.0
                count = 0
                for k in range(i - half_w, i + half_w + 1):
                    sx += coords[k][0]
                    sy += coords[k][1]
                    count += 1
                blended[i] = (sx / count, sy / count)

            if len(blended) >= 2:
                smooth_segs.append(LineString(blended))
            else:
                smooth_segs.append(seg)

        if smooth_segs:
            smoothed[route_id] = smooth_segs

    return smoothed


# ═══════════════════════════════════════════════════════════════════════════
# Phase 5: Export — Merge, Reproject, Encode
# ═══════════════════════════════════════════════════════════════════════════

def _export_to_encoded_polylines(
    route_segments: dict[str, list[LineString]],
) -> dict[str, list[str]]:
    """Phase 5: Merge fragments, reproject to WGS84, and encode.

    1. Merge nearby fragments into continuous polylines.
    2. Reproject from EPSG:3857 to WGS84.
    3. Google-encode each polyline.

    Returns: dict[route_id → list of encoded polyline strings].
    """
    encoded_by_route: dict[str, list[str]] = {}

    for route_id, segments in route_segments.items():
        if not segments:
            continue

        # Merge nearby line fragments
        merged = _merge_line_segments(segments, tolerance=SNAP_TOLERANCE * 2)

        encoded: list[str] = []
        for line in merged:
            coords_m = list(line.coords)
            if len(coords_m) < 2:
                continue

            try:
                coords_wgs = project_to_wgs84(coords_m)
                encoded.append(encode_polyline(coords_wgs))
            except Exception:
                continue

        if encoded:
            encoded_by_route[route_id] = encoded

    return encoded_by_route


def _merge_line_segments(
    segments: list[LineString],
    tolerance: float = 10.0,
) -> list[LineString]:
    """Merge LineString segments whose endpoints are within tolerance.

    Greedy nearest-endpoint chaining to reduce fragment count.
    """
    if len(segments) <= 1:
        return segments

    # Order segments by connectivity
    ordered = _order_segments(segments)

    # Chain together segments whose endpoints touch
    merged: list[LineString] = []
    current_coords: list[tuple[float, float]] = []

    for seg in ordered:
        seg_coords = list(seg.coords)
        if not seg_coords:
            continue

        if not current_coords:
            current_coords = list(seg_coords)
        else:
            gap = _point_dist(current_coords[-1], seg_coords[0])
            if gap <= tolerance:
                current_coords.extend(seg_coords[1:])
            else:
                if len(current_coords) >= 2:
                    merged.append(LineString(current_coords))
                current_coords = list(seg_coords)

    if len(current_coords) >= 2:
        merged.append(LineString(current_coords))

    return merged


def _order_segments(segments: list[LineString]) -> list[LineString]:
    """Order LineStrings into a roughly connected chain.

    Greedy nearest-endpoint chaining.
    """
    if len(segments) <= 1:
        return list(segments)

    remaining = list(segments)
    chain: list[LineString] = [remaining.pop(0)]

    while remaining:
        current_end = chain[-1].coords[-1]
        best_idx = 0
        best_dist = float("inf")
        best_reversed = False

        for i, seg in enumerate(remaining):
            d_start = _point_dist(current_end, seg.coords[0])
            d_end = _point_dist(current_end, seg.coords[-1])

            if d_start < best_dist:
                best_dist = d_start
                best_idx = i
                best_reversed = False
            if d_end < best_dist:
                best_dist = d_end
                best_idx = i
                best_reversed = True

        seg = remaining.pop(best_idx)
        if best_reversed:
            seg = LineString(seg.coords[::-1])
        chain.append(seg)

    return chain


# ═══════════════════════════════════════════════════════════════════════════
# Phase 6: Stop Processing — Snap GTFS stops onto offset lines
# ═══════════════════════════════════════════════════════════════════════════

_processed_stops_cache: list[dict] | None = None


def get_processed_stops() -> list[dict]:
    """Return the most recently computed snapped stop positions.

    Call after ``apply_topological_offsets`` to retrieve stop metadata
    for the iOS app to draw station markers on the offset lines.
    """
    return _processed_stops_cache or []


def _process_stop_positions(
    route_segments: dict[str, list[LineString]],
) -> list[dict]:
    """Phase 6: Snap GTFS stops onto offset lines.

    For each subway station, projects the stop coordinate into EPSG:3857
    and snaps it onto each route's nearest offset polyline.  Classifies
    stations as transfer hubs (≥2 trunk groups).
    """
    from app.services.mapping.subway_shapes import get_all_subway_stations

    raw_stations = get_all_subway_stations()
    if not raw_stations:
        return []

    route_geoms: dict[str, list[LineString]] = {}
    for route_id, segments in route_segments.items():
        valid = [s for s in segments if s.length >= MIN_EDGE_LENGTH]
        if valid:
            route_geoms[route_id] = valid

    results: list[dict] = []

    for station in raw_stations:
        station_id: str = station["id"]
        name: str = station["name"]
        routes: list[str] = station.get("routes", [])
        orig_lat: float = station["lat"]
        orig_lon: float = station["lon"]

        try:
            stop_m = _to_meters.transform(orig_lon, orig_lat)
        except Exception:
            continue

        stop_pt = Point(stop_m)
        positions: list[dict] = []
        trunk_groups_seen: set[int] = set()

        for route_id in routes:
            if route_id not in route_geoms:
                continue

            segs = route_geoms[route_id]
            best_dist = float("inf")
            best_seg: LineString | None = None
            for seg in segs:
                d = seg.distance(stop_pt)
                if d < best_dist:
                    best_dist = d
                    best_seg = seg

            if best_seg is None or best_dist > ROUTE_MAP_BUFFER * 5:
                continue

            projected_dist = best_seg.project(stop_pt)
            snapped_pt = best_seg.interpolate(projected_dist)

            try:
                lon, lat = _to_wgs84.transform(snapped_pt.x, snapped_pt.y)
            except Exception:
                continue

            positions.append({
                "route_id": route_id,
                "lat": lat,
                "lon": lon,
            })

            trunk = ROUTE_TO_TRUNK.get(route_id)
            if trunk is not None:
                trunk_groups_seen.add(trunk)

        if not positions:
            positions.append({
                "route_id": routes[0] if routes else "",
                "lat": orig_lat,
                "lon": orig_lon,
            })

        is_transfer = len(trunk_groups_seen) >= 2

        results.append({
            "station_id": station_id,
            "name": name,
            "is_transfer": is_transfer,
            "positions": positions,
        })

    TrackLogger.info(
        f"[StopSnap] Processed {len(results)} stations, "
        f"{sum(1 for r in results if r['is_transfer'])} transfer hubs"
    )

    return results


# ═══════════════════════════════════════════════════════════════════════════
# MAIN ENTRY POINT — orchestrates all phases
# ═══════════════════════════════════════════════════════════════════════════

def apply_topological_offsets(
    overlays: list,  # list[SubwayLineOverlay]
) -> list:
    """Top-level entry point: 5-phase topological graph pipeline.

    Input:  list of SubwayLineOverlay (route_id, color_hex, polylines[encoded])
    Output: list of SubwayLineOverlay with properly offset polylines.

    Phases:
    1. Skeletonization → unified topological graph
    2. Lane ordering → anti-spaghetti assignments via Hungarian algorithm
    3. Parallel rendering → manual perpendicular vertex offsets
    4. Junction blending → smooth transitions at corridor boundaries
    5. Export → merge fragments, reproject to WGS84, encode polylines
    6. Stop processing → snap stops to offset lines (cached for /stations/processed)
    """
    from app.models import SubwayLineOverlay

    if not overlays:
        return overlays

    TrackLogger.info(
        f"[Pipeline] Starting topological offset pipeline for {len(overlays)} overlays"
    )

    # ── Decode and project all polylines ──
    route_polylines: list[RoutePolyline] = []
    original_polys: dict[str, list[list[tuple[float, float]]]] = {}

    for overlay in overlays:
        decoded = [decode_polyline(p) for p in overlay.polylines]
        original_polys[overlay.route_id] = decoded

        for coords in decoded:
            if len(coords) < 2:
                continue
            try:
                projected = project_to_meters(coords)
                line_m = LineString(projected)
                if line_m.length >= MIN_MAPPABLE_LENGTH:
                    route_polylines.append(RoutePolyline(
                        route_id=overlay.route_id,
                        coords_m=projected,
                        line_m=line_m,
                    ))
            except Exception:
                continue

    if not route_polylines:
        TrackLogger.warning("[Pipeline] No valid route polylines — returning originals")
        return overlays

    TrackLogger.info(f"[Pipeline] Decoded {len(route_polylines)} route polylines")

    # ── Phase 1: Build skeleton graph ──
    try:
        G, route_edges = _build_skeleton(route_polylines)
    except Exception as exc:
        TrackLogger.error(f"[Pipeline] Phase 1 (Skeleton) failed: {exc}", exc_info=True)
        return overlays

    if G.number_of_edges() == 0:
        TrackLogger.warning("[Pipeline] Empty skeleton graph — returning originals")
        return overlays

    # ── Phase 2: Compute lane assignments ──
    try:
        edge_lanes = _compute_lane_assignments(G, route_edges)
    except Exception as exc:
        TrackLogger.error(f"[Pipeline] Phase 2 (Lane ordering) failed: {exc}", exc_info=True)
        return overlays

    if not edge_lanes:
        TrackLogger.warning("[Pipeline] No lane assignments — returning originals")
        return overlays

    # ── Phase 3: Render parallel offsets (manual perpendicular, NO offset_curve) ──
    try:
        route_segments = _render_parallel_offsets(G, edge_lanes)
    except Exception as exc:
        TrackLogger.error(f"[Pipeline] Phase 3 (Parallel render) failed: {exc}", exc_info=True)
        return overlays

    # ── Phase 4: Junction blending ──
    try:
        route_segments = _apply_junction_blending(route_segments)
    except Exception as exc:
        TrackLogger.warning(f"[Pipeline] Phase 4 (Junction blending) failed: {exc}")

    # ── Phase 6: Snap stops onto offset lines ──
    global _processed_stops_cache
    try:
        _processed_stops_cache = _process_stop_positions(route_segments)
    except Exception as exc:
        TrackLogger.warning(f"[Pipeline] Phase 6 (Stop processing) failed: {exc}")
        _processed_stops_cache = None

    # ── Phase 5: Export & reproject ──
    try:
        encoded_by_route = _export_to_encoded_polylines(route_segments)
    except Exception as exc:
        TrackLogger.error(f"[Pipeline] Phase 5 (Export) failed: {exc}", exc_info=True)
        return overlays

    # ── Build output overlays ──
    result: list[SubwayLineOverlay] = []
    for overlay in overlays:
        if overlay.route_id in encoded_by_route:
            new_polys = encoded_by_route[overlay.route_id]
            if new_polys:
                result.append(SubwayLineOverlay(
                    route_id=overlay.route_id,
                    color_hex=overlay.color_hex,
                    polylines=new_polys,
                ))
            else:
                result.append(overlay)
        else:
            result.append(overlay)

    processed = sum(1 for r in encoded_by_route if encoded_by_route[r])
    TrackLogger.info(
        f"[Pipeline] Complete: {processed}/{len(overlays)} routes processed, "
        f"{sum(len(o.polylines) for o in result)} total polylines"
    )

    return result
