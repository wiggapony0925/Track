#!/usr/bin/env python3
"""
Generate Static Bundle

Generates a JSON bundle of static GTFS data for the iOS app.
This bundle is included in the app for offline operation.

Usage:
    cd TrackBackend
    python scripts/generate_static_bundle.py
"""

import sys
import json
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from app.services.gtfs_parser import generate_bundle


def main():
    print("🚇 Generating static GTFS bundle for iOS...")
    
    # Generate the bundle
    bundle = generate_bundle()
    
    # Output paths - changed to Track/Data folder
    output_dir = Path(__file__).parent.parent.parent / "Track" / "Data"
    output_file = output_dir / "subway_bundle.json"
    
    # Ensure output directory exists
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Write JSON file (compact for app size)
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(bundle, f, separators=(',', ':'))
    
    # Print stats with branch count for multi-branch routes
    routes = bundle.get('routes', {})
    total_branches = sum(len(branches) for branches in routes.values())
    stats = bundle.get('stats', {})
    
    print(f"✅ Bundle generated!")
    print(f"   Routes: {len(routes)}")
    print(f"   Branches: {total_branches} (multi-terminus routes like A train include all variants)")
    print(f"   Stops: {len(bundle.get('stops', []))}")
    print(f"   Colors: {len(bundle.get('colors', {}))}")
    print(f"   Version: {bundle.get('version', '?')}")
    print(f"   Output: {output_file}")
    print(f"   Size: {output_file.stat().st_size / 1024:.1f} KB")


if __name__ == "__main__":
    main()
