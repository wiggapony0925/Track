#!/usr/bin/env python3
"""Diagnostic: verify every subway stop is touched by its trunk polyline."""
from __future__ import annotations
import sys
from math import atan2, cos, radians, sin, sqrt
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.mapping.subway_shapes import (
    get_all_subway_stations, _load_route_shapes, _load_shapes,
    _unpack_coords,
)
from app.routers.subway import get_subway_color
from app.services.mapping.corridor_pipeline import (
    ROUTE_TO_TRUNK, _snap_paths_to_stations,
    _group_and_merge_trunks, _normalize_path_direction,
)
from app.utils.polyline_utils import encode_polyline, densify_wgs84, decode_polyline
from app.models import SubwayLineOverlay


def haversine_m(lat1, lon1, lat2, lon2):
    R = 6_371_000
    dlat = radians(lat2 - lat1)
    dlon = radians(lon2 - lon1)
    a = sin(dlat / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ** 2
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))


def min_dist_to_polyline(lat, lon, polyline):
    best = float("inf")
    for i in range(len(polyline) - 1):
        a_lat, a_lon = polyline[i]
        b_lat, b_lon = polyline[i + 1]
        dx = b_lon - a_lon
        dy = b_lat - a_lat
        if dx == 0 and dy == 0:
            d = haversine_m(lat, lon, a_lat, a_lon)
        else:
            t = max(0, min(1, ((lon - a_lon) * dx + (lat - a_lat) * dy) / (dx * dx + dy * dy)))
            d = haversine_m(lat, lon, a_lat + t * dy, a_lon + t * dx)
        if d < best:
            best = d
            if d < 5:
                return d
    return best


def test_subway_stops():
    print("=" * 70)
    print("SUBWAY STOP-POLYLINE COVERAGE TEST")
    print("=" * 70)

    stations = get_all_subway_stations()
    if not stations:
        print("ERROR: No stations loaded")
        return False

    route_shapes = _load_route_shapes()
    shapes_data = _load_shapes()
    skip_variants = {"6X", "7X", "FX", "SR"}

    overlays = []
    lines = [l for l in sorted(route_shapes.keys()) if l not in skip_variants]

    for line in lines:
        ds = route_shapes.get(line)
        if not ds:
            continue
        pd = 0 if 0 in ds else min(ds.keys())
        sids = ds[pd]
        raws = []
        for sid in sids:
            sb = shapes_data.get(sid)
            if sb:
                raws.append(_unpack_coords(sb))
        if not raws:
            continue
        enc = [encode_polyline(densify_wgs84(c)) for c in raws]
        overlays.append(SubwayLineOverlay(route_id=line, color_hex=get_subway_color(line), polylines=enc))

    print("Running trunk merge pipeline...")
    trunk_paths = _group_and_merge_trunks(overlays)
    print("Running station snap...")
    trunk_paths = _snap_paths_to_stations(trunk_paths)
    for ti in list(trunk_paths.keys()):
        trunk_paths[ti] = [_normalize_path_direction(p) for p in trunk_paths[ti]]

    from pyproj import Transformer
    to_wgs = Transformer.from_crs("EPSG:3857", "EPSG:4326", always_xy=True)
    trunk_polys = {}
    for ti, paths in trunk_paths.items():
        trunk_polys[ti] = []
        for path in paths:
            wgs = []
            for x, y in path.coords:
                lo, la = to_wgs.transform(x, y)
                wgs.append((la, lo))
            trunk_polys[ti].append(wgs)

    # Flatten ALL polylines for the "any trunk" check
    all_polys = []
    for polys_list in trunk_polys.values():
        all_polys.extend(polys_list)

    # ── Per-trunk check (route-specific) ──
    total = 0
    misses = []
    far_stops = []
    cross_trunk = []
    for station in stations:
        routes = station.get("routes", [])
        lat = station["lat"]
        lon = station["lon"]
        name = station["name"]
        sid = station["id"]
        tested = set()
        for rid in routes:
            tidx = ROUTE_TO_TRUNK.get(rid)
            if tidx is None or tidx in tested:
                continue
            tested.add(tidx)
            polys = trunk_polys.get(tidx, [])
            if not polys:
                misses.append(
                    (name, sid, rid, tidx, float("inf"), "NO_TRUNK")
                )
                total += 1
                continue
            best = min(
                min_dist_to_polyline(lat, lon, p) for p in polys
            )
            total += 1
            if best > 150:
                # Check if it's a cross-trunk station (on another trunk)
                any_best = min(
                    min_dist_to_polyline(lat, lon, p) for p in all_polys
                )
                if any_best <= 50:
                    cross_trunk.append(
                        (name, sid, rid, tidx, best, any_best)
                    )
                else:
                    misses.append(
                        (name, sid, rid, tidx, best, "MISS")
                    )
            elif best > 50:
                far_stops.append((name, sid, rid, tidx, best))

    mc = len(misses)
    fc = len(far_stops)
    xc = len(cross_trunk)
    ok = total - mc - fc - xc
    print()
    print(f"Total station-trunk pairs: {total}")
    print(f"  OK  <=50m:        {ok}")
    print(f"  WARN 50-150m:     {fc}")
    print(f"  CROSS-TRUNK:      {xc}  (on different trunk polyline)")
    print(f"  FAIL >150m:       {mc}")

    if cross_trunk:
        print()
        print("CROSS-TRUNK stops (distant from own trunk, OK on another):")
        for n, s, r, t, d, ad in sorted(
            cross_trunk, key=lambda x: -x[4]
        ):
            print(
                f"  {n} ({s}) route={r} trunk={t} "
                f"own={d:.0f}m nearest_any={ad:.0f}m"
            )
    if far_stops:
        print()
        print("WARNING stops (50-150m):")
        for n, s, r, t, d in sorted(far_stops, key=lambda x: -x[4]):
            print(f"  {n} ({s}) route={r} trunk={t} dist={d:.0f}m")
    if misses:
        print()
        print("FAILED stops (>150m, not on ANY polyline):")
        for n, s, r, t, d, reason in sorted(
            misses, key=lambda x: -x[4]
        ):
            ds = f"{d:.0f}m" if d < float("inf") else "INF"
            print(
                f"  {n} ({s}) route={r} trunk={t} dist={ds} [{reason}]"
            )

    # ── System-map check: every station on ANY trunk polyline ──
    print()
    print("-" * 50)
    print("SYSTEM MAP CHECK: every station on ANY polyline")
    any_miss = 0
    for station in stations:
        lat = station["lat"]
        lon = station["lon"]
        best = min(
            min_dist_to_polyline(lat, lon, p) for p in all_polys
        )
        if best > 50:
            any_miss += 1
            print(
                f"  MISS: {station['name']} ({station['id']}) "
                f"dist={best:.0f}m"
            )
    total_st = len(stations)
    print(
        f"  {total_st - any_miss}/{total_st} stations within 50m "
        f"of any polyline"
    )
    print()

    # Pass if no TRUE misses (cross-trunk is OK for system map)
    return mc == 0 and fc == 0 and any_miss == 0


