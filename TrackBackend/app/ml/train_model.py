#
# train_model.py
# app/ml/train_model.py
#
# Bootstrap + train the GradientBoosting delay factor model.
#
# Run from the TrackBackend directory:
#   python -m app.ml.train_model
#
# ── What this does ─────────────────────────────────────────────────────────
#
#  Phase 1 — Bootstrap from GTFS (works right now, zero extra data needed)
#  -----------------------------------------------------------------------
#  We have 8M+ stop_times rows in transit_schedule.db.  From those we
#  derive real facts about each route:
#    • Average stop count per trip (proxy for trip length / exposure to delay)
#    • Which hours each route actually runs (from scheduled departure times)
#    • Which modes the route belongs to (subway / bus / lirr / mnr)
#
#  We then generate synthetic training samples by sampling from distributions
#  that encode known MTA OTP (on-time performance) patterns:
#
#    delay_factor = base_for_route
#                + rush_hour_effect
#                + weather_effect
#                + Gaussian noise (σ=0.03)
#
#  This is NOT making things up — it is encoding domain knowledge as a prior
#  so the model starts better than pure heuristics from day one.
#
#  Phase 2 — Real data (automatic over time)
#  -----------------------------------------
#  Once the app is running, recency_model.py records actual vs. MTA-predicted
#  errors per stop into Redis.  Periodically export those to a CSV and rerun
#  this script with --real-data path/to/observations.csv to blend real and
#  bootstrapped samples.  The bootstrapped rows are down-weighted so real
#  data quickly dominates.
#
# ── Output ─────────────────────────────────────────────────────────────────
#   app/data/delay_model.pkl  — joblib-serialised GBR ready to load
#

from __future__ import annotations

import argparse
import random
import sqlite3
import sys
import time
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────────
_ROOT   = Path(__file__).resolve().parent.parent.parent   # TrackBackend/
_DB     = _ROOT / "app" / "data" / "transit_schedule.db"
_OUT    = _ROOT / "app" / "data" / "delay_model.pkl"

# ── Feature encoding (must match delay_model.py exactly) ──────────────────
from app.ml.delay_model import (
    ROUTE_RELIABILITY,
    WEATHER_ENCODING,
    MODE_ENCODING,
    encode_features,
)

# ── MTA on-time performance priors (public data, NYC Transit 2024 reports) ─
# Base delay factor at off-peak, clear weather for each reliability tier.
# Subway: ~80-85% on time → avg factor ≈ 1.05–1.08
# Bus:    ~55-65% on time → avg factor ≈ 1.10–1.18
_TIER_BASE: dict[int, float] = {
    0: 1.02,   # Tier 0 (L, SI) — very reliable
    1: 1.04,   # Tier 1 (7, W)
    2: 1.07,   # Tier 2 (most lines) — moderate chronic delay
    3: 1.10,   # Tier 3 (A/C/4/5/6) — frequently delayed
    4: 1.16,   # Tier 4 (G) — chronically delayed
}

# Rush-hour additive effect per mode tier
_RUSH_SUBWAY = 0.10
_RUSH_BUS    = 0.20

# Weather additive effects
_WEATHER_EFFECTS: dict[str, dict[str, float]] = {
    "subway": {"clear": 0.0, "rain": 0.05, "snow": 0.20},
    "bus":    {"clear": 0.0, "rain": 0.15, "snow": 0.30},
    "lirr":   {"clear": 0.0, "rain": 0.08, "snow": 0.25},
    "mnr":    {"clear": 0.0, "rain": 0.08, "snow": 0.25},
}

# Gaussian noise standard deviation (prevents overfitting to exact priors)
_NOISE_SIGMA = 0.03

# Samples per (route, hour_bucket, dow, weather) cell
_SAMPLES_PER_CELL = 3

# Hour buckets: we sample at representative hours rather than all 24
_HOUR_BUCKETS = [0, 6, 7, 8, 9, 10, 12, 15, 17, 18, 19, 20, 22]

# Day of week values (1=Sun … 7=Sat) in our convention
_WEEKDAYS  = [2, 3, 4, 5, 6]
_WEEKENDS  = [1, 7]


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
        elif rid_upper.startswith("MNR") or rid_upper.startswith("METRO"):
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


def _make_factor(reliability: int, mode: str, hour: int, is_weekday: bool, weather: str) -> float:
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

    weathers = ["clear", "clear", "clear", "rain", "rain", "snow"]  # realistic distribution

    for route_id, info in route_table.items():
        reliability = info["reliability"]
        mode        = info["mode"]
        short       = info["short"]

        for hour in _HOUR_BUCKETS:
            if info["hours"] and hour not in info["hours"]:
                # Skip hours this route doesn't operate (reduces noise)
                continue

            for dow_group in [_WEEKDAYS, _WEEKENDS]:
                is_weekday = (dow_group is _WEEKDAYS)
                for dow in dow_group:
                    for weather in weathers:
                        for _ in range(_SAMPLES_PER_CELL):
                            factor = _make_factor(reliability, mode, hour, is_weekday, weather)
                            # Bootstrap delay_minutes: realistic spread around 0
                            # (mean 0 = on-time, sigma ~1.5 min = observed MTA spread).
                            # Real observations will have actual deviations; the
                            # bootstrap primes the surface so the model learns
                            # the momentum direction immediately.
                            bootleg_delay_s = random.gauss(0, 90)  # ~N(0, 1.5 min)
                            feats = encode_features(short, hour, dow, weather, mode,
                                                    current_delay_s=bootleg_delay_s)
                            X.append(feats)
                            y.append(factor)
                            w.append(0.5)   # bootstrap weight (real data = 1.0)

    print(f"  Generated {len(X):,} bootstrap samples", flush=True)
    return X, y, w


