#
# polyline_utils.py
# TrackBackend
#
# Shared Google-encoded polyline encode/decode utilities.
# Eliminates duplication across subway.py, lirr.py, mnr.py, bus_client.py.
#

from __future__ import annotations


def decode_polyline(encoded: str) -> list[tuple[float, float]]:
    """Decode a Google-encoded polyline into [(lat, lon), ...].

    Time complexity: O(n) where n is the length of the encoded string.
    """
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
        coords.append((lat / 1e5, lng / 1e5))
    return coords


def encode_polyline(coords: list[tuple[float, float]]) -> str:
    """Encode [(lat, lon), ...] into a Google-encoded polyline string.

    Time complexity: O(n) where n is the number of coordinate pairs.
    """
    result: list[str] = []
    prev_lat, prev_lng = 0, 0
    for lat, lng in coords:
        lat_e5 = round(lat * 1e5)
        lng_e5 = round(lng * 1e5)
        _encode_value(lat_e5 - prev_lat, result)
        _encode_value(lng_e5 - prev_lng, result)
        prev_lat, prev_lng = lat_e5, lng_e5
    return "".join(result)


def _encode_value(value: int, result: list[str]) -> None:
    """Encode a single signed value into Google polyline encoding."""
    v = ~(value << 1) if value < 0 else (value << 1)
    while v >= 0x20:
        result.append(chr(((v & 0x1F) | 0x20) + 63))
        v >>= 5
    result.append(chr(v + 63))
