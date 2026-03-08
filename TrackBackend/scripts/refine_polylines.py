#!/usr/bin/env python3
"""
Refine subway polylines: snap to OSM, fill true gaps, clean artifacts.

This is the single production script that takes subway_bundle.json from GTFS
coordinates to clean, Apple Maps–quality polylines:

1. Snap every coordinate to the nearest OSM track centerline
2. Fill real infrastructure gaps (bridges, tunnels, trestles > 1km)
   using graph-based pathfinding through connected OSM ways
3. Remove zigzags, backtracking, and snapping artifacts
4. Apply Catmull-Rom smoothing for curvy, natural appearance

Usage:
    cd TrackBackend
    python scripts/refine_polylines.py
"""

import json
import math
from collections import defaultdict
from pathlib import Path

# ─── Paths ───────────────────────────────────────────────────────────────────

BUNDLE_PATH = Path(__file__).parent.parent.parent / "Track" / "Data" / "subway_bundle.json"
BACKUP_PATH = BUNDLE_PATH.with_suffix(".json.bak")
OSM_DATA_PATH = Path(__file__).parent / "osm_subway_raw.json"

# ─── Config ──────────────────────────────────────────────────────────────────

MAX_SNAP_DISTANCE_M = 80.0       # Max distance to snap a point to OSM track
GRID_CELL_DEG = 0.002            # Spatial index cell size (~220m)
GAP_THRESHOLD_M = 1500.0         # Only fill gaps larger than this (real crossings)
GAP_SEARCH_RADIUS_M = 300.0      # Max lateral distance from gap line for fill points
SPIKE_ANGLE_DEG = 45.0           # Remove turns sharper than this
SMOOTH_SEGMENTS = 4              # Catmull-Rom interpolation segments per curve
SMOOTH_ALPHA = 0.5               # Centripetal parameterization

EXCLUDED_NAME_FRAGMENTS = {
    "yard", "siding", "spur", "shop track", "layup",
    "non-revenue", "transfer track",
    "path", "airtrain", "newark", "hudson-bergen", "hudson–bergen", "hoboken",
}


# ─── Math ────────────────────────────────────────────────────────────────────

COS_NYC = math.cos(math.radians(40.75))  # lon compression at NYC latitude

def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (math.sin(dlat / 2) ** 2 +
         math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) *
         math.sin(dlon / 2) ** 2)
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def nearest_point_on_segment(px, py, ax, ay, bx, by):
    """Nearest point on segment a→b to point p. Returns (lat, lon, dist_sq_scaled)."""
    axs, bxs, pxs = ax, bx, px
    ays, bys, pys = ay * COS_NYC, by * COS_NYC, py * COS_NYC
    dx, dy = bxs - axs, bys - ays
    len_sq = dx*dx + dy*dy
    if len_sq < 1e-20:
        return ax, ay, (pxs - axs)**2 + (pys - ays)**2
    t = max(0.0, min(1.0, ((pxs - axs)*dx + (pys - ays)*dy) / len_sq))
    nlat = ax + t * (bx - ax)
    nlon = ay + t * (by - ay)
    d = (pxs - nlat)**2 + (pys - nlon*COS_NYC)**2
    return nlat, nlon, d


def angle_at(p1, p2, p3):
    """Angle in degrees at p2 formed by p1→p2→p3."""
    v1x = p1[0] - p2[0]; v1y = (p1[1] - p2[1]) * COS_NYC
    v2x = p3[0] - p2[0]; v2y = (p3[1] - p2[1]) * COS_NYC
    dot = v1x*v2x + v1y*v2y
    m1 = math.sqrt(v1x*v1x + v1y*v1y)
    m2 = math.sqrt(v2x*v2x + v2y*v2y)
    if m1 < 1e-12 or m2 < 1e-12:
        return 180.0
    return math.degrees(math.acos(max(-1.0, min(1.0, dot / (m1*m2)))))


