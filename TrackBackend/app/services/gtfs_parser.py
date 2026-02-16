"""
GTFS Parser Service

Parses static GTFS data (shapes.txt, stops.txt) to provide offline route data.
Supports Subway, LIRR, and Metro-North with automatic prefixing to avoid ID collisions.
"""

import csv
import re
from pathlib import Path
from typing import Dict, List, Any
from collections import defaultdict
from functools import lru_cache

from app.utils.transit_utils import get_subway_color

# Path to GTFS data directory
DEFAULT_DATA_DIR = Path(__file__).parent.parent / "data"

def parse_shapes(agency_dir: Path) -> Dict[str, List[Dict[str, float]]]:
    """Parse shapes.txt to get route polylines."""
    shapes_file = agency_dir / "shapes.txt"
    if not shapes_file.exists():
        return {}
    
    shapes: Dict[str, List[tuple]] = defaultdict(list)
    
    with open(shapes_file, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            shape_id = row.get('shape_id', '')
            try:
                sequence = int(row.get('shape_pt_sequence', 0))
                lat = float(row.get('shape_pt_lat', 0))
                lon = float(row.get('shape_pt_lon', 0))
                shapes[shape_id].append((sequence, lat, lon))
            except (ValueError, TypeError):
                continue
    
    result = {}
    for shape_id, points in shapes.items():
        sorted_points = sorted(points, key=lambda x: x[0])
        result[shape_id] = [{"lat": lat, "lon": lon} for _, lat, lon in sorted_points]
    
    return result

def parse_stops(agency_dir: Path, prefix: str = "") -> List[Dict[str, Any]]:
    """Parse stops.txt to get station data."""
    stops_file = agency_dir / "stops.txt"
    if not stops_file.exists():
        return []
    
    stops = []
    with open(stops_file, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            stop_id = row.get('stop_id', '')
            
            # Prefix the stop ID for rail to avoid collisions
            if prefix:
                stop_id = f"{prefix}_{stop_id}"
                
            loc_type = row.get('location_type', '0')
            
            # Subway: location_type=1 (stations) or 0 (stops)
            # Rail: usually location_type=0
            if loc_type == '1' or (loc_type == '0' and not any(s in stop_id for s in ['N', 'S'])):
                try:
                    stops.append({
                        "id": stop_id,
                        "name": row.get('stop_name', ''),
                        "lat": float(row.get('stop_lat', 0)),
                        "lon": float(row.get('stop_lon', 0))
                    })
                except ValueError:
                    continue
    return stops

@lru_cache(maxsize=10)
def _get_shape_to_route_map(agency_dir: Path) -> Dict[str, str]:
    """Build a mapping from shape_id to route_id using trips.txt."""
    trips_file = agency_dir / "trips.txt"
    mapping = {}
    if trips_file.exists():
        with open(trips_file, 'r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                sid = row.get('shape_id')
                rid = row.get('route_id')
                if sid and rid:
                    mapping[sid] = rid
    return mapping

def get_routes_with_shapes(agency_dir: Path, prefix: str = "") -> Dict[str, List[List[Dict[str, float]]]]:
    """Group shapes by route ID, preserving all branches."""
    shapes = parse_shapes(agency_dir)
    sid_to_rid = _get_shape_to_route_map(agency_dir)
    
    route_shapes = defaultdict(list)
    for sid, coords in shapes.items():
        rid = sid_to_rid.get(sid)
        if not rid:
            # Fallback for subway IDs like "A..N03R"
            if '..' in sid:
                rid = sid.split('..')[0]
            else:
                rid = sid
        
        # Apply agency prefix to route ID
        if prefix:
            rid = f"{prefix}_{rid}"
            
        if len(coords) < 5: continue
        
        # Branch detection
        start = (round(coords[0]['lat'], 4), round(coords[0]['lon'], 4))
        end = (round(coords[-1]['lat'], 4), round(coords[-1]['lon'], 4))
        branch_key = frozenset([start, end])
        
        route_shapes[rid].append((branch_key, coords))

    final_routes = {}
    for rid, branch_list in route_shapes.items():
        unique_branches = {}
        for bkey, coords in branch_list:
            if bkey not in unique_branches or len(coords) > len(unique_branches[bkey]):
                unique_branches[bkey] = coords
        final_routes[rid] = list(unique_branches.values())
        
    return final_routes

def generate_bundle() -> Dict[str, Any]:
    """Generate complete static data bundle for iOS app including prefixed Rail."""
    subway_dir = DEFAULT_DATA_DIR / "subway/supplemented_GTFS"
    lirr_dir = DEFAULT_DATA_DIR / "lirr/gtfslirr"
    mnr_dir = DEFAULT_DATA_DIR / "metro_north/gtfsmnr"
    
    all_routes = {}
    # Subway stays unprefixed (backwards compat)
    all_routes.update(get_routes_with_shapes(subway_dir)) 
    # Rail gets prefixed to avoid collision (e.g. LIRR_1 vs Subway 1)
    all_routes.update(get_routes_with_shapes(lirr_dir, prefix="LIRR"))
    all_routes.update(get_routes_with_shapes(mnr_dir, prefix="MNR"))
    
    all_stops = []
    all_stops.extend(parse_stops(subway_dir))
    all_stops.extend(parse_stops(lirr_dir, prefix="LIRR"))
    all_stops.extend(parse_stops(mnr_dir, prefix="MNR"))
    
    all_colors = {}
    for rid in all_routes.keys():
        color = get_subway_color(rid)
        all_colors[rid] = color.lstrip('#')
    
    total_branches = sum(len(b) for b in all_routes.values())
    
    return {
        "version": "3.1",
        "routes": all_routes,
        "stops": all_stops,
        "colors": all_colors,
        "stats": {
            "route_count": len(all_routes),
            "branch_count": total_branches,
            "stop_count": len(all_stops)
        }
    }

def get_route_colors() -> Dict[str, str]:
    """Helper for router to get all colors."""
    bundle = generate_bundle()
    return bundle.get("colors", {})
