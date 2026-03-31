"""
Track GTFS Schema — Entity definitions with declarative field specs.

Superior to Transit App's py-gtfs-loader/schema.py + schema_classes.py:
  • FieldSpec descriptors with min/max, regex, foreign_key declarations
  • Entity base with __slots__-compatible storage, dict protocol, clone()
  • Automatic schema registry via __init_subclass__ (no manual FileCollection)
  • EntityTable / GroupedTable containers with full dict protocol
  • Cross-entity navigation @cached_property with feed back-ref
  • Explicit primary_key / group_by on class — not hidden in a File() call
  • Every entity carries its GTFS filename, required flag, and field metadata
  • Foreign-key declarations for post-load referential integrity checks
"""

from __future__ import annotations

import copy
from functools import cached_property
from typing import (
    Any,
    ClassVar,
    Dict,
    Iterator,
    List,
    Optional,
    Sequence,
    Type,
    get_type_hints,
)

from app.services.gtfs.gtfs_types import (
    ContinuousDropOff,
    ContinuousPickup,
    DirectionId,
    DropOffType,
    ExceptionType,
    GTFSDate,
    GTFSTime,
    LatLon,
    LocationType,
    PickupType,
    RouteType,
    Timepoint,
    TransferType,
    WheelchairAccessible,
    BikesAllowed,
)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  FieldSpec — descriptor carrying validation metadata
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class FieldSpec:
    """
    Declarative field descriptor for GTFS entity classes.

    Carries type, default, constraints, and an optional foreign_key reference
    that the loader uses for post-load referential integrity checks.

    Usage on an Entity subclass::

        class Stop(Entity):
            stop_id: str = FieldSpec(required=True)
            stop_lat: float = FieldSpec(required=True, min_val=-90, max_val=90)
            parent_station: str = FieldSpec(default="", foreign_key="stops.stop_id")
    """

    __slots__ = (
        "required", "default", "min_val", "max_val",
        "foreign_key", "description",
    )

    def __init__(
        self,
        required: bool = False,
        default: Any = "",
        min_val: float | None = None,
        max_val: float | None = None,
        foreign_key: str | None = None,
        description: str = "",
    ):
        self.required = required
        self.default = default
        self.min_val = min_val
        self.max_val = max_val
        self.foreign_key = foreign_key  # "table.column"
        self.description = description


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Schema registry — populated automatically via __init_subclass__
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
_ENTITY_REGISTRY: Dict[str, Type[Entity]] = {}  # filename → class


def get_entity_registry() -> Dict[str, Type[Entity]]:
    """Return a copy of the {gtfs_filename: EntityClass} registry."""
    return dict(_ENTITY_REGISTRY)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  EntityTable / GroupedTable — dict wrappers for loaded data
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class EntityTable(dict):
    """
    ``{primary_key: Entity}`` dict for non-grouped GTFS files.

    Preserves ``_resolved_fields`` so the writer knows the original header.
    """

    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        self._resolved_fields: Dict[str, _ResolvedField] = {}


class GroupedTable(dict):
    """
    ``{primary_key: list[Entity]}`` dict for grouped GTFS files
    (stop_times, shapes, calendar_dates, transfers).
    """

    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        self._resolved_fields: Dict[str, _ResolvedField] = {}