# ─── Spatial index (for snapping) ────────────────────────────────────────────

class TrackIndex:
    def __init__(self, cell=GRID_CELL_DEG):
        self.cell = cell
        self.grid = defaultdict(list)
        self.count = 0

    def _key(self, lat, lon):
        return (int(lat / self.cell), int(lon / self.cell))

    def add(self, lat1, lon1, lat2, lon2):
        mn_lat, mx_lat = min(lat1, lat2), max(lat1, lat2)
        mn_lon, mx_lon = min(lon1, lon2), max(lon1, lon2)
        k0 = self._key(mn_lat - self.cell, mn_lon - self.cell)
        k1 = self._key(mx_lat + self.cell, mx_lon + self.cell)
        seg = (lat1, lon1, lat2, lon2)
        for gx in range(k0[0], k1[0]+1):
            for gy in range(k0[1], k1[1]+1):
                self.grid[(gx, gy)].append(seg)
        self.count += 1

    def nearest(self, lat, lon):
        gx, gy = self._key(lat, lon)
        best_lat, best_lon, best_dsq = None, None, float('inf')
        for dx in range(-1, 2):
            for dy in range(-1, 2):
                for seg in self.grid.get((gx+dx, gy+dy), []):
                    nl, no, dsq = nearest_point_on_segment(
                        lat, lon, seg[0], seg[1], seg[2], seg[3])
                    if dsq < best_dsq:
                        best_dsq = dsq
                        best_lat, best_lon = nl, no
        if best_lat is None:
            return None, None, float('inf')
        return best_lat, best_lon, haversine_m(lat, lon, best_lat, best_lon)


# ─── OSM Way Graph (for gap filling) ────────────────────────────────────────

class WayGraph:
    """Graph of OSM ways for pathfinding through bridges/tunnels."""
    
    def __init__(self, ways, nodes):
        # Build adjacency: node_id → [(neighbor_node_id, distance_m), ...]
        self.nodes = nodes  # id → (lat, lon)
        self.adj = defaultdict(list)
        
        for w in ways:
            node_ids = w.get("nodes", [])
            for i in range(len(node_ids) - 1):
                a, b = node_ids[i], node_ids[i+1]
                if a in self.nodes and b in self.nodes:
                    la, lo = self.nodes[a]
                    lb, lb_o = self.nodes[b]
                    d = haversine_m(la, lo, lb, lb_o)
                    self.adj[a].append((b, d))
                    self.adj[b].append((a, d))
    
    def find_path(self, start_lat, start_lon, end_lat, end_lon, max_total_m=15000):
        """A* pathfinding from nearest node to start → nearest node to end."""
        import heapq
        
        # Find nearest graph nodes to start and end
        start_node = self._nearest_node(start_lat, start_lon, 500)
        end_node = self._nearest_node(end_lat, end_lon, 500)
        
        if start_node is None or end_node is None:
            return None
        if start_node == end_node:
            return None
        
        # A* search
        end_coord = self.nodes[end_node]
        
        # Priority queue: (f_score, g_score, node_id, path)
        open_set = [(0, 0, start_node, [start_node])]
        visited = set()
        
        while open_set:
            f, g, current, path = heapq.heappop(open_set)
            
            if current == end_node:
                # Convert node IDs to coordinates
                return [(self.nodes[n][0], self.nodes[n][1]) for n in path]
            
            if current in visited:
                continue
            visited.add(current)
            
            if g > max_total_m:
                continue
            
            for neighbor, dist in self.adj.get(current, []):
                if neighbor in visited:
                    continue
                new_g = g + dist
                # Heuristic: straight-line distance to end
                nlat, nlon = self.nodes[neighbor]
                h = haversine_m(nlat, nlon, end_coord[0], end_coord[1])
                heapq.heappush(open_set, (new_g + h, new_g, neighbor, path + [neighbor]))
        
        return None  # No path found
    
    def _nearest_node(self, lat, lon, max_dist_m):
        """Find the nearest graph node within max_dist_m."""
        best_id, best_d = None, float('inf')
        for nid, (nlat, nlon) in self.nodes.items():
            if nid not in self.adj:
                continue
            d = haversine_m(lat, lon, nlat, nlon)
            if d < best_d:
                best_d = d
                best_id = nid
        if best_d > max_dist_m:
            return None
        return best_id


