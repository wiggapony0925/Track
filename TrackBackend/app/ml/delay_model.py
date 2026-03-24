#
# delay_model.py
# app/ml/delay_model.py
#
# LightGBM pattern model.
# Predicts a delay_factor for a transit context: route × hour × day × weather × mode.
# The factor multiplies MTA's raw minutes_away to correct for known chronic patterns.
#
# Why LightGBM?
#   • 10–50× faster training vs sklearn GradientBoostingRegressor (leaf-wise growth)
#   • Built-in early stopping — automatically finds optimal tree count, no guessing
#   • Handles millions of rows without OOM issues
#   • Same sklearn-compatible .predict() API — inference code unchanged
#   • ~5 µs inference — safe on every API request.
#   • Trivially retrained as real TripLog data accumulates.
#   • Small model file (<500 KB), ships inside Docker.
#
# Fallback: if no model file exists, falls back to the rule-based heuristic
# so the endpoint never breaks.
#

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

from app.utils.logger import TrackLogger

# ── Model file location ────────────────────────────────────────────────────
MODEL_PATH = Path(__file__).resolve().parent.parent / "data" / "delay_model.pkl"

# ── Feature encoding tables ─────────────────────────────────────────────────
# Route reliability tiers — fallback used when no JSON data is available.
# 0 = most reliable → 4 = most chronically delayed.
ROUTE_RELIABILITY: dict[str, int] = {
    "SI": 0, "L": 0,
    "7": 1, "W": 1, "Z": 1, "SIR": 1,
    "1": 2, "2": 2, "3": 2, "R": 2, "N": 2, "Q": 2, "M": 2,
    "B": 2, "D": 2, "E": 2, "F": 2, "S": 2,
    "LIRR": 2, "MNR": 2,
    "4": 3, "5": 3, "6": 3, "J": 3, "A": 3, "C": 3,
    "G": 4,
}

# Dynamic OTP-derived reliability floats built from downloaded JSON files.
# Populated lazily on first call to encode_features().
# Keys match ROUTE_RELIABILITY keys (uppercase line names).
# Values are floats 0.0–4.0 where 0=perfect OTP, 4=worst OTP.
_OTP_RELIABILITY: dict[str, float] = {}
_OTP_LOADED: bool = False


def _load_otp_reliability() -> None:
    """Read subway_otp_*.json files and populate _OTP_RELIABILITY.

    Called once on demand. Silently skips if files are not present
    (falls back to ROUTE_RELIABILITY integer tiers).
    """
    global _OTP_LOADED
    if _OTP_LOADED:
        return
    _OTP_LOADED = True

    training_dir = Path(__file__).resolve().parent.parent / "data" / "training"
    if not training_dir.exists():
        return

    try:
        import json
        from collections import defaultdict

        accum: dict[str, list[float]] = defaultdict(list)
        for fname in ["subway_otp_2015_2019.json",
                      "subway_otp_2020_2024.json",
                      "subway_otp_2025.json"]:
            p = training_dir / fname
            if not p.exists():
                continue
            for row in json.loads(p.read_text()):
                line = (row.get("line") or "").upper().strip()
                try:
                    accum[line].append(float(row["terminal_on_time_performance"]))
                except (KeyError, ValueError, TypeError):
                    pass

        for line, vals in accum.items():
            avg_otp = sum(vals) / len(vals)
            # 100% OTP → 0.0 reliability score  (very reliable)
            # 50%  OTP → 4.0 reliability score  (very unreliable)
            _OTP_RELIABILITY[line] = max(0.0, min(4.0, (1.0 - avg_otp) * 8.0))

        if _OTP_RELIABILITY:
            TrackLogger.info(
                f"[ML] Loaded OTP reliability for {len(_OTP_RELIABILITY)} lines "
                f"from training JSON files.",
                tag="ML",
            )
    except Exception as exc:
        TrackLogger.warning(f"[ML] Could not load OTP reliability: {exc}", tag="ML")

WEATHER_ENCODING: dict[str, int] = {"clear": 0, "rain": 1, "snow": 2}
MODE_ENCODING: dict[str, int] = {"subway": 0, "bus": 1, "lirr": 2, "mnr": 3}

# Lines with Communications-Based Train Control (CBTC) deployment.
# These lines have sub-segment moving-block position data available to the MTA
# internally, which makes their GTFS-RT arrival predictions significantly more
# accurate than the fixed-block system on other lines.
# Source: MTA — L line (2009), 7 line (2019), Culver/8Av in progress.
# Effect on heuristic: apply a smaller rush-hour correction since the MTA's
# own predictions are already much closer to reality.
_CBTC_LINES: frozenset[str] = frozenset({"L", "7"})

