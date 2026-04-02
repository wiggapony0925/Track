"""MTA open data loaders for training the delay-factor model.

Extracted from train_model.py so that each module stays focused:
  - data_loaders.py  → reads JSON/CSV data into (X, y, w) tuples
  - train_model.py   → orchestrates bootstrap + training pipeline

Run via train_model.py — not directly.
"""

from __future__ import annotations

import contextlib
import csv as _csv
import json
import math
from collections import defaultdict
from pathlib import Path

from app.ml.delay_model import SEASON_ENCODING, encode_features

# ── Root path (TrackBackend/) ──────────────────────────────────────────────
_ROOT = Path(__file__).resolve().parent.parent.parent

# Hour buckets used across several loaders
_HOUR_BUCKETS = [0, 6, 7, 8, 9, 10, 12, 15, 17, 18, 19, 20, 22]

_TWO_PI = 2.0 * math.pi


# ── Helpers ────────────────────────────────────────────────────────────────


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
    """day_type '1'=weekday '2'=weekend -> list of dow values."""
    return [2, 3, 4, 5, 6] if str(day_type) == "1" else [1, 7]


def _clamp(v: float, lo: float = 1.0, hi: float = 2.0) -> float:
    return max(lo, min(hi, v))


def _feats(
    reliability: float,
    hour: int,
    dow: int,
    weather: float,
    mode: float,
    delay_minutes: float = 0.0,
    month: float = 1.0,
) -> list[float]:
    """Build a v3 feature vector (must match FEATURE_NAMES order).

    14 features: v1 core (8) + v2 calendar (2) + v3 cyclical (4).
    """
    is_weekday = 2 <= dow <= 6
    is_rush = float(is_weekday and (hour in range(7, 10) or hour in range(17, 20)))
    season = float(SEASON_ENCODING.get(int(month), 0))
    return [
        reliability,
        float(hour),
        float(dow),
        weather,
        mode,
        is_rush,
        float(not is_weekday),
        delay_minutes,
        month,
        season,
        math.sin(_TWO_PI * hour / 24.0),
        math.cos(_TWO_PI * hour / 24.0),
        math.sin(_TWO_PI * dow / 7.0),
        math.cos(_TWO_PI * dow / 7.0),
    ]


def _parse_month(ts: str) -> float:
    """Extract month (1-12) from MTA timestamp like '2025-01-01T00:00:00.000'."""
    try:
        return float(int(ts.split("-")[1]))
    except (IndexError, ValueError, TypeError):
        return 1.0


# ── MTA open-data loaders ─────────────────────────────────────────────────


def _load_subway_otp(
    training_dir: Path,
) -> dict[str, float]:
    """Step 1: Build per-line OTP reliability from subway OTP JSON files.

    Returns:
        Mapping of line letter -> reliability float (0=perfect, 4=worst).
    """
    otp_accum: dict[str, list[float]] = defaultdict(list)
    for fname in [
        "subway_otp_2015_2019.json",
        "subway_otp_2020_2024.json",
        "subway_otp_2025.json",
    ]:
        p = training_dir / fname
        if not p.exists():
            continue
        for row in json.loads(p.read_text()):
            line = (row.get("line") or "").upper().strip()
            with contextlib.suppress(KeyError, ValueError, TypeError):
                otp_accum[line].append(float(row["terminal_on_time_performance"]))

    line_reliability: dict[str, float] = {}
    for line, vals in otp_accum.items():
        avg_otp = sum(vals) / len(vals)
        line_reliability[line] = _clamp((1.0 - avg_otp) * 8.0, 0.0, 4.0)
    print(
        f"  OTP reliability built for {len(line_reliability)} subway lines",
        flush=True,
    )
    return line_reliability


def _load_subway_customer_journey(
    training_dir: Path,
    line_reliability: dict[str, float],
) -> tuple[list[list[float]], list[float], list[float]]:
    """Step 2: Subway customer journey — APT + ATT delay signal."""
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []
    count = 0

    for fname in [
        "subway_customer_journey_2015_2019.json",
        "subway_customer_journey_2020_2024.json",
        "subway_customer_journey_2025.json",
    ]:
        p = training_dir / fname
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
            month = _parse_month(row.get("month", ""))
            for hr in _period_hours(period):
                for dow in _dow_for_day_type(day_type):
                    X.append(_feats(rel, hr, dow, 0.0, 0.0, month=month))
                    y.append(factor)
                    w.append(0.8)
                    count += 1

    print(f"  Subway customer journey: {count:,} samples", flush=True)
    return X, y, w


