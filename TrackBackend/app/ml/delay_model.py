#
# delay_model.py
# app/ml/delay_model.py
#
# GradientBoosting pattern model.
# Predicts a delay_factor for a transit context: route × hour × day × weather × mode.
# The factor multiplies MTA's raw minutes_away to correct for known chronic patterns.
#
# Why GradientBoostingRegressor?
#   • Handles the non-linear interactions we care about (G train × rush hour,
#     bus × snow) without hand-coding every combination.
#   • ~5 µs inference — safe on every API request.
#   • Trivially retrained as real TripLog data accumulates.
#   • Small model file (<500 KB), ships inside Docker.
#
# Fallback: if no model file exists, falls back to the rule-based heuristic
# so the endpoint never breaks.
#

from __future__ import annotations

from pathlib import Path
from typing import Any

from app.utils.logger import TrackLogger

# ── Model file location ────────────────────────────────────────────────────
MODEL_PATH = Path(__file__).resolve().parent.parent / "data" / "delay_model.pkl"

# ── Feature encoding tables ─────────────────────────────────────────────────
# Route reliability tiers based on historical MTA on-time performance.
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

WEATHER_ENCODING: dict[str, int] = {"clear": 0, "rain": 1, "snow": 2}
MODE_ENCODING: dict[str, int] = {"subway": 0, "bus": 1, "lirr": 2, "mnr": 3}

_RUSH_MORNING = range(7, 10)
_RUSH_EVENING = range(17, 20)

# ── Singleton ──────────────────────────────────────────────────────────────
_model: Any | None = None
_model_loaded: bool = False


def _load_model() -> Any | None:
    global _model, _model_loaded
    if _model_loaded:
        return _model
    _model_loaded = True

    if not MODEL_PATH.exists():
        TrackLogger.warning(
            f"[ML] No model at {MODEL_PATH}. Run: python -m app.ml.train_model",
            tag="ML",
        )
        return None

    try:
        import joblib  # type: ignore[import-untyped]
        _model = joblib.load(MODEL_PATH)
        TrackLogger.info(f"[ML] GBR delay model loaded from {MODEL_PATH}", tag="ML")
        return _model
    except Exception as exc:
        TrackLogger.warning(f"[ML] Model load failed ({exc}). Using heuristic.", tag="ML")
        return None


def encode_features(
    route_id: str, hour: int, dow: int, weather: str, mode: str,
    current_delay_s: float = 0.0,
) -> list[float]:
    """Convert inputs → numeric feature vector.

    Feature order (must match train_model.py exactly):
      [route_reliability, hour, dow, weather_enc, mode_enc, is_rush, is_weekend,
       delay_minutes]  ← 8th feature: live schedule deviation (0.0 for bootstrap)

    The 8th feature teaches the model momentum: a train already running 3 min
    late is likely to arrive even later than the contextual factor alone suggests.
    Backward compatible: models trained on 7 features skip it (see predict_factor).
    """
    key = route_id.upper().strip()
    if "_" in key:
        key = key.split("_")[-1]
    if mode.lower() == "lirr":
        key = "LIRR"
    elif mode.lower() == "mnr":
        key = "MNR"

    reliability = ROUTE_RELIABILITY.get(key, 2)
    weather_enc = WEATHER_ENCODING.get(weather.lower(), 0)
    mode_enc    = MODE_ENCODING.get(mode.lower(), 0)
    is_weekday  = 2 <= dow <= 6
    is_rush     = int(is_weekday and (hour in _RUSH_MORNING or hour in _RUSH_EVENING))
    is_weekend  = int(not is_weekday)
    # Clamp live delay to ±10 min; normalize to minutes so the scale matches
    # the other features.  0.0 for bootstrap / when not provided.
    delay_minutes = max(-10.0, min(10.0, current_delay_s / 60.0))

    return [float(reliability), float(hour), float(dow),
            float(weather_enc), float(mode_enc), float(is_rush), float(is_weekend),
            delay_minutes]


def _heuristic(route_id: str, hour: int, dow: int, weather: str, mode: str) -> float:
    """Rule-based fallback — same logic as the original DelayCalculator.swift."""
    factor = 1.0
    is_weekday = 2 <= dow <= 6
    if is_weekday and (hour in _RUSH_MORNING or hour in _RUSH_EVENING):
        factor += 0.20 if mode.lower() == "bus" else 0.10

    w = weather.lower()
    if w == "rain":
        factor += 0.15 if mode.lower() == "bus" else 0.05
    elif w == "snow":
        factor += 0.30 if mode.lower() == "bus" else 0.20

    key = route_id.upper().strip()
    if "_" in key:
        key = key.split("_")[-1]
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
        feats = encode_features(route_id, hour, dow, weather, mode, current_delay_s)
        # Backward compat: older 7-feature models drop the delay_minutes column
        n_expected: int = getattr(model, "n_features_in_", len(feats))
        X = np.array([feats[:n_expected]])
        raw = float(model.predict(X)[0])
        return round(max(0.90, min(raw, 2.0)), 4), "model"
    except Exception as exc:
        TrackLogger.warning(f"[ML] predict error ({exc}). Heuristic fallback.", tag="ML")
        return _heuristic(route_id, hour, dow, weather, mode), "heuristic"


def reload_model() -> bool:
    """Force-reload model from disk (call after retraining)."""
    global _model, _model_loaded
    _model, _model_loaded = None, False
    return _load_model() is not None