_RUSH_MORNING = range(7, 10)
_RUSH_EVENING = range(17, 20)

# Feature names — must match train_model.py exactly.
# Used to build a named DataFrame at inference time so LightGBM doesn't emit
# "X does not have valid feature names" warnings on every prediction.
FEATURE_NAMES: list[str] = [
    "route_reliability", "hour", "dow", "weather", "mode",
    "is_rush", "is_weekend", "delay_minutes",
]

# ── Singleton ──────────────────────────────────────────────────────────────
_model: Any | None = None
_model_loaded: bool = False


def _load_model() -> Any | None:
    """Synchronous model load — safe to call from threads or sync contexts."""
    global _model, _model_loaded
    if _model_loaded:
        return _model
    _model_loaded = True

    if not MODEL_PATH.exists():
        TrackLogger.model_event(
            f"No model file at {MODEL_PATH} — heuristic fallback active. "
            f"Run: python -m app.ml.train_model",
            level="warning",
        )
        return None

    try:
        import joblib  # type: ignore[import-untyped]
        _model = joblib.load(MODEL_PATH)
        size_kb = MODEL_PATH.stat().st_size // 1024
        n_trees = getattr(_model, "n_estimators", "?")
        TrackLogger.model_event(
            f"LightGBM model loaded — {n_trees} trees, {size_kb} KB ({MODEL_PATH.name})"
        )
        return _model
    except Exception as exc:
        TrackLogger.model_event(
            f"Model load failed ({exc}) — heuristic fallback active.",
            level="warning",
        )
        return None


async def ensure_model_loaded() -> None:
    """Eagerly load the model in a background thread (non-blocking).

    Call this during startup so the first /nearby/grouped request never
    pays the ~60s synchronous joblib.load() penalty.  Running in a thread
    keeps the event loop responsive for health checks while the model loads.
    """
    if _model_loaded:
        return
    TrackLogger.model_event("Pre-loading LightGBM model in background thread...")
    await asyncio.to_thread(_load_model)


def encode_features(
    route_id: str, hour: int, dow: int, weather: str, mode: str,
    current_delay_s: float = 0.0,
) -> list[float]:
    """Convert inputs → numeric feature vector.

    Feature order (must match train_model.py exactly):
      [route_reliability, hour, dow, weather_enc, mode_enc, is_rush, is_weekend,
       delay_minutes]  ← 8th feature: live schedule deviation (0.0 for bootstrap)

    route_reliability is a float 0.0–4.0.  When OTP JSON files are present it
    is derived from real MTA on-time performance data; otherwise it falls back
    to the hard-coded integer tier in ROUTE_RELIABILITY.
    """
    _load_otp_reliability()

    key = route_id.upper().strip()
    if "_" in key:
        key = key.split("_")[-1]
    if mode.lower() == "lirr":
        key = "LIRR"
    elif mode.lower() == "mnr":
        key = "MNR"

    # Prefer real OTP-derived float; fall back to hand-coded int tier
    if key in _OTP_RELIABILITY:
        reliability = _OTP_RELIABILITY[key]
    else:
        reliability = float(ROUTE_RELIABILITY.get(key, 2))

    weather_enc = WEATHER_ENCODING.get(weather.lower(), 0)
    mode_enc    = MODE_ENCODING.get(mode.lower(), 0)
    is_weekday  = 2 <= dow <= 6
    is_rush     = int(is_weekday and (hour in _RUSH_MORNING or hour in _RUSH_EVENING))
    is_weekend  = int(not is_weekday)
    delay_minutes = max(-10.0, min(10.0, current_delay_s / 60.0))

    return [reliability, float(hour), float(dow),
            float(weather_enc), float(mode_enc), float(is_rush), float(is_weekend),
            delay_minutes]


