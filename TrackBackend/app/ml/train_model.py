"""Bootstrap + train the LightGBM delay factor model.

Run from the TrackBackend directory:
python -m app.ml.train_model

── What this does ─────────────────────────────────────────────────────────

Phase 1 — Bootstrap from GTFS (works right now, zero extra data needed)
We have 8M+ stop_times rows in transit_schedule.db.  From those we
derive real facts about each route:
• Average stop count per trip (proxy for trip length / exposure to delay)
• Which hours each route actually runs (from scheduled departure times)
• Which modes the route belongs to (subway / bus / lirr / mnr)

We then generate synthetic training samples by sampling from distributions
that encode known MTA OTP (on-time performance) patterns:

delay_factor = base_for_route
+ rush_hour_effect
+ weather_effect
+ Gaussian noise (σ=0.03)

This is NOT making things up — it is encoding domain knowledge as a prior
so the model starts better than pure heuristics from day one.

Phase 2 — Real data (automatic over time)
Once the app is running, recency_model.py records actual vs. MTA-predicted
errors per stop into Redis.  Periodically export those to a CSV and rerun
this script with --real-data path/to/observations.csv to blend real and
bootstrapped samples.  The bootstrapped rows are down-weighted so real
data quickly dominates.

── Why LightGBM instead of sklearn GradientBoostingRegressor? ────────────
• 10–50× faster training on the same data (leaf-wise growth vs level-wise)
• Built-in early stopping — automatically stops adding trees when
validation error stops improving, preventing overfitting
• Handles large datasets (millions of rows) without OOM issues
• Same sklearn-compatible API: .fit() / .predict() / sample_weight
• Same .pkl output — no changes needed to delay_model.py or the API

── Output ─────────────────────────────────────────────────────────────────
app/data/delay_model.pkl  — joblib-serialised LightGBM ready to load."""

from __future__ import annotations

import argparse
import contextlib
import random
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any

from app.ml.delay_model import (
    ROUTE_RELIABILITY,
    encode_features,
)

# ── Paths ──────────────────────────────────────────────────────────────────
_ROOT = Path(__file__).resolve().parent.parent.parent  # TrackBackend/
_DB = _ROOT / "app" / "data" / "transit_schedule.db"
_OUT = _ROOT / "app" / "data" / "delay_model.pkl"

# ── Feature encoding (must match delay_model.py exactly) ──────────────────

# ── MTA on-time performance priors (public data, NYC Transit 2024 reports) ─
# Base delay factor at off-peak, clear weather for each reliability tier.
# Subway: ~80-85% on time → avg factor ≈ 1.05–1.08
# Bus:    ~55-65% on time → avg factor ≈ 1.10–1.18
_TIER_BASE: dict[int, float] = {
    0: 1.02,  # Tier 0 (L, SI) — very reliable
    1: 1.04,  # Tier 1 (7, W)
    2: 1.07,  # Tier 2 (most lines) — moderate chronic delay
    3: 1.10,  # Tier 3 (A/C/4/5/6) — frequently delayed
    4: 1.16,  # Tier 4 (G) — chronically delayed
}

# Rush-hour additive effect per mode tier
_RUSH_SUBWAY = 0.10
_RUSH_BUS = 0.20

# Weather additive effects
_WEATHER_EFFECTS: dict[str, dict[str, float]] = {
    "subway": {"clear": 0.0, "rain": 0.05, "snow": 0.20},
    "bus": {"clear": 0.0, "rain": 0.15, "snow": 0.30},
    "lirr": {"clear": 0.0, "rain": 0.08, "snow": 0.25},
    "mnr": {"clear": 0.0, "rain": 0.08, "snow": 0.25},
}

# Gaussian noise standard deviation (prevents overfitting to exact priors)
_NOISE_SIGMA = 0.03

# Samples per (route, hour_bucket, dow, weather) cell
_SAMPLES_PER_CELL = 3

# Hour buckets: we sample at representative hours rather than all 24
_HOUR_BUCKETS = [0, 6, 7, 8, 9, 10, 12, 15, 17, 18, 19, 20, 22]

