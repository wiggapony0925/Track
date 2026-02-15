
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
    """Return the official MTA hex color for a given subway line ID."""
    line_id = clean_route_id(line_id)
    if not line_id:
        return "#808183"
    
    letter = line_id[0]
    
    # 1. Numbered Lines
    if letter in {"1", "2", "3", "4", "5", "6", "7"}:
        if letter in {"1", "2", "3"}: return "#EE352E" # Red
        if letter in {"4", "5", "6"}: return "#00933C" # Green
        return "#B933AD" # Purple (7)
    
    # 2. Shuttles & Staten Island (All Shuttles/SI are Gray)
    # We check this first so that FS/SR don't get family colors
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