# ─── Pipeline Steps ──────────────────────────────────────────────────────────

def load_osm(osm_path):
    """Load OSM data and return spatial index + way graph."""
    with open(osm_path) as f:
        data = json.load(f)
    
    elements = data.get("elements", [])
    nodes = {}
    raw_ways = []
    
    for e in elements:
        if e["type"] == "node":
            nodes[e["id"]] = (e["lat"], e["lon"])
        elif e["type"] == "way":
            raw_ways.append(e)
    
    # Filter to mainline tracks
    filtered_ways = []
    for w in raw_ways:
        tags = w.get("tags", {})
        name = tags.get("name", "").lower()
        service = tags.get("service", "").lower()
        if service in ("yard", "siding", "crossover", "spur"):
            continue
        if any(frag in name for frag in EXCLUDED_NAME_FRAGMENTS):
            continue
        filtered_ways.append(w)
    
    # Build spatial index
    index = TrackIndex()
    for w in filtered_ways:
        coords = [nodes[nid] for nid in w.get("nodes", []) if nid in nodes]
        for i in range(len(coords) - 1):
            index.add(coords[i][0], coords[i][1], coords[i+1][0], coords[i+1][1])
    
    # Build way graph for pathfinding
    # Only include nodes that belong to filtered ways
    graph_nodes = {}
    for w in filtered_ways:
        for nid in w.get("nodes", []):
            if nid in nodes:
                graph_nodes[nid] = nodes[nid]
    
    graph = WayGraph(filtered_ways, graph_nodes)
    
    print(f"  {len(filtered_ways)} mainline ways, {index.count} segments, {len(graph_nodes)} graph nodes")
    return index, graph


def step1_snap(bundle, index):
    """Snap all coordinates to nearest OSM track segment."""
    routes = bundle["routes"]
    snapped_count = 0
    total = 0
    
    for rid in sorted(routes):
        for bi, branch in enumerate(routes[rid]):
            for i, pt in enumerate(branch):
                total += 1
                sl, so, dm = index.nearest(pt["lat"], pt["lon"])
                if sl is not None and dm <= MAX_SNAP_DISTANCE_M:
                    branch[i] = {"lat": round(sl, 6), "lon": round(so, 6)}
                    snapped_count += 1
    
    print(f"  Snapped {snapped_count}/{total} points (avg within {MAX_SNAP_DISTANCE_M}m)")
    return bundle


def step2_fill_gaps(bundle, graph):
    """Fill large gaps (bridges/tunnels) using A* pathfinding through OSM graph."""
    routes = bundle["routes"]
    filled = 0
    added = 0
    
    for rid in sorted(routes):
        for bi, branch in enumerate(routes[rid]):
            if len(branch) < 2:
                continue
            
            new_branch = [branch[0]]
            for i in range(1, len(branch)):
                prev = branch[i-1]
                curr = branch[i]
                gap = haversine_m(prev["lat"], prev["lon"], curr["lat"], curr["lon"])
                
                if gap > GAP_THRESHOLD_M:
                    path = graph.find_path(
                        prev["lat"], prev["lon"],
                        curr["lat"], curr["lon"],
                        max_total_m=gap * 2
                    )
                    if path and len(path) >= 3:
                        # Insert intermediate points (skip first/last to avoid dupes)
                        fill_pts = [{"lat": round(p[0], 6), "lon": round(p[1], 6)}
                                    for p in path[1:-1]]
                        new_branch.extend(fill_pts)
                        filled += 1
                        added += len(fill_pts)
                        print(f"    Route {rid} br{bi}: filled {gap:.0f}m gap with {len(fill_pts)} pts (A*)")
                
                new_branch.append(curr)
            
            routes[rid][bi] = new_branch
    
    print(f"  Filled {filled} gaps, added {added} points")
    return bundle