# Day of week values (1=Sun … 7=Sat) in our convention
_WEEKDAYS = [2, 3, 4, 5, 6]
_WEEKENDS = [1, 7]


def _build_route_table(conn: sqlite3.Connection) -> dict[str, dict]:
    """Extract per-route facts from the GTFS DB."""
    print("  Reading routes and trips from GTFS DB ...", flush=True)

    # Map trip → route
    trip_to_route: dict[str, str] = {}
    for trip_id, route_id in conn.execute("SELECT trip_id, route_id FROM trips"):
        trip_to_route[trip_id] = route_id

    # Count stops per trip and accumulate per route
    stop_counts: dict[str, list[int]] = {}
    for row in conn.execute(
        "SELECT trip_id, COUNT(*) as cnt FROM stop_times GROUP BY trip_id"
    ):
        trip_id, cnt = row
        route_id = trip_to_route.get(trip_id)
        if route_id:
            stop_counts.setdefault(route_id, []).append(cnt)

    # Hours each route runs (from departure_time "HH:MM:SS" in stop_times)
    # Only look at sequence=1 stops for performance
    route_hours: dict[str, set[int]] = {}
    for trip_id, dep_time in conn.execute(
        "SELECT trip_id, departure_time FROM stop_times WHERE stop_sequence = 1"
    ):
        route_id = trip_to_route.get(trip_id)
        if not route_id:
            continue
        try:
            h = int(dep_time.split(":")[0]) % 24  # GTFS uses 25+ for overnight
            route_hours.setdefault(route_id, set()).add(h)
        except (ValueError, IndexError):
            pass

    # Build route info dict
    route_table: dict[str, dict] = {}
    for route_id, route_short, route_type in conn.execute(
        "SELECT route_id, route_short_name, route_type FROM routes"
    ):
        key = (route_short or route_id).upper()
        if "_" in key:
            key = key.split("_")[-1]

        # Map GTFS route_type to mode string
        mode = {0: "subway", 1: "subway", 2: "lirr", 3: "bus"}.get(route_type, "subway")
        # Override for commuter rails by route_id prefix
        rid_upper = route_id.upper()
        if rid_upper.startswith("LIRR"):
            mode = "lirr"
        elif rid_upper.startswith(("MNR", "METRO")):
            mode = "mnr"

        reliability = ROUTE_RELIABILITY.get(key, 2)
        avg_stops = 0
        if route_id in stop_counts:
            counts = stop_counts[route_id]
            avg_stops = sum(counts) / len(counts)

        route_table[route_id] = {
            "short": key,
            "mode": mode,
            "reliability": reliability,
            "avg_stops": avg_stops,
            "hours": route_hours.get(route_id, set(range(5, 24))),
        }

    print(f"  Built route table: {len(route_table)} routes", flush=True)
    return route_table


def _is_rush(hour: int, is_weekday: bool) -> bool:
    return is_weekday and (hour in range(7, 10) or hour in range(17, 20))


def _make_factor(
    reliability: int, mode: str, hour: int, is_weekday: bool, weather: str
) -> float:
    base = _TIER_BASE.get(reliability, 1.07)

    if _is_rush(hour, is_weekday):
        base += _RUSH_BUS if mode == "bus" else _RUSH_SUBWAY

    weather_effects = _WEATHER_EFFECTS.get(mode, _WEATHER_EFFECTS["subway"])
    base += weather_effects.get(weather, 0.0)

    # Small random noise so GBR has a smooth surface to fit
    noise = random.gauss(0, _NOISE_SIGMA)
    factor = max(1.0, min(2.0, base + noise))
    return round(factor, 4)


