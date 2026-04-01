#!/usr/bin/env python3
"""
fetch_mta_training_data.py
TrackBackend/scripts/

Download MTA open datasets from data.ny.gov (Socrata API) and store them
locally as JSON files in app/data/training/.

These files are ONLY used offline on your dev machine to train / retrain
the GBR delay model (delay_model.pkl).  They are never sent to production.
The pipeline is:

    data.ny.gov  →  app/data/training/*.json   (this script, ~2–4 GB total, 30 datasets)
         ↓
    train_model.py  (uses the JSON to build better training labels)
         ↓
    app/data/delay_model.pkl   (~487 KB — the ONLY file that goes to prod)
         ↓
    Docker + Supabase → Render cold-start download

Usage:
    cd TrackBackend
    source .venv/bin/activate
    python scripts/fetch_mta_training_data.py            # download all
    python scripts/fetch_mta_training_data.py --check    # show what's saved
    python scripts/fetch_mta_training_data.py --dataset bus_speeds_2025

Socrata API docs: https://dev.socrata.com/docs/queries/
No API key needed for public datasets (rate-limited to 1000 req/hr).
Register a free app token at https://data.ny.gov/profile/app_tokens
to raise the limit.  Pass via --token or env var SOCRATA_APP_TOKEN.
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

import requests

# ── Output directory ──────────────────────────────────────────────────────
# This folder is git-ignored.  It lives only on your dev machine.
TRAINING_DIR = Path(__file__).resolve().parent.parent / "app" / "data" / "training"

# ── Socrata dataset registry ──────────────────────────────────────────────
# Each entry:
#   id        — 4x4 Socrata dataset identifier  (from data.ny.gov URL)
#   filename  — local file saved to app/data/training/
#   columns   — the fields we actually need (reduces download size ~10×)
#   label     — human-readable description
#   limit     — max rows per page (Socrata max = 50_000)
#
# How each dataset improves the model:
#   bus_speeds_2023_2024 + bus_speeds_2025
#       → real measured travel_time / scheduled_time per route+hour+dow
#         replaces synthetic _RUSH_BUS / _WEATHER_EFFECTS bus priors
#         with 2+ years of actual GPS-derived measurements
#
#   subway_otp_2015_2019 + subway_otp_2020_2024 + subway_otp_2025
#       → terminal_on_time_performance (0–1 float) per subway line per month
#         replaces hand-coded ROUTE_RELIABILITY int tiers with real OTP rates
#         across 10 years of data (seasonal patterns, COVID dip, recovery)
#
#   bus_speeds_summary
#       → route-level average_speed, day_type, period (peak/off-peak)
#         faster to query than segment speeds; good for route-level reliability
#
DATASETS: dict[str, dict] = {
    # ── Bus: segment-level travel time per route × hour × dow ────────────
    # max_rows=500_000 — dataset has 15M+ rows total; 500k gives full route
    # coverage across all hours/days without exhausting RAM or taking hours
    "bus_speeds_2023_2024": {
        "id": "58t6-89vi",
        "filename": "bus_segment_speeds_2023_2024.json",
        "columns": "route_id,direction,hour_of_day,day_of_week,month,year,"
        "average_travel_time,average_road_speed,bus_trip_count,route_type,borough",
        "label": "Bus Route Segment Speeds 2023–2024",
        "limit": 50_000,
        "max_rows": 500_000,
    },
    "bus_speeds_2025": {
        "id": "kufs-yh3x",
        "filename": "bus_segment_speeds_2025.json",
        "columns": "route_id,direction,hour_of_day,day_of_week,month,year,"
        "average_travel_time,average_road_speed,bus_trip_count,route_type,borough",
        "label": "Bus Route Segment Speeds Beginning 2025",
        "limit": 50_000,
        "max_rows": 500_000,
    },
    # ── Bus: route-level speed summary (smaller, good for route reliability) ─
    "bus_speeds_summary": {
        "id": "cudb-vcni",
        "filename": "bus_speeds_summary.json",
        "columns": "route_id,trip_type,day_type,period,month,average_speed,"
        "total_mileage,total_operating_time,borough",
        "label": "Bus Speeds Beginning 2015",
        "limit": 50_000,
    },
    # ── Subway: terminal on-time performance per line per month ───────────
    "subway_otp_2015_2019": {
        "id": "f6rf-2a3t",
        "filename": "subway_otp_2015_2019.json",
        "columns": "line,month,day_type,terminal_on_time_performance,"
        "num_sched_trips,num_on_time_trips,division",
        "label": "Subway Terminal On-Time Performance 2015–2019",
        "limit": 50_000,
    },
    "subway_otp_2020_2024": {
        "id": "vtvh-gimj",
        "filename": "subway_otp_2020_2024.json",
        "columns": "line,month,day_type,terminal_on_time_performance,"
        "num_sched_trips,num_on_time_trips,division",
        "label": "Subway Terminal On-Time Performance 2020–2024",
        "limit": 50_000,
    },
    "subway_otp_2025": {
        "id": "ks33-g5ze",
        "filename": "subway_otp_2025.json",
        "columns": "line,month,day_type,terminal_on_time_performance,"
        "num_sched_trips,num_on_time_trips,division",
        "label": "Subway Terminal On-Time Performance Beginning 2025",
        "limit": 50_000,
    },
    # ── Subway: service delivered (% of scheduled trains that actually ran) ─
    # Tells the model which lines routinely run fewer trains than scheduled
    # → used to scale down confidence in predicted arrival for unreliable lines
    "subway_service_delivered_2015_2019": {
        "id": "32ch-sei3",
        "filename": "subway_service_delivered_2015_2019.json",
        "columns": "line,month,day_type,num_sched_trains,num_actual_trains,"
        "service_delivered,division",
        "label": "Subway Service Delivered 2015–2019",
        "limit": 50_000,
    },
    "subway_service_delivered_2020_2024": {
        "id": "bg59-42xi",
        "filename": "subway_service_delivered_2020_2024.json",
        "columns": "line,month,day_type,num_sched_trains,num_actual_trains,"
        "service_delivered,division",
        "label": "Subway Service Delivered 2020–2024",
        "limit": 50_000,
    },
    "subway_service_delivered_2025": {
        "id": "nmu4-7tz9",
        "filename": "subway_service_delivered_2025.json",
        "columns": "line,month,day_type,num_sched_trains,num_actual_trains,"
        "service_delivered,division",
        "label": "Subway Service Delivered Beginning 2025",
        "limit": 50_000,
    },
    # ── Subway: delay-causing incidents per line × month × category ───────
    # Tells the model HOW OFTEN and WHY delays happen on each line
    # → adds an incident_rate feature per route (incidents / scheduled_trips)
    # → category breakdown (crew, infrastructure, police/medical) enables
    #   category-specific boost factors in future model versions
    "subway_delay_incidents": {
        "id": "g937-7k7c",
        "filename": "subway_delay_incidents.json",
        "columns": "line,month,day_type,reporting_category,incidents,division",
        "label": "Subway Delay-Causing Incidents Beginning 2020",
        "limit": 50_000,
    },
    # ── Subway: major incidents (delayed 50+ trains) per line × month ─────
    # These are the worst events — signals, track, subway car failures
    # → used as a heavy-tail multiplier: if a line averages N major
    #   incidents/month, predicted factor gets a bump on rush-hour weekdays
    "subway_major_incidents_2015_2019": {
        "id": "ereg-mcvp",
        "filename": "subway_major_incidents_2015_2019.json",
        "columns": "line,month,day_type,category,count,division",
        "label": "Subway Major Incidents 2015–2019",
        "limit": 50_000,
    },
    "subway_major_incidents_2020_2024": {
        "id": "j6d2-s8m2",
        "filename": "subway_major_incidents_2020_2024.json",
        "columns": "line,month,day_type,category,count,division",
        "label": "Subway Major Incidents 2020–2024",
        "limit": 50_000,
    },
    "subway_major_incidents_2025": {
        "id": "uqnw-2qfk",
        "filename": "subway_major_incidents_2025.json",
        "columns": "line,month,day_type,category,count,division",
        "label": "Subway Major Incidents Beginning 2025",
        "limit": 50_000,
    },
    # ── Subway: total trains delayed per line × month × delay category ────
    # Complements major incidents — captures ALL delays not just worst ones
    # → ratio delays/scheduled_runs gives a per-line delay probability
    "subway_trains_delayed": {
        "id": "9zbp-wz3y",
        "filename": "subway_trains_delayed.json",
        "columns": "line,month,day_type,reporting_category,delays,division",
        "label": "Subway Trains Delayed Beginning 2020",
        "limit": 50_000,
    },
    # ── Subway: hourly ridership per station complex ───────────────────────
    # Tells the model how crowded each station is at each hour
    # → crowding_index feature: high ridership → longer dwell times → more
    #   schedule deviation.  Covers 2017–present across all NYC subway stations
    # max_rows=1_000_000 — large dataset; 1M rows covers all stations + years needed
    "subway_ridership_2017_2019": {
        "id": "t69i-h2me",
        "filename": "subway_ridership_2017_2019.json",
        "columns": "station_complex_id,station_complex,transit_timestamp,"
        "ridership,transit_mode,borough",
        "label": "Subway Hourly Ridership 2017–2019",
        "limit": 50_000,
        "max_rows": 1_000_000,
    },
    "subway_ridership_2020_2024": {
        "id": "wujg-7c2s",
        "filename": "subway_ridership_2020_2024.json",
        "columns": "station_complex_id,station_complex,transit_timestamp,"
        "ridership,transit_mode,borough",
        "label": "Subway Hourly Ridership 2020–2024",
        "limit": 50_000,
        "max_rows": 1_000_000,
    },
    "subway_ridership_2025": {
        "id": "5wq4-mkjj",
        "filename": "subway_ridership_2025.json",
        "columns": "station_complex_id,station_complex,transit_timestamp,"
        "ridership,transit_mode,borough",
        "label": "Subway Hourly Ridership Beginning 2025",
        "limit": 50_000,
        "max_rows": 500_000,
    },
    # ── Bus: wait assessment (% of buses no more than 3 min over interval) ─
    # Bunching metric: low wait_assessment → buses bunch → arrival times
    # widely scattered → raise predicted factor for that route
    "bus_wait_assessment": {
        "id": "v4z4-2h6n",
        "filename": "bus_wait_assessment.json",
        "columns": "route_id,month,period,day_type,trip_type,borough,"
        "wait_assessment,number_of_scheduled_trips,"
        "number_of_trips_passing_wait",
        "label": "Bus Wait Assessment Beginning 2015",
        "limit": 50_000,
    },
    # ── Bus: service delivered (% of peak buses actually provided) ─────────
    # Same concept as subway_service_delivered — ghost bus detection
    # → routes with low service_delivered get a reliability penalty in training
    "bus_service_delivered": {
        "id": "6qwi-vjde",
        "filename": "bus_service_delivered.json",
        "columns": "route_id,month,period,day_type,trip_type,borough,"
        "actual_number_of_buses,scheduled_number_of_buses,service_delivered",
        "label": "Bus Service Delivered Beginning 2015",
        "limit": 50_000,
    },
    # ── Bus: customer journey time performance ────────────────────────────
    # additional_travel_time and additional_bus_stop_time are DIRECT measures
    # of how many extra minutes riders experience vs schedule
    # → the richest bus training signal: use as regression target (in minutes)
    #   instead of the synthetic delay factor we currently use
    "bus_customer_journey": {
        "id": "8mkn-d32t",
        "filename": "bus_customer_journey.json",
        "columns": "route_id,month,period,trip_type,borough,"
        "customer_journey_time,additional_travel_time,"
        "additional_bus_stop_time,number_of_customers",
        "label": "Bus Customer Journey-Focused Metrics Beginning 2017",
        "limit": 50_000,
    },
    # ── Subway: customer journey metrics per line × month × period ────────
    # additional_platform_time (APT) = avg extra wait above schedule (min)
    # additional_train_time (ATT)    = avg extra ride time above schedule (min)
    # customer_journey_time (CJTP)   = % trips completed within 5 min of sched
    # → THE best subway training signal — directly maps to what riders feel
    #   APT drives the "minutes_away" error the most; use APT as regression
    #   target per line × hour, replacing synthetic OTP-only approach
    "subway_customer_journey_2015_2019": {
        "id": "r7qk-6tcy",
        "filename": "subway_customer_journey_2015_2019.json",
        "columns": "line,month,period,division,"
        "additional_platform_time,additional_train_time,"
        "customer_journey_time,over_five_mins_perc,num_passengers",
        "label": "Subway Customer Journey-Focused Metrics 2015–2019",
        "limit": 50_000,
    },
    "subway_customer_journey_2020_2024": {
        "id": "4apg-4kt9",
        "filename": "subway_customer_journey_2020_2024.json",
        "columns": "line,month,period,division,"
        "additional_platform_time,additional_train_time,"
        "customer_journey_time,over_five_mins_perc,num_passengers",
        "label": "Subway Customer Journey-Focused Metrics 2020–2024",
        "limit": 50_000,
    },
    "subway_customer_journey_2025": {
        "id": "s4u6-t435",
        "filename": "subway_customer_journey_2025.json",
        "columns": "line,month,period,division,"
        "additional_platform_time,additional_train_time,"
        "customer_journey_time,over_five_mins_perc,num_passengers",
        "label": "Subway Customer Journey-Focused Metrics Beginning 2025",
        "limit": 50_000,
    },
    # ── LIRR: on-time performance by branch × month × period ─────────────
    # OTP = % trains arriving at final destination within 5:59 of schedule
    # Covers all LIRR branches (Babylon, Ronkonkoma, Port Washington, etc.)
    # → directly replaces hand-coded LIRR reliability tier with real branch OTP
    #   am_peak / pm_peak split enables rush-hour-specific corrections
    "lirr_otp": {
        "id": "6kq9-5ikh",
        "filename": "lirr_otp.json",
        "columns": "branch_line,month,otp,am_peak,pm_peak,off_peak",
        "label": "MTA LIRR On-Time Performance Beginning 2015",
        "limit": 50_000,
    },
    # ── Metro-North: on-time performance by line × month × period ────────
    # Same structure as LIRR OTP — covers Harlem, Hudson, New Haven lines
    # → replaces hand-coded Metro-North reliability tier with real OTP
    "metro_north_otp": {
        "id": "83hw-i6xw",
        "filename": "metro_north_otp.json",
        "columns": "branch_line,month,otp,am_peak,pm_peak,off_peak",
        "label": "MTA Metro-North On-Time Performance Beginning 2020",
        "limit": 50_000,
    },
    # ── Subway: elevator and escalator availability per station × month ───
    # Outages increase effective walk time to/from platforms
    # → stations with high outage rates (e.g. 23rd St, 59th St Columbus)
    #   get a small dwell-time penalty in the crowding feature
    "subway_elevator_escalator": {
        "id": "rc78-7x78",
        "filename": "subway_elevator_escalator.json",
        "columns": "station_complex_name,station_name,borough,equipment_type,"
        "month,_24_hour_availability,am_peak_availability,"
        "pm_peak_availability,unscheduled_outages,total_outages",
        "label": "Subway Elevator and Escalator Availability Beginning 2015",
        "limit": 50_000,
    },
    # ── MTA: service alerts archive by line/agency ─────────────────────────
    # Every alert ever published — type, affected routes, date, description
    # → allows model to learn: line X had N alerts/month historically → scale
    #   up predicted delay factor for that line's reliability encoding
    # → also useful to tag specific time windows as "disrupted" in training
    # max_rows=500_000 — 5+ years of alerts; sample is representative
    "mta_service_alerts": {
        "id": "7kct-peq7",
        "filename": "mta_service_alerts.json",
        "columns": "agency,affected,status_label,date,event_id,header",
        "label": "MTA Service Alerts Beginning April 2020",
        "limit": 50_000,
        "max_rows": 500_000,
    },
    # ── MTA: daily ridership all modes 2020–present ────────────────────────
    # Updated daily — gives systemwide demand level by day and mode
    # → normalize hourly predictions by daily_ridership / baseline to capture
    #   demand spikes (events, holidays, weather closures)
    "mta_daily_ridership": {
        "id": "sayj-mze2",
        "filename": "mta_daily_ridership.json",
        "columns": "date,mode,count",
        "label": "MTA Daily Ridership and Traffic Beginning 2020",
        "limit": 50_000,
    },
    # ── Bus: hourly ridership by route × fare type ────────────────────────
    # Hour-level demand per route (bus_route, transit_timestamp, ridership)
    # → crowding feature for bus: high ridership hours see higher dwell time
    #   and slower boarding → larger additional_travel_time → higher factor
    # max_rows=500_000 — very large dataset; representative sample sufficient
    "bus_hourly_ridership_2020_2024": {
        "id": "kv7t-n8in",
        "filename": "bus_hourly_ridership_2020_2024.json",
        "columns": "transit_timestamp,bus_route,ridership,transfers,"
        "fare_class_category",
        "label": "MTA Bus Hourly Ridership 2020–2024",
        "limit": 50_000,
        "max_rows": 500_000,
    },
    "bus_hourly_ridership_2025": {
        "id": "gxb3-akrn",
        "filename": "bus_hourly_ridership_2025.json",
        "columns": "transit_timestamp,bus_route,ridership,transfers,"
        "fare_class_category",
        "label": "MTA Bus Hourly Ridership Beginning 2025",
        "limit": 50_000,
        "max_rows": 500_000,
    },
}

BASE_URL = "https://data.ny.gov/resource/{id}.json"


def _fetch_all(
    dataset_id: str,
    columns: str,
    limit: int,
    token: str | None,
    max_rows: int | None = None,
) -> list[dict]:
    """Paginate through a Socrata dataset and return rows.

    If max_rows is set, stops after collecting that many rows — useful for
    extremely large datasets (10M+ rows) where a representative sample is
    sufficient for model training.
    """
    url = BASE_URL.format(id=dataset_id)
    headers: dict[str, str] = {"Accept": "application/json"}
    if token:
        headers["X-App-Token"] = token

    rows: list[dict] = []
    offset = 0
    page = 0

    while True:
        page += 1
        params = {
            "$select": columns,
            "$limit": limit,
            "$offset": offset,
            "$order": ":id",  # stable sort for pagination
        }
        print(f"    page {page}  offset={offset:,} ...", end=" ", flush=True)

        try:
            resp = requests.get(url, headers=headers, params=params, timeout=60)
            resp.raise_for_status()
        except requests.RequestException as exc:
            print(f"ERROR: {exc}")
            raise

        page_rows = resp.json()
        count = len(page_rows)
        print(f"{count} rows")
        rows.extend(page_rows)

        if count < limit:
            break  # last page

        offset += limit

        # Stop early if we've hit the per-dataset row cap
        if max_rows and len(rows) >= max_rows:
            print(f"    ↳ reached max_rows cap ({max_rows:,}) — stopping early")
            rows = rows[:max_rows]
            break

        time.sleep(0.3)  # be polite to the API

    return rows


def download(names: list[str], token: str | None) -> None:
    TRAINING_DIR.mkdir(parents=True, exist_ok=True)

    for name in names:
        meta = DATASETS[name]
        out_path = TRAINING_DIR / meta["filename"]

        print(f"\n{'='*60}")
        print(f"  {meta['label']}")
        print(f"  dataset id : {meta['id']}")
        print(f"  saving to  : {out_path.relative_to(Path.cwd())}")
        print(f"{'='*60}")

        try:
            rows = _fetch_all(
                meta["id"],
                meta["columns"],
                meta["limit"],
                token,
                max_rows=meta.get("max_rows"),
            )
        except Exception as exc:
            print(f"  ✗ FAILED: {exc}")
            continue

        with open(out_path, "w") as f:
            json.dump(rows, f, indent=None, separators=(",", ":"))

        size_kb = out_path.stat().st_size / 1024
        print(f"  ✓ saved {len(rows):,} rows  ({size_kb:,.0f} KB)")


def check() -> None:
    """Print what's already downloaded and how many rows each file has."""
    print(f"\nTraining data directory: {TRAINING_DIR}\n")
    for name, meta in DATASETS.items():
        path = TRAINING_DIR / meta["filename"]
        if path.exists():
            with open(path) as f:
                data = json.load(f)
            size_kb = path.stat().st_size / 1024
            print(
                f"  ✓ {name:<28}  {len(data):>8,} rows  {size_kb:>8,.0f} KB  {meta['filename']}"
            )
        else:
            print(f"  ✗ {name:<28}  NOT DOWNLOADED")
    print()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Download MTA open datasets for GBR model training.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--dataset",
        "-d",
        choices=list(DATASETS.keys()),
        action="append",
        dest="datasets",
        metavar="DATASET",
        help=f"Download only this dataset. Repeatable. Choices: {', '.join(DATASETS)}",
    )
    parser.add_argument(
        "--check",
        "-c",
        action="store_true",
        help="Show what files are already downloaded, then exit.",
    )
    parser.add_argument(
        "--token",
        "-t",
        default=os.environ.get("SOCRATA_APP_TOKEN"),
        metavar="TOKEN",
        help="Socrata app token (optional, raises rate limit). "
        "Defaults to $SOCRATA_APP_TOKEN env var.",
    )
    args = parser.parse_args()

    if args.check:
        check()
        return

    targets = args.datasets or list(DATASETS.keys())

    print(f"\nDownloading {len(targets)} dataset(s) to {TRAINING_DIR}")
    if args.token:
        print(f"Using app token: {args.token[:8]}...")
    else:
        print(
            "No app token — rate-limited to ~1000 req/hr. "
            "Register free at https://data.ny.gov/profile/app_tokens"
        )

    download(targets, args.token)

    print("\nDone. Next step:")
    print("  python -m app.ml.train_model")
    print("  (or: python -m app.ml.train_model --real-data observations.csv)")


if __name__ == "__main__":
    main()