class _ResolvedField:
    """Merged header+schema field info carried through load → save."""
    __slots__ = ("type_", "required", "default", "from_schema")

    def __init__(self, type_: type, required: bool, default: Any, from_schema: bool):
        self.type_ = type_
        self.required = required
        self.default = default
        self.from_schema = from_schema  # True if declared in Entity, False if extra CSV column


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Entity — base class for all GTFS row objects
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
class Entity:
    """
    Base class for every GTFS entity (row in a file).

    Like Transit App's Entity, it supports both attribute access
    (``entity.stop_id``) and dict-style access (``entity["stop_id"]``)
    so that generic loader code and specific business logic can coexist.

    Subclass configuration (class variables):
        __gtfs_filename__   "stops.txt"
        __primary_key__     "stop_id"
        __group_by__        None or "stop_sequence" (makes the table grouped)
        __required_file__   True/False — fail if file is missing from feed
    """

    # ── subclass configuration (overridden by concrete entities) ─
    __gtfs_filename__: ClassVar[str] = ""
    __primary_key__: ClassVar[str] = ""
    __group_by__: ClassVar[Optional[str]] = None
    __required_file__: ClassVar[bool] = False

    # ── back-reference to the feed (set during load) ────────────
    _feed: Any = None  # type: GTFSFeed — avoids circular import

    def __init__(self, **kwargs: Any):
        # Apply class-level FieldSpec defaults, then override with kwargs
        for name in self._field_names():
            val = getattr(self.__class__, name, None)
            if isinstance(val, FieldSpec):
                setattr(self, name, copy.copy(val.default))
        for k, v in kwargs.items():
            setattr(self, k, v)

    # ── schema introspection ────────────────────────────────────
    @classmethod
    def _field_names(cls) -> list[str]:
        """Return ordered list of declared field names (from annotations)."""
        names: list[str] = []
        for klass in reversed(cls.__mro__):
            for name in getattr(klass, "__annotations__", {}):
                if name.startswith("_") or name in names:
                    continue
                names.append(name)
        return names

    @classmethod
    def _field_specs(cls) -> Dict[str, FieldSpec]:
        """Return {name: FieldSpec} for all declared fields."""
        specs: Dict[str, FieldSpec] = {}
        for name in cls._field_names():
            val = getattr(cls, name, None)
            if isinstance(val, FieldSpec):
                specs[name] = val
            else:
                # Annotation-only field with no FieldSpec → infer
                specs[name] = FieldSpec(required=True)
        return specs

    @classmethod
    def _field_types(cls) -> Dict[str, type]:
        """Return {name: python_type} from annotations, resolving Optional.

        Uses ``get_type_hints()`` to resolve **PEP 563** stringified annotations
        (caused by ``from __future__ import annotations``) back to real types.
        """
        import typing

        # get_type_hints resolves string annotations to actual types
        try:
            hints = get_type_hints(cls)
        except Exception:
            # Fallback: manual resolution from raw __annotations__
            hints = {}
            for klass in reversed(cls.__mro__):
                hints.update(getattr(klass, "__annotations__", {}))

        result: Dict[str, type] = {}
        for name, hint in hints.items():
            if name.startswith("_"):
                continue
            origin = getattr(hint, "__origin__", None)
            # unwrap Optional[X] → X  (Union[X, None])
            if origin is typing.Union:
                args = [a for a in hint.__args__ if a is not type(None)]
                result[name] = args[0] if args else str
            else:
                result[name] = hint if isinstance(hint, type) else str
        return result

    @classmethod
    def _foreign_keys(cls) -> Dict[str, str]:
        """Return {field_name: 'table.column'} for FK-declared fields."""
        fks: Dict[str, str] = {}
        for name, spec in cls._field_specs().items():
            if spec.foreign_key:
                fks[name] = spec.foreign_key
        return fks

    # ── dict protocol ───────────────────────────────────────────
    def __getitem__(self, key: str) -> Any:
        try:
            return getattr(self, key)
        except AttributeError:
            raise KeyError(key)

    def __setitem__(self, key: str, value: Any) -> None:
        setattr(self, key, value)

    def __delitem__(self, key: str) -> None:
        try:
            delattr(self, key)
        except AttributeError:
            raise KeyError(key)

    def __contains__(self, key: object) -> bool:
        return hasattr(self, str(key))

    def keys(self) -> list[str]:
        return [k for k in self.__dict__ if not k.startswith("_")]

    def values(self) -> list[Any]:
        return [v for k, v in self.__dict__.items() if not k.startswith("_")]

    def items(self) -> list[tuple[str, Any]]:
        return [(k, v) for k, v in self.__dict__.items() if not k.startswith("_")]

    def get(self, key: str, default: Any = None) -> Any:
        return getattr(self, key, default)

    def to_dict(self) -> dict[str, Any]:
        """Public fields as a plain dict (excludes _feed and other internals)."""
        return {k: v for k, v in self.__dict__.items() if not k.startswith("_")}

    # ── clone ───────────────────────────────────────────────────
    def clone(self, **overrides: Any) -> Entity:
        """Deep-copy this entity, optionally overriding fields."""
        new = self.__class__.__new__(self.__class__)
        new.__dict__.update(copy.deepcopy(
            {k: v for k, v in self.__dict__.items() if k != "_feed"}
        ))
        new._feed = self._feed
        for k, v in overrides.items():
            setattr(new, k, v)
        return new

    # ── display ─────────────────────────────────────────────────
    def __repr__(self) -> str:
        pk = self.__class__.__primary_key__
        pk_val = getattr(self, pk, "?")
        cls_name = self.__class__.__name__
        return f"<{cls_name} {pk}={pk_val!r}>"

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Entity):
            return NotImplemented
        pk = self.__class__.__primary_key__
        return (type(self) is type(other)
                and getattr(self, pk, None) == getattr(other, pk, None))

    def __hash__(self) -> int:
        pk = self.__class__.__primary_key__
        return hash((type(self), getattr(self, pk, None)))

    # ── auto-register into _ENTITY_REGISTRY ─────────────────────
    def __init_subclass__(cls, **kwargs: Any):
        super().__init_subclass__(**kwargs)
        fn = cls.__gtfs_filename__
        if fn:
            _ENTITY_REGISTRY[fn] = cls


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Concrete GTFS Entities
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ────────────────────── agency.txt ──────────────────────────────
class Agency(Entity):
    __gtfs_filename__ = "agency.txt"
    __primary_key__ = "agency_id"
    __required_file__ = True

    agency_id: str = FieldSpec(required=True)
    agency_name: str = FieldSpec(required=True)
    agency_url: str = FieldSpec(required=True)
    agency_timezone: str = FieldSpec(required=True)
    agency_lang: str = FieldSpec(default="")
    agency_phone: str = FieldSpec(default="")
    agency_fare_url: str = FieldSpec(default="")
    agency_email: str = FieldSpec(default="")