def generate_bootstrap_samples(
    route_table: dict[str, dict],
) -> tuple[list[list[float]], list[float], list[float]]:
    """Generate (X_rows, y_labels, sample_weights) from route table.

    Bootstrap samples have weight=0.5. Real observation samples (Phase 2)
    have weight=1.0.
    """
    print("  Generating bootstrap training samples ...", flush=True)
    random.seed(42)

    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []

    weathers = [
        "clear",
        "clear",
        "clear",
        "rain",
        "rain",
        "snow",
    ]  # realistic distribution

    for _route_id, info in route_table.items():
        reliability = info["reliability"]
        mode = info["mode"]
        short = info["short"]

        for hour in _HOUR_BUCKETS:
            if info["hours"] and hour not in info["hours"]:
                # Skip hours this route doesn't operate (reduces noise)
                continue

            for dow_group in [_WEEKDAYS, _WEEKENDS]:
                is_weekday = dow_group is _WEEKDAYS
                for dow in dow_group:
                    for weather in weathers:
                        for _ in range(_SAMPLES_PER_CELL):
                            factor = _make_factor(
                                reliability, mode, hour, is_weekday, weather
                            )
                            # Bootstrap delay_minutes: realistic spread around 0
                            # (mean 0 = on-time, sigma ~1.5 min = observed MTA spread).
                            # Real observations will have actual deviations; the
                            # bootstrap primes the surface so the model learns
                            # the momentum direction immediately.
                            bootleg_delay_s = random.gauss(0, 90)  # ~N(0, 1.5 min)
                            feats = encode_features(
                                short,
                                hour,
                                dow,
                                weather,
                                mode,
                                current_delay_s=bootleg_delay_s,
                            )
                            X.append(feats)
                            y.append(factor)
                            w.append(0.5)  # bootstrap weight (real data = 1.0)

    print(f"  Generated {len(X):,} bootstrap samples", flush=True)
    return X, y, w


