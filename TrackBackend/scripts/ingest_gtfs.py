from __future__ import annotations

import csv
import sqlite3
from pathlib import Path

# Path to the database
DB_PATH = Path("app/data/transit_schedule.db")


def create_schema(conn):
    """Create the SQLite schema for GTFS data."""
    cursor = conn.cursor()

    # 1. Stops Table
    cursor.execute("DROP TABLE IF EXISTS stops")
    cursor.execute("""
    CREATE TABLE stops (
        stop_id TEXT PRIMARY KEY,
        stop_name TEXT,
        stop_lat REAL,
        stop_lon REAL
    )
    """)

    # 2. Routes Table
    cursor.execute("DROP TABLE IF EXISTS routes")
    cursor.execute("""
    CREATE TABLE routes (
        route_id TEXT PRIMARY KEY,
        route_short_name TEXT,
        route_long_name TEXT,
        route_color TEXT,
        route_type INTEGER
    )
    """)

    # 3. Trips Table
    cursor.execute("DROP TABLE IF EXISTS trips")
    cursor.execute("""
    CREATE TABLE trips (
        trip_id TEXT PRIMARY KEY,
        route_id TEXT,
        service_id TEXT,
        trip_headsign TEXT,
        direction_id INTEGER
    )
    """)

    # 4. Stop Times Table
    cursor.execute("DROP TABLE IF EXISTS stop_times")
    cursor.execute("""
    CREATE TABLE stop_times (
        trip_id TEXT,
        arrival_time TEXT,
        departure_time TEXT,
        stop_id TEXT,
        stop_sequence INTEGER
    )
    """)

    # 5. Calendar Dates Table
    cursor.execute("DROP TABLE IF EXISTS calendar_dates")
    cursor.execute("""
    CREATE TABLE calendar_dates (
        service_id TEXT,
        date TEXT,
        exception_type INTEGER
    )
    """)

    conn.commit()


def create_indices(conn):
    """Create indices after ingestion for massive speed boost."""
    print("⚡ Creating indices (this might take a moment)...")
    cursor = conn.cursor()
    cursor.execute("CREATE INDEX idx_stop_times_stop ON stop_times(stop_id)")
    cursor.execute("CREATE INDEX idx_stop_times_arrival ON stop_times(arrival_time)")
    cursor.execute("CREATE INDEX idx_trips_service ON trips(service_id)")
    cursor.execute("CREATE INDEX idx_calendar_date ON calendar_dates(date)")
    conn.commit()


def ingest_file(conn, file_path, table_name, mapping):
    """Generic CSV ingestor for GTFS files."""
    if not file_path.exists():
        print(f"⚠️ Skip: {file_path} not found")
        return

    cursor = conn.cursor()
    with open(file_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)

        # Prepare SQL
        placeholders = ", ".join(["?"] * len(mapping))
        columns = ", ".join(mapping.keys())
        sql = f"INSERT OR REPLACE INTO {table_name} ({columns}) VALUES ({placeholders})"

        batch = []
        count = 0
        for row in reader:
            vals = []
            for csv_col in mapping.values():
                vals.append(row.get(csv_col, "").strip())
            batch.append(tuple(vals))

            if len(batch) >= 10000:
                cursor.executemany(sql, batch)
                count += len(batch)
                batch = []

        if batch:
            cursor.executemany(sql, batch)
            count += len(batch)

    conn.commit()
    print(f"✅ Ingested {count} rows into {table_name} from {file_path.name}")