# ────────────────────── calendar.txt ───────────────────────────
class Calendar(Entity):
    __gtfs_filename__ = "calendar.txt"
    __primary_key__ = "service_id"

    service_id: str = FieldSpec(required=True)
    monday: bool = FieldSpec(required=True)
    tuesday: bool = FieldSpec(required=True)
    wednesday: bool = FieldSpec(required=True)
    thursday: bool = FieldSpec(required=True)
    friday: bool = FieldSpec(required=True)
    saturday: bool = FieldSpec(required=True)
    sunday: bool = FieldSpec(required=True)
    start_date: GTFSDate = FieldSpec(required=True)
    end_date: GTFSDate = FieldSpec(required=True)

    _WEEKDAY_ATTRS = ("monday", "tuesday", "wednesday",
                      "thursday", "friday", "saturday", "sunday")

    def is_active_on(self, d: GTFSDate) -> bool:
        """Check if this service pattern is active on a given date."""
        if not (self.start_date <= d <= self.end_date):
            return False
        return bool(getattr(self, self._WEEKDAY_ATTRS[d.weekday()]))


# ────────────────────── calendar_dates.txt ─────────────────────
class CalendarDate(Entity):
    __gtfs_filename__ = "calendar_dates.txt"
    __primary_key__ = "service_id"
    __group_by__ = "date"

    service_id: str = FieldSpec(required=True)
    date: GTFSDate = FieldSpec(required=True)
    exception_type: ExceptionType = FieldSpec(required=True)


