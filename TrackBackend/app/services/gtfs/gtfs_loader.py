"""
Track GTFS Schema — Feed loader, validator, and writer.

Superior to Transit App's py-gtfs-loader/__init__.py:
  • Error accumulation (not fail-fast) — collects all problems with severity
  • Foreign-key validation post-load (they have none)
  • FieldSpec min/max range validation during load
  • BOM-safe + quote-stripping (handles MTA's quirky CSVs)
  • Preserves unknown CSV columns (extension-safe, round-trips cleanly)
  • GTFSFeed container with named table attributes + cross-entity helpers
  • Selective file loading (only parse what you need)
  • Memory stats and entity counts for diagnostics
  • Write-back with original header preservation
  • Integration hooks for our existing gtfs_validator.py
"""

from __future__ import annotations

import contextlib
import copy
import csv
import io
import json
import logging
import shutil
import struct
import typing
from collections import defaultdict
from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path
from typing import (
    TYPE_CHECKING,
    Any,
    Union,
)

from app.services.gtfs.gtfs_entities import (
    Agency,
    Calendar,
    CalendarDate,
    Entity,
    EntityTable,
    FeedInfo,
    FieldSpec,
    Frequency,
    GroupedTable,
    Route,
    Shape,
    Stop,
    StopTime,
    Transfer,
    Trip,
    _ResolvedField,
    get_entity_registry,
)
from app.services.gtfs.gtfs_types import GTFSDate, GTFSTime, LatLon, serialize

if TYPE_CHECKING:
    from collections.abc import Sequence

logger = logging.getLogger(__name__)

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Problem / Error accumulation
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


class Severity:
    ERROR = "error"
    WARNING = "warning"
    NOTICE = "notice"


@dataclass
class LoadProblem:
    """A single problem found during feed loading."""

    severity: str
    file: str
    line: int
    field: str
    message: str
    value: str = ""

    def __str__(self) -> str:
        loc = f"{self.file}:{self.line}" if self.line else self.file
        return f"[{self.severity.upper()}] {loc} field={self.field}: {self.message}"


class ProblemCollector:
    """Accumulates LoadProblems up to per-file caps."""

    def __init__(self, max_per_file: int = 100):
        self._problems: list[LoadProblem] = []
        self._counts: dict[str, int] = defaultdict(int)
        self._max = max_per_file

    def add(
        self,
        severity: str,
        file: str,
        line: int,
        field_name: str,
        message: str,
        value: str = "",
    ) -> None:
        self._counts[file] += 1
        if self._counts[file] <= self._max:
            self._problems.append(
                LoadProblem(
                    severity=severity,
                    file=file,
                    line=line,
                    field=field_name,
                    message=message,
                    value=value,
                )
            )

    @property
    def problems(self) -> list[LoadProblem]:
        return list(self._problems)

    @property
    def error_count(self) -> int:
        return sum(1 for p in self._problems if p.severity == Severity.ERROR)

    @property
    def warning_count(self) -> int:
        return sum(1 for p in self._problems if p.severity == Severity.WARNING)

    def has_errors(self) -> bool:
        return self.error_count > 0

    def summary(self) -> str:
        return (
            f"{self.error_count} errors, {self.warning_count} warnings, "
            f"{len(self._problems) - self.error_count - self.warning_count} notices"
        )


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Type conversion — smarter than py-gtfs-loader's convert()
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


def _get_inner_type(type_hint: type) -> type:
    """Unwrap Optional[X] and List[X]."""
    origin = getattr(type_hint, "__origin__", None)
    if origin is Union or origin is typing.Union:
        args = [a for a in type_hint.__args__ if a is not type(None)]
        return args[0] if args else str
    if origin is list:
        return type_hint.__args__[0] if type_hint.__args__ else str
    return type_hint


def _is_optional(type_hint: type) -> bool:
    """Check if type is Optional[X]."""
    origin = getattr(type_hint, "__origin__", None)
    if origin is Union or origin is typing.Union:
        return type(None) in type_hint.__args__
    return False