def step2b_dedup_branches(bundle):
    """
    Collapse GTFS trip-level branches to canonical physical branches.
    
    GTFS shapes.txt stores one shape per trip variant: northbound, southbound,
    rush-hour express, weekend short-turn, etc.  This produces 14 "branches"
    for the 5 train when reality is ~3.  We collapse them:
    
    1. Sort branches longest-first (the trunk baseline).
    2. Build a spatial grid from kept branches.
    3. For each remaining branch, compute overlap with kept geometry.
    4. >85% overlap → probably duplicate, but still check if the
       non-overlapping tail reaches a genuinely different terminal.
    5. <15% overlap → entirely new corridor, keep whole branch.
    6. 15–85% overlap → extract only the unique contiguous stubs
       (the part that diverges from already-kept geometry).
    """
    CELL = 0.001  # ~84m at NYC latitude
    MIN_STUB_PTS = 10  # Ignore runs shorter than this
    MIN_TERMINAL_DIST_M = 800  # Stub endpoint must be this far from all kept endpoints
    
    def cell_key(lat, lon):
        return (int(math.floor(lat / CELL)), int(math.floor(lon / CELL)))
    
    def pack(lc, nc):
        return lc * 10_000_000 + nc
    
    routes = bundle["routes"]
    total_before = sum(len(br) for brs in routes.values() for br in brs)
    branches_before = sum(len(brs) for brs in routes.values())
    
    for rid in sorted(routes):
        branches = routes[rid]
        if len(branches) <= 1:
            continue
        
        # Sort longest first
        indexed = sorted(enumerate(branches), key=lambda x: -len(x[1]))
        
        grid = set()
        kept = []
        kept_endpoints = []  # Track (lat, lon) of all kept branch start/end points
        
        def add_to_grid(branch):
            for pt in branch:
                lc, nc = cell_key(pt["lat"], pt["lon"])
                grid.add(pack(lc, nc))
        
        def is_covered(lat, lon):
            lc, nc = cell_key(lat, lon)
            for dl in range(-1, 2):
                for dn in range(-1, 2):
                    if pack(lc + dl, nc + dn) in grid:
                        return True
            return False
        
        def is_near(lat, lon):
            """Wider check (±4 cells ≈ 450m) for branch validation."""
            lc, nc = cell_key(lat, lon)
            for dl in range(-4, 5):
                for dn in range(-4, 5):
                    if pack(lc + dl, nc + dn) in grid:
                        return True
            return False
        
        def is_new_terminal(lat, lon):
            """Check if this endpoint is far enough from all kept endpoints."""
            for elat, elon in kept_endpoints:
                if haversine_m(lat, lon, elat, elon) < MIN_TERMINAL_DIST_M:
                    return False
            return True
        
        def extract_stubs(branch, min_pts=MIN_STUB_PTS):
            """Extract contiguous uncovered runs from a branch."""
            cov = [is_covered(pt["lat"], pt["lon"]) for pt in branch]
            runs = []
            run_start = None
            for i, c in enumerate(cov):
                if not c:
                    if run_start is None:
                        run_start = i
                elif run_start is not None:
                    if i - run_start >= min_pts:
                        runs.append((run_start, i - 1))
                    run_start = None
            if run_start is not None and len(branch) - run_start >= min_pts:
                runs.append((run_start, len(branch) - 1))
            
            stubs = []
            for rs, re in runs:
                mid = (rs + re) // 2
                # Skip corridor variants — start, mid, AND end all near existing geometry
                if (is_near(branch[rs]["lat"], branch[rs]["lon"]) and
                    is_near(branch[mid]["lat"], branch[mid]["lon"]) and
                    is_near(branch[re]["lat"], branch[re]["lon"])):
                    continue
                
                # Extend a few points into covered area for seamless connection
                ext_s = max(0, rs - 5)
                ext_e = min(len(branch) - 1, re + 5)
                stub = branch[ext_s:ext_e + 1]
                if len(stub) >= 2:
                    stubs.append(stub)
            return stubs
        
        # Seed with longest branch
        first = indexed[0][1]
        kept.append(first)
        add_to_grid(first)
        kept_endpoints.append((first[0]["lat"], first[0]["lon"]))
        kept_endpoints.append((first[-1]["lat"], first[-1]["lon"]))
        
        for orig_idx, branch in indexed[1:]:
            if len(branch) < 2:
                continue
            
            covered_count = sum(1 for pt in branch if is_covered(pt["lat"], pt["lon"]))
            ratio = covered_count / len(branch)
            
            if ratio > 0.85:
                # Mostly duplicate — but check if the non-overlapping portion
                # reaches a genuinely new terminal (e.g. A train Rockaway Park
                # branch shares 85% trunk with Far Rockaway branch but diverges
                # to a different destination)
                stubs = extract_stubs(branch, min_pts=8)
                for stub in stubs:
                    ep_start = (stub[0]["lat"], stub[0]["lon"])
                    ep_end = (stub[-1]["lat"], stub[-1]["lon"])
                    if is_new_terminal(*ep_start) or is_new_terminal(*ep_end):
                        kept.append(stub)
                        add_to_grid(stub)
                        kept_endpoints.append(ep_start)
                        kept_endpoints.append(ep_end)
                continue
            
            if ratio < 0.15:
                kept.append(branch)
                add_to_grid(branch)
                kept_endpoints.append((branch[0]["lat"], branch[0]["lon"]))
                kept_endpoints.append((branch[-1]["lat"], branch[-1]["lon"]))
                continue
            
            # Partial overlap — extract unique stubs
            stubs = extract_stubs(branch)
            for stub in stubs:
                kept.append(stub)
                add_to_grid(stub)
                kept_endpoints.append((stub[0]["lat"], stub[0]["lon"]))
                kept_endpoints.append((stub[-1]["lat"], stub[-1]["lon"]))
        
        routes[rid] = kept
    
    total_after = sum(len(br) for brs in routes.values() for br in brs)
    branches_after = sum(len(brs) for brs in routes.values())
    print(f"  {branches_before} → {branches_after} branches, {total_before} → {total_after} points")
    return bundle


