from __future__ import annotations

import io
import zipfile
from pathlib import Path

import requests

# URLs for MTA Data
# Note: These URLs are subject to change by the MTA.
URLS = {
    "subway": "http://web.mta.info/developers/data/nyct/subway/google_transit.zip",
    "lirr": "http://web.mta.info/developers/data/lirr/google_transit.zip",
    "metro_north": "http://web.mta.info/developers/data/mnr/google_transit.zip",
    "bus_bronx": "http://web.mta.info/developers/data/nyct/bus/google_transit_bronx.zip",
    "bus_brooklyn": "http://web.mta.info/developers/data/nyct/bus/google_transit_brooklyn.zip",
    "bus_manhattan": "http://web.mta.info/developers/data/nyct/bus/google_transit_manhattan.zip",
    "bus_queens": "http://web.mta.info/developers/data/nyct/bus/google_transit_queens.zip",
    "bus_staten_island": "http://web.mta.info/developers/data/nyct/bus/google_transit_staten_island.zip",
    "bus_mta": "http://web.mta.info/developers/data/busco/google_transit.zip",
}

# Mapping URLs to local directories
# This matches the structure expected by ingest_gtfs.py
DATA_DIR = Path("app/data")
MAPPINGS = {
    "subway": DATA_DIR / "subway/supplemented_GTFS",
    "lirr": DATA_DIR / "lirr/gtfslirr",
    "metro_north": DATA_DIR / "metro_north/gtfsmnr",
    "bus_bronx": DATA_DIR / "bus/Bronx",
    "bus_brooklyn": DATA_DIR / "bus/Brooklyn",
    "bus_manhattan": DATA_DIR / "bus/Manhattan",
    "bus_queens": DATA_DIR / "bus/Queens",
    "bus_staten_island": DATA_DIR / "bus/Staten Island",
    "bus_mta": DATA_DIR / "MTA Bus Company",
}


def download_and_unzip(url, dest_dir):
    """Downloads a ZIP from url and extracts it to dest_dir."""
    print(f"⬇️  Downloading {url}...")
    try:
        r = requests.get(url, stream=True)
        r.raise_for_status()

        print(f"📦 Extracting to {dest_dir}...")
        dest_dir.mkdir(parents=True, exist_ok=True)

        with zipfile.ZipFile(io.BytesIO(r.content)) as z:
            z.extractall(dest_dir)

        print(f"✅ Done: {dest_dir}")

    except Exception as e:
        print(f"❌ Failed to download/extract {url}: {e}")


def main():
    print("🚀 Starting GTFS Data Download...")
    print("   Target Directory: TrackBackend/app/data")

    # Ensure we are running from the correct directory or adjust paths
    # Assuming running from TrackBackend/

    for key, url in URLS.items():
        dest = MAPPINGS.get(key)
        if dest:
            # Check if data already exists to avoid unnecessary downloads?
            # For now, let's force update or maybe check for a key file.
            # if (dest / "stop_times.txt").exists():
            #    print(f"⚠️  Skipping {key} (Data already exists)")
            #    continue

            download_and_unzip(url, dest)

    print(
        "\n✨ All downloads complete. You can now run ingest_gtfs.py to build the database."
    )


if __name__ == "__main__":
    main()
