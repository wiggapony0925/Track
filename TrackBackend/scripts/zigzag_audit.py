"""Audit server trunk polylines for zigzag artifacts in Manhattan."""

import math
import sys

sys.path.insert(0, ".")

import polyline as pl
from app.routers.subway import _build_shapes_all_sync

resp = _build_shapes_all_sync()
print(f"trunk_polylines: {len(resp.trunk_polylines)}")

zigzag_count = 0
for i, trunk in enumerate(resp.trunk_polylines):
    for j, encoded_poly in enumerate(trunk.polylines):
        coords = pl.decode(encoded_poly, 5)
        for k in range(1, len(coords) - 1):
            lat0, lon0 = coords[k - 1]
            lat1, lon1 = coords[k]
            lat2, lon2 = coords[k + 1]
            ax, ay = lat1 - lat0, lon1 - lon0
            bx, by = lat2 - lat1, lon2 - lon1
            dot = ax * bx + ay * by
            mag_a = (ax**2 + ay**2) ** 0.5
            mag_b = (bx**2 + by**2) ** 0.5
            if mag_a < 1e-9 or mag_b < 1e-9:
                continue
            cos_angle = max(-1, min(1, dot / (mag_a * mag_b)))
            angle = math.degrees(math.acos(cos_angle))
            if angle > 150:
                if 40.72 < lat1 < 40.82 and -74.01 < lon1 < -73.93:
                    print(
                        f"  trunk[{i}] routes={trunk.route_ids} "
                        f"poly[{j}] vtx {k}/{len(coords)}: "
                        f"angle={angle:.1f} at ({lat1:.5f},{lon1:.5f})"
                    )
                    zigzag_count += 1
        if zigzag_count > 30:
            break
    if zigzag_count > 30:
        break

if zigzag_count == 0:
    print("No sharp reversals (>150) found in Manhattan area")
else:
    print(f"\nTotal sharp reversals found: {zigzag_count}")

# Also check for large geographic jumps (>500m between consecutive vertices)
print("\n--- Large jumps (>300m) in Manhattan ---")
jump_count = 0
for i, trunk in enumerate(resp.trunk_polylines):
    for j, encoded_poly in enumerate(trunk.polylines):
        coords = pl.decode(encoded_poly, 5)
        for k in range(1, len(coords)):
            lat0, lon0 = coords[k - 1]
            lat1, lon1 = coords[k]
            if not (40.72 < lat1 < 40.82 and -74.01 < lon1 < -73.93):
                continue
            dlat = (lat1 - lat0) * 111_000
            dlon = (lon1 - lon0) * 111_000 * math.cos(
                math.radians(lat1)
            )
            dist = (dlat**2 + dlon**2) ** 0.5
            if dist > 300:
                print(
                    f"  trunk[{i}] routes={trunk.route_ids} "
                    f"poly[{j}] vtx {k}: jump={dist:.0f}m "
                    f"from ({lat0:.5f},{lon0:.5f}) "
                    f"to ({lat1:.5f},{lon1:.5f})"
                )
                jump_count += 1
        if jump_count > 20:
            break
    if jump_count > 20:
        break

if jump_count == 0:
    print("No large jumps found in Manhattan area")
else:
    print(f"Total large jumps: {jump_count}")