def step3_remove_artifacts(bundle):
    """Remove consecutive duplicates, spikes, and zigzag artifacts."""
    routes = bundle["routes"]
    dupes_removed = 0
    spikes_removed = 0
    
    for rid in sorted(routes):
        for bi, branch in enumerate(routes[rid]):
            # Pass 1: remove consecutive duplicates
            cleaned = [branch[0]] if branch else []
            for i in range(1, len(branch)):
                if (branch[i]["lat"] != cleaned[-1]["lat"] or
                    branch[i]["lon"] != cleaned[-1]["lon"]):
                    cleaned.append(branch[i])
                else:
                    dupes_removed += 1
            
            # Pass 2: remove spikes (sharp angle < threshold, iterative)
            changed = True
            passes = 0
            while changed and passes < 5:
                changed = False
                passes += 1
                new_cleaned = [cleaned[0]] if cleaned else []
                
                i = 1
                while i < len(cleaned) - 1:
                    p1 = (cleaned[i-1]["lat"], cleaned[i-1]["lon"])
                    p2 = (cleaned[i]["lat"], cleaned[i]["lon"])
                    p3 = (cleaned[i+1]["lat"], cleaned[i+1]["lon"])
                    
                    angle = angle_at(p1, p2, p3)
                    
                    if angle < SPIKE_ANGLE_DEG:
                        # This is a spike — skip it
                        spikes_removed += 1
                        changed = True
                        i += 1
                        continue
                    
                    new_cleaned.append(cleaned[i])
                    i += 1
                
                if cleaned:
                    new_cleaned.append(cleaned[-1])
                cleaned = new_cleaned
            
            # Pass 3: remove micro-backtracking (two consecutive sharp turns)
            final = [cleaned[0]] if cleaned else []
            i = 1
            while i < len(cleaned) - 1:
                p1 = (cleaned[i-1]["lat"], cleaned[i-1]["lon"])
                p2 = (cleaned[i]["lat"], cleaned[i]["lon"])
                p3 = (cleaned[i+1]["lat"], cleaned[i+1]["lon"])
                
                angle = angle_at(p1, p2, p3)
                
                # Check if this is a backtrack (short segment + sharp turn back)
                seg_len = haversine_m(p1[0], p1[1], p2[0], p2[1])
                if angle < 80 and seg_len < 50:
                    spikes_removed += 1
                    i += 1
                    continue
                
                final.append(cleaned[i])
                i += 1
            
            if cleaned:
                final.append(cleaned[-1])
            
            routes[rid][bi] = final
    
    print(f"  Removed {dupes_removed} duplicates, {spikes_removed} spikes/backtracks")
    return bundle


