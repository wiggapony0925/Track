#
# corridor_pipeline.py
# TrackBackend
#
# Topological Graph Pipeline for generating parallel subway line offsets.
#
# Replaces the naive Shapely offset_curve approach with a strict 5-phase
# pipeline inspired by the Transit App engineering blog post:
#   "How we built the world's prettiest auto-generated transit maps"
#
# The key insight: you cannot offset raw GPS polylines and expect them to
# look good. Instead you must:
#   1. Build a single unified skeleton (the "street grid")
#   2. Map routes onto that skeleton as a mathematical graph
#   3. Solve a global lane-ordering problem to minimise crossovers
#   4. Render parallel offsets from the skeleton edges
#   5. Round junctions with concentric circular arc fillets
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
from shapely.geometry import LineString, MultiLineString, Point
from shapely.ops import linemerge, nearest_points, snap, unary_union
from shapely.validation import make_valid

from app.utils.logger import TrackLogger
from app.utils.polyline_utils import decode_polyline, encode_polyline


# ═══════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════

# Perpendicular distance between adjacent subway lanes (meters).
# 12 m ≈ comfortable visual separation at typical transit-map zoom levels.
LANE_WIDTH: float = 12.0

# Tolerance for Ramer-Douglas-Peucker simplification (meters).
# 8 m nukes GPS jitter without losing meaningful geometry.
RDP_TOLERANCE: float = 8.0

# Snapping tolerance for collapsing near-coincident GTFS shapes into the
# skeleton graph (meters).  15 m catches northbound/southbound tracks that
# are physically ~10 m apart.
SNAP_TOLERANCE: float = 15.0

# Minimum edge length to keep in the skeleton graph (meters).
# Tiny stubs from GPS noise get pruned.
MIN_EDGE_LENGTH: float = 25.0

# Node-junction curve setback distance (meters).
# Lines are trimmed this far back from each node and a circular arc
# fillet connects the trimmed ends.
JUNCTION_SETBACK: float = 30.0

# Minimum length for a GTFS shape to be route-mapped (meters).
# Prevents micro-fragments from polluting the graph.
MIN_MAPPABLE_LENGTH: float = 50.0

# Buffer used when mapping routes onto skeleton edges (meters).
# A route's GTFS shape must lie within this distance of a skeleton edge
# to be considered "traversing" that edge.
ROUTE_MAP_BUFFER: float = 35.0

# Minimum fillet radius at junction nodes (meters).
# Prevents arcs from becoming too tight at very sharp turns.
MIN_FILLET_RADIUS: float = 20.0


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
# Phase 1: Skeletonization — Build the unified topological graph
# ═══════════════════════════════════════════════════════════════════════════