def _load_lirr_otp(
    training_dir: Path,
) -> tuple[list[list[float]], list[float], list[float]]:
    """Step 3: LIRR OTP — per-branch, per-period."""
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []
    count = 0

    p = training_dir / "lirr_otp.json"
    if not p.exists():
        return X, y, w

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
                dows = [2, 3, 4, 5, 6] if is_peak else [2, 3, 4, 5, 6, 1, 7]
                for dow in dows:
                    X.append(_feats(2.0, hr, dow, 0.0, 2.0))
                    y.append(factor)
                    w.append(0.8)
                    count += 1

    print(f"  LIRR OTP: {count:,} samples", flush=True)
    return X, y, w


def _load_mnr_otp(
    training_dir: Path,
) -> tuple[list[list[float]], list[float], list[float]]:
    """Step 4: Metro-North OTP."""
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []
    count = 0

    p = training_dir / "metro_north_otp.json"
    if not p.exists():
        return X, y, w

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
                    X.append(_feats(2.0, hr, dow, 0.0, 3.0))
                    y.append(factor)
                    w.append(0.8)
                    count += 1

    print(f"  Metro-North OTP: {count:,} samples", flush=True)
    return X, y, w


def _load_bus_customer_journey(
    training_dir: Path,
) -> tuple[list[list[float]], list[float], list[float]]:
    """Step 5: Bus customer journey — extra travel time above schedule."""
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []
    count = 0

    p = training_dir / "bus_customer_journey.json"
    if not p.exists():
        return X, y, w

    for row in json.loads(p.read_text()):
        try:
            att = float(row.get("additional_travel_time") or 0)
        except (ValueError, TypeError):
            continue
        factor = _clamp(1.0 + att / 10.0)
        period = row.get("period", "")
        trip_type = (row.get("trip_type") or "").lower()
        day_type = "1" if ("weekday" in trip_type or "peak" in period.lower()) else "2"
        for hr in _period_hours(period):
            for dow in _dow_for_day_type(day_type):
                X.append(_feats(2.0, hr, dow, 0.0, 1.0))
                y.append(factor)
                w.append(0.8)
                count += 1

    print(f"  Bus customer journey: {count:,} samples", flush=True)
    return X, y, w


def _load_bus_wait_assessment(
    training_dir: Path,
) -> tuple[list[list[float]], list[float], list[float]]:
    """Step 6: Bus wait assessment — bunching rate per route."""
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []
    count = 0

    p = training_dir / "bus_wait_assessment.json"
    if not p.exists():
        return X, y, w

    wa_accum: dict[str, list[float]] = defaultdict(list)
    for row in json.loads(p.read_text()):
        route = (row.get("route_id") or "").upper().strip()
        with contextlib.suppress(KeyError, ValueError, TypeError):
            wa_accum[route].append(float(row["wait_assessment"]))

    for _route, vals in wa_accum.items():
        avg_wa = sum(vals) / len(vals)
        factor = _clamp(1.0 + (1.0 - avg_wa) * 0.25)
        for hr in [8, 9, 12, 17, 18]:
            for dow in [2, 3, 4, 5, 6]:
                X.append(_feats(2.0, hr, dow, 0.0, 1.0))
                y.append(factor)
                w.append(0.7)
                count += 1

    print(f"  Bus wait assessment: {count:,} samples", flush=True)
    return X, y, w


def _load_subway_delay_incidents(
    training_dir: Path,
    line_reliability: dict[str, float],
) -> tuple[list[list[float]], list[float], list[float]]:
    """Step 7: Subway delay incidents — monthly incident rate."""
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []
    count = 0

    p = training_dir / "subway_delay_incidents.json"
    if not p.exists():
        return X, y, w

    inc_accum: dict[tuple, dict] = defaultdict(lambda: {"total": 0.0, "months": set()})
    for row in json.loads(p.read_text()):
        line = (row.get("line") or "").upper().strip()
        try:
            inc_count = float(row.get("incidents") or 0)
            month = row.get("month", "")
            day_type = str(row.get("day_type", "1"))
        except (ValueError, TypeError):
            continue
        key = (line, day_type)
        inc_accum[key]["total"] += inc_count
        inc_accum[key]["months"].add(month)

    for (line, day_type), d in inc_accum.items():
        months = max(1, len(d["months"]))
        monthly_rate = d["total"] / months
        boost = min(0.20, monthly_rate / 130.0)
        base_rel = line_reliability.get(line, 2.0)
        factor = _clamp(1.05 + boost + base_rel * 0.03)
        for hr in [8, 9, 17, 18, 19]:
            for dow in _dow_for_day_type(day_type):
                X.append(_feats(base_rel, hr, dow, 0.0, 0.0))
                y.append(factor)
                w.append(0.6)
                count += 1

    print(f"  Subway delay incidents: {count:,} samples", flush=True)
    return X, y, w