def step4_smooth(bundle):
    """Apply Catmull-Rom centripetal spline smoothing for curvy natural appearance."""
    routes = bundle["routes"]
    total_before = 0
    total_after = 0
    
    for rid in sorted(routes):
        for bi, branch in enumerate(routes[rid]):
            n = len(branch)
            total_before += n
            
            if n < 3:
                total_after += n
                continue
            
            smoothed = []
            for i in range(n - 1):
                # 4 control points with endpoint clamping
                p0 = branch[max(i-1, 0)]
                p1 = branch[i]
                p2 = branch[i+1]
                p3 = branch[min(i+2, n-1)]
                
                if i == 0:
                    smoothed.append(p1)
                
                # Knot distances (centripetal)
                d01 = _knot_dist(p0, p1)
                d12 = _knot_dist(p1, p2)
                d23 = _knot_dist(p2, p3)
                
                if d12 < 1e-12:
                    smoothed.append(p2)
                    continue
                
                t0 = 0.0
                t1 = t0 + d01
                t2 = t1 + d12
                t3 = t2 + d23
                
                for step in range(1, SMOOTH_SEGMENTS + 1):
                    frac = step / SMOOTH_SEGMENTS
                    t = t1 + frac * (t2 - t1)
                    
                    lat, lon = _catmull_rom(
                        (p0["lat"], p0["lon"]),
                        (p1["lat"], p1["lon"]),
                        (p2["lat"], p2["lon"]),
                        (p3["lat"], p3["lon"]),
                        t, t0, t1, t2, t3
                    )
                    smoothed.append({"lat": round(lat, 6), "lon": round(lon, 6)})
            
            total_after += len(smoothed)
            routes[rid][bi] = smoothed
    
    print(f"  {total_before} → {total_after} points (Catmull-Rom, {SMOOTH_SEGMENTS} segs/curve)")
    return bundle


def _knot_dist(a, b):
    dx = (b["lon"] - a["lon"]) * COS_NYC
    dy = b["lat"] - a["lat"]
    return pow(dx*dx + dy*dy, SMOOTH_ALPHA * 0.5)


