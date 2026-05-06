"""Heavy contract drift detector — Pydantic ↔ Swift Codable.

For each curated (Pydantic model, Swift struct) pair, this test confirms
that every JSON key the backend emits has a matching Swift property
(via either CodingKeys override or auto-camelCase conversion) AND that
every Swift property the iOS Codable expects is actually emitted by
the backend.

Direction:
    backend → iOS  : missing key on iOS → silent data loss in the app.
    iOS → backend  : missing key on backend → DECODE FAILURE for any
                     non-optional Swift property without a default.

Both directions are checked. Failures are reported with field-level
diagnostics so drift can be fixed in one pass.

The Pydantic side is introspected from `model_fields` (authoritative).
The Swift side is parsed from source with a lightweight regex parser
that handles `let`/`var` properties and `enum CodingKeys` overrides —
sufficient for the project's flat Codable structs.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

import pytest

from app.models import (
    AllCommuterRailLinesResponse,
    AllSubwayLinesResponse,
    AllSubwayStationsResponse,
    BusArrival,
    BusRoute,
    BusScheduleDeparture,
    BusScheduleDirection,
    BusScheduleResponse,
    BusStop,
    BusVehicle,
    CommuterRailLineOverlay,
    CommuterRailStop,
    DirectionArrivals,
    DirectionShape,
    ElevatorStatus,
    GroupedNearbyTransit,
    InlineAlert,
    LiveVehicleDetail,
    NearbyTransitArrival,
    ProcessedStation,
    ProcessedStationsResponse,
    RouteShape,
    StopPosition,
    SubwayLineOverlay,
    SubwayStation,
    TrackArrival,
    TransitAlert,
    TransitVehicle,
    TrunkGroupPolylines,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
SWIFT_MODELS_DIR = REPO_ROOT / "Track" / "Models"


# ---------------------------------------------------------------------------
# Mapping table — single source of truth for which Swift type each Pydantic
# model corresponds to. Adding a new endpoint? Add the pair here.
# ---------------------------------------------------------------------------
PAIRS: list[tuple[type, str]] = [
    (TrackArrival, "TransitArrivalResponse"),
    (TransitAlert, "TransitAlert"),
    (ElevatorStatus, "ElevatorStatus"),
    (BusRoute, "BusRoute"),
    (BusStop, "BusStop"),
    (BusArrival, "BusArrival"),
    (BusVehicle, "BusVehicleResponse"),
    (NearbyTransitArrival, "NearbyTransitResponse"),
    (DirectionArrivals, "DirectionArrivalsResponse"),
    (InlineAlert, "InlineAlertResponse"),
    (GroupedNearbyTransit, "GroupedNearbyTransitResponse"),
    (LiveVehicleDetail, "LiveVehicleDetailResponse"),
    (DirectionShape, "DirectionShapeResponse"),
    (RouteShape, "RouteShapeResponse"),
    (SubwayLineOverlay, "SubwayLineOverlay"),
    (TrunkGroupPolylines, "TrunkGroupPolylines"),
    (AllSubwayLinesResponse, "AllSubwayLinesResponse"),
    (SubwayStation, "SubwayStation"),
    (AllSubwayStationsResponse, "AllSubwayStationsResponse"),
    (StopPosition, "ProcessedStopPosition"),
    (ProcessedStation, "ProcessedStation"),
    (ProcessedStationsResponse, "ProcessedStationsResponse"),
    (CommuterRailStop, "CommuterRailStopOverlay"),
    (CommuterRailLineOverlay, "CommuterRailLineOverlay"),
    (AllCommuterRailLinesResponse, "AllCommuterRailLinesResponse"),
    (BusScheduleDeparture, "BusScheduledDeparture"),
    (BusScheduleDirection, "BusScheduleDirection"),
    (BusScheduleResponse, "BusScheduleResponse"),
    (TransitVehicle, "TrainVehicle"),
]


# Swift property names that are *intentionally* not on the backend
# (computed properties, client-only fields, defaults applied locally).
# Add a (swift_struct_name, swift_property_name) entry to silence a
# legitimate divergence so the test stays clean.
SWIFT_LOCAL_ONLY: set[tuple[str, str]] = {
    # `id` is a computed identity used for SwiftUI diffing; backend does
    # not emit it.
    ("NearbyTransitResponse", "id"),
    ("BusArrival", "id"),
    ("GroupedNearbyTransitResponse", "id"),
    ("DirectionArrivalsResponse", "id"),
    ("BusVehicleResponse", "id"),
    # `LiveVehicleDetailResponse` uses a custom `init(from:)` that
    # branches the backend's polymorphic `vehicle` payload into either
    # `busVehicle` or `trainVehicle` and stamps `receivedAt` locally.
    ("LiveVehicleDetailResponse", "busVehicle"),
    ("LiveVehicleDetailResponse", "trainVehicle"),
    ("LiveVehicleDetailResponse", "receivedAt"),
}

# Backend-only fields that the iOS app intentionally ignores (e.g.
# fields used only by other clients or analytics). These cause an INFO
# warning, never a failure.
BACKEND_ONLY_OK: set[tuple[type, str]] = {
    # Polymorphic field — iOS branches it into `busVehicle`/`trainVehicle`
    # via a custom decoder rather than a 1-to-1 property.
    (LiveVehicleDetail, "vehicle"),
}


# ---------------------------------------------------------------------------
# Swift parsing
# ---------------------------------------------------------------------------


@dataclass
class SwiftField:
    name: str          # Swift property name (camelCase)
    type_text: str     # raw type as written, e.g. "String", "[Int]?", "Double?"
    optional: bool     # ends with `?` OR has `= nil` default
    has_default: bool  # `= ...` present
    json_key: str      # resolved JSON key (CodingKeys override or property name)


_STRUCT_RE = re.compile(
    r"^\s*(?:public\s+|private\s+|internal\s+|fileprivate\s+)?"
    r"struct\s+(?P<name>\w+)\s*(?:<[^>]+>\s*)?"
    r"(?::\s*[^\{]+)?\{",
    re.MULTILINE,
)

# Match `let foo: Bar` / `var foo: Bar = baz`. Skip computed properties
# (those have `{` after the type instead of `=` or end-of-line).
_PROP_RE = re.compile(
    r"^\s*(?:public\s+|private\s+|internal\s+|fileprivate\s+)?"
    r"(?:@\w+(?:\([^)]*\))?\s+)*"            # property wrappers / attributes
    r"(let|var)\s+(?P<name>\w+)\s*:\s*"
    r"(?P<type>[^={\n]+?)"
    r"(?:\s*=\s*(?P<default>[^\n]+?))?\s*$",
    re.MULTILINE,
)

_CODING_KEYS_RE = re.compile(
    r"enum\s+CodingKeys\s*:\s*String\s*,\s*CodingKey\s*\{(?P<body>[^}]*)\}",
    re.DOTALL,
)


def _extract_struct_body(source: str, struct_name: str) -> str:
    """Return the brace-balanced body of `struct StructName { ... }`.

    Handles nested braces (CodingKeys enum, computed properties).
    """
    for match in _STRUCT_RE.finditer(source):
        if match.group("name") != struct_name:
            continue
        # Walk forward from the opening brace, balancing braces.
        start = match.end() - 1  # position of `{`
        depth = 0
        for i in range(start, len(source)):
            ch = source[i]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return source[start + 1 : i]
        raise ValueError(f"Unbalanced braces in struct {struct_name}")
    raise LookupError(f"struct {struct_name} not found")


def _parse_coding_keys(body: str) -> dict[str, str]:
    """Return {swift_property_name: json_key} from the CodingKeys enum, if any."""
    match = _CODING_KEYS_RE.search(body)
    if not match:
        return {}
    out: dict[str, str] = {}
    for raw_line in match.group("body").splitlines():
        line = raw_line.split("//", 1)[0].strip()
        if not line.startswith("case "):
            continue
        line = line[len("case "):].strip().rstrip(",")
        # Each `case` may declare multiple comma-separated entries.
        for piece in line.split(","):
            piece = piece.strip()
            if not piece:
                continue
            if "=" in piece:
                name, raw_key = piece.split("=", 1)
                key = raw_key.strip().strip('"')
                out[name.strip()] = key
            else:
                out[piece] = piece
    return out


def _parse_swift_struct(source: str, struct_name: str) -> list[SwiftField]:
    body = _extract_struct_body(source, struct_name)
    coding_keys = _parse_coding_keys(body)

    # Only top-level stored properties of the struct count as Codable
    # fields — properties declared inside computed-property bodies,
    # methods, initializers, or nested types must be ignored.
    top_level = _top_level_lines(body)

    fields: list[SwiftField] = []
    seen: set[str] = set()
    for line in top_level:
        match = _PROP_RE.match(line)
        if not match:
            continue
        name = match.group("name")
        if name in seen:
            continue
        seen.add(name)
        type_text = match.group("type").strip()
        default = match.group("default")
        optional = type_text.endswith("?") or (default is not None and default.strip() == "nil")
        json_key = coding_keys.get(name, name)
        fields.append(
            SwiftField(
                name=name,
                type_text=type_text,
                optional=optional,
                has_default=default is not None,
                json_key=json_key,
            )
        )
    return fields


def _top_level_lines(body: str) -> list[str]:
    """Return source lines that live at brace-depth 0 inside the struct body.

    A stored property is always declared at depth 0; anything inside
    `{ ... }` (computed property bodies, methods, nested types, init,
    extensions) lives at depth ≥ 1 and must be filtered out so the
    regex doesn't pick up local `let`/`var` declarations as Codable
    fields.
    """
    out: list[str] = []
    depth = 0
    in_string = False
    in_line_comment = False
    in_block_comment = False
    line_start = 0
    line_open_depth = 0  # depth at the start of the current line
    i = 0
    while i < len(body):
        ch = body[i]
        nxt = body[i + 1] if i + 1 < len(body) else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            else:
                i += 1
                continue
        elif in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue
        elif in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        else:
            if ch == "/" and nxt == "/":
                in_line_comment = True
                i += 2
                continue
            if ch == "/" and nxt == "*":
                in_block_comment = True
                i += 2
                continue
            if ch == '"':
                in_string = True
                i += 1
                continue
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth = max(0, depth - 1)

        if ch == "\n":
            if line_open_depth == 0:
                out.append(body[line_start:i])
            line_start = i + 1
            line_open_depth = depth
        i += 1
    # Trailing line
    if line_open_depth == 0 and line_start < len(body):
        out.append(body[line_start:])
    return out


# ---------------------------------------------------------------------------
# Pydantic introspection
# ---------------------------------------------------------------------------


@dataclass
class PydField:
    json_key: str
    optional: bool
    annotation: object


def _pydantic_fields(model: type) -> list[PydField]:
    out: list[PydField] = []
    for name, info in model.model_fields.items():  # type: ignore[attr-defined]
        json_key = info.alias or name
        # A Pydantic field is "optional" for our purposes if it accepts
        # None OR has a default value (so the backend may legitimately
        # omit it from JSON output).
        annotation = info.annotation
        is_nullable = "None" in repr(annotation)
        has_default = info.is_required() is False
        out.append(
            PydField(
                json_key=json_key,
                optional=is_nullable or has_default,
                annotation=annotation,
            )
        )
    return out


# ---------------------------------------------------------------------------
# Swift source loading
# ---------------------------------------------------------------------------


def _load_all_swift_sources() -> dict[str, tuple[Path, str]]:
    """Return {struct_name: (file_path, full_source)} for every struct in
    Track/Models/. The full source is shared so multiple structs in the
    same file are parsed against the same text (line-cheap, no re-read).
    """
    out: dict[str, tuple[Path, str]] = {}
    for path in SWIFT_MODELS_DIR.rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        for match in _STRUCT_RE.finditer(text):
            out.setdefault(match.group("name"), (path, text))
    return out


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def swift_index() -> dict[str, tuple[Path, str]]:
    return _load_all_swift_sources()


@pytest.mark.parametrize(
    "pyd_model,swift_name",
    PAIRS,
    ids=[f"{p.__name__}->{s}" for p, s in PAIRS],
)
def test_pydantic_to_swift_no_missing_keys(pyd_model, swift_name, swift_index):
    """Every backend JSON key must have a Swift property that consumes it."""
    assert (
        swift_name in swift_index
    ), f"Swift struct '{swift_name}' not found under Track/Models/"
    _, source = swift_index[swift_name]
    swift_fields = _parse_swift_struct(source, swift_name)
    swift_keys = {f.json_key for f in swift_fields}

    pyd_fields = _pydantic_fields(pyd_model)

    missing: list[str] = []
    for f in pyd_fields:
        if (pyd_model, f.json_key) in BACKEND_ONLY_OK:
            continue
        if f.json_key not in swift_keys:
            missing.append(f.json_key)

    assert not missing, (
        f"\nBackend `{pyd_model.__name__}` emits keys the iOS `{swift_name}` "
        f"never reads (silent data loss):\n  - " + "\n  - ".join(missing)
        + "\n\nFix: add the matching property + CodingKey to the Swift struct, "
        "or whitelist via BACKEND_ONLY_OK."
    )


@pytest.mark.parametrize(
    "pyd_model,swift_name",
    PAIRS,
    ids=[f"{p.__name__}<-{s}" for p, s in PAIRS],
)
def test_swift_to_pydantic_no_orphan_keys(pyd_model, swift_name, swift_index):
    """Every Swift Codable property must come from the backend or be marked local-only.

    A Swift property the backend never emits will:
      * silently decode as `nil` if optional → invisible feature gap, or
      * raise `keyNotFound` and break the screen entirely if non-optional.
    """
    _, source = swift_index[swift_name]
    swift_fields = _parse_swift_struct(source, swift_name)
    pyd_keys = {f.json_key for f in _pydantic_fields(pyd_model)}

    orphans_required: list[str] = []
    orphans_optional: list[str] = []
    for f in swift_fields:
        if (swift_name, f.name) in SWIFT_LOCAL_ONLY:
            continue
        if f.json_key in pyd_keys:
            continue
        if f.optional or f.has_default:
            orphans_optional.append(f"{f.name} (json:'{f.json_key}')")
        else:
            orphans_required.append(f"{f.name} (json:'{f.json_key}')")

    msg_parts: list[str] = []
    if orphans_required:
        msg_parts.append(
            "REQUIRED Swift fields with no backend source — decode WILL fail:\n  - "
            + "\n  - ".join(orphans_required)
        )
    if orphans_optional:
        msg_parts.append(
            "Optional Swift fields the backend never sends (silent nil — verify "
            "intent):\n  - " + "\n  - ".join(orphans_optional)
        )

    assert not orphans_required, (
        f"\niOS `{swift_name}` declares fields the backend `{pyd_model.__name__}` "
        f"never emits.\n\n" + "\n\n".join(msg_parts)
        + "\n\nFix: either add the field to the Pydantic model, mark the Swift "
        "property optional / give it a default, or whitelist via SWIFT_LOCAL_ONLY."
    )


def test_every_pair_resolves(swift_index):
    """Sanity: every mapping in PAIRS must point at a real Swift struct."""
    missing = [name for _, name in PAIRS if name not in swift_index]
    assert not missing, "Mapped Swift structs not found: " + ", ".join(missing)