def convert_value(
    raw: str,
    target_type: type,
    is_optional: bool,
    default: Any,
    spec: FieldSpec | None = None,
) -> Any:
    """
    Convert a raw CSV string to the target Python type.

    Handles: str, int, float, bool, IntEnum subclasses, GTFSTime,
    GTFSDate, Optional[X], and JSON-encoded lists.
    """
    stripped = raw.strip().strip('"')  # handle MTA's quoted fields

    # Empty cell
    if stripped == "":
        if is_optional:
            return None
        return default

    inner = _get_inner_type(target_type) if is_optional else target_type

    # List stored as JSON string
    if getattr(inner, "__origin__", None) is list:
        return json.loads(stripped)

    # bool (GTFS uses "0"/"1")
    if inner is bool:
        return bool(int(stripped))

    # IntEnum subclass
    if isinstance(inner, type) and issubclass(inner, IntEnum):
        return inner(int(stripped))

    # Our custom types
    if inner is GTFSTime:
        return GTFSTime(stripped)
    if inner is GTFSDate:
        return GTFSDate(stripped)

    # Numeric
    if inner is int:
        return int(stripped)
    if inner is float:
        return float(stripped)

    # Default: string
    return stripped


def _validate_range(
    value: Any,
    spec: FieldSpec,
    filename: str,
    line: int,
    field_name: str,
    collector: ProblemCollector,
) -> None:
    """Check min/max constraints from FieldSpec."""
    if (
        spec.min_val is not None
        and isinstance(value, (int, float))
        and value < spec.min_val
    ):
        collector.add(
            Severity.WARNING,
            filename,
            line,
            field_name,
            f"value {value} below minimum {spec.min_val}",
            str(value),
        )
    if (
        spec.max_val is not None
        and isinstance(value, (int, float))
        and value > spec.max_val
    ):
        collector.add(
            Severity.WARNING,
            filename,
            line,
            field_name,
            f"value {value} above maximum {spec.max_val}",
            str(value),
        )


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  CSV loading pipeline
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


def _merge_header_and_schema(
    header: list[str],
    entity_cls: type[Entity],
) -> dict[str, _ResolvedField]:
    """
    Merge CSV header columns with Entity schema declarations.

    Returns ordered dict of _ResolvedField.  Unknown CSV columns are kept
    as ``str`` fields (extension-safe).  Missing required fields are
    flagged by the caller.
    """
    field_types = entity_cls._field_types()
    field_specs = entity_cls._field_specs()
    resolved: dict[str, _ResolvedField] = {}

    # Columns present in the CSV
    for col in header:
        if col in field_types:
            spec = field_specs.get(col, FieldSpec())
            type_ = field_types[col]
            is_opt = _is_optional(type_)
            _get_inner_type(type_) if is_opt else type_
            resolved[col] = _ResolvedField(
                type_=type_,
                required=spec.required,
                default=spec.default,
                from_schema=True,
            )
        else:
            # Unknown column — preserve as string
            resolved[col] = _ResolvedField(
                type_=str,
                required=False,
                default="",
                from_schema=False,
            )

    # Schema fields NOT in header
    for name in entity_cls._field_names():
        if name not in resolved:
            spec = field_specs.get(name, FieldSpec())
            resolved[name] = _ResolvedField(
                type_=field_types.get(name, str),
                required=spec.required,
                default=spec.default,
                from_schema=True,
            )

    return resolved