def load_real_observations(csv_path: Path) -> tuple[list[list[float]], list[float], list[float]]:
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
                w.append(1.0)   # real data gets full weight
            except (ValueError, KeyError):
                continue
    print(f"  Loaded {len(X):,} real observation samples from {csv_path}", flush=True)
    return X, y, w


def train(X: list[list[float]], y: list[float], w: list[float]) -> Any:
    """Train a GBR and return the fitted estimator."""
    from sklearn.ensemble import GradientBoostingRegressor  # type: ignore
    import numpy as np  # type: ignore

    print("  Fitting GradientBoostingRegressor ...", flush=True)
    t0 = time.perf_counter()

    model = GradientBoostingRegressor(
        n_estimators=200,        # enough trees to capture interactions
        max_depth=4,             # shallow — prevents overfitting on small data
        learning_rate=0.05,      # slow rate + more trees = better generalisation
        subsample=0.8,           # stochastic GBR reduces variance
        min_samples_leaf=10,     # each leaf must cover at least 10 samples
        random_state=42,
    )

    X_arr = np.array(X, dtype=float)
    y_arr = np.array(y, dtype=float)
    w_arr = np.array(w, dtype=float)

    model.fit(X_arr, y_arr, sample_weight=w_arr)

    elapsed = time.perf_counter() - t0
    print(f"  Trained in {elapsed:.1f}s", flush=True)

    # Train/test split for validation (simpler than CV with sample weights)
    from sklearn.model_selection import train_test_split  # type: ignore
    from sklearn.metrics import mean_absolute_error       # type: ignore
    X_tr, X_val, y_tr, y_val, w_tr, w_val = train_test_split(
        X_arr, y_arr, w_arr, test_size=0.15, random_state=42
    )
    val_model = GradientBoostingRegressor(
        n_estimators=200, max_depth=4, learning_rate=0.05,
        subsample=0.8, min_samples_leaf=10, random_state=42
    )
    val_model.fit(X_tr, y_tr, sample_weight=w_tr)
    mae = mean_absolute_error(y_val, val_model.predict(X_val))
    print(f"  Validation MAE: {mae:.4f} delay_factor units "
          f"({mae * 10:.2f} min on a 10-min trip)", flush=True)

    # Feature importances
    feature_names = ["route_reliability", "hour", "dow", "weather", "mode",
                     "is_rush", "is_weekend", "delay_minutes"]
    importances = sorted(zip(feature_names, model.feature_importances_), key=lambda x: -x[1])
    print("  Feature importances:")
    for name, imp in importances:
        bar = "█" * int(imp * 40)
        print(f"    {name:<20} {imp:.3f}  {bar}")

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
    print("\nStep 2/4  Generating training data from GTFS")
    X_boot, y_boot, w_boot = generate_bootstrap_samples(route_table)

    X, y, w = X_boot, y_boot, w_boot

    # ── Real observations (optional) ───────────────────────────────────
    if real_data_csv and real_data_csv.exists():
        print(f"\nStep 2b   Loading real observations: {real_data_csv}")
        X_real, y_real, w_real = load_real_observations(real_data_csv)
        X += X_real
        y += y_real
        w += w_real
        print(f"  Total samples: {len(X):,} ({len(X_real):,} real + {len(X_boot):,} bootstrap)")
    else:
        print(f"\n  (No real data CSV — bootstrap only.  Total: {len(X):,} samples)")
        print("  As users ride trains, recency_model.py logs errors to Redis.")
        print("  Export them with:  python -m app.ml.export_observations")
        print("  Then retrain with: python -m app.ml.train_model --real-data observations.csv")

    # ── Train ──────────────────────────────────────────────────────────
    print("\nStep 3/4  Training GradientBoostingRegressor")
    model = train(X, y, w)

    # ── Save ───────────────────────────────────────────────────────────
    print(f"\nStep 4/4  Saving model → {_OUT}")
    import joblib  # type: ignore
    _OUT.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, _OUT)
    size_kb = _OUT.stat().st_size / 1024
    print(f"  Saved ({size_kb:.0f} KB)\n")

    print("━━━  Done.  Call POST /predict/reload-model to hot-swap on a live server.  ━━━\n")


# Allow direct import of the `Any` type used in train()
from typing import Any


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
