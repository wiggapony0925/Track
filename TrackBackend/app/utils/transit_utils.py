
"""
Transit Utilities
Algorithms for mapping route IDs to colors, feed groups, and display properties.
"""

def clean_route_id(line_id: str) -> str:
    """Standardize a route ID by removing brackets, whitespace, and converting to uppercase."""
    if not line_id:
        return ""
    return line_id.strip().upper().replace("<", "").replace(">", "")

def resolve_subway_feed_key(line_id: str) -> str | None:
    """Algorithmically map a subway Line ID to its corresponding URL key in settings.json."""
    line_id = clean_route_id(line_id)
    if not line_id:
        return None
    
    # 1. Numbered Lines (1, 2, 3, 4, 5, 6, 7) + 42nd St Shuttle (GS) 
    # all live in the primary 'gtfs' feed.
    if line_id[0].isdigit() or line_id == "GS":
        return "subway_123456"
        
    # 2. Map lettered lines and shuttles to their respective feeds
    feed_groups = {
        "subway_ace":  {"A", "C", "E", "SR", "H"},         # Eighth Ave + Rockaway
        "subway_bdfm": {"B", "D", "F", "FX", "M", "FS"},   # Sixth Ave + Franklin
        "subway_nqrw": {"N", "Q", "R", "W"},               # Broadway
        "subway_jz":   {"J", "Z"},                         # Nassau St
        "subway_l":    {"L"},                              # Canarsie
        "subway_g":    {"G"},                              # Crosstown
        "subway_si":   {"SI"}                              # Staten Island
    }
    
    for key, members in feed_groups.items():
        if line_id in members:
            return key
            
    return None

def get_subway_color(line_id: str) -> str:
    """Return the official MTA hex color for a given subway line ID or Rail Branch."""
    if not line_id:
        return "#808183"

    # 0. Check strict Rail Branch Names FIRST (before cleaning removes spaces/case)
    # This prevents "Ronkonkoma Branch" from matching "R" subway logic
    rail_names = {
        "Babylon Branch": "#00985F",
        "Belmont Park Branch": "#60269E",
        "City Terminal Zone": "#4D5357",
        "Far Rockaway Branch": "#6E3219",
        "Hempstead Branch": "#CE8E00",
        "Long Beach Branch": "#FF6319",
        "Montauk Branch": "#00B2A9",
        "Oyster Bay Branch": "#00AF3F",
        "Port Jefferson Branch": "#006EC7",
        "Port Washington Branch": "#C60C30",
        "Ronkonkoma Branch": "#A626AA",
        "West Hempstead Branch": "#00A1DE",
        "Harlem Line": "#0039A6",
        "Hudson Line": "#009B3A",
        "New Haven Line": "#E00034",
        "Pascack Valley Line": "#923D97",
        "Port Jervis Line": "#FF7900",
        "Staten Island Railway": "#08179C" 
    }
    
    if line_id in rail_names:
        return rail_names[line_id]

    line_id = clean_route_id(line_id)
    if not line_id:
        return "#808183"
    
    letter = line_id[0]
    
    # 1. Numbered Lines (Strict check to avoid matching LIRR IDs like "10")
    # Only 1-7 (and express variants) are subway lines.
    is_subway_numbered = line_id in {"1", "2", "3", "4", "5", "5X", "6", "6X", "7", "7X"}
    
    if is_subway_numbered:
        if letter in {"1", "2", "3"}: return "#EE352E" # Red
        if letter in {"4", "5", "6"}: return "#00933C" # Green
        return "#B933AD" # Purple (7)
    
    # 2. Commuter Rail (LIRR & Metro-North)
    # Map Route IDs/Names to official colors
    
    # LIRR Route IDs (numeric in GTFS) -> Hex
    lirr_id_map = {
        "1": "#00985F",  # Babylon
        "2": "#CE8E00",  # Hempstead
        "3": "#00AF3F",  # Oyster Bay
        "4": "#A626AA",  # Ronkonkoma
        "5": "#00B2A9",  # Montauk
        "6": "#FF6319",  # Long Beach
        "7": "#6E3219",  # Far Rockaway
        "8": "#00A1DE",  # West Hempstead
        "9": "#C60C30",  # Port Washington
        "10": "#006EC7", # Port Jefferson
        "11": "#60269E", # Belmont Park
        "12": "#4D5357", # City Terminal Zone
        "13": "#A626AA", # Greenport (Same as Ronkonkoma)
    }
    
    # Metro-North Route IDs -> Hex
    mnr_id_map = {
        "1": "#009B3A", # Hudson
        "2": "#0039A6", # Harlem
        "3": "#EE0034", # New Haven
        "4": "#EE0034", # New Canaan (Branch of NH)
        "5": "#EE0034", # Danbury (Branch of NH)
        "6": "#EE0034", # Waterbury (Branch of NH)
    }

    # Branch Name Mapping removed (handled at start of function)
        
    # Check numeric IDs ONLY if we know the context is Rail,
    # OR if the ID is > typical subway numbers (e.g. 10, 11, 12, 13)
    # This is tricky because LIRR "1" conflicts with Subway "1".
    # Best practice: The caller should prefix LIRR IDs (e.g. "LIRR_1")
    # But for robustness, we check for high numbers or if it's already cleared as not subway.
    
    if line_id.isdigit():
        lid = int(line_id)
        if lid >= 10 and str(lid) in lirr_id_map:
            return lirr_id_map[str(lid)]
            
    # Generic LIRR/MNR fallback if the branch isn't known but the ID implies rail
    if line_id in {"LIRR", "MNR", "METRO-NORTH", "PATH", "AIRTRAIN"}:
        return "#0039A6" # Generic MTA Blue
    
    if line_id in {"S", "GS", "FS", "SR", "SI", "H"}: 
        return "#808183" # Dark Gray

    # 3. Lettered Families
    # We only match if it's a single letter or a known express variant
    is_valid_subway = len(line_id) == 1 or line_id.endswith("X")
    
    if not is_valid_subway:
        return "#808183" # Fallback for buses/unknown

    if letter in {"A", "C", "E"}: return "#0039A6" # Blue
    if letter in {"B", "D", "F", "M"} or line_id == "FX": return "#FF6319" # Orange
    if letter in {"N", "Q", "R", "W"}: return "#FCCC0A" # Yellow
    if letter in {"J", "Z"}: return "#996633" # Brown
    
    # 4. Individual Lines
    if line_id == "L": return "#A7A9AC" # Gray (Canarsie)
    if line_id == "G": return "#6CBE45" # Lime (Crosstown)
    
    return "#808183" # Fallback

def get_all_subway_lines() -> list[str]:
    """Returns a clean list of all official subway lines for the system map."""
    return [
        "1", "2", "3", "4", "5", "6", "6X", "7", "7X",
        "A", "C", "E", "B", "D", "F", "FX", "M", "G",
        "J", "Z", "L", "N", "Q", "R", "W",
        "GS", "FS", "SR", "SI"
    ]