def _load_subway_trains_delayed(
    training_dir: Path,
    line_reliability: dict[str, float],
) -> tuple[list[list[float]], list[float], list[float]]:
    """Step 8: Subway trains delayed — total delay counts."""
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []
    count = 0

    p = training_dir / "subway_trains_delayed.json"
    if not p.exists():
        return X, y, w

    del_accum: dict[tuple, dict] = defaultdict(lambda: {"total": 0.0, "months": set()})
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
        boost = min(0.15, monthly_delays / 20000.0)
        base_rel = line_reliability.get(line, 2.0)
        factor = _clamp(1.03 + boost + base_rel * 0.02)
        for hr in _HOUR_BUCKETS:
            for dow in _dow_for_day_type(day_type):
                X.append(_feats(base_rel, hr, dow, 0.0, 0.0))
                y.append(factor)
                w.append(0.6)
                count += 1

    print(f"  Subway trains delayed: {count:,} samples", flush=True)
    return X, y, w


def _load_bus_service_delivered(
    training_dir: Path,
) -> tuple[list[list[float]], list[float], list[float]]:
    """Step 9: Bus service delivered — ghost bus / cancelled trips."""
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []
    count = 0

    p = training_dir / "bus_service_delivered.json"
    if not p.exists():
        return X, y, w

    sd_accum: dict[str, list[float]] = defaultdict(list)
    for row in json.loads(p.read_text()):
        route = (row.get("route_id") or "").upper().strip()
        with contextlib.suppress(KeyError, ValueError, TypeError):
            sd_accum[route].append(float(row["service_delivered"]))

    for _route, vals in sd_accum.items():
        avg_sd = sum(vals) / len(vals)
        factor = _clamp(1.0 + (1.0 - avg_sd) * 0.4)
        for hr in [8, 12, 17]:
            for dow in [2, 3, 4, 5, 6]:
                X.append(
                    _feats(2.0, hr, dow, 0.0, 1.0)
                )
                y.append(factor)
                w.append(0.7)
                count += 1

    print(f"  Bus service delivered: {count:,} samples", flush=True)
    return X, y, w


def _load_bus_segment_speeds(
    training_dir: Path,
) -> tuple[list[list[float]], list[float], list[float]]:
    """Step 10: Bus segment speeds — REAL speed data by route×hour×day.

    This is one of the most valuable datasets (1M rows).  Average road
    speed by route, hour_of_day, and day_of_week gives us *actual*
    delay patterns instead of synthetic priors.

    Logic:
      1. For each route, find its maximum observed speed (free-flow baseline).
      2. For each (route, hour, dow), compute: speed_ratio = avg_speed / max_speed.
      3. Delay factor = 1.0 / speed_ratio (slower → higher factor).
    """
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []
    count = 0

    _DOW_MAP = {
        "monday": 2,
        "tuesday": 3,
        "wednesday": 4,
        "thursday": 5,
        "friday": 6,
        "saturday": 7,
        "sunday": 1,
    }

    for fname in ["bus_segment_speeds_2023_2024.json", "bus_segment_speeds_2025.json"]:
        p = training_dir / fname
        if not p.exists():
            continue

        data = json.loads(p.read_text())

        # Phase 1: find max speed per route (free-flow baseline)
        route_max_speed: dict[str, float] = defaultdict(float)
        for row in data:
            try:
                speed = float(row.get("average_road_speed") or 0)
                route = (row.get("route_id") or "").upper().strip()
            except (ValueError, TypeError):
                continue
            if speed > 0 and route:
                route_max_speed[route] = max(route_max_speed[route], speed)

        # Phase 2: derive delay factors from speed ratios
        for row in data:
            try:
                speed = float(row.get("average_road_speed") or 0)
                route = (row.get("route_id") or "").upper().strip()
                hour = int(row.get("hour_of_day") or 0)
                dow_str = (row.get("day_of_week") or "").lower().strip()
                month_val = float(row.get("month") or 1)
            except (ValueError, TypeError):
                continue

            if speed <= 0 or route not in route_max_speed:
                continue

            max_speed = route_max_speed[route]
            if max_speed <= 0:
                continue

            dow = _DOW_MAP.get(dow_str, 3)
            speed_ratio = speed / max_speed
            # Invert: slower buses → higher delay factor
            # Clamp between 1.0 (full speed) and 2.0 (half speed or worse)
            factor = _clamp(1.0 / max(speed_ratio, 0.5))

            X.append(_feats(2.0, hour, dow, 0.0, 1.0, month=month_val))
            y.append(factor)
            w.append(0.9)  # high weight — this is REAL measured data
            count += 1

    print(f"  Bus segment speeds: {count:,} samples", flush=True)
    return X, y, w


