#!/usr/bin/env python3
"""
test_stop_polyline_coverage.py
──────────────────────────────
Check which stations are NOT within a threshold distance of any polyline
belonging to their route(s).

Usage:
    python scripts/test_stop_polyline_coverage.py [--threshold 80] [--backend http://localhost:8767]

Outputs a report of uncovered stops sorted by distance to nearest polyline point.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import urllib.request
from dataclasses import dataclass, field


# ── Haversine distance (meters) ─────────────────────────────────────────────

def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance between two WGS-84 points in meters."""
    R = 6_371_000.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def point_to_segment_distance_m(
    plat: float, plon: float,
    alat: float, alon: float,
    blat: float, blon: float,
) -> float:
    """Approx minimum distance from point P to line segment A–B (meters).

    Projects P onto the segment in a local Cartesian frame, then converts
    the perpendicular offset to meters.  Accurate enough for distances < 1 km.
    """
    cos_lat = math.cos(math.radians(plat))
    # local meters per degree
    m_per_deg_lat = 111_132.0
    m_per_deg_lon = max(cos_lat * 111_320.0, 1.0)

    # Convert to local meters
    ax = (alon - plon) * m_per_deg_lon
    ay = (alat - plat) * m_per_deg_lat
    bx = (blon - plon) * m_per_deg_lon
    by = (blat - plat) * m_per_deg_lat

    dx, dy = bx - ax, by - ay
    seg_len_sq = dx * dx + dy * dy
    if seg_len_sq < 1e-12:
        return math.sqrt(ax * ax + ay * ay)

    t = max(0.0, min(1.0, ((-ax) * dx + (-ay) * dy) / seg_len_sq))
    cx = ax + t * dx
    cy = ay + t * dy
    return math.sqrt(cx * cx + cy * cy)


# ── Polyline decoder (precision-6) ──────────────────────────────────────────

def decode_polyline(encoded: str) -> list[tuple[float, float]]:
    coords: list[tuple[float, float]] = []
    i, lat, lng = 0, 0, 0
    while i < len(encoded):
        for is_lng in (False, True):
            shift, result = 0, 0
            while True:
                b = ord(encoded[i]) - 63
                i += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            delta = ~(result >> 1) if (result & 1) else (result >> 1)
            if is_lng:
                lng += delta
            else:
                lat += delta
        coords.append((lat / 1e6, lng / 1e6))
    return coords


# ── Data structures ─────────────────────────────────────────────────────────

@dataclass
class Station:
    id: str
    name: str
    lat: float
    lon: float
    routes: list[str]


@dataclass
class RoutePolylines:
    route_id: str
    segments: list[list[tuple[float, float]]] = field(default_factory=list)


@dataclass
class CoverageResult:
    station: Station
    route_id: str
    min_distance_m: float
    nearest_point: tuple[float, float]


# ── API fetchers ────────────────────────────────────────────────────────────

def fetch_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def fetch_stations(backend: str) -> list[Station]:
    data = fetch_json(f"{backend}/subway/stations/all")
    stations = []
    for s in data.get("stations", []):
        stations.append(Station(
            id=s["id"],
            name=s["name"],
            lat=s["lat"],
            lon=s["lon"],
            routes=s.get("routes", []),
        ))
    return stations


def fetch_polylines(backend: str) -> dict[str, RoutePolylines]:
    data = fetch_json(f"{backend}/subway/shapes/all")
    routes: dict[str, RoutePolylines] = {}
    for line in data.get("lines", []):
        rid = line["route_id"]
        rp = RoutePolylines(route_id=rid)
        for encoded in line.get("polylines", []):
            coords = decode_polyline(encoded)
            if len(coords) >= 2:
                rp.segments.append(coords)
        routes[rid] = rp
    return routes


# ── Coverage check ──────────────────────────────────────────────────────────

def min_distance_to_route(
    lat: float, lon: float, route: RoutePolylines
) -> tuple[float, tuple[float, float]]:
    """Return (min_distance_m, nearest_point) from (lat, lon) to route polylines."""
    best_dist = float("inf")
    best_point = (0.0, 0.0)

    for segment in route.segments:
        # Check segment-by-segment for true perpendicular projection
        for j in range(len(segment) - 1):
            d = point_to_segment_distance_m(
                lat, lon,
                segment[j][0], segment[j][1],
                segment[j + 1][0], segment[j + 1][1],
            )
            if d < best_dist:
                best_dist = d
                # Approximate nearest point (use midpoint of closest segment)
                best_point = (
                    (segment[j][0] + segment[j + 1][0]) / 2,
                    (segment[j][1] + segment[j + 1][1]) / 2,
                )
        # Also check raw vertices (handles endpoints)
        for pt in segment:
            d = haversine_m(lat, lon, pt[0], pt[1])
            if d < best_dist:
                best_dist = d
                best_point = pt

    return best_dist, best_point