def load_mta_open_data() -> tuple[list[list[float]], list[float], list[float]]:
    """Load all available MTA open JSON files from app/data/training/ and
    generate high-quality training samples.

    Sample weights:
      0.8 — MTA open data (real per-line measurements, better than bootstrap)
      0.6 — incident-derived samples (less direct signal)
      0.5 — bootstrap (synthetic priors, fallback when JSON missing)

    Feature order must match encode_features():
      [route_reliability, hour, dow, weather_enc, mode_enc,
       is_rush, is_weekend, delay_minutes]
    """
    import json
    from collections import defaultdict

    TRAINING_DIR = _ROOT / "app" / "data" / "training"
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []

    if not TRAINING_DIR.exists():
        print("  No training/ directory — skipping MTA open data.", flush=True)
        return X, y, w

    # ── Helpers ────────────────────────────────────────────────────────────
    def _period_hours(period: str) -> list[int]:
        """Map a Socrata 'period' string to representative hour integers."""
        p = (period or "").lower()
        if "am peak" in p or ("peak" in p and "am" in p):
            return [7, 8, 9]
        if "pm peak" in p or ("peak" in p and "pm" in p):
            return [17, 18, 19]
        if "peak" in p:
            return [7, 8, 9, 17, 18, 19]
        return [6, 10, 12, 14, 20, 22]  # off-peak

    def _dow_for_day_type(day_type: str) -> list[int]:
        """day_type '1'=weekday '2'=weekend → list of dow values."""
        return [2, 3, 4, 5, 6] if str(day_type) == "1" else [1, 7]

    def _clamp(v: float, lo: float = 1.0, hi: float = 2.0) -> float:
        return max(lo, min(hi, v))

    def _feats(
        reliability: float, hour: int, dow: int, weather: float, mode: float
    ) -> list[float]:
        is_weekday = 2 <= dow <= 6
        is_rush = float(is_weekday and (hour in range(7, 10) or hour in range(17, 20)))
        return [
            reliability,
            float(hour),
            float(dow),
            weather,
            mode,
            is_rush,
            float(not is_weekday),
            0.0,
        ]

    # ── Step 1: Build per-line OTP reliability from subway OTP JSON files ──
    # Accumulate as running totals so we can average across all three files
    otp_accum: dict[str, list[float]] = defaultdict(list)
    for fname in [
        "subway_otp_2015_2019.json",
        "subway_otp_2020_2024.json",
        "subway_otp_2025.json",
    ]:
        p = TRAINING_DIR / fname
        if not p.exists():
            continue
        for row in json.loads(p.read_text()):
            line = (row.get("line") or "").upper().strip()
            with contextlib.suppress(KeyError, ValueError, TypeError):
                otp_accum[line].append(float(row["terminal_on_time_performance"]))

    # Map OTP → reliability float  (0 = perfect, 4 = very unreliable)
    # 100% OTP → 0.0,  75% OTP → 2.0,  50% OTP → 4.0
    line_reliability: dict[str, float] = {}
    for line, vals in otp_accum.items():
        avg_otp = sum(vals) / len(vals)
        line_reliability[line] = _clamp((1.0 - avg_otp) * 8.0, 0.0, 4.0)
    print(
        f"  OTP reliability built for {len(line_reliability)} subway lines", flush=True
    )

    # ── Step 2: Subway customer journey — best per-line delay signal ───────
    # additional_platform_time (APT) = avg extra wait minutes above schedule
    # additional_train_time   (ATT) = avg extra ride minutes above schedule
    # factor = 1 + (apt + att) / 15  (15 min is a typical short-trip baseline)
    cj_count = 0
    for fname in [
        "subway_customer_journey_2015_2019.json",
        "subway_customer_journey_2020_2024.json",
        "subway_customer_journey_2025.json",
    ]:
        p = TRAINING_DIR / fname
        if not p.exists():
            continue
        for row in json.loads(p.read_text()):
            line = (row.get("line") or "").upper().strip()
            try:
                apt = float(row.get("additional_platform_time") or 0)
                att = float(row.get("additional_train_time") or 0)
            except (ValueError, TypeError):
                continue
            factor = _clamp(1.0 + (apt + att) / 15.0)
            rel = line_reliability.get(line, 2.0)
            period = row.get("period", "")
            day_type = str(row.get("day_type", "1"))
            for hr in _period_hours(period):
                for dow in _dow_for_day_type(day_type):
                    X.append(
                        _feats(rel, hr, dow, 0.0, 0.0)
                    )  # mode=subway, weather=clear
                    y.append(factor)
                    w.append(0.8)
                    cj_count += 1
    print(f"  Subway customer journey: {cj_count:,} samples", flush=True)

    # ── Step 3: LIRR OTP — per-branch, per-period ─────────────────────────
    lirr_count = 0
    p = TRAINING_DIR / "lirr_otp.json"
    if p.exists():
        for row in json.loads(p.read_text()):
            try:
                overall_otp = float(row.get("otp") or 0)
            except (ValueError, TypeError):
                continue
            for col, hours_list in [
                ("am_peak", [7, 8, 9]),
                ("pm_peak", [17, 18, 19]),
                ("off_peak", [12, 19, 20, 22]),
            ]:
                try:
                    period_otp = float(row.get(col) or overall_otp)
                except (ValueError, TypeError):
                    period_otp = overall_otp
                factor = _clamp(1.0 + (1.0 - period_otp) * 0.5)
                is_peak = col != "off_peak"
                for hr in hours_list:
                    for dow in ([2, 3, 4, 5, 6] if is_peak else [2, 3, 4, 5, 6, 1, 7]):
                        X.append(
                            _feats(2.0, hr, dow, 0.0, 2.0)
                        )  # mode=lirr, weather=clear
                        y.append(factor)
                        w.append(0.8)
                        lirr_count += 1
    print(f"  LIRR OTP: {lirr_count:,} samples", flush=True)

    # ── Step 4: Metro-North OTP ────────────────────────────────────────────
    mnr_count = 0
    p = TRAINING_DIR / "metro_north_otp.json"
    if p.exists():
        for row in json.loads(p.read_text()):
            try:
                overall_otp = float(row.get("otp") or 0)
            except (ValueError, TypeError):
                continue
            for col, hours_list in [
                ("am_peak", [7, 8, 9]),
                ("pm_peak", [17, 18, 19]),
                ("off_peak", [12, 19, 20, 22]),
            ]:
                try:
                    period_otp = float(row.get(col) or overall_otp)
                except (ValueError, TypeError):
                    period_otp = overall_otp
                factor = _clamp(1.0 + (1.0 - period_otp) * 0.5)
                for hr in hours_list:
                    for dow in [2, 3, 4, 5, 6]:
                        X.append(_feats(2.0, hr, dow, 0.0, 3.0))  # mode=mnr
                        y.append(factor)
                        w.append(0.8)
                        mnr_count += 1
    print(f"  Metro-North OTP: {mnr_count:,} samples", flush=True)

    # ── Step 5: Bus customer journey — extra travel time above schedule ────
    bus_cj_count = 0
    p = TRAINING_DIR / "bus_customer_journey.json"
    if p.exists():
        for row in json.loads(p.read_text()):
            try:
                att = float(row.get("additional_travel_time") or 0)
            except (ValueError, TypeError):
                continue
            # 10 min baseline for a city bus trip; att is extra minutes
            factor = _clamp(1.0 + att / 10.0)
            period = row.get("period", "")
            trip_type = (row.get("trip_type") or "").lower()
            day_type = (
                "1" if ("weekday" in trip_type or "peak" in period.lower()) else "2"
            )
            for hr in _period_hours(period):
                for dow in _dow_for_day_type(day_type):
                    X.append(_feats(2.0, hr, dow, 0.0, 1.0))  # mode=bus
                    y.append(factor)
                    w.append(0.8)
                    bus_cj_count += 1
    print(f"  Bus customer journey: {bus_cj_count:,} samples", flush=True)

    # ── Step 6: Bus wait assessment — bunching rate per route ─────────────
    # wait_assessment < 1.0 means buses bunch; use as reliability factor
    bus_wa_count = 0
    p = TRAINING_DIR / "bus_wait_assessment.json"
    if p.exists():
        wa_accum: dict[str, list[float]] = defaultdict(list)
        for row in json.loads(p.read_text()):
            route = (row.get("route_id") or "").upper().strip()
            with contextlib.suppress(KeyError, ValueError, TypeError):
                wa_accum[route].append(float(row["wait_assessment"]))
        for _route, vals in wa_accum.items():
            avg_wa = sum(vals) / len(vals)
            # Low wait_assessment = bunching = higher delay factor for bus
            factor = _clamp(1.0 + (1.0 - avg_wa) * 0.25)
            for hr in [8, 9, 12, 17, 18]:
                for dow in [2, 3, 4, 5, 6]:
                    is_rush = float(hr in range(7, 10) or hr in range(17, 20))
                    X.append([2.0, float(hr), float(dow), 0.0, 1.0, is_rush, 0.0, 0.0])
                    y.append(factor)
                    w.append(0.7)
                    bus_wa_count += 1
    print(f"  Bus wait assessment: {bus_wa_count:,} samples", flush=True)

    # ── Step 7: Subway delay incidents — monthly incident rate ────────────
    # incident rate → line gets a reliability penalty on peak hour weekdays
    inc_count = 0
    p = TRAINING_DIR / "subway_delay_incidents.json"
    if p.exists():
        inc_accum: dict[tuple, dict] = defaultdict(
            lambda: {"total": 0.0, "months": set()}
        )
        for row in json.loads(p.read_text()):
            line = (row.get("line") or "").upper().strip()
            try:
                count = float(row.get("incidents") or 0)
                month = row.get("month", "")
                day_type = str(row.get("day_type", "1"))
            except (ValueError, TypeError):
                continue
            key = (line, day_type)
            inc_accum[key]["total"] += count
            inc_accum[key]["months"].add(month)
        for (line, day_type), d in inc_accum.items():
            months = max(1, len(d["months"]))
            monthly_rate = d["total"] / months
            # 0 incidents/month → 0 boost; ~130/month (high) → +0.15 boost
            boost = min(0.20, monthly_rate / 130.0)
            base_rel = line_reliability.get(line, 2.0)
            factor = _clamp(1.05 + boost + base_rel * 0.03)
            for hr in [8, 9, 17, 18, 19]:
                for dow in _dow_for_day_type(day_type):
                    is_rush = float(hr in range(7, 10) or hr in range(17, 20))
                    X.append(
                        [
                            base_rel,
                            float(hr),
                            float(dow),
                            0.0,
                            0.0,
                            is_rush,
                            float(1 - (2 <= dow <= 6)),
                            0.0,
                        ]
                    )
                    y.append(factor)
                    w.append(0.6)
                    inc_count += 1
    print(f"  Subway delay incidents: {inc_count:,} samples", flush=True)

    # ── Step 8: Subway trains delayed — total delay counts ────────────────
    delayed_count = 0
    p = TRAINING_DIR / "subway_trains_delayed.json"
    if p.exists():
        del_accum: dict[tuple, dict] = defaultdict(
            lambda: {"total": 0.0, "months": set()}
        )
        for row in json.loads(p.read_text()):
            line = (row.get("line") or "").upper().strip()
            try:
                delays = float(row.get("delays") or 0)
                month = row.get("month", "")
                day_type = str(row.get("day_type", "1"))
            except (ValueError, TypeError):
                continue
            key = (line, day_type)
            del_accum[key]["total"] += delays
            del_accum[key]["months"].add(month)
        for (line, day_type), d in del_accum.items():
            months = max(1, len(d["months"]))
            monthly_delays = d["total"] / months
            # Normalize: ~2000 delays/month for heavily delayed lines → boost 0.10
            boost = min(0.15, monthly_delays / 20000.0)
            base_rel = line_reliability.get(line, 2.0)
            factor = _clamp(1.03 + boost + base_rel * 0.02)
            for hr in _HOUR_BUCKETS:
                for dow in _dow_for_day_type(day_type):
                    is_rush = float(
                        (2 <= dow <= 6) and (hr in range(7, 10) or hr in range(17, 20))
                    )
                    X.append(
                        [
                            base_rel,
                            float(hr),
                            float(dow),
                            0.0,
                            0.0,
                            is_rush,
                            float(1 - (2 <= dow <= 6)),
                            0.0,
                        ]
                    )
                    y.append(factor)
                    w.append(0.6)
                    delayed_count += 1
    print(f"  Subway trains delayed: {delayed_count:,} samples", flush=True)

    # ── Step 9: Bus service delivered — ghost bus / cancelled trips ────────
    bus_sd_count = 0
    p = TRAINING_DIR / "bus_service_delivered.json"
    if p.exists():
        sd_accum: dict[str, list[float]] = defaultdict(list)
        for row in json.loads(p.read_text()):
            route = (row.get("route_id") or "").upper().strip()
            with contextlib.suppress(KeyError, ValueError, TypeError):
                sd_accum[route].append(float(row["service_delivered"]))
        for _route, vals in sd_accum.items():
            avg_sd = sum(vals) / len(vals)
            # service_delivered < 1.0 → ghost buses → riders wait longer
            factor = _clamp(1.0 + (1.0 - avg_sd) * 0.4)
            for hr in [8, 12, 17]:
                for dow in [2, 3, 4, 5, 6]:
                    is_rush = float(hr in range(7, 10) or hr in range(17, 20))
                    X.append([2.0, float(hr), float(dow), 0.0, 1.0, is_rush, 0.0, 0.0])
                    y.append(factor)
                    w.append(0.7)
                    bus_sd_count += 1
    print(f"  Bus service delivered: {bus_sd_count:,} samples", flush=True)

    print(
        f"\n  MTA open data total: {len(X):,} samples across all datasets", flush=True
    )
    return X, y, w


