
import sys
import os

# Add the parent directory to sys.path so we can import app
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from app.config import resolve_subway_feed_key
from app.utils.transit_utils import get_subway_color

def test_subway_mapping():
    tests = [
        # Numbers (1-7)
        ("1", "subway_123456", "#EE352E"),
        ("2", "subway_123456", "#EE352E"),
        ("3", "subway_123456", "#EE352E"),
        ("4", "subway_123456", "#00933C"),
        ("5", "subway_123456", "#00933C"),
        ("6", "subway_123456", "#00933C"),
        ("7", "subway_123456", "#B933AD"),
        
        # Express Numbers & Variants
        ("6X", "subway_123456", "#00933C"),
        ("7X", "subway_123456", "#B933AD"),
        ("<6>", "subway_123456", "#00933C"), # Bracketed variant
        ("<7>", "subway_123456", "#B933AD"),
        
        # Shuttles
        ("GS", "subway_123456", "#808183"), # 42nd St Shuttle
        ("FS", "subway_bdfm", "#808183"),   # Franklin Ave Shuttle
        ("SR", "subway_ace", "#808183"),    # Rockaway Park Shuttle (Standard Gray)
        ("H", "subway_ace", "#808183"),     # Rockaway Park Shuttle (Internal ID)
        ("S", None, "#808183"),            # Generic S (Maps to nothing specific in feed, but Gray)
        
        # Lettered Families
        ("A", "subway_ace", "#0039A6"), ("C", "subway_ace", "#0039A6"), ("E", "subway_ace", "#0039A6"),
        ("B", "subway_bdfm", "#FF6319"), ("D", "subway_bdfm", "#FF6319"), ("F", "subway_bdfm", "#FF6319"), 
        ("FX", "subway_bdfm", "#FF6319"), ("M", "subway_bdfm", "#FF6319"),
        ("N", "subway_nqrw", "#FCCC0A"), ("Q", "subway_nqrw", "#FCCC0A"), ("R", "subway_nqrw", "#FCCC0A"), ("W", "subway_nqrw", "#FCCC0A"),
        ("L", "subway_l", "#A7A9AC"), ("G", "subway_g", "#6CBE45"),
        ("J", "subway_jz", "#996633"), ("Z", "subway_jz", "#996633"),
        ("SI", "subway_si", "#808183"),
        
        # Bus Routes (Should NOT match subway feeds, should be Gray)
        ("Bx1", None, "#808183"), ("B38", None, "#808183"), ("M15", None, "#808183"), 
        ("Q10", None, "#808183"), ("S79", None, "#808183"), ("M15-SBS", None, "#808183"),
        
        # Express Bus
        ("BM1", None, "#808183"), ("QM2", None, "#808183"), ("SIM1C", None, "#808183"),
        
        # Commuter Rail (Should NOT match subway feeds, should be Gray)
        ("LIRR", None, "#808183"), ("MNR", None, "#808183"), ("METRO-NORTH", None, "#808183"),
        ("PATH", None, "#808183"), ("AIRTRAIN", None, "#808183"),
        
        # Edge Cases
        ("a", "subway_ace", "#0039A6"), # Case insensitivity
        (" 1 ", "subway_123456", "#EE352E"), # Whitespace
        ("", None, "#808183"), # Empty
        ("9", "subway_123456", "#808183"), # Future number
    ]
    
    passed = 0
    failed = 0
    
    print("\n🧪 Testing Transit Mapping Algorithm (Feed & Color)...")
    print("-" * 80)
    print(f"{'ID':<10} | {'FEED':<20} | {'COLOR':<10} | {'STATUS'}")
    print("-" * 80)
    
    for route_id_raw, exp_feed, exp_color in tests:
        route_id = route_id_raw.strip().upper()
        # Clean <6> to 6 for the algorithm if it doesn't handle brackets
        # but wait, the algorithm should be robust. Let's see if we need to clean it.
        
        feed = resolve_subway_feed_key(route_id)
        color = get_subway_color(route_id)
        
        passed_test = (feed == exp_feed and color == exp_color)
        status = "✅" if passed_test else "❌"
        
        if passed_test:
            passed += 1
        else:
            failed += 1
            
        print(f"{route_id_raw:<10} | {str(feed):<20} | {color:<10} | {status}")
        if not passed_test:
            print(f"   Mismatch! Expected Feed: {exp_feed}, Color: {exp_color}")
            
    print("-" * 80)
    print(f"Summary: {passed} passed, {failed} failed.")
    
    if failed == 0:
        print("\n✨ ALL TESTS PASSED! The transit utilities are robust.")
    else:
        print(f"\n⚠️ {failed} tests failed. Check the logic.")

if __name__ == "__main__":
    test_subway_mapping()