# ────────────────────── routes.txt ─────────────────────────────
class Route(Entity):
    __gtfs_filename__ = "routes.txt"
    __primary_key__ = "route_id"
    __required_file__ = True

    route_id: str = FieldSpec(required=True)
    agency_id: str = FieldSpec(default="", foreign_key="agency.agency_id")
    route_short_name: str = FieldSpec(default="")
    route_long_name: str = FieldSpec(default="")
    route_desc: str = FieldSpec(default="")
    route_type: RouteType = FieldSpec(required=True)
    route_url: str = FieldSpec(default="")
    route_color: str = FieldSpec(default="FFFFFF")
    route_text_color: str = FieldSpec(default="000000")
    route_sort_order: int = FieldSpec(default=0)
    continuous_pickup: ContinuousPickup = FieldSpec(default=ContinuousPickup.NONE)
    continuous_drop_off: ContinuousDropOff = FieldSpec(default=ContinuousDropOff.NONE)

    @property
    def display_name(self) -> str:
        return self.route_short_name or self.route_long_name or self.route_id


# ────────────────────── trips.txt ──────────────────────────────
class Trip(Entity):
    __gtfs_filename__ = "trips.txt"
    __primary_key__ = "trip_id"
    __required_file__ = True

    trip_id: str = FieldSpec(required=True)
    route_id: str = FieldSpec(required=True, foreign_key="routes.route_id")
    service_id: str = FieldSpec(required=True, foreign_key="calendar.service_id")
    trip_headsign: str = FieldSpec(default="")
    trip_short_name: str = FieldSpec(default="")
    direction_id: Optional[DirectionId] = FieldSpec(default=None)
    block_id: str = FieldSpec(default="")
    shape_id: str = FieldSpec(default="", foreign_key="shapes.shape_id")
    wheelchair_accessible: WheelchairAccessible = FieldSpec(
        default=WheelchairAccessible.UNKNOWN)
    bikes_allowed: BikesAllowed = FieldSpec(default=BikesAllowed.UNKNOWN)

    # ── cross-entity navigation ─────────────────────────────────
    @cached_property
    def route(self) -> Route:
        return self._feed.routes[self.route_id]

    @cached_property
    def stop_times_list(self) -> list[StopTime]:
        return self._feed.stop_times.get(self.trip_id, [])

    @cached_property
    def first_departure(self) -> Optional[GTFSTime]:
        sts = self.stop_times_list
        if not sts:
            return None
        return sts[0].departure_time

    @cached_property
    def last_arrival(self) -> Optional[GTFSTime]:
        sts = self.stop_times_list
        if not sts:
            return None
        return sts[-1].arrival_time

    @cached_property
    def first_stop(self) -> Optional[Stop]:
        sts = self.stop_times_list
        return sts[0].stop if sts else None

    @cached_property
    def last_stop(self) -> Optional[Stop]:
        sts = self.stop_times_list
        return sts[-1].stop if sts else None


# ────────────────────── stops.txt ──────────────────────────────
class Stop(Entity):
    __gtfs_filename__ = "stops.txt"
    __primary_key__ = "stop_id"
    __required_file__ = True

    stop_id: str = FieldSpec(required=True)
    stop_code: str = FieldSpec(default="")
    stop_name: str = FieldSpec(default="")
    stop_desc: str = FieldSpec(default="")
    stop_lat: float = FieldSpec(required=True, min_val=-90.0, max_val=90.0)
    stop_lon: float = FieldSpec(required=True, min_val=-180.0, max_val=180.0)
    zone_id: str = FieldSpec(default="")
    stop_url: str = FieldSpec(default="")
    location_type: LocationType = FieldSpec(default=LocationType.STOP)
    parent_station: str = FieldSpec(default="", foreign_key="stops.stop_id")
    stop_timezone: str = FieldSpec(default="")
    wheelchair_boarding: WheelchairAccessible = FieldSpec(
        default=WheelchairAccessible.UNKNOWN)
    platform_code: str = FieldSpec(default="")

    @cached_property
    def location(self) -> LatLon:
        return LatLon(self.stop_lat, self.stop_lon)


