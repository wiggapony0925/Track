"""ML model visualization dashboard for Track.

Generates a multi-panel PNG showing how the delay-factor model behaves:
  1. Feature importances (horizontal bar chart)
  2. Delay factor by hour of day (line chart, per mode)
  3. Delay factor by reliability tier (box plot)
  4. ETA accuracy benchmark buckets (stacked bar chart)
  5. Prediction error distribution (histogram)
  6. Rush vs off-peak factor comparison (grouped bar chart)

Run directly:
    python -m app.ml.visualize               # default output: ml_dashboard.png
    python -m app.ml.visualize -o report.png  # custom output path
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path
from typing import Any

import numpy as np  # type: ignore

from app.ml.delay_model import FEATURE_NAMES, SEASON_ENCODING

# ── Paths ──────────────────────────────────────────────────────────────────
_ROOT = Path(__file__).resolve().parent.parent.parent  # TrackBackend/
_MODEL_PATH = _ROOT / "app" / "data" / "delay_model.pkl"
_DEFAULT_OUT = _ROOT / "ml_dashboard.png"


# ── Helpers ────────────────────────────────────────────────────────────────


def _load_model() -> Any:
    """Load the trained LightGBM model from disk."""
    import joblib  # type: ignore

    if not _MODEL_PATH.exists():
        print(
            f"ERROR: No model found at {_MODEL_PATH}.  "
            f"Train first: python -m app.ml.train_model",
            file=sys.stderr,
        )
        sys.exit(1)
    return joblib.load(_MODEL_PATH)


def _synthetic_grid() -> tuple[np.ndarray, dict[str, np.ndarray]]:
    """Build a grid of synthetic feature vectors covering the input space.

    Feature order matches ``FEATURE_NAMES`` (v3, 14 features).

    Returns:
        (X_grid, meta) where meta maps column names to their values.
    """
    _two_pi = 2.0 * math.pi
    hours = np.arange(0, 24)
    dows = np.arange(1, 8)  # 1=Sun .. 7=Sat
    reliabilities = np.array([0, 1, 2, 3, 4], dtype=float)
    modes = np.array([0.0, 1.0, 2.0, 3.0])  # subway, bus, lirr, mnr
    weathers = np.array([0.0, 1.0, 2.0])  # clear, rain, snow
    month = 6.0  # June — a neutral baseline month

    rows: list[list[float]] = []
    for rel in reliabilities:
        for hour in hours:
            for dow in dows:
                for mode in modes:
                    for weather in weathers:
                        is_weekday = 2 <= dow <= 6
                        is_rush = float(
                            is_weekday
                            and (
                                hour in range(7, 10)
                                or hour in range(17, 20)
                            )
                        )
                        season = float(
                            SEASON_ENCODING.get(int(month), 0)
                        )
                        rows.append([
                            rel,
                            float(hour),
                            float(dow),
                            weather,
                            mode,
                            is_rush,
                            float(not is_weekday),
                            0.0,  # delay_minutes baseline
                            month,
                            season,
                            math.sin(_two_pi * hour / 24.0),
                            math.cos(_two_pi * hour / 24.0),
                            math.sin(_two_pi * dow / 7.0),
                            math.cos(_two_pi * dow / 7.0),
                        ])
    X = np.array(rows, dtype=float)

    # Wrap in a DataFrame so LightGBM sees the feature names
    # the model was trained with, avoiding UserWarnings.
    import pandas as pd  # type: ignore[import-untyped]

    n_model = len(FEATURE_NAMES)
    X_df = pd.DataFrame(X[:, :n_model], columns=FEATURE_NAMES[:n_model])

    meta = {
        "reliability": X[:, 0],
        "hour": X[:, 1],
        "dow": X[:, 2],
        "weather": X[:, 3],
        "mode": X[:, 4],
        "is_rush": X[:, 5],
        "is_weekend": X[:, 6],
    }
    return X_df, meta


_MODE_LABELS = {0.0: "Subway", 1.0: "Bus", 2.0: "LIRR", 3.0: "MNR"}
_MODE_COLORS = {
    0.0: "#1f77b4",
    1.0: "#ff7f0e",
    2.0: "#2ca02c",
    3.0: "#d62728",
}
_WEATHER_LABELS = {0.0: "Clear", 1.0: "Rain", 2.0: "Snow"}


# ── Panel builders ─────────────────────────────────────────────────────────


def _panel_feature_importance(ax: Any, model: Any) -> None:
    """Panel 1: Horizontal bar chart of feature importances."""
    importances = model.feature_importances_
    n_features = len(importances)
    names = FEATURE_NAMES[:n_features]

    # Sort by importance
    idx = np.argsort(importances)
    ax.barh(
        np.array(names)[idx],
        importances[idx] / (importances.sum() or 1),
        color="#4c72b0",
        edgecolor="white",
    )
    ax.set_xlabel("Relative Importance")
    ax.set_title("Feature Importances (Gain)")


def _panel_factor_by_hour(
    ax: Any,
    predictions: np.ndarray,
    meta: dict[str, np.ndarray],
) -> None:
    """Panel 2: Delay factor vs hour of day, one line per mode."""
    # Filter to weekday, clear weather, reliability=2 for a clean view
    mask = (
        (meta["weather"] == 0.0)
        & (meta["dow"] >= 2)
        & (meta["dow"] <= 6)
        & (meta["reliability"] == 2.0)
    )
    for mode_val, label in _MODE_LABELS.items():
        m = mask & (meta["mode"] == mode_val)
        if not m.any():
            continue
        hours = meta["hour"][m]
        factors = predictions[m]
        # average per hour
        unique_hours = np.arange(0, 24)
        avg_factors = np.array(
            [
                factors[hours == h].mean() if (hours == h).any() else np.nan
                for h in unique_hours
            ]
        )
        ax.plot(
            unique_hours,
            avg_factors,
            label=label,
            color=_MODE_COLORS[mode_val],
            linewidth=2,
        )

    ax.set_xlabel("Hour of Day")
    ax.set_ylabel("Delay Factor")
    ax.set_title("Delay Factor by Hour (Weekday, Clear)")
    ax.legend(fontsize=8)
    ax.set_xticks([0, 4, 8, 12, 16, 20])
    ax.axvspan(7, 10, alpha=0.08, color="red", label="AM Rush")
    ax.axvspan(17, 20, alpha=0.08, color="orange", label="PM Rush")
    ax.grid(True, alpha=0.3)


def _panel_factor_by_reliability(
    ax: Any,
    predictions: np.ndarray,
    meta: dict[str, np.ndarray],
) -> None:
    """Panel 3: Box plot of delay factor by reliability tier."""
    mask = (meta["weather"] == 0.0) & (meta["mode"] == 0.0)  # subway, clear
    tiers = [0, 1, 2, 3, 4]
    data = []
    for t in tiers:
        m = mask & (meta["reliability"] == float(t))
        data.append(predictions[m])

    bp = ax.boxplot(
        data,
        tick_labels=[f"Tier {t}" for t in tiers],
        patch_artist=True,
    )
    colors = ["#2ecc71", "#27ae60", "#f39c12", "#e67e22", "#e74c3c"]
    for patch, color in zip(bp["boxes"], colors, strict=False):
        patch.set_facecolor(color)
        patch.set_alpha(0.7)

    ax.set_xlabel("Reliability Tier (0=best, 4=worst)")
    ax.set_ylabel("Delay Factor")
    ax.set_title("Delay Factor by Reliability (Subway, Clear)")
    ax.grid(True, alpha=0.3, axis="y")


def _panel_eta_benchmark(ax: Any, predictions: np.ndarray, y: np.ndarray) -> None:
    """Panel 4: ETA benchmark accuracy per time bucket."""
    from app.ml.eta_accuracy_benchmark import (
        BUCKETS,
        PredictionSample,
        run_benchmark,
    )

    baseline_s = 600.0
    samples = []
    for pred, actual in zip(predictions, y, strict=False):
        samples.append(
            PredictionSample(
                predicted_arrival_ts=float(pred) * baseline_s,
                actual_arrival_ts=float(actual) * baseline_s,
                sample_ts=0.0,
                source="model",
            )
        )

    result = run_benchmark(samples)

    bucket_names = [b.name for b in BUCKETS]
    accuracies = []
    early_rates = []
    late_rates = []
    for br in result.bucket_results:
        accuracies.append(br.accuracy)
        early_rates.append(br.early_miss_rate)
        late_rates.append(br.late_miss_rate)

    x = np.arange(len(bucket_names))
    width = 0.28
    ax.bar(x - width, accuracies, width, label="Accurate", color="#2ecc71")
    ax.bar(x, early_rates, width, label="Early Miss", color="#e74c3c")
    ax.bar(x + width, late_rates, width, label="Late Miss", color="#f39c12")

    ax.set_xticks(x)
    ax.set_xticklabels(bucket_names, fontsize=8)
    ax.set_ylabel("Rate")
    ax.set_title(f"ETA Benchmark ({result.overall_accuracy:.1%} overall)")
    ax.legend(fontsize=7)
    ax.set_ylim(0, 1.05)
    ax.grid(True, alpha=0.3, axis="y")


def _panel_error_distribution(
    ax: Any,
    predictions: np.ndarray,
    y: np.ndarray,
) -> None:
    """Panel 5: Histogram of prediction errors (predicted - actual)."""
    errors = (predictions - y) * 10  # convert to minutes on a 10-min trip
    ax.hist(
        errors,
        bins=50,
        color="#3498db",
        edgecolor="white",
        alpha=0.8,
        density=True,
    )
    mean_err = errors.mean()
    std_err = errors.std()
    ax.axvline(mean_err, color="red", linestyle="--", linewidth=1.5)
    ax.set_xlabel("Error (minutes, on 10-min trip)")
    ax.set_ylabel("Density")
    ax.set_title(f"Prediction Error Dist (mean={mean_err:.2f}, std={std_err:.2f})")
    ax.grid(True, alpha=0.3)


def _panel_rush_comparison(
    ax: Any,
    predictions: np.ndarray,
    meta: dict[str, np.ndarray],
) -> None:
    """Panel 6: Rush vs off-peak grouped bar chart per mode."""
    mask_clear = meta["weather"] == 0.0
    modes = [0.0, 1.0, 2.0, 3.0]
    labels = [_MODE_LABELS[m] for m in modes]

    rush_means = []
    offpeak_means = []
    for mode_val in modes:
        m_mode = mask_clear & (meta["mode"] == mode_val)
        rush_mask = m_mode & (meta["is_rush"] == 1.0)
        offpeak_mask = m_mode & (meta["is_rush"] == 0.0)
        rush_means.append(predictions[rush_mask].mean() if rush_mask.any() else 0)
        offpeak_means.append(
            predictions[offpeak_mask].mean() if offpeak_mask.any() else 0
        )

    x = np.arange(len(modes))
    width = 0.35
    ax.bar(x - width / 2, rush_means, width, label="Rush Hour", color="#e74c3c")
    ax.bar(
        x + width / 2,
        offpeak_means,
        width,
        label="Off-Peak",
        color="#3498db",
    )
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_ylabel("Avg Delay Factor")
    ax.set_title("Rush Hour vs Off-Peak (Clear Weather)")
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3, axis="y")


# ── Main dashboard builder ────────────────────────────────────────────────


def generate_dashboard(output_path: Path | None = None) -> Path:
    """Generate the 6-panel ML dashboard PNG.

    Args:
        output_path: Where to save the image. Defaults to ml_dashboard.png.

    Returns:
        Path to the saved image.
    """
    import matplotlib

    matplotlib.use("Agg")  # non-interactive backend
    import matplotlib.pyplot as plt

    out = output_path or _DEFAULT_OUT

    print("\n━━━  Track ML — Visual Dashboard  ━━━\n")

    # Load model
    print("  Loading model ...", flush=True)
    model = _load_model()

    # Build synthetic grid and predict
    print("  Generating prediction grid ...", flush=True)
    X_grid, meta = _synthetic_grid()
    predictions = model.predict(X_grid)

    # Add small noise to predictions as synthetic "actuals" for benchmark
    # and error distribution panels.
    rng = np.random.default_rng(42)
    y_noisy = predictions + rng.normal(0, 0.02, size=len(predictions))

    # Create figure
    print("  Rendering panels ...", flush=True)
    fig, axes = plt.subplots(2, 3, figsize=(18, 10))
    fig.suptitle(
        "Track ML — Delay Factor Model Dashboard",
        fontsize=16,
        fontweight="bold",
        y=0.98,
    )

    _panel_feature_importance(axes[0, 0], model)
    _panel_factor_by_hour(axes[0, 1], predictions, meta)
    _panel_factor_by_reliability(axes[0, 2], predictions, meta)
    _panel_eta_benchmark(axes[1, 0], predictions, y_noisy)
    _panel_error_distribution(axes[1, 1], predictions, y_noisy)
    _panel_rush_comparison(axes[1, 2], predictions, meta)

    fig.tight_layout(rect=[0, 0, 1, 0.95])
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)

    print(f"  Dashboard saved → {out}")
    print(f"  ({out.stat().st_size / 1024:.0f} KB)\n")
    return out


# ── CLI entry-point ────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a visual dashboard for the Track ML model."
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Output PNG path (default: ml_dashboard.png in TrackBackend/)",
    )
    args = parser.parse_args()
    generate_dashboard(output_path=args.output)


if __name__ == "__main__":
    main()