def load_real_observations(
    csv_path: Path,
) -> tuple[list[list[float]], list[float], list[float]]:
    """Load real observation CSV produced by export_observations.py.

    Expected columns:
      route_id, stop_id, hour, dow, weather, mode, actual_factor
    """
    import csv as _csv

    X, y, w = [], [], []
    with open(csv_path, newline="", encoding="utf-8") as f:
        reader = _csv.DictReader(f)
        for row in reader:
            try:
                factor = float(row["actual_factor"])
                feats = encode_features(
                    route_id=row["route_id"],
                    hour=int(row["hour"]),
                    dow=int(row["dow"]),
                    weather=row.get("weather", "clear"),
                    mode=row.get("mode", "subway"),
                    current_delay_s=float(row.get("deviation_s", 0.0)),
                )
                X.append(feats)
                y.append(max(1.0, min(2.0, factor)))
                w.append(1.0)  # real data gets full weight
            except (ValueError, KeyError):
                continue
    print(f"  Loaded {len(X):,} real observation samples from {csv_path}", flush=True)
    return X, y, w


def train(X: list[list[float]], y: list[float], w: list[float]) -> Any:
    """Train a LightGBM regressor and return the fitted estimator.

    Uses early stopping on a 15% validation split so the model automatically
    stops adding trees when improvements stall — no manual n_estimators tuning
    needed.  The full model is then re-fitted on 100% of the data using the
    optimal tree count found by early stopping.
    """
    import lightgbm as lgb  # type: ignore
    import numpy as np  # type: ignore
    from sklearn.metrics import mean_absolute_error  # type: ignore
    from sklearn.model_selection import train_test_split  # type: ignore

    X_arr = np.array(X, dtype=float)
    y_arr = np.array(y, dtype=float)
    w_arr = np.array(w, dtype=float)

    # ── Split for early-stopping validation ───────────────────────────
    X_tr, X_val, y_tr, y_val, w_tr, w_val = train_test_split(
        X_arr, y_arr, w_arr, test_size=0.15, random_state=42
    )

    print("  Fitting LightGBM (early stopping on 15% val split) ...", flush=True)
    t0 = time.perf_counter()

    # LightGBM leaf-wise model — faster and more accurate than level-wise GBR
    # num_leaves=63 ≈ max_depth=6 but LightGBM grows leaves not levels, so it
    # finds better splits without adding depth overhead.
    val_model = lgb.LGBMRegressor(
        n_estimators=2000,  # upper bound — early stopping will cut this down
        num_leaves=63,  # 2^6-1: expressive but not overfit
        learning_rate=0.05,
        subsample=0.8,  # row-level bagging per tree
        colsample_bytree=0.8,  # feature-level bagging per tree
        min_child_samples=20,  # leaf must have ≥20 samples (regularisation)
        reg_alpha=0.1,  # L1 — sparsifies feature use
        reg_lambda=0.1,  # L2 — smooths leaf values
        random_state=42,
        verbose=-1,  # suppress LightGBM's per-iteration output
    )
    val_model.fit(
        X_tr,
        y_tr,
        sample_weight=w_tr,
        eval_set=[(X_val, y_val)],
        eval_sample_weight=[w_val],
        callbacks=[
            lgb.early_stopping(stopping_rounds=50, verbose=False),
            lgb.log_evaluation(period=0),  # silent
        ],
    )

    best_n = val_model.best_iteration_
    mae = mean_absolute_error(y_val, val_model.predict(X_val))
    elapsed = time.perf_counter() - t0
    print(f"  Early stopping: best iteration = {best_n}  (of 2000 max)", flush=True)
    print(
        f"  Validation MAE: {mae:.4f} delay_factor units "
        f"({mae * 10:.2f} min on a 10-min trip)",
        flush=True,
    )
    print(f"  Val fit time: {elapsed:.1f}s", flush=True)

    # ── Re-fit on 100% of data using the optimal tree count ───────────
    print(f"  Re-fitting on full dataset with n_estimators={best_n} ...", flush=True)
    t1 = time.perf_counter()
    model = lgb.LGBMRegressor(
        n_estimators=best_n,
        num_leaves=63,
        learning_rate=0.05,
        subsample=0.8,
        colsample_bytree=0.8,
        min_child_samples=20,
        reg_alpha=0.1,
        reg_lambda=0.1,
        random_state=42,
        verbose=-1,
    )
    model.fit(X_arr, y_arr, sample_weight=w_arr)
    print(f"  Full fit time:  {time.perf_counter() - t1:.1f}s", flush=True)

    # ── Feature importances (gain-based) ─────────────────────────────
    feature_names = [
        "route_reliability",
        "hour",
        "dow",
        "weather",
        "mode",
        "is_rush",
        "is_weekend",
        "delay_minutes",
    ]
    importances = sorted(
        zip(feature_names, model.feature_importances_, strict=False),
        key=lambda x: -x[1],
    )
    total_imp = sum(imp for _, imp in importances) or 1
    print("  Feature importances (gain):")
    for name, imp in importances:
        pct = imp / total_imp
        bar = "█" * int(pct * 40)
        print(f"    {name:<20} {pct:.3f}  {bar}")

    return model


