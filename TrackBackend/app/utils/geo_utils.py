#
# geo_utils.py
# TrackBackend
#
# Shared geographic and time utilities.
# Deduplicates haversine (bus_client + station_lookup) and
# minutes_until (data_cleaner + rail_client).
#

from __future__ import annotations

import math
import time as _time

METERS_PER_DEG_LAT = 111_000.0


def meters_per_deg_lon(lat: float) -> float:
    """Metres per degree of longitude at the given *lat*.

    Works for any latitude — not tied to a specific region.
    """
    return 111_320.0 * math.cos(math.radians(lat))


# Backward-compatible alias (NYC ~40.76°N).  New code should call
# ``meters_per_deg_lon(lat)`` or use the provider's ``meters_per_deg_lon``.
METERS_PER_DEG_LON_NYC = meters_per_deg_lon(40.758)  # ≈ 84_370


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


def bounding_box_degrees(
    radius_m: float, center_lat: float = 40.758
) -> tuple[float, float]:
    """Return (lat_delta, lon_delta) in degrees for a bounding box.

    *center_lat* determines the longitude scaling.  Defaults to NYC
    for backward compatibility — new callers should pass an explicit
    latitude (or use ``provider.region_center_lat``).
    """
    lat_delta = radius_m / METERS_PER_DEG_LAT
    lon_delta = radius_m / meters_per_deg_lon(center_lat)
    return lat_delta, lon_delta


def minutes_until(epoch_s: int) -> int:
    """Return whole minutes from now until *epoch_s* (clamped to 0)."""
    diff = epoch_s - int(_time.time())
    return max(0, diff // 60)