def _build_skeleton(
    route_polylines: list[RoutePolyline],
) -> tuple[nx.Graph, dict[str, list[tuple[int, int]]]]:
    """Phase 1: Extract a topological skeleton from overlapping GTFS shapes.

    Pipeline:
    1. Collect ALL route geometries (already projected to EPSG:3857).
    2. Simplify with RDP to remove GPS jitter.
    3. Snap nearby endpoints together (within SNAP_TOLERANCE).
    4. Merge overlapping lines with unary_union → the geometric skeleton.
    5. Convert skeleton to a networkx graph:
       - Nodes = intersections / branching points / endpoints
       - Edges = corridor segments between nodes
    6. Map each original route onto the skeleton edges it traverses.

    Returns:
        G: networkx.Graph with node positions and edge geometries.
        route_edges: dict mapping route_id → list of (u, v) edge keys.
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

    TrackLogger.info(f"[Skeleton] Starting with {len(simplified_lines)} simplified line segments")

    # ── 1b. Snap nearby endpoints so they converge to shared nodes ──
    # Collect all endpoints, cluster them within SNAP_TOLERANCE, and snap
    # each line's endpoints to the cluster centroid.
    endpoints: list[tuple[float, float]] = []
    for line in simplified_lines:
        endpoints.append(line.coords[0])
        endpoints.append(line.coords[-1])

    # Greedy union-find clustering of endpoints within tolerance
    clusters = _cluster_points(endpoints, SNAP_TOLERANCE)

    # Snap lines to cluster centroids
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
    # unary_union nodes all intersections, producing a clean planar graph.
    raw_union = unary_union(snapped_lines)
    if raw_union.is_empty:
        return nx.Graph(), {}

    # Merge fragmented pieces back into maximal LineStrings
    merged = linemerge(raw_union) if raw_union.geom_type != "LineString" else raw_union

    # Collect all skeleton segments
    skeleton_segments: list[LineString] = []
    if merged.geom_type == "LineString":
        skeleton_segments = [merged]
    elif merged.geom_type == "MultiLineString":
        skeleton_segments = [g for g in merged.geoms if g.geom_type == "LineString"]
    elif hasattr(merged, "geoms"):
        skeleton_segments = [g for g in merged.geoms if g.geom_type == "LineString"]

    # Filter out micro-stubs
    skeleton_segments = [s for s in skeleton_segments if s.length >= MIN_EDGE_LENGTH]

    if not skeleton_segments:
        return nx.Graph(), {}

    TrackLogger.info(f"[Skeleton] Unified skeleton: {len(skeleton_segments)} segments")

    # ── 1d. Build the networkx graph ──
    # Nodes = unique coordinate tuples (rounded to 1m to merge near-coincident points)
    # Edges = skeleton segments with geometry attached
    G = nx.Graph()
    node_id_map: dict[tuple[float, float], int] = {}
    next_node_id = 0

    def _get_node_id(coord: tuple[float, float]) -> int:
        nonlocal next_node_id
        # Round to 1m to merge near-coincident endpoints
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
            continue  # Self-loop from rounding — skip
        if G.has_edge(u, v):
            # Keep the longer geometry if duplicate edge
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

    # ── 1e. Map routes onto skeleton edges ──
    # For each route polyline, find which skeleton edges it traverses.
    # Strategy: buffer each skeleton edge by ROUTE_MAP_BUFFER and check
    # if the route's geometry overlaps significantly.
    route_edges: dict[str, list[tuple[int, int]]] = defaultdict(list)

    # ── Build a spatial index (STRtree) of skeleton edge geometries ──
    from shapely import STRtree
    edge_keys: list[tuple[int, int]] = []
    edge_line_list: list[LineString] = []
    for u, v, data in G.edges(data=True):
        geom = data.get("geometry")
        if geom and not geom.is_empty:
            edge_keys.append((u, v))
            edge_line_list.append(geom)

    strtree = STRtree(edge_line_list)

    # ── For each route, sample points along its GTFS shape and find ──
    # ── the nearest skeleton edges via spatial index.                ──
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
            # Sample points along the route at ~50m intervals
            sample_spacing = 50.0
            n_samples = max(2, int(route_line.length / sample_spacing))
            sample_points = [
                route_line.interpolate(i * route_line.length / n_samples)
                for i in range(n_samples + 1)
            ]

            # For each sample point, use STRtree nearest to find the
            # closest skeleton edge — O(log n) per query.
            edge_votes: dict[tuple[int, int], int] = defaultdict(int)

            for sample_pt in sample_points:
                nearest_idx = strtree.nearest(sample_pt)
                nearest_geom = edge_line_list[nearest_idx]
                dist = nearest_geom.distance(sample_pt)

                # Only count if within 20m (tight radius)
                if dist < 20.0:
                    edge_votes[edge_keys[nearest_idx]] += 1

            # An edge is "traversed" by this route if enough sample points
            # voted for it.  Require at least 2 votes (100m coverage) or
            # 25% of expected samples for the edge.
            for (u, v), votes in edge_votes.items():
                edge_len = G[u][v].get("length", 0)
                expected_samples = max(1, edge_len / sample_spacing)
                coverage_ratio = votes / expected_samples

                if votes >= 2 and coverage_ratio >= 0.25:
                    G[u][v]["routes"].add(route_id)
                    if (u, v) not in route_edges[route_id]:
                        route_edges[route_id].append((u, v))

    # Log route mapping stats
    mapped_count = sum(1 for e_data in G.edges(data=True) if e_data[2].get("routes"))
    TrackLogger.info(
        f"[Skeleton] Route mapping complete: {len(route_edges)} routes mapped, "
        f"{mapped_count}/{G.number_of_edges()} edges have routes"
    )

    return G, dict(route_edges)


def _cluster_points(
    points: list[tuple[float, float]],
    tolerance: float,
) -> dict[tuple[float, float], tuple[float, float]]:
    """Cluster nearby points and return a mapping from original → centroid.

    Uses a simple grid-based approach: points that fall in the same
    tolerance-sized grid cell get merged. This is O(n) instead of O(n²)
    pair-wise comparison.
    """
    # Grid cell size = tolerance
    cells: dict[tuple[int, int], list[tuple[float, float]]] = defaultdict(list)
    for pt in points:
        cell = (int(pt[0] // tolerance), int(pt[1] // tolerance))
        cells[cell].append(pt)

    # Build centroid map — also check adjacent cells for cross-boundary clusters
    point_to_centroid: dict[tuple[float, float], tuple[float, float]] = {}

    processed_cells: set[tuple[int, int]] = set()
    for cell, pts in cells.items():
        if cell in processed_cells:
            continue

        # Gather points from this cell and 8 neighbours
        cluster_pts: list[tuple[float, float]] = []
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                neighbour = (cell[0] + di, cell[1] + dj)
                if neighbour in cells:
                    cluster_pts.extend(cells[neighbour])
                    processed_cells.add(neighbour)

        if not cluster_pts:
            continue

        # Compute centroid
        cx = sum(p[0] for p in cluster_pts) / len(cluster_pts)
        cy = sum(p[1] for p in cluster_pts) / len(cluster_pts)
        centroid = (cx, cy)

        for pt in cluster_pts:
            dx = pt[0] - cx
            dy = pt[1] - cy
            if math.sqrt(dx * dx + dy * dy) <= tolerance:
                point_to_centroid[pt] = centroid

    return point_to_centroid


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: Global Line Ordering — The "Anti-Spaghetti" Engine
# ═══════════════════════════════════════════════════════════════════════════

def _compute_lane_assignments(
    G: nx.Graph,
    route_edges: dict[str, list[tuple[int, int]]],
) -> dict[tuple[int, int], dict[str, int]]:
    """Phase 2: Compute globally-consistent lane assignments for every edge.

    The core anti-spaghetti algorithm:
    1. For each edge, collect the set of routes traversing it.
    2. Group routes by trunk (same-color lines stay together).
    3. Use a global ordering heuristic to assign lane indices.
    4. Propagate consistency: if routes A and B appear on consecutive
       edges, their relative ordering should be preserved to avoid
       visual crossovers.

    The result is a dict: edge (u,v) → {route_id: lane_index}.
    Lane 0 is leftmost, lane N-1 is rightmost.

    Algorithm:
    - Build a "route adjacency" preference matrix across the graph.
    - Use the Hungarian algorithm (scipy.optimize.linear_sum_assignment)
      on each edge to find the minimum-penalty lane assignment.
    - Penalties:
        * Crossing penalty: routes swap order relative to prior edge.
        * Trunk separation: routes of same trunk forced apart.
        * Divergence penalty: routes diverging left should be on left.
    """
    if not route_edges:
        return {}

    # ── 2a. Compute a global canonical ordering of all routes ──
    # This is the "seed" ordering that we try to maintain across the graph.
    # We order by trunk group first (so same-color lines cluster), then
    # alphabetically within each trunk.
    all_routes_in_graph: set[str] = set()
    for routes in route_edges.values():
        for edge in routes:
            u, v = edge
            if G.has_edge(u, v):
                all_routes_in_graph.update(G[u][v].get("routes", set()))

    # Sort: trunk index ascending, then route_id within trunk
    canonical_order = sorted(
        all_routes_in_graph,
        key=lambda r: (ROUTE_TO_TRUNK.get(r, 99), r),
    )
    route_to_canonical: dict[str, int] = {r: i for i, r in enumerate(canonical_order)}

    # ── 2b. Build per-edge lane assignments ──
    edge_lanes: dict[tuple[int, int], dict[str, int]] = {}

    # Track the lane assignment of the previously-processed edge for
    # each route, to encourage consistency (minimize crossovers).
    # Key: route_id → last assigned lane index
    route_last_lane: dict[str, int] = {}

    # Process edges in BFS order from the highest-degree node to maximise
    # propagation of consistent ordering.
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

        route_list = sorted(routes_on_edge, key=lambda r: route_to_canonical.get(r, 99))
        n = len(route_list)

        if n == 1:
            # Single route — lane 0, centered
            edge_lanes[edge_key] = {route_list[0]: 0}
            route_last_lane[route_list[0]] = 0
            continue

        # ── Build cost matrix for Hungarian algorithm ──
        # Rows = routes, Columns = lane positions (0..n-1)
        # Cost[i][j] = penalty for assigning route_list[i] to lane j
        cost = np.zeros((n, n), dtype=np.float64)

        for i, route in enumerate(route_list):
            trunk_i = ROUTE_TO_TRUNK.get(route, -1)

            for lane in range(n):
                penalty = 0.0

                # Penalty 1: Canonical order deviation.
                # Routes should maintain their canonical (trunk-grouped)
                # ordering.  The cost is proportional to how far a route
                # deviates from its canonical rank position.
                canonical_rank = route_to_canonical.get(route, 0)
                # Normalise the canonical rank to [0, n-1] range
                rank_among_edge_routes = sorted(
                    range(n),
                    key=lambda idx: route_to_canonical.get(route_list[idx], 0),
                )
                ideal_lane = rank_among_edge_routes.index(i)
                penalty += 2.0 * abs(lane - ideal_lane)

                # Penalty 2: Consistency with previous edge.
                # If this route was in lane X on the previous edge, prefer
                # it stays near lane X to avoid crossovers.
                if route in route_last_lane:
                    prev_lane = route_last_lane[route]
                    # Scale by 5.0 — crossing penalty is the most important
                    penalty += 5.0 * abs(lane - prev_lane)

                # Penalty 3: Trunk cohesion.
                # Same-trunk routes should be adjacent lanes.
                for j, other_route in enumerate(route_list):
                    if j == i:
                        continue
                    trunk_j = ROUTE_TO_TRUNK.get(other_route, -2)
                    if trunk_i == trunk_j and trunk_i >= 0:
                        # Same trunk — prefer adjacent lane assignments.
                        # No penalty if they'd be adjacent; increasing
                        # penalty if they'd be separated by other-trunk lines.
                        # (We can't know other_route's lane yet, but we can
                        # encode a soft preference.)
                        canonical_j = route_to_canonical.get(other_route, 0)
                        if abs(canonical_rank - canonical_j) <= 1:
                            # These are consecutive in canonical order —
                            # they should be consecutive in lane order too.
                            pass  # The canonical penalty above handles this

                # Penalty 4: Divergence direction.
                # If a route diverges at the downstream node, it should be
                # assigned to the side it diverges towards.
                # Check if this route continues past node v.
                downstream_node = v
                route_continues = False
                diverge_direction = 0  # -1 = left, +1 = right

                for neighbor in G.neighbors(downstream_node):
                    if neighbor == u:
                        continue
                    neighbor_edge = (min(downstream_node, neighbor),
                                     max(downstream_node, neighbor))
                    neighbor_routes = G.edges[downstream_node, neighbor].get("routes", set())
                    if route in neighbor_routes:
                        route_continues = True
                        # Compute divergence direction from the edge geometry
                        edge_geom = G[u][v].get("geometry")
                        next_geom = G.edges[downstream_node, neighbor].get("geometry")
                        if edge_geom and next_geom:
                            diverge_direction = _compute_divergence_side(
                                edge_geom, next_geom, downstream_node, G
                            )
                        break

                if diverge_direction != 0:
                    # Route diverges left → prefer lower lane index
                    # Route diverges right → prefer higher lane index
                    center = (n - 1) / 2.0
                    if diverge_direction < 0:
                        # Should be on the left (low lane index)
                        penalty += 3.0 * max(0, lane - center)
                    else:
                        # Should be on the right (high lane index)
                        penalty += 3.0 * max(0, center - lane)

                cost[i][lane] = penalty

        # ── Solve the assignment problem ──
        try:
            row_ind, col_ind = linear_sum_assignment(cost)
            assignment = {}
            for i, lane in zip(row_ind, col_ind):
                assignment[route_list[i]] = lane
                route_last_lane[route_list[i]] = lane
            edge_lanes[edge_key] = assignment
        except Exception:
            # Fallback: canonical ordering
            assignment = {route_list[i]: i for i in range(n)}
            edge_lanes[edge_key] = assignment

    # Also process any edges not reached by BFS (disconnected components)
    for u, v, data in G.edges(data=True):
        edge_key = (min(u, v), max(u, v))
        if edge_key in edge_lanes:
            continue
        routes_on_edge = data.get("routes", set())
        if routes_on_edge:
            route_list = sorted(routes_on_edge,
                                key=lambda r: route_to_canonical.get(r, 99))
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
    """Determine if a connecting edge diverges to the left or right.

    Uses the cross product of the incoming edge direction and the
    outgoing edge direction at the shared node.

    Returns:
        -1 if the next edge veers LEFT
        +1 if the next edge veers RIGHT
         0 if roughly straight or indeterminate
    """
    try:
        node_pos = G.nodes[node].get("pos")
        if node_pos is None:
            return 0

        # Get incoming direction (last ~50m of the edge approaching the node)
        edge_coords = list(edge_geom.coords)
        # Check if the node is at the start or end of the edge
        node_pt = Point(node_pos)
        if node_pt.distance(Point(edge_coords[-1])) < node_pt.distance(Point(edge_coords[0])):
            # Node is at the end — incoming direction is penultimate → last
            if len(edge_coords) >= 2:
                dx_in = edge_coords[-1][0] - edge_coords[-2][0]
                dy_in = edge_coords[-1][1] - edge_coords[-2][1]
            else:
                return 0
        else:
            # Node is at the start — incoming direction is second → first
            if len(edge_coords) >= 2:
                dx_in = edge_coords[0][0] - edge_coords[1][0]
                dy_in = edge_coords[0][1] - edge_coords[1][1]
            else:
                return 0

        # Get outgoing direction (first ~50m of the next edge leaving the node)
        next_coords = list(next_geom.coords)
        if node_pt.distance(Point(next_coords[0])) < node_pt.distance(Point(next_coords[-1])):
            # Node is at the start of next edge
            if len(next_coords) >= 2:
                dx_out = next_coords[1][0] - next_coords[0][0]
                dy_out = next_coords[1][1] - next_coords[0][1]
            else:
                return 0
        else:
            # Node is at the end of next edge
            if len(next_coords) >= 2:
                dx_out = next_coords[-2][0] - next_coords[-1][0]
                dy_out = next_coords[-2][1] - next_coords[-1][1]
            else:
                return 0

        # Cross product: positive = left turn, negative = right turn
        cross = dx_in * dy_out - dy_in * dx_out

        if abs(cross) < 1e-6:
            return 0  # Straight
        return -1 if cross > 0 else 1

    except Exception:
        return 0


# ═══════════════════════════════════════════════════════════════════════════
# Phase 3: Parallel Rendering — Offset from Skeleton
# ═══════════════════════════════════════════════════════════════════════════

def _render_parallel_offsets(
    G: nx.Graph,
    edge_lanes: dict[tuple[int, int], dict[str, int]],
) -> dict[str, list[LineString]]:
    """Phase 3: Generate offset geometries for each route based on lane assignments.

    Instead of producing one offset segment per edge (which creates many
    fragments that are hard to merge), this builds continuous route paths
    through the graph and offsets them as whole polylines.

    Algorithm:
    1. For each route, find all edges it traverses.
    2. Chain those edges into continuous paths using graph connectivity.
    3. For each continuous path, concatenate the skeleton geometries into
       one LineString, then apply the per-segment offset.
    4. Where the lane assignment changes between consecutive edges on the
       same path, insert a short transition.

    Returns:
        route_segments: dict mapping route_id → list of offset LineString
        geometries (in EPSG:3857 meters).
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

        # ── Chain edges into continuous paths via graph traversal ──
        paths = _chain_edges_into_paths(G, edges)

        for path_edges in paths:
            if not path_edges:
                continue

            # Check if the entire path has a uniform lane assignment
            # (same offset everywhere). If so, offset one big polyline.
            uniform_offset = True
            first_offset = None

            for edge in path_edges:
                ek = (min(edge[0], edge[1]), max(edge[0], edge[1]))
                assignments = edge_lanes.get(ek, {})
                n_lanes = len(assignments)
                lane_idx = assignments.get(route_id, 0)
                center = (n_lanes - 1) / 2.0 if n_lanes > 0 else 0.0
                offset_m = (lane_idx - center) * LANE_WIDTH

                if first_offset is None:
                    first_offset = offset_m
                elif abs(offset_m - first_offset) > 0.5:
                    uniform_offset = False
                    break

            if uniform_offset and first_offset is not None:
                # Build one continuous polyline from the chained edge
                # geometries and offset it once.
                combined_coords = _stitch_edge_geometries(G, path_edges)
                if not combined_coords or len(combined_coords) < 2:
                    continue

                line = LineString(combined_coords)
                if abs(first_offset) < 0.5:
                    route_segments[route_id].append(line)
                else:
                    try:
                        offset_geom = line.offset_curve(
                            first_offset, join_style="round",
                        )
                        clean = _clean_offset_geometry(offset_geom)
                        if clean is not None:
                            route_segments[route_id].append(clean)
                        else:
                            route_segments[route_id].append(line)
                    except Exception:
                        route_segments[route_id].append(line)
            else:
                # Lane assignment varies along the path — offset per edge
                # and stitch with small connecting segments.
                for edge in path_edges:
                    u, v = edge
                    if not G.has_edge(u, v):
                        continue
                    edge_geom = G[u][v].get("geometry")
                    if edge_geom is None or edge_geom.is_empty:
                        continue

                    ek = (min(u, v), max(u, v))
                    assignments = edge_lanes.get(ek, {})
                    n_lanes = len(assignments)
                    lane_idx = assignments.get(route_id, 0)
                    center = (n_lanes - 1) / 2.0 if n_lanes > 0 else 0.0
                    offset_m = (lane_idx - center) * LANE_WIDTH

                    if abs(offset_m) < 0.5:
                        route_segments[route_id].append(edge_geom)
                    else:
                        try:
                            offset_geom = edge_geom.offset_curve(
                                offset_m, join_style="round",
                            )
                            clean = _clean_offset_geometry(offset_geom)
                            if clean is not None:
                                route_segments[route_id].append(clean)
                            else:
                                route_segments[route_id].append(edge_geom)
                        except Exception:
                            route_segments[route_id].append(edge_geom)

    return dict(route_segments)


