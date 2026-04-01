"""
GTFS Parser Service

Generates the static iOS bundle (route polylines, stations, colors) from GTFS data.
Uses the schema-driven GTFSFeed loader — no manual csv.DictReader calls.

Supports Subway, LIRR, and Metro-North with automatic prefixing to avoid ID collisions.
"""

from __future__ import annotations

from collections import defaultdict
from pathlib import Path
from typing import Any

from app.services.gtfs.gtfs_entities import Route, Shape, Stop, Trip
from app.services.gtfs.gtfs_loader import GTFSFeed, load_feed
from app.utils.logger import TrackLogger
from app.utils.transit_utils import get_subway_color

# Path to GTFS data directory
DEFAULT_DATA_DIR = Path(__file__).resolve().parent.parent.parent / "data"


def _load_feed_light(agency_dir: Path) -> GTFSFeed:
    """Load only shapes, stops, trips, and routes — the minimum for bundle gen."""
    return load_feed(
        agency_dir,
        files=[Shape, Stop, Trip, Route],
        validate_fks=False,
    )


def _shapes_from_feed(feed: GTFSFeed) -> dict[str, list[dict[str, float]]]:
    """Extract {shape_id: [{lat, lon}, ...]} from a loaded feed."""
    result: dict[str, list[dict[str, float]]] = {}
    for shape_id, points in feed.shapes.items():
        # points already sorted by shape_pt_sequence from the loader
        result[shape_id] = [
            {"lat": pt.shape_pt_lat, "lon": pt.shape_pt_lon} for pt in points
        ]
    return result


def _shape_to_route_map(feed: GTFSFeed) -> dict[str, str]:
    """Build shape_id → route_id mapping from trips."""
    mapping: dict[str, str] = {}
    for trip in feed.trips.values():
        if trip.shape_id and trip.route_id:
            mapping[trip.shape_id] = trip.route_id
    return mapping


def _stops_from_feed(feed: GTFSFeed, prefix: str = "") -> list[dict[str, Any]]:
    """Extract station list from a loaded feed, applying optional prefix."""
    stops: list[dict[str, Any]] = []
    for stop in feed.stops.values():
        stop_id = f"{prefix}_{stop.stop_id}" if prefix else stop.stop_id
        loc_type = int(stop.location_type) if stop.location_type is not None else 0

        # Subway: location_type=1 (stations) or 0 (stops without N/S suffix)
        # Rail: usually location_type=0
        if loc_type == 1 or (
            loc_type == 0 and not any(s in stop_id for s in ["N", "S"])
        ):
            stops.append(
                {
                    "id": stop_id,
                    "name": stop.stop_name,
                    "lat": stop.stop_lat,
                    "lon": stop.stop_lon,
                }
            )
    return stops


def get_routes_with_shapes(
    agency_dir: Path, prefix: str = ""
) -> dict[str, list[list[dict[str, float]]]]:
    """Group shapes by route ID, preserving all branches."""
    feed = _load_feed_light(agency_dir)
    shapes = _shapes_from_feed(feed)
    sid_to_rid = _shape_to_route_map(feed)

    route_shapes: dict[str, list] = defaultdict(list)
    for sid, coords in shapes.items():
        rid = sid_to_rid.get(sid)
        if not rid:
            # Fallback for subway IDs like "A..N03R"
            rid = sid.split("..")[0] if ".." in sid else sid

        # Apply agency prefix to route ID
        if prefix:
            rid = f"{prefix}_{rid}"

        if len(coords) < 5:
            continue

        # Branch detection
        start = (round(coords[0]["lat"], 4), round(coords[0]["lon"], 4))
        end = (round(coords[-1]["lat"], 4), round(coords[-1]["lon"], 4))
        branch_key = frozenset([start, end])

        route_shapes[rid].append((branch_key, coords))

    final_routes: dict[str, list[list[dict[str, float]]]] = {}
    for rid, branch_list in route_shapes.items():
        unique_branches: dict[frozenset, list[dict[str, float]]] = {}
        for bkey, coords in branch_list:
            if bkey not in unique_branches or len(coords) > len(unique_branches[bkey]):
                unique_branches[bkey] = coords
        final_routes[rid] = list(unique_branches.values())

    return final_routes


def generate_bundle() -> dict[str, Any]:
    """Generate complete static data bundle for iOS app including prefixed Rail."""
    subway_dir = DEFAULT_DATA_DIR / "subway/supplemented_GTFS"
    lirr_dir = DEFAULT_DATA_DIR / "lirr/gtfslirr"
    mnr_dir = DEFAULT_DATA_DIR / "metro_north/gtfsmnr"

    all_routes: dict[str, list[list[dict[str, float]]]] = {}
    # Subway stays unprefixed (backwards compat)
    all_routes.update(get_routes_with_shapes(subway_dir))
    # Rail gets prefixed to avoid collision (e.g. LIRR_1 vs Subway 1)
    all_routes.update(get_routes_with_shapes(lirr_dir, prefix="LIRR"))
    all_routes.update(get_routes_with_shapes(mnr_dir, prefix="MNR"))

    # Load stops via GTFSFeed (one load per agency)
    all_stops: list[dict[str, Any]] = []
    all_stops.extend(_stops_from_feed(_load_feed_light(subway_dir)))
    all_stops.extend(_stops_from_feed(_load_feed_light(lirr_dir), prefix="LIRR"))
    all_stops.extend(_stops_from_feed(_load_feed_light(mnr_dir), prefix="MNR"))

    all_colors: dict[str, str] = {}
    for rid in all_routes:
        color = get_subway_color(rid)
        all_colors[rid] = color.lstrip("#")

    total_branches = sum(len(b) for b in all_routes.values())

    TrackLogger.data(
        f"GTFS bundle: {len(all_routes)} routes, "
        f"{total_branches} branches, {len(all_stops)} stops"
    )

    return {
        "version": "3.1",
        "routes": all_routes,
        "stops": all_stops,
        "colors": all_colors,
        "stats": {
            "route_count": len(all_routes),
            "branch_count": total_branches,
            "stop_count": len(all_stops),
        },
    }


def get_route_colors() -> dict[str, str]:
    """Helper for router to get all colors."""
    bundle = generate_bundle()
    return bundle.get("colors", {})