def _load_mta_service_alerts(
    training_dir: Path,
    line_reliability: dict[str, float],
) -> tuple[list[list[float]], list[float], list[float]]:
    """Step 11: MTA service alerts — disruption frequency per route.

    Uses 470K+ rows of historical service alerts to compute per-route
    disruption rates.  Routes with frequent cancellations/delays get
    higher delay factors, weighted by alert severity.
    """
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []
    count = 0

    p = training_dir / "mta_service_alerts.json"
    if not p.exists():
        return X, y, w

    data = json.loads(p.read_text())

    # Count alerts per affected route
    route_alert_count: dict[str, int] = defaultdict(int)
    route_severe_count: dict[str, int] = defaultdict(int)
    total_months = set()

    for row in data:
        affected = (row.get("affected") or "").upper().strip()
        status = (row.get("status_label") or "").lower()
        date_str = row.get("date", "")

        if not affected:
            continue

        route_alert_count[affected] += 1
        if "cancel" in status or "delay" in status or "suspend" in status:
            route_severe_count[affected] += 1

        # Track months for rate calculation
        with contextlib.suppress(IndexError, ValueError):
            total_months.add(date_str[:7])

    n_months = max(1, len(total_months))

    # Generate training samples for routes with significant alert history
    for route, alert_count in route_alert_count.items():
        monthly_rate = alert_count / n_months
        severe_rate = route_severe_count.get(route, 0) / n_months

        if monthly_rate < 1.0:
            continue  # skip routes with very few alerts

        # More alerts → higher delay factor
        boost = min(0.30, monthly_rate / 50.0 + severe_rate / 20.0)
        factor = _clamp(1.03 + boost)

        # Determine mode from agency/route
        is_bus = len(route) > 2  # bus routes are like "BX1", "M15"
        mode_val = 1.0 if is_bus else 0.0
        rel = line_reliability.get(route, 2.0)

        # Generate samples across rush hours (alerts mostly impact peak)
        for hr in [7, 8, 9, 17, 18, 19]:
            for dow in [2, 3, 4, 5, 6]:
                X.append(_feats(rel, hr, dow, 0.0, mode_val))
                y.append(factor)
                w.append(0.6)
                count += 1

    print(f"  MTA service alerts: {count:,} samples", flush=True)
    return X, y, w


# ── Public API ─────────────────────────────────────────────────────────────


def load_mta_open_data() -> tuple[list[list[float]], list[float], list[float]]:
    """Load all MTA open JSON files from app/data/training/.

    Delegates to one helper per dataset:
      1. Subway OTP  →  per-line reliability
      2. Subway customer journey (APT + ATT)
      3. LIRR OTP
      4. Metro-North OTP
      5. Bus customer journey
      6. Bus wait assessment
      7. Subway delay incidents
      8. Subway trains delayed
      9. Bus service delivered

    Returns:
        (X, y, w) lists ready for LightGBM training.
    """
    training_dir = _ROOT / "app" / "data" / "training"
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []

    if not training_dir.exists():
        print("  No training/ directory — skipping MTA open data.", flush=True)
        return X, y, w

    # Step 1 — reliability lookup (used by steps 2, 7, 8)
    line_reliability = _load_subway_otp(training_dir)

    # Steps 2–11 — each returns independent (X, y, w) segments
    loaders = [
        lambda: _load_subway_customer_journey(training_dir, line_reliability),
        lambda: _load_lirr_otp(training_dir),
        lambda: _load_mnr_otp(training_dir),
        lambda: _load_bus_customer_journey(training_dir),
        lambda: _load_bus_wait_assessment(training_dir),
        lambda: _load_subway_delay_incidents(training_dir, line_reliability),
        lambda: _load_subway_trains_delayed(training_dir, line_reliability),
        lambda: _load_bus_service_delivered(training_dir),
        lambda: _load_bus_segment_speeds(training_dir),
        lambda: _load_mta_service_alerts(training_dir, line_reliability),
    ]
    for loader in loaders:
        x_seg, y_seg, w_seg = loader()
        X += x_seg
        y += y_seg
        w += w_seg

    print(
        f"\n  MTA open data total: {len(X):,} samples across all datasets",
        flush=True,
    )
    return X, y, w


def load_real_observations(
    csv_path: Path,
) -> tuple[list[list[float]], list[float], list[float]]:
    """Load real observation CSV produced by export_observations.py.

    Expected columns:
        route_id, stop_id, hour, dow, weather, mode, actual_factor
    """
    X: list[list[float]] = []
    y: list[float] = []
    w: list[float] = []

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

    print(
        f"  Loaded {len(X):,} real observation samples from {csv_path}",
        flush=True,
    )
    return X, y, w