def check_coverage(
    stations: list[Station],
    route_polylines: dict[str, RoutePolylines],
    threshold_m: float,
) -> list[CoverageResult]:
    """Find stations not within threshold_m of any of their route's polylines."""
    uncovered: list[CoverageResult] = []

    for station in stations:
        for rid in station.routes:
            route = route_polylines.get(rid)
            if route is None:
                # Route not in shapes response — might be a shuttle or special
                uncovered.append(CoverageResult(
                    station=station,
                    route_id=rid,
                    min_distance_m=float("inf"),
                    nearest_point=(0, 0),
                ))
                continue

            if not route.segments:
                uncovered.append(CoverageResult(
                    station=station,
                    route_id=rid,
                    min_distance_m=float("inf"),
                    nearest_point=(0, 0),
                ))
                continue

            dist, nearest = min_distance_to_route(station.lat, station.lon, route)
            if dist > threshold_m:
                uncovered.append(CoverageResult(
                    station=station,
                    route_id=rid,
                    min_distance_m=dist,
                    nearest_point=nearest,
                ))

    return uncovered


# ── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Check stop-to-polyline coverage")
    parser.add_argument("--threshold", type=float, default=80,
                        help="Max distance (m) for a stop to be 'covered' (default: 80)")
    parser.add_argument("--backend", default="http://localhost:8767",
                        help="Backend URL (default: http://localhost:8767)")
    args = parser.parse_args()

    print(f"Backend:   {args.backend}")
    print(f"Threshold: {args.threshold} m")
    print()

    # Fetch data
    print("Fetching stations...", end=" ", flush=True)
    stations = fetch_stations(args.backend)
    print(f"{len(stations)} stations")

    print("Fetching polylines...", end=" ", flush=True)
    route_polylines = fetch_polylines(args.backend)
    total_segments = sum(len(r.segments) for r in route_polylines.values())
    total_points = sum(sum(len(s) for s in r.segments) for r in route_polylines.values())
    print(f"{len(route_polylines)} routes, {total_segments} segments, {total_points:,} points")
    print()

    # Check coverage
    print("Checking coverage...", end=" ", flush=True)
    uncovered = check_coverage(stations, route_polylines, args.threshold)
    print("done")
    print()

    # Count total stop-route pairs
    total_pairs = sum(len(s.routes) for s in stations)
    covered = total_pairs - len(uncovered)

    print(f"{'='*70}")
    print(f"COVERAGE SUMMARY")
    print(f"{'='*70}")
    print(f"Total stop-route pairs:  {total_pairs}")
    print(f"Covered (< {args.threshold}m):       {covered}  ({100*covered/total_pairs:.1f}%)")
    print(f"Uncovered (>= {args.threshold}m):     {len(uncovered)}  ({100*len(uncovered)/total_pairs:.1f}%)")
    print()

    if not uncovered:
        print("✅ All stops are covered by their route polylines!")
        return

    # Sort by distance (worst first)
    uncovered.sort(key=lambda r: r.min_distance_m, reverse=True)

    # Separate missing routes vs distant stops
    missing_route = [r for r in uncovered if r.min_distance_m == float("inf")]
    distant = [r for r in uncovered if r.min_distance_m != float("inf")]

    if missing_route:
        print(f"⚠️  MISSING ROUTES ({len(missing_route)} stop-route pairs with no polyline data):")
        print(f"{'─'*70}")
        seen_routes: set[str] = set()
        for r in missing_route:
            if r.route_id not in seen_routes:
                stops_for_route = [x for x in missing_route if x.route_id == r.route_id]
                print(f"  Route {r.route_id:>3s}: {len(stops_for_route)} stops, no polyline")
                seen_routes.add(r.route_id)
        print()

    if distant:
        print(f"❌ UNCOVERED STOPS ({len(distant)} stop-route pairs farther than {args.threshold}m):")
        print(f"{'─'*70}")
        print(f"  {'Route':>5s}  {'Distance':>8s}  {'Station ID':>10s}  {'Station Name'}")
        print(f"  {'─'*5:>5s}  {'─'*8:>8s}  {'─'*10:>10s}  {'─'*30}")
        for r in distant:
            dist_str = f"{r.min_distance_m:.0f}m"
            print(f"  {r.route_id:>5s}  {dist_str:>8s}  {r.station.id:>10s}  {r.station.name}")
        print()

        # Group by route for a route-level view
        print(f"BY ROUTE:")
        print(f"{'─'*70}")
        route_groups: dict[str, list[CoverageResult]] = {}
        for r in distant:
            route_groups.setdefault(r.route_id, []).append(r)
        for rid in sorted(route_groups.keys()):
            group = route_groups[rid]
            avg_dist = sum(r.min_distance_m for r in group) / len(group)
            max_dist = max(r.min_distance_m for r in group)
            print(f"  Route {rid:>3s}: {len(group):>3d} uncovered stops"
                  f"  (avg {avg_dist:.0f}m, max {max_dist:.0f}m)")

    print()
    print(f"{'='*70}")
    if distant:
        print(f"🔍 {len(distant)} stops need polyline coverage attention")
    else:
        print(f"✅ All stops with polyline data are within {args.threshold}m")


if __name__ == "__main__":
    main()