def _load_csv(
    filepath: Path,
    entity_cls: type[Entity],
    feed: GTFSFeed,
    collector: ProblemCollector,
    strip_quotes: bool = True,
) -> tuple[EntityTable | GroupedTable, int]:
    """
    Parse a single GTFS CSV file into an EntityTable or GroupedTable.

    Returns (table, row_count).
    """
    filename = filepath.name
    pk_field = entity_cls.__primary_key__
    group_field = entity_cls.__group_by__
    is_grouped = group_field is not None

    table: EntityTable | GroupedTable
    table = GroupedTable() if is_grouped else EntityTable()

    # Read with BOM handling
    try:
        text = filepath.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError:
        text = filepath.read_text(encoding="latin-1")

    reader = csv.DictReader(io.StringIO(text))
    if reader.fieldnames is None:
        collector.add(Severity.ERROR, filename, 0, "", "empty or missing header")
        return table, 0

    header = [h.strip().strip('"') for h in reader.fieldnames]
    resolved = _merge_header_and_schema(header, entity_cls)
    table._resolved_fields = resolved

    # Check for required fields missing from header
    field_specs = entity_cls._field_specs()
    for name, spec in field_specs.items():
        if spec.required and name not in header:
            collector.add(
                Severity.ERROR,
                filename,
                1,
                name,
                f"required field '{name}' missing from header",
            )

    row_count = 0
    for line_no, row in enumerate(reader, start=2):
        entity = entity_cls.__new__(entity_cls)
        entity.__dict__["_feed"] = feed

        for col_name, rfield in resolved.items():
            raw = row.get(col_name, "")
            if raw is None:
                raw = ""

            # Strip extra quotes (MTA quirk)
            if strip_quotes and isinstance(raw, str):
                raw = raw.strip()

            # Required field check
            if rfield.required and raw.strip() == "":
                collector.add(
                    Severity.ERROR,
                    filename,
                    line_no,
                    col_name,
                    "required field is empty",
                )
                setattr(entity, col_name, rfield.default)
                continue

            # Convert
            try:
                value = convert_value(
                    raw,
                    rfield.type_,
                    _is_optional(rfield.type_),
                    rfield.default,
                )
            except (ValueError, TypeError, KeyError) as exc:
                collector.add(
                    Severity.ERROR,
                    filename,
                    line_no,
                    col_name,
                    f"conversion failed: {exc}",
                    raw,
                )
                setattr(entity, col_name, rfield.default)
                continue

            # Range validation
            spec = field_specs.get(col_name)
            if spec and (spec.min_val is not None or spec.max_val is not None):
                _validate_range(value, spec, filename, line_no, col_name, collector)

            setattr(entity, col_name, value)

        # Apply defaults for schema fields not in CSV at all
        for name in entity_cls._field_names():
            if not hasattr(entity, name):
                spec = field_specs.get(name, FieldSpec())
                setattr(entity, name, copy.copy(spec.default))

        # Index the entity
        pk_val = getattr(entity, pk_field, "")
        if is_grouped:
            table.setdefault(pk_val, []).append(entity)
        else:
            table[pk_val] = entity

        row_count += 1

    # Sort grouped tables by group_by field
    if is_grouped and group_field:
        for key in table:
            with contextlib.suppress(TypeError):
                table[key].sort(key=lambda e: getattr(e, group_field, 0))

    return table, row_count


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  CSV write-back
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


def _flatten_entities(table: EntityTable | GroupedTable) -> list[Entity]:
    """Un-nest grouped tables into a flat row list."""
    if isinstance(table, GroupedTable):
        rows: list[Entity] = []
        for group in table.values():
            if isinstance(group, list):
                rows.extend(group)
            else:
                rows.append(group)
        return rows
    return list(table.values())


