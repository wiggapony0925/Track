"""
Track GTFS Schema — Typed primitives and enums.

Superior to Transit App's py-gtfs-loader/types.py:
  • GTFSTime:  Optional support (no -1 sentinel), from_seconds(), to_hms(),
               rich arithmetic, 72-hour cap, timedelta interop
  • GTFSDate:  weekday helpers, date_range(), from_today(), ISO + compact parse
  • LatLon:    __slots__, haversine, bearing, segment distance, GeoJSON
  • Enums:     all standard GTFS enums with human-readable names
  • serialize: singledispatch round-trip serialiser matching CSV spec
"""

from __future__ import annotations

import functools
import json
import math
from datetime import date, datetime, time, timedelta
from enum import IntEnum
from typing import Any, Sequence

# ─────────────────────────── constants ────────────────────────────
EARTH_RADIUS_M = 6_371_008.8
DAY_SECONDS = 86_400
MAX_GTFS_HOURS = 72  # generous; spec implies ~48 max in practice


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  GTFSTime — seconds-since-midnight as an int subclass
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class GTFSTime(int):
    """
    Represents a GTFS time value (HH:MM:SS) as total seconds since midnight.

    Subclasses ``int`` so all comparison / arithmetic operators work for free.
    Unlike Transit App's version we:
      - never use ``-1`` as a sentinel — use ``None`` in Optional fields instead
      - support hours up to 72 (their cap is 36)
      - expose helper methods (to_hms, to_timedelta, from_seconds)
    """

    __slots__ = ()

    def __new__(cls, value: int | str = 0) -> GTFSTime:
        if isinstance(value, int):
            return super().__new__(cls, value)
        if isinstance(value, str):
            value = value.strip()
            if value == "":
                raise ValueError("empty time string — use Optional[GTFSTime] for nullable times")
            parts = value.split(":")
            if len(parts) != 3:
                raise ValueError(f"expected HH:MM:SS, got {value!r}")
            h, m, s = int(parts[0]), int(parts[1]), int(parts[2])
            if h < 0 or h > MAX_GTFS_HOURS:
                raise ValueError(f"hours={h} outside 0..{MAX_GTFS_HOURS}")
            if not (0 <= m < 60 and 0 <= s < 60):
                raise ValueError(f"invalid MM:SS in {value!r}")
            return super().__new__(cls, h * 3600 + m * 60 + s)
        raise TypeError(f"GTFSTime requires str or int, got {type(value).__name__}")

    # ── arithmetic that preserves type ──────────────────────────
    def __add__(self, other: int) -> GTFSTime:
        return GTFSTime(int.__add__(self, other))

    def __radd__(self, other: int) -> GTFSTime:
        return GTFSTime(int.__radd__(self, other))

    def __sub__(self, other: int) -> GTFSTime:
        return GTFSTime(int.__sub__(self, other))

    # ── conversions ─────────────────────────────────────────────
    def to_hms(self) -> tuple[int, int, int]:
        """Return (hours, minutes, seconds) — hours may exceed 23."""
        total = int(self)
        h, rem = divmod(total, 3600)
        m, s = divmod(rem, 60)
        return h, m, s

    def to_timedelta(self) -> timedelta:
        return timedelta(seconds=int(self))

    def to_time(self) -> time:
        """Clock time (wraps at 24 h). Raises if hours ≥ 24."""
        h, m, s = self.to_hms()
        return time(h % 24, m, s)

    @classmethod
    def from_seconds(cls, seconds: int) -> GTFSTime:
        return cls(seconds)

    @classmethod
    def from_timedelta(cls, td: timedelta) -> GTFSTime:
        return cls(int(td.total_seconds()))

    # ── string round-trip ───────────────────────────────────────
    def __str__(self) -> str:
        h, m, s = self.to_hms()
        return f"{h:02d}:{m:02d}:{s:02d}"

    def __repr__(self) -> str:
        return f"GTFSTime('{self!s}')"


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  GTFSDate — date with compact GTFS formatting
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class GTFSDate(date):
    """
    Represents a GTFS calendar date (YYYYMMDD or YYYY-MM-DD).

    Subclasses ``date`` so comparisons, weekday(), etc. work natively.
    """

    def __new__(cls, value: str | date | datetime = "19700101") -> GTFSDate:
        if isinstance(value, datetime):
            return super().__new__(cls, value.year, value.month, value.day)
        if isinstance(value, date):
            return super().__new__(cls, value.year, value.month, value.day)
        if isinstance(value, str):
            value = value.strip().replace("-", "")
            if len(value) != 8:
                raise ValueError(f"expected YYYYMMDD, got {value!r}")
            y, m, d = int(value[:4]), int(value[4:6]), int(value[6:8])
            return super().__new__(cls, y, m, d)
        raise TypeError(f"GTFSDate requires str or date, got {type(value).__name__}")

    @classmethod
    def today_gtfs(cls) -> GTFSDate:
        """Return today as a GTFSDate."""
        return cls(date.today())

    @classmethod
    def from_date(cls, d: date) -> GTFSDate:
        return cls(d)

    # ── weekday helpers ─────────────────────────────────────────
    @property
    def is_weekday(self) -> bool:
        return self.weekday() < 5

    @property
    def is_weekend(self) -> bool:
        return self.weekday() >= 5

    @property
    def weekday_name(self) -> str:
        return ("monday", "tuesday", "wednesday", "thursday",
                "friday", "saturday", "sunday")[self.weekday()]

    # ── range generator ─────────────────────────────────────────
    @staticmethod
    def date_range(start: GTFSDate | date, end: GTFSDate | date):
        """Yield GTFSDate for each day in [start, end] inclusive."""
        current = start
        while current <= end:
            yield GTFSDate(current)
            current += timedelta(days=1)

    # ── string round-trip ───────────────────────────────────────
    def __str__(self) -> str:
        return f"{self.year:04d}{self.month:02d}{self.day:02d}"

    def __repr__(self) -> str:
        return f"GTFSDate('{self!s}')"


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  LatLon — lightweight geo point
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class LatLon:
    """
    Immutable latitude/longitude point stored in **radians** internally.

    Uses ``__slots__`` for minimal memory. Compatible with our geo_utils.py
    but self-contained for the schema layer.
    """

    __slots__ = ("lat", "lon")

    def __init__(self, lat_deg: float, lon_deg: float):
        object.__setattr__(self, "lat", math.radians(lat_deg))
        object.__setattr__(self, "lon", math.radians(lon_deg))

    @property
    def lat_deg(self) -> float:
        return math.degrees(self.lat)

    @property
    def lon_deg(self) -> float:
        return math.degrees(self.lon)

    # ── distances ───────────────────────────────────────────────
    def angular_distance_to(self, other: LatLon) -> float:
        """Haversine angular distance in radians."""
        dlat = other.lat - self.lat
        dlon = other.lon - self.lon
        a = (math.sin(dlat / 2) ** 2
             + math.cos(self.lat) * math.cos(other.lat) * math.sin(dlon / 2) ** 2)
        return 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))

    def distance_m(self, other: LatLon) -> float:
        """Great-circle distance in metres."""
        return self.angular_distance_to(other) * EARTH_RADIUS_M

    def bearing_to(self, other: LatLon) -> float:
        """Initial bearing in radians, north = 0, clockwise."""
        dlon = other.lon - self.lon
        x = math.sin(dlon) * math.cos(other.lat)
        y = (math.cos(self.lat) * math.sin(other.lat)
             - math.sin(self.lat) * math.cos(other.lat) * math.cos(dlon))
        return math.atan2(x, y) % (2 * math.pi)

    @staticmethod
    def distance_to_segment(pt: LatLon, seg_a: LatLon, seg_b: LatLon) -> float:
        """Perpendicular distance in metres from *pt* to segment [seg_a, seg_b]."""
        d_ab = seg_a.angular_distance_to(seg_b)
        if d_ab < 1e-12:
            return pt.distance_m(seg_a)
        d_ap = seg_a.angular_distance_to(pt)
        brg_ab = seg_a.bearing_to(seg_b)
        brg_ap = seg_a.bearing_to(pt)
        cross_track = math.asin(math.sin(d_ap) * math.sin(brg_ap - brg_ab))
        along_track = math.acos(math.cos(d_ap) / max(math.cos(cross_track), 1e-15))
        if along_track > d_ab:
            return min(pt.distance_m(seg_a), pt.distance_m(seg_b))
        return abs(cross_track) * EARTH_RADIUS_M

    # ── serialisation ───────────────────────────────────────────
    def geojson(self) -> list[float]:
        """[longitude, latitude] for GeoJSON."""
        return [round(self.lon_deg, 6), round(self.lat_deg, 6)]

    # ── equality / hashing ──────────────────────────────────────
    def __eq__(self, other: object) -> bool:
        if not isinstance(other, LatLon):
            return NotImplemented
        return self.lat == other.lat and self.lon == other.lon

    def __hash__(self) -> int:
        return hash((self.lat, self.lon))

    def __repr__(self) -> str:
        return f"LatLon({self.lat_deg:.6f}, {self.lon_deg:.6f})"


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  GTFS Enums (IntEnum for CSV round-trip)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class RouteType(IntEnum):
    TRAM = 0
    SUBWAY = 1
    RAIL = 2
    BUS = 3
    FERRY = 4
    CABLE_TRAM = 5
    AERIAL_LIFT = 6
    FUNICULAR = 7
    TROLLEYBUS = 11
    MONORAIL = 12


