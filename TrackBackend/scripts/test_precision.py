"""Test float32 precision loss in the polyline pipeline."""

from __future__ import annotations

import math
import struct
import sys

sys.path.insert(0, "/Users/jeffreyfernandez/code/Track/TrackBackend")

from app.utils.polyline_utils import decode_polyline, encode_polyline

test_coords = [
    (40.758896, -73.985130),  # Times Square
    (40.748817, -73.985428),  # Empire State
    (40.706086, -73.996864),  # Brooklyn Bridge
    (40.680920, -73.974370),  # Prospect Park
]


def calc_error(lat_orig, lon_orig, lat_final, lon_final):
    lat_err_m = abs(lat_orig - lat_final) * 111320
    lon_err_m = abs(lon_orig - lon_final) * 111320 * math.cos(math.radians(lat_orig))
    return math.sqrt(lat_err_m**2 + lon_err_m**2)


print("=== float32 Precision Loss ===")
for lat, lon in test_coords:
    buf = struct.pack("<2f", lat, lon)
    lat32, lon32 = struct.unpack("<2f", buf)
    err = calc_error(lat, lon, lat32, lon32)
    print(f"  ({lat:.6f}, {lon:.6f}) -> ({lat32:.6f}, {lon32:.6f})  err={err:.2f} m")

print("\n=== Double Quantization (float32 -> encode_polyline) ===")
for lat, lon in test_coords:
    buf = struct.pack("<2f", lat, lon)
    lat32, lon32 = struct.unpack("<2f", buf)
    encoded = encode_polyline([(lat32, lon32)])
    decoded = decode_polyline(encoded)
    lat_final, lon_final = decoded[0]
    err = calc_error(lat, lon, lat_final, lon_final)
    print(
        f"  ({lat:.6f}, {lon:.6f}) -> ({lat_final:.6f}, {lon_final:.6f})  err={err:.2f} m"
    )

print("\n=== Direct float64 -> encode_polyline (NO float32) ===")
for lat, lon in test_coords:
    encoded = encode_polyline([(lat, lon)])
    decoded = decode_polyline(encoded)
    lat_final, lon_final = decoded[0]
    err = calc_error(lat, lon, lat_final, lon_final)
    print(
        f"  ({lat:.6f}, {lon:.6f}) -> ({lat_final:.6f}, {lon_final:.6f})  err={err:.2f} m"
    )

# Test with a real GTFS shape to see cumulative effect
print("\n=== Real GTFS Shape Test (A train) ===")
from app.services.mapping.shape_utils import unpack_coords  # noqa: E402
from app.services.mapping.subway_shapes import _load_shapes  # noqa: E402

shapes = _load_shapes()
# Find any shape
for shape_id, buf in shapes.items():
    coords = unpack_coords(buf)
    if len(coords) >= 50:
        # Compare first 10 points float32 vs encoding
        encoded = encode_polyline(coords[:50])
        decoded = decode_polyline(encoded)
        errors = []
        for (lat32, lon32), (lat_dec, lon_dec) in zip(
            coords[:50], decoded, strict=False
        ):
            errors.append(calc_error(lat32, lon32, lat_dec, lon_dec))
        print(f"  Shape {shape_id}: {len(coords)} pts")
        print(
            f"  float32->encode->decode max error: {max(errors):.2f} m, avg: {sum(errors)/len(errors):.2f} m"
        )

        # But what was the float32 error FROM the original GTFS?
        # We can't know since original was already packed. The float32 error
        # is baked into the stored data.
        print("  (Note: float32 error from original GTFS is already baked in)")
        break