def _save_csv(
    filepath: Path,
    table: EntityTable | GroupedTable,
    entity_cls: type[Entity],
    sorted_output: bool = False,
) -> None:
    """Write a table back to CSV, preserving the original header order."""
    rows = _flatten_entities(table)
    if not rows:
        # Delete the file if empty
        filepath.unlink(missing_ok=True)
        return

    # Use resolved fields if available, otherwise derive from entity
    if hasattr(table, "_resolved_fields") and table._resolved_fields:
        columns = list(table._resolved_fields.keys())
    else:
        columns = entity_cls._field_names()

    with open(filepath, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(columns)

        if sorted_output:
            pk = entity_cls.__primary_key__
            rows.sort(key=lambda e: getattr(e, pk, ""))

        for entity in rows:
            writer.writerow([serialize(entity.get(col, "")) for col in columns])


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Foreign-key validation
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


def _validate_foreign_keys(feed: GTFSFeed, collector: ProblemCollector) -> None:
    """
    Check referential integrity across all loaded tables.

    This is something Transit App's py-gtfs-loader does NOT do at all —
    broken foreign keys only fail at access time with a KeyError.
    """
    registry = get_entity_registry()

    for filename, entity_cls in registry.items():
        table_name = filename.replace(".txt", "")
        table = getattr(feed, table_name, None)
        if table is None or not table:
            continue

        fks = entity_cls._foreign_keys()
        if not fks:
            continue

        entities = (
            _flatten_entities(table)
            if isinstance(table, GroupedTable)
            else list(table.values())
        )

        for fk_field, target_spec in fks.items():
            target_table_name, target_col = target_spec.split(".", 1)
            target_table = getattr(feed, target_table_name, None)
            if target_table is None:
                continue  # target table not loaded

            # Build set of valid keys
            if isinstance(target_table, GroupedTable):
                valid_keys: set[str] = set(target_table.keys())
            else:
                valid_keys = set(target_table.keys())

            broken_count = 0
            for entity in entities:
                fk_val = getattr(entity, fk_field, "")
                if fk_val and fk_val not in valid_keys:
                    broken_count += 1
                    if broken_count <= 10:  # cap per FK relation
                        collector.add(
                            Severity.WARNING,
                            filename,
                            0,
                            fk_field,
                            f"references non-existent {target_table_name}.{target_col}={fk_val!r}",
                            str(fk_val),
                        )

            if broken_count > 10:
                collector.add(
                    Severity.WARNING,
                    filename,
                    0,
                    fk_field,
                    f"... and {broken_count - 10} more broken {fk_field} references",
                )


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  GTFSFeed — the top-level container
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Default set of files to load (mirrors py-gtfs-loader's GTFS_SUBSET_SCHEMA)
DEFAULT_FILES: list[type[Entity]] = [
    Agency,
    Calendar,
    CalendarDate,
    Route,
    Trip,
    Stop,
    StopTime,
    Shape,
    Transfer,
    FeedInfo,
    Frequency,
]


class GTFSFeed:
    """In-memory representation of a GTFS feed.

    Access tables by name::

        feed = GTFSFeed.load("/path/to/gtfs")
        feed.stops["stop_id"]           # → Stop entity
        feed.stop_times["trip_id"]      # → [StopTime, ...]
        for route in feed.routes.values(): ...

    This replaces the loose-dict approach in py-gtfs-loader with a
    typed, navigable, validated container.

    Attributes:
        agency: Keyed table of Agency entities.
        calendar: Keyed table of Calendar entries.
        calendar_dates: Grouped table of CalendarDate exceptions.
        routes: Keyed table of Route entities.
        trips: Keyed table of Trip entities.
        stops: Keyed table of Stop entities.
        stop_times: Grouped table of StopTime records keyed by trip_id.
        shapes: Grouped table of Shape points keyed by shape_id.
        transfers: Grouped table of Transfer records.
        feed_info: Keyed table of FeedInfo metadata.
        frequencies: Grouped table of Frequency entries.
        source_dir: Filesystem path the feed was loaded from.
        problems: List of LoadProblem instances found during loading.
    """

    def __init__(self) -> None:
        # Core tables
        self.agency: EntityTable = EntityTable()
        self.calendar: EntityTable = EntityTable()
        self.calendar_dates: GroupedTable = GroupedTable()
        self.routes: EntityTable = EntityTable()
        self.trips: EntityTable = EntityTable()
        self.stops: EntityTable = EntityTable()
        self.stop_times: GroupedTable = GroupedTable()
        self.shapes: GroupedTable = GroupedTable()
        self.transfers: GroupedTable = GroupedTable()
        self.feed_info: EntityTable = EntityTable()
        self.frequencies: GroupedTable = GroupedTable()

        # Metadata
        self.source_dir: Path | None = None
        self.problems: list[LoadProblem] = []
        self._entity_counts: dict[str, int] = {}

    # ── named table access by filename ──────────────────────────
    _TABLE_MAP: dict[str, str] = {
        "agency.txt": "agency",
        "calendar.txt": "calendar",
        "calendar_dates.txt": "calendar_dates",
        "routes.txt": "routes",
        "trips.txt": "trips",
        "stops.txt": "stops",
        "stop_times.txt": "stop_times",
        "shapes.txt": "shapes",
        "transfers.txt": "transfers",
        "feed_info.txt": "feed_info",
        "frequencies.txt": "frequencies",
    }

    def table_for_filename(self, filename: str) -> EntityTable | GroupedTable | None:
        attr = self._TABLE_MAP.get(filename)
        return getattr(self, attr) if attr else None

    # ── convenience queries ─────────────────────────────────────
    def trips_for_route(self, route_id: str) -> list[Trip]:
        """Return all trips belonging to a route."""
        return [t for t in self.trips.values() if t.route_id == route_id]

    def stops_for_trip(self, trip_id: str) -> list[Stop]:
        """Return ordered list of Stop entities for a trip."""
        sts = self.stop_times.get(trip_id, [])
        result = []
        for st in sts:
            stop = self.stops.get(st.stop_id)
            if stop:
                result.append(stop)
        return result

    def shape_points(self, shape_id: str) -> list[LatLon]:
        """Return ordered LatLon list for a shape."""
        pts = self.shapes.get(shape_id, [])
        return [LatLon(p.shape_pt_lat, p.shape_pt_lon) for p in pts]

    def shape_as_packed_bytes(self, shape_id: str) -> bytes:
        """
        Return shape as packed float32 pairs (lat, lon) — matches Track's
        existing subway_shapes.py binary format for zero-change integration.
        """
        pts = self.shapes.get(shape_id, [])
        buf = bytearray()
        for p in pts:
            buf.extend(struct.pack("<ff", p.shape_pt_lat, p.shape_pt_lon))
        return bytes(buf)

    def active_services(self, on_date: GTFSDate | None = None) -> set[str]:
        """
        Return set of service_ids active on a given date.

        Combines calendar.txt weekly patterns + calendar_dates.txt exceptions.
        """
        if on_date is None:
            on_date = GTFSDate.today_gtfs()

        active: set[str] = set()

        # Strategy 1: calendar.txt
        for cal in self.calendar.values():
            if cal.is_active_on(on_date):
                active.add(cal.service_id)

        # Strategy 2: calendar_dates.txt exceptions
        for svc_id, dates in self.calendar_dates.items():
            for cd in dates:
                if cd.date == on_date:
                    if cd.exception_type == 1:  # ADD
                        active.add(svc_id)
                    elif cd.exception_type == 2:  # REMOVE
                        active.discard(svc_id)

        return active

    # ── diagnostics ─────────────────────────────────────────────
    def entity_counts(self) -> dict[str, int]:
        return dict(self._entity_counts)

    def summary(self) -> str:
        parts = []
        for _fname, attr in self._TABLE_MAP.items():
            table = getattr(self, attr, None)
            if table:
                count = (
                    sum(len(v) if isinstance(v, list) else 1 for v in table.values())
                    if isinstance(table, GroupedTable)
                    else len(table)
                )
                if count:
                    parts.append(f"{attr}: {count:,}")
        return " | ".join(parts) if parts else "(empty feed)"

    def __repr__(self) -> str:
        src = self.source_dir or "(in-memory)"
        return f"<GTFSFeed src={src} {self.summary()}>"

    # ── class-level loaders ─────────────────────────────────────
    @classmethod
    def load(
        cls,
        gtfs_dir: str | Path,
        *,
        files: Sequence[type[Entity]] | None = None,
        validate_fks: bool = True,
        strip_quotes: bool = True,
        verbose: bool = False,
    ) -> GTFSFeed:
        """
        Load a GTFS feed from a directory.

        Args:
            gtfs_dir: Path to the directory containing .txt files.
            files: Subset of entity classes to load (default: all).
            validate_fks: Run foreign-key validation after load.
            strip_quotes: Strip double-quotes from cell values (MTA compat).
            verbose: Log progress to logger.

        Returns:
            GTFSFeed instance with all loaded tables.
        """
        gtfs_path = Path(gtfs_dir)
        if not gtfs_path.is_dir():
            raise FileNotFoundError(f"GTFS directory not found: {gtfs_path}")

        feed = cls()
        feed.source_dir = gtfs_path
        collector = ProblemCollector()

        entities_to_load = files or DEFAULT_FILES

        for entity_cls in entities_to_load:
            filename = entity_cls.__gtfs_filename__
            filepath = gtfs_path / filename

            if not filepath.exists():
                if entity_cls.__required_file__:
                    collector.add(
                        Severity.ERROR,
                        filename,
                        0,
                        "",
                        f"required file '{filename}' not found",
                    )
                continue

            table, count = _load_csv(
                filepath,
                entity_cls,
                feed,
                collector,
                strip_quotes=strip_quotes,
            )

            # Assign to the feed attribute
            attr = cls._TABLE_MAP.get(filename)
            if attr:
                setattr(feed, attr, table)
            feed._entity_counts[filename] = count

            if verbose:
                logger.info("Loaded %s: %d rows", filename, count)

        # Post-load validation
        if validate_fks:
            _validate_foreign_keys(feed, collector)

        feed.problems = collector.problems
        if collector.has_errors() and verbose:
            logger.warning("Feed loaded with problems: %s", collector.summary())

        return feed

    @classmethod
    def load_file(
        cls,
        filepath: str | Path,
        entity_cls: type[Entity],
    ) -> tuple[EntityTable | GroupedTable, list[LoadProblem]]:
        """
        Load a single GTFS file outside a feed context.

        Useful for one-off parsing (e.g. just stops.txt).
        Returns (table, problems).
        """
        feed = cls()
        collector = ProblemCollector()
        table, _ = _load_csv(Path(filepath), entity_cls, feed, collector)
        return table, collector.problems

    # ── write-back ──────────────────────────────────────────────
    def save(
        self,
        output_dir: str | Path,
        *,
        sorted_output: bool = False,
        files: Sequence[type[Entity]] | None = None,
    ) -> None:
        """
        Write the feed back to CSV files.

        If output_dir is different from source_dir, non-schema files
        (like README, license) are NOT copied — this is intentional for
        Track's workflow (we generate, not patch).
        """
        out = Path(output_dir)
        out.mkdir(parents=True, exist_ok=True)

        get_entity_registry()
        to_write = files or DEFAULT_FILES

        for entity_cls in to_write:
            filename = entity_cls.__gtfs_filename__
            attr = self._TABLE_MAP.get(filename)
            if not attr:
                continue
            table = getattr(self, attr, None)
            if table is None:
                continue

            _save_csv(out / filename, table, entity_cls, sorted_output)

    def patch(
        self,
        source_dir: str | Path,
        output_dir: str | Path,
        *,
        sorted_output: bool = False,
    ) -> None:
        """
        Copy source feed to output, replacing only the tables we have loaded.

        This mirrors py-gtfs-loader's patch() — copy all files, then overwrite
        the ones we have data for.
        """
        src = Path(source_dir)
        out = Path(output_dir)
        out.mkdir(parents=True, exist_ok=True)

        # Copy all non-.txt files (and unknown .txt files) from source
        if src != out:
            for item in src.iterdir():
                if item.is_file():
                    shutil.copy2(item, out / item.name)

        # Overwrite our tables
        self.save(output_dir, sorted_output=sorted_output)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Module-level convenience functions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


def load_feed(
    gtfs_dir: str | Path,
    **kwargs: Any,
) -> GTFSFeed:
    """Convenience alias for ``GTFSFeed.load()``."""
    return GTFSFeed.load(gtfs_dir, **kwargs)


def load_stops(gtfs_dir: str | Path) -> EntityTable:
    """Load just stops.txt — common one-off need in Track."""
    feed = GTFSFeed.load(gtfs_dir, files=[Stop], validate_fks=False)
    return feed.stops


def load_shapes(gtfs_dir: str | Path) -> GroupedTable:
    """Load just shapes.txt — common one-off need in Track."""
    feed = GTFSFeed.load(gtfs_dir, files=[Shape], validate_fks=False)
    return feed.shapes


def load_routes(gtfs_dir: str | Path) -> EntityTable:
    """Load just routes.txt — common one-off need in Track."""
    feed = GTFSFeed.load(gtfs_dir, files=[Route], validate_fks=False)
    return feed.routes


def load_trips(gtfs_dir: str | Path) -> EntityTable:
    """Load just trips.txt — common one-off need in Track."""
    feed = GTFSFeed.load(gtfs_dir, files=[Trip], validate_fks=False)
    return feed.trips
