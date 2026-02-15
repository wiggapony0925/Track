"""
GTFS Parser Service

Parses static GTFS data (shapes.txt, stops.txt) to provide offline route data.
"""

import csv
from pathlib import Path
from typing import Dict, List, Any
from collections import defaultdict

# Path to GTFS data directory
DATA_DIR = Path(__file__).parent.parent / "data"


def parse_shapes() -> Dict[str, List[Dict[str, float]]]:
    """
    Parse shapes.txt to get route polylines.
    
    Returns:
        Dict mapping shape_id to list of coordinates [{lat, lon}, ...]
    """
    shapes_file = DATA_DIR / "shapes.txt"
    if not shapes_file.exists():
        return {}
    
    shapes: Dict[str, List[tuple]] = defaultdict(list)
    
    with open(shapes_file, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            shape_id = row.get('shape_id', '')
            sequence = int(row.get('shape_pt_sequence', 0))
            lat = float(row.get('shape_pt_lat', 0))
            lon = float(row.get('shape_pt_lon', 0))
            
            shapes[shape_id].append((sequence, lat, lon))
    
    # Sort by sequence and convert to coordinate list
    result = {}
    for shape_id, points in shapes.items():
        sorted_points = sorted(points, key=lambda x: x[0])
        result[shape_id] = [
            {"lat": lat, "lon": lon} 
            for _, lat, lon in sorted_points
        ]
    
    return result


def parse_stops() -> List[Dict[str, Any]]:
    """
    Parse stops.txt to get station data.
    
    Returns:
        List of station dictionaries with id, name, lat, lon, routes
    """
    stops_file = DATA_DIR / "stops.txt"
    if not stops_file.exists():
        return []
    
    stops = []
    
    with open(stops_file, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            stop_id = row.get('stop_id', '')
            
            # Skip direction-specific stops (N/S suffixes)
            if stop_id.endswith('N') or stop_id.endswith('S'):
                continue
            
            # Skip child stations (location_type = 0 or empty)
            location_type = row.get('location_type', '0')
            if location_type != '1':
                continue
            
            stops.append({
                "id": stop_id,
                "name": row.get('stop_name', ''),
                "lat": float(row.get('stop_lat', 0)),
                "lon": float(row.get('stop_lon', 0))
            })
    
    return stops


def parse_routes() -> List[Dict[str, Any]]:
    """
    Parse routes.txt to get route metadata.
    
    Returns:
        List of route dictionaries with id, name, color
    """
    routes_file = DATA_DIR / "routes.txt" if (DATA_DIR / "routes.txt").exists() else None
    
    # Fallback to MTA colors CSV
    colors_file = DATA_DIR / "MTA_Colors_Lines_20260215.csv"
    
    routes = []
    
    # Try routes.txt first
    if routes_file and routes_file.exists():
        with open(routes_file, 'r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                routes.append({
                    "id": row.get('route_id', ''),
                    "name": row.get('route_short_name', '') or row.get('route_long_name', ''),
                    "color": row.get('route_color', '808080')
                })
    
    # Parse MTA colors CSV for official colors
    if colors_file.exists():
        route_colors = {}
        with open(colors_file, 'r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                service = row.get('Service', '')
                hex_color = row.get('Hex color', '').lstrip('#')
                
                # Parse route IDs from service (e.g., "A,C,E" -> ["A", "C", "E"])
                if ',' in service:
                    for route_id in service.split(','):
                        route_colors[route_id.strip()] = hex_color
                else:
                    route_colors[service.strip()] = hex_color
        
        # Update routes with official colors
        for route in routes:
            if route['id'] in route_colors:
                route['color'] = route_colors[route['id']]
    
    return routes


def get_route_colors() -> Dict[str, str]:
    """
    Get official MTA route colors.
    
    Returns:
        Dict mapping route_id to hex color
    """
    colors_file = DATA_DIR / "MTA_Colors_Lines_20260215.csv"
    
    if not colors_file.exists():
        # Hardcoded fallback colors
        return {
            "1": "EE352E", "2": "EE352E", "3": "EE352E",
            "4": "00933C", "5": "00933C", "6": "00933C",
            "7": "B933AD",
            "A": "0039A6", "C": "0039A6", "E": "0039A6",
            "B": "FF6319", "D": "FF6319", "F": "FF6319", "M": "FF6319",
            "G": "6CBE45",
            "J": "996633", "Z": "996633",
            "L": "A7A9AC",
            "N": "FCCC0A", "Q": "FCCC0A", "R": "FCCC0A", "W": "FCCC0A",
            "S": "808183"
        }
    
    colors = {}
    with open(colors_file, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            service = row.get('Service', '')
            hex_color = row.get('Hex color', '').lstrip('#')
            
            if ',' in service:
                for route_id in service.split(','):
                    colors[route_id.strip()] = hex_color
            else:
                colors[service.strip()] = hex_color
    
    return colors


def extract_route_id_from_shape(shape_id: str) -> str:
    """
    Extract route ID from shape ID.
    Shape IDs look like "1..N03R" -> "1"
    """
    if '..' in shape_id:
        return shape_id.split('..')[0]
    return shape_id


def get_routes_with_shapes() -> Dict[str, List[List[Dict[str, float]]]]:
    """
    Group shapes by route ID for route polylines.
    
    Returns:
        Dict mapping route_id to list of polylines (each polyline is a list of coordinates).
        This supports multi-branch routes like the A train (Lefferts, Far Rockaway, main).
    """
    shapes = parse_shapes()
    colors = get_route_colors()
    
    # Group ALL shapes by route (to support branches like A train's 3 branches)
    route_shapes: Dict[str, List[tuple]] = {}  # route_id -> [(shape_id, coordinates, endpoint_key), ...]
    
    for shape_id, coordinates in shapes.items():
        route_id = extract_route_id_from_shape(shape_id)
        
        # Skip very short shapes (likely partial/error data)
        if len(coordinates) < 10:
            continue
        
        # Create endpoint key for deduplication
        # 3 decimal places ≈ 111m at equator, sufficient for terminal deduplication
        start = coordinates[0]
        end = coordinates[-1]
        endpoint_key = (
            round(start['lat'], 3), round(start['lon'], 3),
            round(end['lat'], 3), round(end['lon'], 3)
        )
        
        if route_id not in route_shapes:
            route_shapes[route_id] = []
        
        route_shapes[route_id].append((shape_id, coordinates, endpoint_key))
    
    # Deduplicate: keep only unique branches based on endpoints
    # For routes with multiple variants of the same branch, keep the longest one
    routes: Dict[str, List[List[Dict[str, float]]]] = {}
    
    for route_id, shape_list in route_shapes.items():
        # Group by endpoint key and keep the longest shape for each endpoint pair
        endpoint_groups: Dict[tuple, List[Dict[str, float]]] = {}
        
        for shape_id, coordinates, endpoint_key in shape_list:
            if endpoint_key not in endpoint_groups or len(coordinates) > len(endpoint_groups[endpoint_key]):
                endpoint_groups[endpoint_key] = coordinates
        
        # Also group by reversed endpoints (same route, opposite direction)
        # We only want one direction per branch
        final_branches: Dict[frozenset, List[Dict[str, float]]] = {}
        
        for endpoint_key, coordinates in endpoint_groups.items():
            # Create a direction-agnostic key using frozenset of start/end coords
            start_coords = (endpoint_key[0], endpoint_key[1])
            end_coords = (endpoint_key[2], endpoint_key[3])
            direction_key = frozenset([start_coords, end_coords])
            
            # Keep the longest version of this branch
            if direction_key not in final_branches or len(coordinates) > len(final_branches[direction_key]):
                final_branches[direction_key] = coordinates
        
        routes[route_id] = list(final_branches.values())
    
    return routes


def generate_bundle() -> Dict[str, Any]:
    """
    Generate complete static data bundle for iOS app.
    
    Returns:
        Dict with routes (multi-branch), stops, and colors
    """
    routes_with_branches = get_routes_with_shapes()
    
    # Count total branches
    total_branches = sum(len(branches) for branches in routes_with_branches.values())
    
    return {
        "version": "2.0",  # Updated version to indicate multi-branch support
        "routes": routes_with_branches,  # Now Dict[route_id, List[List[coord]]]
        "stops": parse_stops(),
        "colors": get_route_colors(),
        "stats": {
            "route_count": len(routes_with_branches),
            "branch_count": total_branches
        }
    }