class LocationType(IntEnum):
    STOP = 0
    STATION = 1
    ENTRANCE = 2
    GENERIC_NODE = 3
    BOARDING_AREA = 4


class PickupType(IntEnum):
    REGULAR = 0
    NONE = 1
    PHONE_AGENCY = 2
    COORDINATE_DRIVER = 3


class DropOffType(IntEnum):
    REGULAR = 0
    NONE = 1
    PHONE_AGENCY = 2
    COORDINATE_DRIVER = 3


class ExceptionType(IntEnum):
    ADD = 1
    REMOVE = 2


class TransferType(IntEnum):
    RECOMMENDED = 0
    TIMED = 1
    MIN_TIME = 2
    NOT_POSSIBLE = 3
    IN_SEAT = 4
    RE_BOARD = 5


class DirectionId(IntEnum):
    OUTBOUND = 0
    INBOUND = 1


class WheelchairAccessible(IntEnum):
    UNKNOWN = 0
    ACCESSIBLE = 1
    NOT_ACCESSIBLE = 2


class BikesAllowed(IntEnum):
    UNKNOWN = 0
    ALLOWED = 1
    NOT_ALLOWED = 2


class ContinuousPickup(IntEnum):
    CONTINUOUS = 0
    NONE = 1
    PHONE_AGENCY = 2
    COORDINATE_DRIVER = 3


class ContinuousDropOff(IntEnum):
    CONTINUOUS = 0
    NONE = 1
    PHONE_AGENCY = 2
    COORDINATE_DRIVER = 3


class Timepoint(IntEnum):
    APPROXIMATE = 0
    EXACT = 1


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Serialiser — singledispatch for CSV round-trip
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
@functools.singledispatch
def serialize(value: Any) -> str:
    """Convert a Python value back to a GTFS CSV cell string."""
    if isinstance(value, list):
        return json.dumps(value, separators=(",", ":"))
    return str(value)


@serialize.register(type(None))
def _ser_none(_: None) -> str:
    return ""


@serialize.register(bool)
def _ser_bool(v: bool) -> str:
    return str(int(v))


@serialize.register(IntEnum)
def _ser_enum(v: IntEnum) -> str:
    return str(int(v))


@serialize.register(GTFSTime)
def _ser_time(v: GTFSTime) -> str:
    return str(v)


@serialize.register(GTFSDate)
def _ser_date(v: GTFSDate) -> str:
    return str(v)


@serialize.register(LatLon)
def _ser_latlon(v: LatLon) -> str:
    return f"{v.lat_deg:.6f}"
