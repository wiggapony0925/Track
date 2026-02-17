#
# geo_utils.py
# TrackBackend
#
# Shared geographic utilities. Eliminates duplication of haversine
# between station_lookup.py and bus_client.py.
#

from __future__ import annotations

import math

# NYC-specific constants
METERS_PER_DEG_LAT = 111_000.0
METERS_PER_DEG_LON_NYC = 85_000.0  # at ~40.7°N


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Haversine distance in meters between two lat/lon points.

    Time complexity: O(1).
    """
    R = 6_371_000
    rlat1, rlat2 = math.radians(lat1), math.radians(lat2)
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (
        math.sin(dlat / 2) ** 2
        + math.cos(rlat1) * math.cos(rlat2) * math.sin(dlon / 2) ** 2
    )
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def bounding_box_degrees(radius_m: float) -> tuple[float, float]:
    """Return (lat_delta, lon_delta) in degrees for a bounding box around NYC.

    Used as a fast O(1) pre-filter before expensive haversine calculations.
    """
    lat_delta = radius_m / METERS_PER_DEG_LAT
    lon_delta = radius_m / METERS_PER_DEG_LON_NYC
    return lat_delta, lon_delta