def _chain_edges_into_paths(
    G: nx.Graph,
    edges: list[tuple[int, int]],
) -> list[list[tuple[int, int]]]:
    """Chain a set of graph edges into continuous paths.

    Given a set of edges that a route traverses, find connected sequences
    (paths) by walking the graph.  Returns a list of paths, where each
    path is an ordered list of (u, v) edge tuples.
    """
    if not edges:
        return []

    # Build an adjacency structure for just these edges
    adj: dict[int, list[tuple[int, int]]] = defaultdict(list)
    edge_set: set[tuple[int, int]] = set()
    for u, v in edges:
        canonical = (min(u, v), max(u, v))
        if canonical not in edge_set:
            edge_set.add(canonical)
            adj[u].append(v)
            adj[v].append(u)

    # Find connected components via DFS and chain edges
    visited_edges: set[tuple[int, int]] = set()
    paths: list[list[tuple[int, int]]] = []

    # Start from endpoint nodes (degree 1 in this subgraph) for cleaner chains
    node_degree = {n: len(neighbors) for n, neighbors in adj.items()}
    start_nodes = [n for n, d in node_degree.items() if d == 1]
    if not start_nodes:
        start_nodes = list(adj.keys())

    for start in start_nodes:
        # DFS from this start node, building a path
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
    """Concatenate skeleton edge geometries along a path into one coord list.

    At each edge, checks whether the geometry needs to be reversed to
    maintain path continuity (edge geometry direction may not match the
    traversal direction).
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

        # Check if we need to reverse this edge's geometry to maintain
        # continuity with the previous segment.
        if all_coords:
            last_pt = all_coords[-1]
            d_start = _point_dist(last_pt, coords[0])
            d_end = _point_dist(last_pt, coords[-1])
            if d_end < d_start:
                coords = coords[::-1]

            # Skip the first point if it's close to the last (avoid dup)
            if _point_dist(all_coords[-1], coords[0]) < SNAP_TOLERANCE:
                coords = coords[1:]

        all_coords.extend(coords)

    return all_coords


def _clean_offset_geometry(geom) -> LineString | None:
    """Extract the longest valid LineString from an offset result.

    offset_curve can produce MultiLineString with self-intersecting
    bowties at sharp corners.  This cleans and returns the best piece.
    """
    if geom is None or geom.is_empty:
        return None

    if not geom.is_valid:
        geom = make_valid(geom)

    if geom.geom_type == "LineString":
        return geom if len(geom.coords) >= 2 else None

    if geom.geom_type == "MultiLineString":
        merged = linemerge(geom)
        if merged.geom_type == "LineString" and len(merged.coords) >= 2:
            return merged
        if merged.geom_type == "MultiLineString":
            candidates = [g for g in merged.geoms
                          if g.geom_type == "LineString" and len(g.coords) >= 2]
            if candidates:
                return max(candidates, key=lambda g: g.length)
        return None

    if hasattr(geom, "geoms"):
        lines = [g for g in geom.geoms
                 if g.geom_type == "LineString" and len(g.coords) >= 2]
        if lines:
            return max(lines, key=lambda g: g.length)

    return None


# ═══════════════════════════════════════════════════════════════════════════
# Phase 4: Node Rounding — Concentric Circular Arc Fillets
# ═══════════════════════════════════════════════════════════════════════════

def _apply_junction_rounding(
    G: nx.Graph,
    route_segments: dict[str, list[LineString]],
    edge_lanes: dict[tuple[int, int], dict[str, int]],
) -> dict[str, list[LineString]]:
    """Phase 4: Round junctions with concentric circular arc fillets.

    Replaces cubic Bézier curves with true circular arcs.  Parallel
    lanes turning the same corner produce concentric arcs (shared centre,
    different radii) so offset lines maintain uniform spacing through
    turns — this is the core geometrical guarantee from the Transit Inc.
    architecture.

    Algorithm:
    1. Pre-compute skeleton edge directions at every junction node.
       The arc centre for each turn is placed on the angle bisector of
       the two skeleton edges, guaranteeing that ALL lanes at the same
       node share one centre point.
    2. For each route, order its offset segments into a chain.
    3. At each consecutive-segment gap (a junction), find the nearest
       skeleton node and compute a circular arc whose radius equals
       the distance from the shared centre to the route's offset
       line tangent point.
    4. Trim incoming/outgoing segments and splice in the arc.

    Because every lane's arc uses the same centre, the arcs are
    concentric by construction.  The radius naturally adapts to the
    lane's offset distance.
    """
    if not route_segments:
        return route_segments

    # ── Step 1: Pre-compute skeleton junction info ──
    junction_data = _precompute_skeleton_junctions(G)

    # Build arrays for fast nearest-node lookup (typically <200 nodes)
    jnode_ids: list[int] = list(junction_data.keys())
    jnode_pts: list[tuple[float, float]] = [
        junction_data[nid][0] for nid in jnode_ids
    ]

    smoothed_segments: dict[str, list[LineString]] = {}

    for route_id, segments in route_segments.items():
        if not segments:
            continue

        # Build a chain of segments ordered by connectivity
        chain = _order_segments(segments)

        final_parts: list[LineString] = []

        for i, seg in enumerate(chain):
            if seg.length < JUNCTION_SETBACK * 2.5:
                # Segment too short to trim — keep as-is
                final_parts.append(seg)
                continue

            # Attempt to insert an arc fillet before the next segment
            if i < len(chain) - 1:
                next_seg = chain[i + 1]

                # Check if endpoints are close enough to form a junction
                seg_end = seg.coords[-1]
                next_start = next_seg.coords[0]
                gap = _point_dist(seg_end, next_start)

                if gap < JUNCTION_SETBACK * 3:
                    # Midpoint of the gap ≈ junction location
                    mid = (
                        (seg_end[0] + next_start[0]) / 2,
                        (seg_end[1] + next_start[1]) / 2,
                    )

                    # ── Try skeleton-centred arc (guarantees concentricity) ──
                    arc_result: tuple[LineString, float, float] | None = None
                    j_idx = _nearest_point_index(mid, jnode_pts)
                    if j_idx is not None:
                        jnid = jnode_ids[j_idx]
                        jpos = jnode_pts[j_idx]
                        dist_to_j = _point_dist(mid, jpos)

                        if dist_to_j < JUNCTION_SETBACK * 4:
                            arc_result = _arc_fillet_at_skeleton_node(
                                seg, next_seg, jpos, G, jnid,
                            )

                    # ── Fallback: arc from segment geometry alone ──
                    if arc_result is None:
                        arc_result = _arc_fillet_from_segments(seg, next_seg)

                    if arc_result is not None:
                        arc_geom, setback_in, setback_out = arc_result
                        trimmed_current = _trim_line_end(seg, setback_in)
                        trimmed_next = _trim_line_start(next_seg, setback_out)

                        if trimmed_current and trimmed_next:
                            final_parts.append(trimmed_current)
                            final_parts.append(arc_geom)
                            chain[i + 1] = trimmed_next
                            continue

            final_parts.append(seg)

        smoothed_segments[route_id] = final_parts

    return smoothed_segments


def _precompute_skeleton_junctions(
    G: nx.Graph,
) -> dict[int, tuple[tuple[float, float], list[tuple[float, float]]]]:
    """Collect position and incident-edge unit directions at each junction node.

    Returns dict[node_id] → (node_pos, [direction_unit_vectors …])
    where each direction vector points AWAY from the node along an
    incident skeleton edge.
    """
    junctions: dict[int, tuple[tuple[float, float], list[tuple[float, float]]]] = {}

    for node in G.nodes():
        if G.degree(node) < 2:
            continue
        pos = G.nodes[node].get("pos")
        if pos is None:
            continue

        directions: list[tuple[float, float]] = []
        for _u, _v, data in G.edges(node, data=True):
            geom = data.get("geometry")
            if geom is None or geom.is_empty or len(geom.coords) < 2:
                continue

            coords = list(geom.coords)
            d_start = _point_dist(pos, coords[0])
            d_end = _point_dist(pos, coords[-1])

            if d_start <= d_end:
                # Node at start → direction away is toward the next vertex
                dx = coords[1][0] - coords[0][0]
                dy = coords[1][1] - coords[0][1]
            else:
                # Node at end → direction away is toward the previous vertex
                dx = coords[-2][0] - coords[-1][0]
                dy = coords[-2][1] - coords[-1][1]

            d_len = math.sqrt(dx * dx + dy * dy)
            if d_len < 1e-10:
                continue
            directions.append((dx / d_len, dy / d_len))

        if len(directions) >= 2:
            junctions[node] = (pos, directions)

    return junctions


def _arc_fillet_at_skeleton_node(
    seg_in: LineString,
    seg_out: LineString,
    node_pos: tuple[float, float],
    G: nx.Graph,
    node_id: int,
) -> tuple[LineString, float, float] | None:
    """Create a concentric circular arc fillet using a skeleton junction.

    The arc centre is derived from the skeleton edge directions at the
    node so that all parallel lanes share the same centre — the key to
    concentricity.

    Returns (arc_geometry, setback_incoming, setback_outgoing) or None.
    """
    # Gather skeleton edge directions pointing AWAY from this node
    edge_dirs: list[tuple[float, float]] = []
    for _u, _v, data in G.edges(node_id, data=True):
        geom = data.get("geometry")
        if geom is None or geom.is_empty or len(geom.coords) < 2:
            continue
        coords = list(geom.coords)
        d_start = _point_dist(node_pos, coords[0])
        d_end = _point_dist(node_pos, coords[-1])
        if d_start <= d_end:
            dx, dy = coords[1][0] - coords[0][0], coords[1][1] - coords[0][1]
        else:
            dx, dy = coords[-2][0] - coords[-1][0], coords[-2][1] - coords[-1][1]
        d_len = math.sqrt(dx * dx + dy * dy)
        if d_len > 1e-10:
            edge_dirs.append((dx / d_len, dy / d_len))

    if len(edge_dirs) < 2:
        return None

    # Match skeleton edges to the route's incoming / outgoing segments
    in_dir = _get_line_end_direction(seg_in)
    out_dir = _get_line_start_direction(seg_out)
    if in_dir is None or out_dir is None:
        return None

    # The incoming segment APPROACHES the node, so its direction at the
    # junction points TOWARD the node.  The skeleton edge direction points
    # AWAY.  Best match = highest dot product with the REVERSED in_dir.
    neg_in = (-in_dir[0], -in_dir[1])
    best_in_dir = max(edge_dirs, key=lambda d: neg_in[0] * d[0] + neg_in[1] * d[1])

    # The outgoing segment LEAVES the node, matching the skeleton edge
    # direction (both point away from the node).
    best_out_dir = max(edge_dirs, key=lambda d: out_dir[0] * d[0] + out_dir[1] * d[1])

    # Avoid picking the same skeleton edge for both in and out
    if best_in_dir == best_out_dir and len(edge_dirs) > 1:
        remaining = [d for d in edge_dirs if d != best_in_dir]
        if remaining:
            best_out_dir = max(
                remaining,
                key=lambda d: out_dir[0] * d[0] + out_dir[1] * d[1],
            )

    # Skeleton "approaching node" direction = opposite of best_in_dir
    # Skeleton "leaving node" direction = best_out_dir
    skel_dir_in = (-best_in_dir[0], -best_in_dir[1])
    skel_dir_out = best_out_dir

    return _compute_arc_from_directions(
        node_pos, skel_dir_in, skel_dir_out, seg_in, seg_out,
    )


def _arc_fillet_from_segments(
    seg_in: LineString,
    seg_out: LineString,
) -> tuple[LineString, float, float] | None:
    """Fallback: compute a circular arc fillet from offset segments alone.

    Used when no skeleton junction is nearby.  Still produces a true
    circular arc (not a Bézier), but without the strict concentricity
    guarantee since there is no shared skeleton reference.
    """
    in_dir = _get_line_end_direction(seg_in)
    out_dir = _get_line_start_direction(seg_out)
    if in_dir is None or out_dir is None:
        return None

    # Use the midpoint of the gap as the virtual vertex
    seg_end = seg_in.coords[-1]
    next_start = seg_out.coords[0]
    vertex = (
        (seg_end[0] + next_start[0]) / 2,
        (seg_end[1] + next_start[1]) / 2,
    )

    return _compute_arc_from_directions(
        vertex, in_dir, out_dir, seg_in, seg_out,
    )


def _compute_arc_from_directions(
    vertex: tuple[float, float],
    dir_in: tuple[float, float],
    dir_out: tuple[float, float],
    seg_in: LineString,
    seg_out: LineString,
) -> tuple[LineString, float, float] | None:
    """Core arc computation using the angle-bisector method.

    Given a junction vertex and skeleton-level directions, compute a
    shared arc centre and generate a circular arc for this route's
    offset segments.

    Args:
        vertex:  Junction vertex position (skeleton node or gap midpoint).
        dir_in:  Unit direction pointing TOWARD the vertex from the
                 incoming side.
        dir_out: Unit direction pointing AWAY from the vertex toward the
                 outgoing side.
        seg_in:  Incoming offset segment for this route.
        seg_out: Outgoing offset segment for this route.

    Returns (arc_LineString, setback_incoming, setback_outgoing) or None.
    """
    ux, uy = dir_in
    wx, wy = dir_out

    # ── Angle at vertex ──
    # Half-lines from vertex: backward (−u) and forward (w).
    cos_alpha = (-ux) * wx + (-uy) * wy
    cos_alpha = max(-1.0, min(1.0, cos_alpha))
    alpha = math.acos(cos_alpha)       # angle at the vertex
    deflection = math.pi - alpha       # how much the path turns

    # Skip nearly straight turns (<5°) and near-U-turns (>160°)
    if deflection < 0.087 or deflection > 2.79:
        return None

    half_alpha = alpha / 2.0
    sin_half = math.sin(half_alpha)
    tan_half = math.tan(half_alpha)

    if sin_half < 1e-10 or abs(tan_half) < 1e-10:
        return None

    # ── Bisector direction (vertex → arc centre) ──
    # The bisector of the angle between half-lines (−u) and (w) points
    # into the inscribed arc sector.
    bx = -ux + wx
    by = -uy + wy
    b_len = math.sqrt(bx * bx + by * by)
    if b_len < 1e-10:
        return None
    bx /= b_len
    by /= b_len

    # ── Base fillet radius on the skeleton centre-line ──
    base_radius = max(JUNCTION_SETBACK, MIN_FILLET_RADIUS)

    # Centre distance from vertex along bisector: R / sin(α/2)
    center_dist = base_radius / sin_half

    # Arc centre (shared by all lanes at this junction)
    cx = vertex[0] + bx * center_dist
    cy = vertex[1] + by * center_dist
    center = (cx, cy)

    # Turn direction from cross product dir_in × dir_out
    cross = ux * wy - uy * wx
    turn_left = cross > 0

    # ── Effective radii for THIS route's offset segments ──
    r_in = _point_dist(center, seg_in.coords[-1])
    r_out = _point_dist(center, seg_out.coords[0])

    if r_in < MIN_FILLET_RADIUS * 0.3 or r_out < MIN_FILLET_RADIUS * 0.3:
        return None
    if r_in > JUNCTION_SETBACK * 12 or r_out > JUNCTION_SETBACK * 12:
        return None

    # Setback for each leg: R_lane / tan(α/2)
    setback_in = r_in / tan_half
    setback_out = r_out / tan_half

    # Cap setbacks so we don't consume too much of the segment
    max_in = seg_in.length * 0.8
    max_out = seg_out.length * 0.8
    if setback_in > max_in:
        setback_in = max_in
    if setback_out > max_out:
        setback_out = max_out

    # ── Predict the tangent points after trimming ──
    try:
        t1_pt = seg_in.interpolate(seg_in.length - setback_in)
        t2_pt = seg_out.interpolate(setback_out)
    except Exception:
        return None

    t1 = (t1_pt.x, t1_pt.y)
    t2 = (t2_pt.x, t2_pt.y)

    # Recompute radii from the actual tangent points
    r1 = _point_dist(center, t1)
    r2 = _point_dist(center, t2)

    if r1 < 3.0 or r2 < 3.0:
        return None

    # ── Generate the circular arc ──
    arc = _generate_circular_arc(center, t1, t2, r1, r2, turn_left)
    if arc is None:
        return None

    return arc, setback_in, setback_out


def _generate_circular_arc(
    center: tuple[float, float],
    start_pt: tuple[float, float],
    end_pt: tuple[float, float],
    r_start: float,
    r_end: float,
    turn_left: bool,
    num_points: int = 16,
) -> LineString | None:
    """Generate a circular (or spiral-transition) arc from *start* to *end*.

    If *r_start* ≈ *r_end* this is a true circle; if they differ (lane
    assignment changes at a junction) the radius linearly interpolates,
    producing a gentle spiral that still looks smooth.

    Args:
        center:     Shared arc centre (from skeleton bisector).
        start_pt:   Tangent point on the incoming segment.
        end_pt:     Tangent point on the outgoing segment.
        r_start:    Radius at the start of the arc.
        r_end:      Radius at the end of the arc.
        turn_left:  True → counter-clockwise sweep, False → clockwise.
        num_points: Number of interpolation points on the arc.

    Returns a LineString or None.
    """
    angle_start = math.atan2(start_pt[1] - center[1], start_pt[0] - center[0])
    angle_end = math.atan2(end_pt[1] - center[1], end_pt[0] - center[0])

    # Sweep in the correct rotational direction
    if turn_left:
        # Counter-clockwise: sweep should be positive
        sweep = angle_end - angle_start
        if sweep <= 0:
            sweep += 2 * math.pi
        # A CCW sweep > π probably means we took the long way
        if sweep > math.pi * 1.1:
            sweep -= 2 * math.pi
    else:
        # Clockwise: sweep should be negative
        sweep = angle_end - angle_start
        if sweep >= 0:
            sweep -= 2 * math.pi
        # A CW sweep < −π is the long way
        if sweep < -math.pi * 1.1:
            sweep += 2 * math.pi

    # Skip degenerate arcs
    if abs(sweep) < 0.01:
        return None

    coords: list[tuple[float, float]] = []
    for i in range(num_points + 1):
        t = i / num_points
        angle = angle_start + t * sweep
        r = r_start + t * (r_end - r_start)
        x = center[0] + r * math.cos(angle)
        y = center[1] + r * math.sin(angle)
        coords.append((x, y))

    if len(coords) >= 2:
        return LineString(coords)
    return None


def _get_line_end_direction(line: LineString) -> tuple[float, float] | None:
    """Unit direction vector at the END of a LineString (pointing toward end)."""
    coords = list(line.coords)
    if len(coords) < 2:
        return None
    dx = coords[-1][0] - coords[-2][0]
    dy = coords[-1][1] - coords[-2][1]
    d_len = math.sqrt(dx * dx + dy * dy)
    if d_len < 1e-10:
        return None
    return (dx / d_len, dy / d_len)


def _get_line_start_direction(line: LineString) -> tuple[float, float] | None:
    """Unit direction vector at the START of a LineString (pointing away from start)."""
    coords = list(line.coords)
    if len(coords) < 2:
        return None
    dx = coords[1][0] - coords[0][0]
    dy = coords[1][1] - coords[0][1]
    d_len = math.sqrt(dx * dx + dy * dy)
    if d_len < 1e-10:
        return None
    return (dx / d_len, dy / d_len)


def _nearest_point_index(
    target: tuple[float, float],
    points: list[tuple[float, float]],
) -> int | None:
    """Return the index of the closest point in *points* to *target*, or None."""
    if not points:
        return None
    best_idx = 0
    best_d2 = float("inf")
    tx, ty = target
    for i, (px, py) in enumerate(points):
        d2 = (px - tx) ** 2 + (py - ty) ** 2
        if d2 < best_d2:
            best_d2 = d2
            best_idx = i
    return best_idx


def _trim_line_end(line: LineString, distance: float) -> LineString | None:
    """Trim `distance` meters from the END of a LineString."""
    if line.length <= distance:
        return None
    try:
        # Keep from 0 to (length - distance)
        trimmed = _substring(line, 0, line.length - distance)
        if trimmed and len(trimmed.coords) >= 2:
            return trimmed
    except Exception:
        pass
    return None


def _trim_line_start(line: LineString, distance: float) -> LineString | None:
    """Trim `distance` meters from the START of a LineString."""
    if line.length <= distance:
        return None
    try:
        trimmed = _substring(line, distance, line.length)
        if trimmed and len(trimmed.coords) >= 2:
            return trimmed
    except Exception:
        pass
    return None


def _substring(line: LineString, start_dist: float, end_dist: float) -> LineString | None:
    """Extract a substring of a LineString between two distances along it.

    Reimplements shapely.ops.substring logic for robustness.
    """
    if start_dist >= end_dist or line.is_empty:
        return None

    coords = list(line.coords)
    if len(coords) < 2:
        return None

    result_coords: list[tuple[float, float]] = []
    current_dist = 0.0

    for i in range(len(coords) - 1):
        seg_start = coords[i]
        seg_end = coords[i + 1]
        dx = seg_end[0] - seg_start[0]
        dy = seg_end[1] - seg_start[1]
        seg_len = math.sqrt(dx * dx + dy * dy)

        next_dist = current_dist + seg_len

        # Check if the start_dist falls within this segment
        if current_dist <= start_dist <= next_dist and not result_coords:
            if seg_len > 0:
                frac = (start_dist - current_dist) / seg_len
                start_pt = (
                    seg_start[0] + frac * dx,
                    seg_start[1] + frac * dy,
                )
                result_coords.append(start_pt)

        # Add intermediate points that fall between start and end
        if result_coords and current_dist >= start_dist:
            result_coords.append(seg_start)

        # Check if end_dist falls within this segment
        if current_dist <= end_dist <= next_dist:
            if seg_len > 0:
                frac = (end_dist - current_dist) / seg_len
                end_pt = (
                    seg_start[0] + frac * dx,
                    seg_start[1] + frac * dy,
                )
                result_coords.append(end_pt)
            break

        # Add the endpoint of this segment if we're past start
        if result_coords:
            result_coords.append(seg_end)

        current_dist = next_dist

    if len(result_coords) >= 2:
        return LineString(result_coords)
    return None


def _order_segments(segments: list[LineString]) -> list[LineString]:
    """Order a list of LineStrings into a roughly connected chain.

    Greedy nearest-endpoint chaining: start with the first segment, then
    repeatedly find the unvisited segment whose start or end is closest
    to the current chain's end.  Reverses segments as needed.
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
            # Distance to this segment's start
            d_start = _point_dist(current_end, seg.coords[0])
            # Distance to this segment's end (would need reversing)
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
            seg = LineString(list(seg.coords)[::-1])
        chain.append(seg)

    return chain