def test_bus_stops():
    print("=" * 70)
    print("BUS STOP-POLYLINE COVERAGE TEST (static GTFS)")
    print("=" * 70)
    try:
        from app.clients.bus_client import (
            _load_static_bus_route_shape_index,
        )
    except Exception as e:
        print(f"Cannot load bus module: {e} — skipping")
        return True

    index = _load_static_bus_route_shape_index()
    if not index:
        print("No static bus shapes — skipping")
        return True

    total_r = 0
    total_s = 0
    total_m = 0
    route_misses = []
    for rid, shape in sorted(index.items()):
        if not shape.stops or not shape.polylines:
            continue
        polys = [decode_polyline(e) for e in shape.polylines]
        polys = [p for p in polys if len(p) >= 2]
        if not polys:
            continue
        total_r += 1
        rm = 0
        wd = 0.0
        for stop in shape.stops:
            total_s += 1
            best = min(
                min_dist_to_polyline(stop.lat, stop.lon, p)
                for p in polys
            )
            if best > 100:
                rm += 1
                total_m += 1
            if best > wd:
                wd = best
        if rm > 0:
            route_misses.append((rid, rm, len(shape.stops), wd))

    pct = (1 - total_m / total_s) * 100 if total_s > 0 else 100
    print()
    print(f"Routes tested:  {total_r}")
    print(f"Total stops:    {total_s}")
    print(f"Stops >100m:    {total_m}")
    print(f"Coverage:       {pct:.1f}%")
    if route_misses:
        print()
        print(f"Routes with misses ({len(route_misses)}):")
        for r, mc, sc, wd in sorted(
            route_misses, key=lambda x: -x[1]
        )[:25]:
            print(
                f"  {r}: {mc}/{sc} miss "
                f"({mc / sc * 100:.0f}%), worst={wd:.0f}m"
            )
        if len(route_misses) > 25:
            print(f"  ... and {len(route_misses) - 25} more")
    print()
    return total_m == 0


if __name__ == "__main__":
    s = test_subway_stops()
    b = test_bus_stops()
    print("=" * 70)
    print("SUMMARY")
    sr = "PASS" if s else "ISSUES"
    br = "PASS" if b else "ISSUES"
    print(f"  Subway: {sr}")
    print(f"  Bus:    {br}")
    sys.exit(0 if s and b else 1)