def main(real_data_csv: Path | None = None) -> None:
    print("\n━━━  Track ML — Delay Model Training  ━━━\n")

    # ── Load GTFS ──────────────────────────────────────────────────────
    if not _DB.exists():
        print(f"ERROR: GTFS database not found at {_DB}", file=sys.stderr)
        sys.exit(1)

    print(f"Step 1/4  Reading GTFS database: {_DB}")
    conn = sqlite3.connect(_DB)
    route_table = _build_route_table(conn)
    conn.close()

    # ── Bootstrap samples ──────────────────────────────────────────────
    print("\nStep 2/5  Generating bootstrap training data from GTFS")
    X_boot, y_boot, w_boot = generate_bootstrap_samples(route_table)

    X, y, w = X_boot[:], y_boot[:], w_boot[:]

    # ── MTA open data (downloaded JSON files) ─────────────────────────
    print("\nStep 3/5  Loading MTA open datasets from app/data/training/")
    X_mta, y_mta, w_mta = load_mta_open_data()
    if X_mta:
        X += X_mta
        y += y_mta
        w += w_mta
        print(
            f"  Bootstrap: {len(X_boot):,}  MTA open: {len(X_mta):,}  "
            f"combined: {len(X):,} samples"
        )
    else:
        print("  No MTA open data found — bootstrap only.")
        print("  Run: python scripts/fetch_mta_training_data.py  to download datasets.")

    # ── Real observations (optional) ───────────────────────────────────
    if real_data_csv and real_data_csv.exists():
        print(f"\nStep 3b   Loading real observations: {real_data_csv}")
        X_real, y_real, w_real = load_real_observations(real_data_csv)
        X += X_real
        y += y_real
        w += w_real
        print(
            f"  Total samples: {len(X):,} ({len(X_real):,} real + {len(X_mta):,} MTA + {len(X_boot):,} bootstrap)"
        )
    else:
        print(
            f"\n  (No real-observations CSV — using bootstrap + MTA open data.  "
            f"Total: {len(X):,} samples)"
        )
        print("  As users ride trains, recency_model.py logs errors to Redis.")
        print("  Export them with:  python -m app.ml.export_observations")
        print(
            "  Then retrain with: python -m app.ml.train_model --real-data observations.csv"
        )

    # ── Train ──────────────────────────────────────────────────────────
    print("\nStep 4/5  Training LightGBM")
    model = train(X, y, w)

    # ── Save ───────────────────────────────────────────────────────────
    print(f"\nStep 5/5  Saving model → {_OUT}")
    import joblib  # type: ignore

    _OUT.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, _OUT)
    size_kb = _OUT.stat().st_size / 1024
    print(f"  Saved ({size_kb:.0f} KB)\n")

    print(
        "━━━  Done.  Call POST /predict/reload-model to hot-swap on a live server.  ━━━\n"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train the Track delay model.")
    parser.add_argument(
        "--real-data",
        type=Path,
        default=None,
        help="Path to real observations CSV (route_id,stop_id,hour,dow,weather,mode,actual_factor)",
    )
    args = parser.parse_args()
    main(real_data_csv=args.real_data)