def _point_dist(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Euclidean distance between two 2D points."""
    dx = a[0] - b[0]
    dy = a[1] - b[1]
    return math.sqrt(dx * dx + dy * dy)


# ═══════════════════════════════════════════════════════════════════════════
# Phase 5: Export & Reprojection
# ═══════════════════════════════════════════════════════════════════════════

def _export_to_encoded_polylines(
    route_segments: dict[str, list[LineString]],
) -> dict[str, list[str]]:
    """Phase 5: Stitch, project back to WGS84, and encode.

    1. Merge consecutive segments per route into continuous LineStrings
       where endpoints are close together.
    2. Reproject from EPSG:3857 back to EPSG:4326 (WGS84).
    3. Encode as Google polyline strings for the iOS MKPolylineRenderer.
    """
    result: dict[str, list[str]] = {}

    for route_id, segments in route_segments.items():
        if not segments:
            continue

        # Merge segments — first with SNAP_TOLERANCE for tight matches,
        # then with a wider tolerance (LANE_WIDTH * 3) to bridge offsets
        # at graph nodes where lane assignments cause endpoint gaps.
        merged = _merge_linestrings(segments, tolerance=SNAP_TOLERANCE)
        if len(merged) > 1:
            merged = _merge_linestrings(merged, tolerance=LANE_WIDTH * 3)

        encoded_polylines: list[str] = []
        for line_m in merged:
            coords_m = list(line_m.coords)
            if len(coords_m) < 2:
                continue

            # Drop tiny stubs shorter than MIN_EDGE_LENGTH — they're
            # GPS/skeleton artifacts, not meaningful geometry.
            if line_m.length < MIN_EDGE_LENGTH:
                continue

            # Reproject to WGS84
            wgs84_coords = project_to_wgs84(coords_m)
            encoded_polylines.append(encode_polyline(wgs84_coords))

        if encoded_polylines:
            result[route_id] = encoded_polylines

    return result


def _merge_linestrings(
    segments: list[LineString],
    tolerance: float = 2.0,
) -> list[LineString]:
    """Merge consecutive LineStrings whose endpoints are within tolerance meters."""
    if not segments:
        return []
    if len(segments) == 1:
        return segments

    # Order segments into a chain first
    ordered = _order_segments(segments)

    merged: list[LineString] = []
    current_coords: list[tuple[float, float]] = list(ordered[0].coords)

    for seg in ordered[1:]:
        seg_coords = list(seg.coords)
        if not seg_coords:
            continue

        # Check if this segment connects to the current chain
        gap = _point_dist(current_coords[-1], seg_coords[0])
        if gap <= tolerance:
            # Append (skipping the first point to avoid duplication)
            current_coords.extend(seg_coords[1:])
        else:
            # Gap too large — flush current and start new chain
            if len(current_coords) >= 2:
                merged.append(LineString(current_coords))
            current_coords = list(seg_coords)

    if len(current_coords) >= 2:
        merged.append(LineString(current_coords))

    return merged


# ═══════════════════════════════════════════════════════════════════════════
# Phase 6: Topological Stop Processing
# ═══════════════════════════════════════════════════════════════════════════

# Module-level cache for the most recently computed stop positions.
_processed_stops_cache: list[dict] | None = None


def get_processed_stops() -> list[dict]:
    """Return the most recently computed snapped stop positions.

    Call this after ``apply_topological_offsets`` to retrieve stop
    metadata that the iOS app can use to draw station markers on the
    offset lines.

    Each entry::

        {
            "station_id": str,
            "name": str,
            "is_transfer": bool,          # ≥ 2 trunk groups → white bar
            "positions": [                 # one per route through this station
                {"route_id": str, "lat": float, "lon": float},
                …
            ]
        }
    """
    return _processed_stops_cache or []


def _process_stop_positions(
    route_segments: dict[str, list[LineString]],
) -> list[dict]:
    """Phase 6: Snap GTFS stops onto offset lines and identify transfer hubs.

    For each subway station:
    1. Project the GTFS stop coordinate into EPSG:3857.
    2. For each route the station serves that has offset geometry:
       - Use Shapely ``project`` + ``interpolate`` to snap the stop
         onto the route's nearest offset LineString.
       - Record the snapped (lat, lon) on the offset line.
    3. Classify the station:
       - Single-trunk-group → ``is_transfer = False`` →
         iOS draws a small circle per line.
       - Multi-trunk-group → ``is_transfer = True`` →
         iOS draws a white bar spanning the parallel offset lines.

    Returns a list of station dicts (see ``get_processed_stops`` for schema).
    """
    from app.services.mapping.subway_shapes import get_all_subway_stations

    raw_stations = get_all_subway_stations()
    if not raw_stations:
        return []

    # Build lookup of valid offset segments per route
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

        # Project stop to meters
        try:
            stop_m = _to_meters.transform(orig_lon, orig_lat)
        except Exception:
            continue

        stop_pt = Point(stop_m)

        # Snap onto each route's offset line
        positions: list[dict] = []
        trunk_groups_seen: set[int] = set()

        for route_id in routes:
            if route_id not in route_geoms:
                continue

            segs = route_geoms[route_id]

            # Find the nearest offset segment to this stop
            best_dist = float("inf")
            best_seg: LineString | None = None
            for seg in segs:
                d = seg.distance(stop_pt)
                if d < best_dist:
                    best_dist = d
                    best_seg = seg

            if best_seg is None or best_dist > ROUTE_MAP_BUFFER * 3:
                # Too far from any offset line — skip this route
                continue

            # Snap: project the stop onto the nearest segment
            projected_dist = best_seg.project(stop_pt)
            snapped_pt = best_seg.interpolate(projected_dist)

            # Reproject snapped point back to WGS84
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
            # No routes were snapped — use original position as fallback
            positions.append({
                "route_id": routes[0] if routes else "",
                "lat": orig_lat,
                "lon": orig_lon,
            })

        # A transfer hub serves ≥ 2 different trunk groups
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
# MAIN ENTRY POINT — orchestrates all 6 phases
# ═══════════════════════════════════════════════════════════════════════════

def apply_topological_offsets(
    overlays: list,  # list[SubwayLineOverlay] — using `list` to avoid circular import
) -> list:
    """Top-level entry point: replace naive offset_curve with the full
    topological graph pipeline.

    Input:  list of SubwayLineOverlay (route_id, color_hex, polylines[encoded])
    Output: list of SubwayLineOverlay with properly offset polylines.

    Phases:
    1. Skeletonization → unified topological graph
    2. Global line ordering → anti-spaghetti lane assignments
    3. Parallel rendering → offset geometries
    4. Node rounding → concentric circular arc fillets
    5. Export → re-encoded polylines
    6. Stop processing → snap stops to offset lines, identify transfer hubs
    """
    from app.models import SubwayLineOverlay

    if not overlays:
        return overlays

    TrackLogger.info(f"[Pipeline] Starting topological offset pipeline for {len(overlays)} overlays")

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

    # ── Phase 3: Render parallel offsets ──
    try:
        route_segments = _render_parallel_offsets(G, edge_lanes)
    except Exception as exc:
        TrackLogger.error(f"[Pipeline] Phase 3 (Parallel render) failed: {exc}", exc_info=True)
        return overlays

    # ── Phase 4: Junction rounding ──
    try:
        route_segments = _apply_junction_rounding(G, route_segments, edge_lanes)
    except Exception as exc:
        TrackLogger.warning(f"[Pipeline] Phase 4 (Junction rounding) failed: {exc}")
        # Continue with unrounded segments — they're still valid

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

    # ── Build the output overlays ──
    # For routes that got pipeline-processed, use the new polylines.
    # For routes not in the output (e.g. isolated routes with no corridor
    # neighbours), keep the original polylines.
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
            # Route wasn't processed — pass through original
            result.append(overlay)

    processed = sum(1 for r in encoded_by_route if encoded_by_route[r])
    TrackLogger.info(
        f"[Pipeline] Complete: {processed}/{len(overlays)} routes processed, "
        f"{sum(len(o.polylines) for o in result)} total polylines"
    )

    return result
