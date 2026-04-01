#!/usr/bin/env python3
"""Diagnose polyline artifacts near Atlantic Ave / Downtown Brooklyn."""
import json
import math
import os

CACHE = os.path.join(os.path.dirname(__file__), "..", "app", "data", "_cache_shapes_all.json")

def decode_polyline(encoded):
    coords = []
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


def bearing(lat1, lon1, lat2, lon2):
    """Bearing from point 1 to point 2 in degrees [0, 360)."""
    dx = lon2 - lon1
    dy = lat2 - lat1
    return math.degrees(math.atan2(dx, dy)) % 360


def turn_angle(lat0, lon0, lat1, lon1, lat2, lon2):
    """Absolute turn angle at vertex 1 in degrees [0, 180]."""
    dx1 = lon1 - lon0
    dy1 = lat1 - lat0
    dx2 = lon2 - lon1
    dy2 = lat2 - lat1
    mag1 = math.sqrt(dx1*dx1 + dy1*dy1)
    mag2 = math.sqrt(dx2*dx2 + dy2*dy2)
    if mag1 < 1e-12 or mag2 < 1e-12:
        return 0
    dot = (dx1*dx2 + dy1*dy2) / (mag1 * mag2)
    dot = max(-1, min(1, dot))
    return math.degrees(math.acos(dot))


def main():
    with open(os.path.abspath(CACHE)) as f:
        data = json.load(f)

    # Atlantic Ave / DeKalb: lat ~40.684, lon ~-73.978
    lat_min, lat_max = 40.678, 40.698
    lon_min, lon_max = -73.992, -73.968

    print("=" * 70)
    print("POLYLINE DIAGNOSIS: Atlantic Ave / Downtown Brooklyn area")
    print(f"Bounding box: [{lat_min},{lon_min}] to [{lat_max},{lon_max}]")
    print("=" * 70)

    print("\n── TRUNK POLYLINES ──")
    for trunk in data.get("trunk_polylines", []):
        tidx = trunk["trunk_index"]
        rids = trunk["route_ids"]
        offsets = trunk.get("polyline_lane_offsets", [])
        for pi, poly_enc in enumerate(trunk["polylines"]):
            coords = decode_polyline(poly_enc)
            nearby_indices = [
                i for i, (lat, lon) in enumerate(coords)
                if lat_min <= lat <= lat_max and lon_min <= lon <= lon_max
            ]
            if not nearby_indices:
                continue
            offset = offsets[pi] if pi < len(offsets) else "?"
            print(f"\n  Trunk {tidx} ({','.join(rids)}) poly[{pi}]: "
                  f"{len(coords)} pts total, {len(nearby_indices)} near Atlantic, offset={offset}")

            # Check for sharp turns in the nearby region
            sharp_turns = []
            for idx in nearby_indices:
                if idx < 1 or idx >= len(coords) - 1:
                    continue
                ta = turn_angle(
                    coords[idx-1][0], coords[idx-1][1],
                    coords[idx][0], coords[idx][1],
                    coords[idx+1][0], coords[idx+1][1],
                )
                if ta > 60:  # > 60 degree turn
                    sharp_turns.append((idx, ta, coords[idx]))
            
            if sharp_turns:
                print(f"  ⚠️  {len(sharp_turns)} SHARP TURNS (>60°) in area:")
                for idx, angle, (lat, lon) in sharp_turns[:10]:
                    print(f"    idx={idx}: {angle:.1f}° turn at ({lat:.6f}, {lon:.6f})")
                if len(sharp_turns) > 10:
                    print(f"    ... and {len(sharp_turns)-10} more")
            
            # Check for near-reversals (>150°)
            reversals = [(i, a, c) for i, a, c in sharp_turns if a > 150]
            if reversals:
                print(f"  🔴 {len(reversals)} REVERSALS (>150°!) — these create spikes:")
                for idx, angle, (lat, lon) in reversals:
                    # Show context
                    context_start = max(0, idx - 2)
                    context_end = min(len(coords), idx + 3)
                    for ci in range(context_start, context_end):
                        marker = " >>>" if ci == idx else "    "
                        print(f"  {marker} [{ci}] ({coords[ci][0]:.6f}, {coords[ci][1]:.6f})")

            # Check point density (are there too many clustered points?)
            nearby_coords = [coords[i] for i in nearby_indices]
            if len(nearby_coords) >= 2:
                dists = []
                for j in range(len(nearby_coords) - 1):
                    dx = nearby_coords[j+1][1] - nearby_coords[j][1]
                    dy = nearby_coords[j+1][0] - nearby_coords[j][0]
                    dists.append(math.sqrt(dx*dx + dy*dy))
                avg_spacing = sum(dists) / len(dists)
                min_spacing = min(dists)
                max_spacing = max(dists)
                print(f"  Point spacing in area: avg={avg_spacing*111000:.1f}m, "
                      f"min={min_spacing*111000:.1f}m, max={max_spacing*111000:.1f}m")

    print("\n── PER-ROUTE POLYLINES ──")
    for line in data["lines"]:
        rid = line["route_id"]
        for pi, poly_enc in enumerate(line["polylines"]):
            coords = decode_polyline(poly_enc)
            nearby = [
                (lat, lon) for lat, lon in coords
                if lat_min <= lat <= lat_max and lon_min <= lon <= lon_max
            ]
            if nearby:
                print(f"  Route {rid} poly[{pi}]: {len(coords)} pts total, {len(nearby)} near Atlantic")


if __name__ == "__main__":
    main()