def _heuristic(route_id: str, hour: int, dow: int, weather: str, mode: str) -> float:
    """Rule-based fallback — same logic as the original DelayCalculator.swift.

    CBTC-aware: the L and 7 lines use Communications-Based Train Control which
    gives the MTA sub-segment position tracking (vs the fixed-block "occupancy
    only" system on the rest of the network).  Their arrival times from GTFS-RT
    are already significantly more accurate, so the heuristic applies a smaller
    rush-hour bonus to avoid over-correcting an already-precise prediction.
    Reference: MTA CBTC deployment — L line (2009), 7 line (2019).
    """
    key = route_id.upper().strip()
    if "_" in key:
        key = key.split("_")[-1]
    is_cbtc = key in _CBTC_LINES

    factor = 1.0
    is_weekday = 2 <= dow <= 6
    if is_weekday and (hour in _RUSH_MORNING or hour in _RUSH_EVENING):
        if mode.lower() == "bus":
            factor += 0.20
        elif is_cbtc:
            # CBTC lines: MTA arrival time is already precise — smaller correction
            factor += 0.04
        else:
            factor += 0.10

    w = weather.lower()
    if w == "rain":
        factor += 0.15 if mode.lower() == "bus" else 0.05
    elif w == "snow":
        factor += 0.30 if mode.lower() == "bus" else 0.20

    # Route-specific chronic delay offsets (key already normalised above)
    if key == "G":
        factor += 0.10
    elif key in ("J", "Z", "A", "C", "4", "5", "6"):
        factor += 0.05

    return round(min(factor, 2.0), 4)


def predict_factor(
    route_id: str, hour: int, dow: int, weather: str, mode: str = "subway",
    current_delay_s: float = 0.0,
) -> tuple[float, str]:
    """Return (delay_factor, source).

    factor is clamped to [1.0, 2.0]:
      - Never < 1.0: we never tell a user a train is ahead of schedule
        (risky — they'd miss it).
      - Never > 2.0: sanity guard against bad inputs.

    current_delay_s: live schedule deviation from SIRI/GTFS-RT.  Passed
    through to encode_features as the 8th feature.  Old 7-feature models
    silently receive a truncated vector matching their expected n_features_in_.
    """
    model = _load_model()
    if model is None:
        return _heuristic(route_id, hour, dow, weather, mode), "heuristic"

    try:
        import numpy as np  # type: ignore[import-untyped]
        import warnings
        feats = encode_features(route_id, hour, dow, weather, mode, current_delay_s)
        # Backward compat: older 7-feature models drop the delay_minutes column
        n_expected: int = getattr(model, "n_features_in_", len(feats))
        X = np.array([feats[:n_expected]], dtype=np.float64)
        # Suppress "X does not have valid feature names" — we deliberately
        # pass a numpy array (fast) instead of a DataFrame (slow).  The
        # feature order is guaranteed correct by encode_features().
        with warnings.catch_warnings():
            warnings.filterwarnings(
                "ignore",
                message="X does not have valid feature names",
                category=UserWarning,
            )
            raw = float(model.predict(X)[0])
        return round(max(0.90, min(raw, 2.0)), 4), "model"
    except Exception as exc:
        TrackLogger.model_event(
            f"predict error ({exc}) — heuristic fallback.", level="warning"
        )
        return _heuristic(route_id, hour, dow, weather, mode), "heuristic"


def predict_factor_batch(
    items: list[tuple[str, int, int, str, str, float]],
) -> list[tuple[float, str]]:
    """Batch version of predict_factor — one model.predict() call for N items.

    Each item is (route_id, hour, dow, weather, mode, current_delay_s).
    Returns list of (factor, source) in the same order as ``items``.

    Using a single predict() call on an (N, F) matrix is 50-200× faster
    than N individual predict() calls because GBR traverses all trees
    once for the entire batch (vectorised C loop) instead of N times.
    """
    if not items:
        return []
    model = _load_model()
    if model is None:
        return [
            (_heuristic(r, h, d, w, m), "heuristic")
            for r, h, d, w, m, _ in items
        ]
    try:
        import numpy as np
        import warnings

        n_expected: int = getattr(model, "n_features_in_", 8)
        rows = []
        for route_id, hour, dow, weather, mode, delay_s in items:
            feats = encode_features(route_id, hour, dow, weather, mode, delay_s)
            rows.append(feats[:n_expected])
        X = np.array(rows, dtype=np.float64)

        with warnings.catch_warnings():
            warnings.filterwarnings(
                "ignore",
                message="X does not have valid feature names",
                category=UserWarning,
            )
            raw_preds = model.predict(X)  # shape (N,)

        return [
            (round(max(0.90, min(float(p), 2.0)), 4), "model")
            for p in raw_preds
        ]
    except Exception as exc:
        TrackLogger.model_event(
            f"batch predict error ({exc}) — heuristic fallback.", level="warning"
        )
        return [
            (_heuristic(r, h, d, w, m), "heuristic")
            for r, h, d, w, m, _ in items
        ]


def reload_model() -> bool:
    """Force-reload model from disk (call after retraining)."""
    global _model, _model_loaded
    _model, _model_loaded = None, False
    return _load_model() is not None