# ────────────────────── stop_times.txt ─────────────────────────
class StopTime(Entity):
    __gtfs_filename__ = "stop_times.txt"
    __primary_key__ = "trip_id"
    __group_by__ = "stop_sequence"
    __required_file__ = True

    trip_id: str = FieldSpec(required=True, foreign_key="trips.trip_id")
    arrival_time: Optional[GTFSTime] = FieldSpec(default=None)
    departure_time: Optional[GTFSTime] = FieldSpec(default=None)
    stop_id: str = FieldSpec(required=True, foreign_key="stops.stop_id")
    stop_sequence: int = FieldSpec(required=True, min_val=0)
    stop_headsign: str = FieldSpec(default="")
    pickup_type: PickupType = FieldSpec(default=PickupType.REGULAR)
    drop_off_type: DropOffType = FieldSpec(default=DropOffType.REGULAR)
    continuous_pickup: ContinuousPickup = FieldSpec(default=ContinuousPickup.NONE)
    continuous_drop_off: ContinuousDropOff = FieldSpec(default=ContinuousDropOff.NONE)
    shape_dist_traveled: Optional[float] = FieldSpec(default=None)
    timepoint: Timepoint = FieldSpec(default=Timepoint.EXACT)

    @cached_property
    def stop(self) -> Stop:
        return self._feed.stops[self.stop_id]

    @cached_property
    def trip(self) -> Trip:
        return self._feed.trips[self.trip_id]


# ────────────────────── shapes.txt ─────────────────────────────
class Shape(Entity):
    __gtfs_filename__ = "shapes.txt"
    __primary_key__ = "shape_id"
    __group_by__ = "shape_pt_sequence"

    shape_id: str = FieldSpec(required=True)
    shape_pt_lat: float = FieldSpec(required=True, min_val=-90.0, max_val=90.0)
    shape_pt_lon: float = FieldSpec(required=True, min_val=-180.0, max_val=180.0)
    shape_pt_sequence: int = FieldSpec(required=True, min_val=0)
    shape_dist_traveled: Optional[float] = FieldSpec(default=None)

    @cached_property
    def location(self) -> LatLon:
        return LatLon(self.shape_pt_lat, self.shape_pt_lon)


# ────────────────────── transfers.txt ──────────────────────────
class Transfer(Entity):
    __gtfs_filename__ = "transfers.txt"
    __primary_key__ = "from_stop_id"
    __group_by__ = "to_stop_id"

    from_stop_id: str = FieldSpec(required=True, foreign_key="stops.stop_id")
    to_stop_id: str = FieldSpec(required=True, foreign_key="stops.stop_id")
    transfer_type: TransferType = FieldSpec(default=TransferType.RECOMMENDED)
    min_transfer_time: Optional[int] = FieldSpec(default=None, min_val=0)
    from_trip_id: str = FieldSpec(default="", foreign_key="trips.trip_id")
    to_trip_id: str = FieldSpec(default="", foreign_key="trips.trip_id")
    from_route_id: str = FieldSpec(default="", foreign_key="routes.route_id")
    to_route_id: str = FieldSpec(default="", foreign_key="routes.route_id")


# ────────────────────── feed_info.txt ──────────────────────────
class FeedInfo(Entity):
    __gtfs_filename__ = "feed_info.txt"
    __primary_key__ = "feed_publisher_name"

    feed_publisher_name: str = FieldSpec(required=True)
    feed_publisher_url: str = FieldSpec(required=True)
    feed_lang: str = FieldSpec(required=True)
    feed_start_date: Optional[GTFSDate] = FieldSpec(default=None)
    feed_end_date: Optional[GTFSDate] = FieldSpec(default=None)
    feed_version: str = FieldSpec(default="")
    feed_contact_email: str = FieldSpec(default="")
    feed_contact_url: str = FieldSpec(default="")


# ────────────────────── frequencies.txt ────────────────────────
class Frequency(Entity):
    __gtfs_filename__ = "frequencies.txt"
    __primary_key__ = "trip_id"
    __group_by__ = "start_time"

    trip_id: str = FieldSpec(required=True, foreign_key="trips.trip_id")
    start_time: GTFSTime = FieldSpec(required=True)
    end_time: GTFSTime = FieldSpec(required=True)
    headway_secs: int = FieldSpec(required=True, min_val=1)
    exact_times: int = FieldSpec(default=0)