def _catmull_rom(p0, p1, p2, p3, t, t0, t1, t2, t3):
    def lerp(a, b, f):
        return (a[0] + (b[0]-a[0])*f, a[1] + (b[1]-a[1])*f)
    
    dt10 = t1-t0; dt21 = t2-t1; dt32 = t3-t2
    dt20 = t2-t0; dt31 = t3-t1
    
    if abs(dt10) < 1e-12 or abs(dt21) < 1e-12 or abs(dt32) < 1e-12 or \
       abs(dt20) < 1e-12 or abs(dt31) < 1e-12:
        return p1
    
    a1 = lerp(p0, p1, (t-t0)/dt10)
    a2 = lerp(p1, p2, (t-t1)/dt21)
    a3 = lerp(p2, p3, (t-t2)/dt32)
    b1 = lerp(a1, a2, (t-t0)/dt20)
    b2 = lerp(a2, a3, (t-t1)/dt31)
    return lerp(b1, b2, (t-t1)/dt21)


def step5_final_cleanup(bundle):
    """Final pass: remove any remaining consecutive duplicates from smoothing."""
    routes = bundle["routes"]
    removed = 0
    for rid in routes:
        for bi, branch in enumerate(routes[rid]):
            cleaned = [branch[0]] if branch else []
            for i in range(1, len(branch)):
                if branch[i]["lat"] != cleaned[-1]["lat"] or branch[i]["lon"] != cleaned[-1]["lon"]:
                    cleaned.append(branch[i])
                else:
                    removed += 1
            routes[rid][bi] = cleaned
    if removed:
        print(f"  Removed {removed} final duplicates")
    return bundle


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    print("=" * 60)
    print("  Refine Subway Polylines (snap + fill + clean + smooth)")
    print("=" * 60)
    
    # Load original (unmodified) bundle from backup
    print("\nLoading original GTFS bundle...")
    with open(BACKUP_PATH) as f:
        bundle = json.load(f)
    total_pts = sum(sum(len(b) for b in br) for br in bundle["routes"].values())
    print(f"  {len(bundle['routes'])} routes, {total_pts} points")
    
    # Load OSM data
    print("\nLoading OSM track data...")
    index, graph = load_osm(OSM_DATA_PATH)
    
    # Step 1: Snap to OSM tracks
    print("\nStep 1: Snapping to OSM tracks...")
    bundle = step1_snap(bundle, index)
    
    # Step 2: Fill bridge/tunnel gaps using graph pathfinding
    print("\nStep 2: Filling bridge/tunnel gaps (A* pathfinding)...")
    bundle = step2_fill_gaps(bundle, graph)
    
    # Step 2b: Deduplicate GTFS trip variants to canonical physical branches
    print("\nStep 2b: Deduplicating branches...")
    bundle = step2b_dedup_branches(bundle)
    
    # Step 3: Remove artifacts (duplicates, spikes, zigzags)
    print("\nStep 3: Removing artifacts...")
    bundle = step3_remove_artifacts(bundle)
    
    # Step 4: Catmull-Rom smoothing — SKIP
    # Smoothing is applied in the iOS app:
    #   - Route detail: HomeViewModel does smoothPolyline(segmentsPerCurve: 4)
    #   - System map: We'll add smoothing to MapSystemViewModel.swift
    # Pre-smoothing in the bundle would double-smooth and bloat the file.
    print("\nStep 4: Smoothing skipped (applied in iOS rendering)")
    
    # Step 5: Final cleanup
    print("\nStep 5: Final cleanup...")
    bundle = step5_final_cleanup(bundle)
    
    # Update version
    bundle["version"] = "4.0"
    
    # Write output
    print("\nWriting refined bundle...")
    with open(BUNDLE_PATH, 'w') as f:
        json.dump(bundle, f, separators=(',', ':'))
    
    final_pts = sum(sum(len(b) for b in br) for br in bundle["routes"].values())
    size_kb = BUNDLE_PATH.stat().st_size / 1024
    print(f"  {final_pts} total points, {size_kb:.1f} KB")
    
    print("\n" + "=" * 60)
    print("  Done! Clean, curvy, OSM-aligned polylines ready.")
    print("=" * 60)


if __name__ == "__main__":
    main()