def run_ingestion():
    """Main entry point for GTFS ingestion."""
    print("🐘 Starting GTFS Ingestion into SQLite...")

    # Ensure data directory exists
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(DB_PATH)
    create_schema(conn)

    # Disable synchronous for faster ingestion
    conn.execute("PRAGMA synchronous = OFF")
    conn.execute("PRAGMA journal_mode = MEMORY")

    # 1. Subway Supplemented GTFS
    subway_path = Path("app/data/subway/supplemented_GTFS")
    if subway_path.exists():
        print("\n🚇 Processing Subway (Supplemented)...")
        ingest_file(
            conn,
            subway_path / "stops.txt",
            "stops",
            {
                "stop_id": "stop_id",
                "stop_name": "stop_name",
                "stop_lat": "stop_lat",
                "stop_lon": "stop_lon",
            },
        )
        ingest_file(
            conn,
            subway_path / "routes.txt",
            "routes",
            {
                "route_id": "route_id",
                "route_short_name": "route_short_name",
                "route_long_name": "route_long_name",
                "route_color": "route_color",
                "route_type": "route_type",
            },
        )
        ingest_file(
            conn,
            subway_path / "trips.txt",
            "trips",
            {
                "trip_id": "trip_id",
                "route_id": "route_id",
                "service_id": "service_id",
                "trip_headsign": "trip_headsign",
                "direction_id": "direction_id",
            },
        )
        ingest_file(
            conn,
            subway_path / "stop_times.txt",
            "stop_times",
            {
                "trip_id": "trip_id",
                "arrival_time": "arrival_time",
                "departure_time": "departure_time",
                "stop_id": "stop_id",
                "stop_sequence": "stop_sequence",
            },
        )
        ingest_file(
            conn,
            subway_path / "calendar_dates.txt",
            "calendar_dates",
            {
                "service_id": "service_id",
                "date": "date",
                "exception_type": "exception_type",
            },
        )

    # 2. LIRR GTFS
    lirr_path = Path("app/data/lirr/gtfslirr")
    if lirr_path.exists():
        print("\n🚆 Processing LIRR...")
        ingest_file(
            conn,
            lirr_path / "stops.txt",
            "stops",
            {
                "stop_id": "stop_id",
                "stop_name": "stop_name",
                "stop_lat": "stop_lat",
                "stop_lon": "stop_lon",
            },
        )
        ingest_file(
            conn,
            lirr_path / "routes.txt",
            "routes",
            {
                "route_id": "route_id",
                "route_short_name": "route_short_name",
                "route_long_name": "route_long_name",
                "route_color": "route_color",
                "route_type": "route_type",
            },
        )
        ingest_file(
            conn,
            lirr_path / "trips.txt",
            "trips",
            {
                "trip_id": "trip_id",
                "route_id": "route_id",
                "service_id": "service_id",
                "trip_headsign": "trip_headsign",
                "direction_id": "direction_id",
            },
        )
        ingest_file(
            conn,
            lirr_path / "stop_times.txt",
            "stop_times",
            {
                "trip_id": "trip_id",
                "arrival_time": "arrival_time",
                "departure_time": "departure_time",
                "stop_id": "stop_id",
                "stop_sequence": "stop_sequence",
            },
        )
        ingest_file(
            conn,
            lirr_path / "calendar_dates.txt",
            "calendar_dates",
            {
                "service_id": "service_id",
                "date": "date",
                "exception_type": "exception_type",
            },
        )

    # 3. Metro-North GTFS
    mnr_path = Path("app/data/metro_north/gtfsmnr")
    if mnr_path.exists():
        print("\n🚅 Processing Metro-North...")
        ingest_file(
            conn,
            mnr_path / "stops.txt",
            "stops",
            {
                "stop_id": "stop_id",
                "stop_name": "stop_name",
                "stop_lat": "stop_lat",
                "stop_lon": "stop_lon",
            },
        )
        # Note: LIRR/MNR often share routes/trips logic
        ingest_file(
            conn,
            mnr_path / "routes.txt",
            "routes",
            {
                "route_id": "route_id",
                "route_short_name": "route_short_name",
                "route_long_name": "route_long_name",
                "route_color": "route_color",
                "route_type": "route_type",
            },
        )
        ingest_file(
            conn,
            mnr_path / "trips.txt",
            "trips",
            {
                "trip_id": "trip_id",
                "route_id": "route_id",
                "service_id": "service_id",
                "trip_headsign": "trip_headsign",
                "direction_id": "direction_id",
            },
        )
        ingest_file(
            conn,
            mnr_path / "stop_times.txt",
            "stop_times",
            {
                "trip_id": "trip_id",
                "arrival_time": "arrival_time",
                "departure_time": "departure_time",
                "stop_id": "stop_id",
                "stop_sequence": "stop_sequence",
            },
        )
        ingest_file(
            conn,
            mnr_path / "calendar_dates.txt",
            "calendar_dates",
            {
                "service_id": "service_id",
                "date": "date",
                "exception_type": "exception_type",
            },
        )

    # 4. Bus GTFS (Borough-based)
    bus_base_path = Path("app/data/bus")
    if bus_base_path.exists():
        boroughs = [
            "Bronx",
            "Brooklyn",
            "Manhattan",
            "Queens",
            "Staten Island",
            "MTA Bus Company",
        ]
        for borough in boroughs:
            path = bus_base_path / borough
            if not path.exists():
                continue

            print(f"\n🚌 Processing Bus ({borough})...")
            ingest_file(
                conn,
                path / "stops.txt",
                "stops",
                {
                    "stop_id": "stop_id",
                    "stop_name": "stop_name",
                    "stop_lat": "stop_lat",
                    "stop_lon": "stop_lon",
                },
            )
            ingest_file(
                conn,
                path / "routes.txt",
                "routes",
                {
                    "route_id": "route_id",
                    "route_short_name": "route_short_name",
                    "route_long_name": "route_long_name",
                    "route_color": "route_color",
                    "route_type": "route_type",
                },
            )
            ingest_file(
                conn,
                path / "trips.txt",
                "trips",
                {
                    "trip_id": "trip_id",
                    "route_id": "route_id",
                    "service_id": "service_id",
                    "trip_headsign": "trip_headsign",
                    "direction_id": "direction_id",
                },
            )
            ingest_file(
                conn,
                path / "stop_times.txt",
                "stop_times",
                {
                    "trip_id": "trip_id",
                    "arrival_time": "arrival_time",
                    "departure_time": "departure_time",
                    "stop_id": "stop_id",
                    "stop_sequence": "stop_sequence",
                },
            )
            ingest_file(
                conn,
                path / "calendar_dates.txt",
                "calendar_dates",
                {
                    "service_id": "service_id",
                    "date": "date",
                    "exception_type": "exception_type",
                },
            )

    # Create indices at the end
    create_indices(conn)

    conn.close()
    print("\n✨ Ingestion complete! 'app/data/transit_schedule.db' is ready.")


if __name__ == "__main__":
    run_ingestion()
