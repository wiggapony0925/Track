# Track ML — Delay Prediction System

> **Current model:** LightGBM · 3,873,270 training samples · 14 v3 features · R² 0.715 · MAE 0.122 · 95.2% ETA accuracy
> **Last trained:** April 1, 2026 · `app/data/delay_model.pkl` (1,476 KB) · 212 trees (early-stopped)

## Overview

The Track ML system corrects MTA's raw `minutes_away` values before they
reach the iOS app.  Instead of displaying whatever the MTA GTFS-RT feed
reports, every arrival time passes through a **four-stage pipeline** that
accounts for chronic route patterns, current service alerts, and recent
real-world observations at the specific stop.

The result is a single corrected integer (still called `minutes_away`)
that the iOS app uses directly — no frontend changes required.

---

## Architecture

```
MTA GTFS-RT / SIRI feed
        │
        ▼
  raw minutes_away
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│                  _ml_corrected()                         │
│              app/routers/nearby.py                       │
│                                                          │
│  Step 1 ── Alert boost          alert_service.py         │
│            SEVERE → ×1.25                                │
│            WARNING → ×1.10                               │
│                                                          │
│  Step 2 ── LightGBM delay factor  delay_model.py        │
│            f(14 features incl. cyclical encodings)       │
│            range: [0.90, 2.0]                            │
│                                                          │
│  Step 3 ── Recency delta          recency_model.py       │
│            EWMA of observed stop errors (±5 min cap)     │
│            from Redis ZSET  (λ=0.5, half-life ≈ 1.4 h)  │
│                                                          │
│  Step 4 ── Blend + horizon cap                           │
│            base_s  = raw_s + recency_delta               │
│            factor  = min(2.0, lgbm × (1 + alert_boost)) │
│            result  = base_s × factor / 60               │
│            capped at ±2/3/4 min depending on horizon     │
└──────────────────────────────────────────────────────────┘
        │
        ▼
  corrected minutes_away  →  iOS app
```

---

## Feature Vector v3 (14 features)

| # | Name | Type | Source | Description |
|---|------|------|--------|-------------|
| 0 | `route_reliability` | int 0–4 | GTFS route table | Reliability tier. 0 = most reliable (L, SI), 4 = chronically late (G). |
| 1 | `hour` | int 0–23 | request time | Current hour of request. |
| 2 | `dow` | int 1–7 | request time | Day of week. Mon=2, Sun=1 (legacy convention). |
| 3 | `weather` | int 0–6 | weather API | 7-tier encoding: clear=0 → heavy\_snow=6. |
| 4 | `mode` | int 0–3 | route prefix | subway=0, bus=1, lirr=2, mnr=3. |
| 5 | `is_rush` | int 0/1 | hour+dow | 1 if weekday 7–9 AM or 5–7 PM. |
| 6 | `is_weekend` | int 0/1 | dow | 1 if Saturday or Sunday. |
| 7 | `delay_minutes` | float | SIRI live | Schedule deviation clamped ±10 min. Encodes momentum. |
| 8 | `month` | int 1–12 | request time | Calendar month (v2). |
| 9 | `season` | int 0–3 | month | 0=winter, 1=spring, 2=summer, 3=fall (v2). |
| 10 | `hour_sin` | float | hour | sin(2π × hour / 24) — cyclical encoding (v3). |
| 11 | `hour_cos` | float | hour | cos(2π × hour / 24) — cyclical encoding (v3). |
| 12 | `dow_sin` | float | dow | sin(2π × dow / 7) — cyclical encoding (v3). |
| 13 | `dow_cos` | float | dow | cos(2π × dow / 7) — cyclical encoding (v3). |

> **Weather note:** Feature 3 is always `clear` (0) inside `_ml_corrected()`.
> Weather's real-time impact is already captured by feature 7 (`delay_minutes`)
> — SIRI `schedule_deviation_s` reflects actual running time including weather
> conditions.  Keeping weather as a feature preserves the model's learned
> seasonal patterns for bootstrap training.

> **Cyclical note (v3):** Raw `hour` and `dow` create an artificial boundary
> (hour 23 → 0 looks like a 23-unit jump).  sin/cos encoding tells the model
> that midnight is adjacent to 23:00, and Sunday is adjacent to Monday.

---

## Module Reference

### `delay_model.py` — LightGBM Inference Singleton

Predicts a multiplicative delay factor for a given transit context using a
LightGBM regressor trained on 3.87M samples of GTFS-bootstrapped +
MTA open data.

#### Key Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `encode_features()` | `(route_id, hour, dow, weather, mode, current_delay_s=0.0) → list[float]` | Builds 14-element v3 vector. |
| `predict_factor()` | `(route_id, hour, dow, weather, mode="subway", current_delay_s=0.0) → (float, str)` | Returns `(factor ∈ [0.90, 2.0], "model"\|"heuristic")`. |
| `predict_factor_batch()` | `(items: list[tuple]) → list[tuple[float, str]]` | Vectorised batch; 50–200× faster. |
| `reload_model()` | `() → bool` | Force-reload from disk (hot swap). |
| `ensure_model_loaded()` | `async () → None` | Pre-loads model in background thread at startup. |

#### Constants

| Constant | Value |
|----------|-------|
| `MODEL_PATH` | `app/data/delay_model.pkl` |
| `FACTOR_MIN` / `FACTOR_MAX` | 0.90 / 2.0 |
| `SEASON_ENCODING` | `{1:0, 2:0, 3:1, 4:1, 5:1, 6:2, 7:2, 8:2, 9:3, 10:3, 11:3, 12:0}` |
| `WEATHER_ENCODING` | 7 tiers (0–6): clear…heavy_snow (17 string keys) |
| `MODE_ENCODING` | `{"subway":0, "bus":1, "lirr":2, "mnr":3}` |
| `_CBTC_LINES` | `frozenset({"L", "7"})` |

#### Route Reliability Tiers

| Tier | Routes |
|------|--------|
| 0 | SI, L |
| 1 | 7, W, Z, SIR |
| 2 | 1, 2, 3, R, N, Q, M, B, D, E, F, S, LIRR, MNR |
| 3 | 4, 5, 6, J, A, C |
| 4 | G |

#### Model File

- Path: `app/data/delay_model.pkl`
- Format: joblib-serialised `lightgbm.LGBMRegressor`
- Size: ~1,476 KB (212 trees × 14 features)
- Loaded once on first request (singleton), then cached in memory (~5 µs per inference)

---

### `train_model.py` — Training Pipeline

6-step end-to-end training orchestrator.  Supports optional Optuna
Bayesian hyperparameter search.

#### Pipeline Steps

```
Step 1/6  Read GTFS database (transit_schedule.db)
          └→ _build_route_table()  →  per-route facts (mode, reliability, hours)

Step 2/6  Generate bootstrap samples from route table
          └→ generate_bootstrap_samples()  →  ~622K synthetic (X, y, w) at weight=0.5

Step 3/6  Load MTA open data (30 JSON files, 11 loaders)
          └→ data_loaders.load_mta_open_data()  →  ~3.25M real (X, y, w) at weight=0.6–0.9

Step 4/6  Train LightGBM
          └→ train()  →  85/15 holdout, early stopping, optional Optuna

Step 5/6  Save model + print evaluation
          └→ joblib.dump()  →  delay_model.pkl

Step 6/6  Post-train benchmark + logging
          └→ _run_post_train_benchmark()  →  Transit App ETA accuracy
          └→ _log_training_run()  →  append JSONL to training_runs.jsonl
```

#### Optuna Tuning (when `--tune` is passed)

| Parameter | Value |
|-----------|-------|
| Trials | 30 |
| CV folds | 3 (`KFold`) |
| Subsample cap | 500,000 samples |
| Scoring metric | Negative MAE |

Search space includes `num_leaves`, `learning_rate`, `subsample`,
`colsample_bytree`, `min_child_samples`, `reg_alpha`, `reg_lambda`.

#### Default Hyperparameters (no `--tune`)

```
n_estimators       2000 (early-stopped to ~212)
num_leaves         63
learning_rate      0.05
subsample          0.8
colsample_bytree   0.8
min_child_samples  20
reg_alpha          0.1
reg_lambda         0.1
early_stopping     50 rounds (15% internal validation split)
```

#### Bootstrap Factor Priors

| Tier | Base Factor | Routes |
|------|-------------|--------|
| 0 | 1.02 | L, SI |
| 1 | 1.04 | 7, W, SIR |
| 2 | 1.07 | Most lines, LIRR, MNR |
| 3 | 1.10 | A, C, 4, 5, 6, J |
| 4 | 1.16 | G |

Rush-hour additive: +0.10 (subway), +0.20 (bus)
Weather additive (subway): rain +0.05, snow +0.20
Weather additive (bus): rain +0.15, snow +0.30
Gaussian noise σ=0.03 prevents overfitting to exact priors.

#### Training Run Logging

Every training run appends a JSONL record to `app/data/training_runs.jsonl`:

```json
{
  "timestamp": "2026-04-01T23:59:06.399492+00:00",
  "holdout_mae": 0.13064,
  "holdout_r2": 0.71632,
  "n_estimators": 212,
  "n_features": 14,
  "n_train": 3292279,
  "n_test": 580991,
  "best_params": { "...": "..." },
  "feature_importances": { "hour": 0.178, "...": "..." },
  "tuned": false,
  "eta_accuracy": 0.9525,
  "model_size_kb": 1476.0,
  "total_samples": 3873270
}
```

The Jupyter notebook (`model_insights.ipynb`) reads this log to plot
metric trends across training runs.

#### CLI

```bash
python -m app.ml.train_model               # standard training (~2 min)
python -m app.ml.train_model --tune         # + Optuna search (~4 min)
python -m app.ml.train_model --real-data X  # blend real Redis observations
```

---

### `data_loaders.py` — MTA Open Data Loaders

Reads 30 JSON/CSV files from `app/data/training/` into `(X, y, w)` tuples.
Each loader converts MTA performance metrics (OTP percentages, wait
assessment, segment speeds, delay incidents) into delay-factor labels.

#### 11 Loaders

| # | Function | Dataset | Records | Weight |
|---|----------|---------|---------|--------|
| 1 | `_load_subway_otp()` | subway_otp\_\*.json (3 eras) | ~4.9K | builds reliability dict |
| 2 | `_load_subway_customer_journey()` | subway\_customer\_journey\_\*.json | ~5.5K | 0.8 |
| 3 | `_load_lirr_otp()` | lirr_otp.json | ~1.6K | 0.8 |
| 4 | `_load_mnr_otp()` | metro\_north\_otp.json | ~511 | 0.8 |
| 5 | `_load_bus_customer_journey()` | bus\_customer\_journey.json | ~64.5K | 0.8 |
| 6 | `_load_bus_wait_assessment()` | bus\_wait\_assessment.json | ~162K | 0.7 |
| 7 | `_load_subway_delay_incidents()` | subway\_delay\_incidents.json | ~22.8K | 0.6 |
| 8 | `_load_subway_trains_delayed()` | subway\_trains\_delayed.json | ~17.4K | 0.6 |
| 9 | `_load_bus_service_delivered()` | bus\_service\_delivered.json | ~79K | 0.7 |
| 10 | `_load_bus_segment_speeds()` | bus\_segment\_speeds\_\*.json (3 files) | **~1M** | 0.9 |
| 11 | `_load_mta_service_alerts()` | mta\_service\_alerts.json | **~470K** | 0.6 |

**Total MTA open data contribution:** ~3.25M samples.

#### Public API

```python
def load_mta_open_data() -> tuple[list, list, list]
    # Orchestrates all 11 loaders.
def load_real_observations(csv_path: Path) -> tuple[list, list, list]
    # Reads export_observations CSV at weight=1.0.
```

---

### `recency_model.py` — Per-Stop EWMA Recency Correction

Watches GTFS-RT/SIRI polls, records actual-vs-predicted errors per stop,
returns an exponentially-weighted mean to correct `minutes_away`.

#### Observation Paths

| Path | Source | Signal Volume |
|------|--------|---------------|
| **A** — `observe_trip_updates()` | GTFS-RT snapshots (`data_cleaner.py`) | Every ~30s, detects stops that disappeared |
| **B** — `observe_siri_delay()` | SIRI StopMonitoring (`bus_client.py`) | Every poll; 10–30× more signal for bus routes |

Both paths write to the same Redis sorted-set structure:

```
track:recency:obs:{route}:{stop_id}:{dow}:{hour}  ZSET  TTL=25h  max=50
```

#### Query: `get_weighted_error(route_id, stop_id, dow, hour)`

1. Fetch exact `(route, stop, dow, hour)` bucket (2× weight).
2. Fetch adjacent hours `(hour−1)` and `(hour+1)` at 1× weight.
3. Apply exponential decay: `w = exp(−0.5 × age_hours)`.
4. Return weighted mean error in seconds, or `None` if < 3 observations.

| Constant | Value | Meaning |
|----------|-------|---------|
| `_LAMBDA` | 0.5 | Decay constant → half-life ≈ 1.4 hours |
| `MAX_OBS_PER_KEY` | 50 | Max ZSET cardinality |
| `MAX_AGE_HOURS` | 6.0 | Discard observations older than 6h |
| `_MAX_ERROR_SECS` | 600 | ±10 min garbage filter |

#### Batch API

```python
async def get_weighted_errors_batch(queries) -> dict[tuple, float | None]
    # Single-pipeline fetch; 1 Redis round-trip.
async def observe_siri_delays_batch(observations) -> None
async def observe_trip_updates_batch(trips) -> None
```

#### Graceful Degradation

Every Redis call is wrapped in `try/except`.  If Redis is unavailable,
`observe_*` is a no-op and `get_weighted_error` returns `None`.  The
pipeline treats `None` as zero delta — seamless fallback.

---

### `eta_accuracy_benchmark.py` — Transit App ETA Accuracy

Implements Transit App's open-source methodology with asymmetric
time-bucketed thresholds.

#### Time Buckets

| Bucket | Range | Early Tolerance | Late Tolerance |
|--------|-------|-----------------|----------------|
| 0–3 min | 0–180s | 30s | 90s |
| 3–6 min | 180–360s | 60s | 150s |
| 6–10 min | 360–600s | 60s | 210s |
| 10–15 min | 600–900s | 90s | 270s |

**Overall accuracy** = equally-weighted mean of 4 bucket-level percentages.

#### Key API

```python
def run_benchmark(samples: list[PredictionSample]) -> BenchmarkResult
def run_benchmark_by_route(samples) -> dict[str, BenchmarkResult]
def get_current_benchmark() -> dict[str, Any]  # API-ready JSON
```

Used by `train_model.py` post-train evaluation.  No CLI entry point.

---

### `export_observations.py` — Redis → CSV Exporter

Exports live Redis recency observations to CSV for retraining with `--real-data`.

**Output format:**

```csv
route_id,stop_id,hour,dow,weather,mode,actual_factor,deviation_s
A,404231,8,3,clear,subway,1.18,142.0
```

**Factor conversion:** `actual_factor = 1.0 + clamp(deviation_s, 0, 300) / 300`

```bash
python -m app.ml.export_observations                  # → observations.csv
python -m app.ml.export_observations -o my_data.csv   # custom path
python -m app.ml.export_observations --min-obs 5      # require ≥5 obs/key
```

Requires `REDIS_URL` env var.  Read-only.

---

### `visualize.py` — ML Dashboard PNG

Generates a 6-panel static dashboard image.

| Panel | Content |
|-------|---------|
| 1 | Feature importances (gain-based bar chart) |
| 2 | Delay factor by hour per mode (weekday, clear, tier 2) |
| 3 | Delay factor by reliability tier (box plot) |
| 4 | ETA accuracy benchmark (stacked bar) |
| 5 | Prediction error distribution (histogram) |
| 6 | Rush vs off-peak factor (grouped bar) |

```bash
python -m app.ml.visualize               # → ml_dashboard.png
python -m app.ml.visualize -o report.png  # custom output
```

---

### `model_insights.ipynb` — Interactive Jupyter Notebook

24-cell notebook for post-training model exploration.  Run after each
retrain to see how the model changed.

| Section | Cells | What it shows |
|---------|-------|---------------|
| Setup | 1–3 | Imports, load model, print vitals |
| Training History | 4 | JSONL log → metric trend plots (MAE, R², accuracy, size) |
| Feature Importance | 5 | Normalised gain bar chart |
| Holdout Data | 6 | Rebuild 85/15 split from GTFS + MTA data |
| SHAP | 7–9 | Beeswarm, bar, and dependence plots (10K sample) |
| Prediction Distribution | 10 | Histogram + actual-vs-predicted scatter |
| Error Analysis | 11–13 | MAE by hour (rush highlights), mode, reliability tier |
| Residual Analysis | 14 | Distribution, residual-vs-predicted, hourly bias |
| Health Summary | 15 | One-glance vitals card |

**Requirements:** `shap>=0.45.0`, `jupyterlab` (both in venv).

```bash
.venv/bin/jupyter lab app/ml/model_insights.ipynb
# Then: Run → Run All Cells
```

The generator script at `scripts/write_notebook.py` can regenerate the
notebook if cell edits are needed in bulk.

---

## The Correction Pipeline in Detail

`_ml_corrected(minutes_away, route_id, mode, stop_id, deviation_s)` in
`app/routers/nearby.py`:

```python
# Step 1 — alert boost (non-blocking, O(1))
await _maybe_refresh_alerts()
alert_boost = _get_alert_boost(route_id)          # 0.0 / 0.10 / 0.25

# Step 2 — LightGBM factor (~5 µs, sync)
factor, _ = _predict_factor(
    route_id=route_id, hour=hour, dow=dow,
    weather="clear",              # deviation_s encodes real weather impact
    mode=mode,
    current_delay_s=deviation_s,  # SIRI live schedule deviation
)                                 # factor ∈ [0.90, 2.0]

# Step 3 — recency delta (~1 ms, async Redis)
recency_s = 0.0
if stop_id:
    err = await _get_weighted_error(route_id, stop_id, dow, hour)
    if err is not None:
        recency_s = max(-300.0, min(300.0, err))  # cap ±5 min

# Step 4 — blend
base_seconds = max(0.0, minutes_away * 60.0 + recency_s)
final_factor = min(2.0, factor * (1.0 + alert_boost))
result       = round(base_seconds * final_factor / 60.0)

# Step 5 — horizon-scaled correction cap
max_delta = 2 if minutes_away <= 10 else (3 if minutes_away <= 25 else 4)
result    = max(minutes_away - max_delta, min(minutes_away + max_delta, result))
return max(0, result)
```

---

## Current Model Metrics

From the latest training run (April 1, 2026):

| Metric | Value |
|--------|-------|
| **Holdout MAE** | 0.122 |
| **Holdout R²** | 0.715 |
| **ETA Accuracy** | 95.2% |
| **Trees** | 212 (early-stopped from 2,000) |
| **Features** | 14 (v3 with cyclical encodings) |
| **Training samples** | 3,292,279 |
| **Holdout test** | 580,991 |
| **Total data** | 3,873,270 |
| **Model size** | 1,476 KB |
| **Mean bias** | 0.00072 (essentially zero) |

### Feature Importances (gain, normalised)

```
hour                 0.178  ███████████
month                0.144  █████████
route_reliability    0.123  ███████▋
hour_cos             0.081  █████
mode                 0.079  ████▉
hour_sin             0.078  ████▉
dow                  0.064  ████
is_rush              0.047  ██▉
weather              0.045  ██▊
delay_minutes        0.039  ██▍
season               0.037  ██▎
is_weekend           0.033  ██
dow_cos              0.026  █▌
dow_sin              0.026  █▌
```

`hour` + `hour_sin` + `hour_cos` combined = 33.7% — time-of-day is the
strongest predictor family.

---

## API Endpoint

### `GET /predict/delay`

Direct access to the LightGBM factor.  Used by the iOS app's
`DelayCalculator` fallback and for debugging.

**Query params:**

| Param | Type | Required | Example |
|-------|------|----------|---------|
| `route_id` | string | ✓ | `A`, `M34-SBS`, `LIRR_5` |
| `mode` | string | ✓ | `subway`, `bus`, `lirr`, `mnr` |
| `minutes_away` | int | ✓ | `8` |
| `hour` | int | ✓ | `8` |
| `day_of_week` | int | ✓ | `2` (Monday) |
| `weather` | string | | `clear` (default) |
| `stop_id` | string | | `404231` |
| `deviation_s` | float | | `142.0` |

**Response:**

```json
{
  "adjusted_minutes": 10,
  "original_minutes": 8,
  "delay_factor": 1.1984,
  "adjustment_reason": "+20% (rush hour, clear)",
  "model_source": "model",
  "recency_error_seconds": 0.0
}
```

---

## Operations

### Retrain the Model

```bash
cd TrackBackend
source .venv/bin/activate

# Standard training (~2 min)
python -m app.ml.train_model

# With Optuna hyperparameter search (~4 min)
python -m app.ml.train_model --tune

# Blend real Redis observations
python -m app.ml.train_model --real-data path/to/observations.csv
```

### Generate Dashboard

```bash
python -m app.ml.visualize               # → ml_dashboard.png
python -m app.ml.visualize -o report.png
```

### Open Insights Notebook

```bash
.venv/bin/jupyter lab app/ml/model_insights.ipynb
```

### Export Redis Observations

```bash
python -m app.ml.export_observations
# → observations.csv (requires REDIS_URL)
```

### Hot-Swap on Live Server (no restart)

```bash
curl -X POST https://track-vkrr.onrender.com/predict/reload-model
```

The singleton in `delay_model.py` resets `_model_loaded = False`,
triggering a fresh `joblib.load()` on the next inference request.

### View Model Status

```bash
curl 'https://track-vkrr.onrender.com/predict/delay?route_id=4&mode=subway&minutes_away=8&hour=8&day_of_week=2'
# model_source: "model"      ← LightGBM loaded
# model_source: "heuristic"  ← pkl missing or failed to load
```

---

## File Map

```
app/ml/
├── README.md                    ← this file
├── __init__.py
├── delay_model.py               ← LightGBM singleton, encode_features(), predict_factor()
├── recency_model.py             ← Redis EWMA per-stop error tracker
├── train_model.py               ← 6-step training pipeline + Optuna + JSONL logging
├── data_loaders.py              ← 11 MTA open data loaders → (X, y, w) tuples
├── eta_accuracy_benchmark.py    ← Transit App ETA accuracy methodology
├── export_observations.py       ← Redis → CSV exporter for retraining
├── visualize.py                 ← 6-panel static PNG dashboard
└── model_insights.ipynb         ← 24-cell interactive Jupyter notebook (SHAP + analysis)

app/services/
└── alert_service.py             ← in-process alert boost dict, 2-min refresh

app/routers/
└── nearby.py                    ← _ml_corrected() wires all 4 pipeline steps

app/data/
├── delay_model.pkl              ← trained LightGBM artefact (joblib, 1,476 KB)
├── training_runs.jsonl          ← append-only JSONL training run log
├── transit_schedule.db          ← GTFS database (routes, trips, stops, stop_times)
└── training/                    ← 30 MTA open data JSON files (~6.1M rows total)

scripts/
├── write_notebook.py            ← regenerates model_insights.ipynb
├── accuracy_test.py             ← single-location Track vs SIRI diff
└── benchmark.py                 ← 10-location aggregate bias measurement
```

---

## Dependencies (ML-related)

| Package | Version | Role |
|---------|---------|------|
| `lightgbm` | ≥4.3, <5 | Gradient boosting regressor |
| `scikit-learn` | ≥1.4, <2 | train/test split, metrics |
| `optuna` | ≥3.5, <5 | Bayesian hyperparameter search |
| `shap` | ≥0.45, <1 | SHAP feature explainability |
| `numpy` | ≥1.26, <3 | Array operations |
| `pandas` | ≥2.0, <3 | DataFrames for LightGBM feature names |
| `joblib` | ≥1.3, <2 | Model serialisation |
| `matplotlib` | ≥3.8, <4 | Dashboard PNG + notebook plots |
| `scipy` | ≥1.12, <2 | Numeric utilities |
| `redis` | ≥5.0, <6 | Recency model storage |
| `jupyterlab` | (dev) | Notebook UI |

---

## MTA Open Data Inventory

| Dataset | Records |
|---------|---------|
| bus\_segment\_speeds (2023–2025, 3 files) | ~1,000,000 |
| mta\_service\_alerts | ~470,000 |
| bus\_wait\_assessment | ~162,000 |
| bus\_service\_delivered | ~79,000 |
| bus\_customer\_journey | ~64,500 |
| subway\_elevator\_escalator | ~78,000 |
| subway\_delay\_incidents | ~22,800 |
| subway\_trains\_delayed | ~17,400 |
| mta\_daily\_ridership | ~16,100 |
| subway\_customer\_journey (3 eras) | ~5,500 |
| subway\_otp (3 eras) | ~4,900 |
| subway\_service\_delivered (3 eras) | ~6,100 |
| subway\_major\_incidents (3 eras) | ~5,500 |
| subway\_ridership (2017–2025) | ~2,500,000 (capped) |
| bus\_hourly\_ridership (2020–2025) | ~1,000,000 (capped) |
| lirr\_otp | ~1,600 |
| metro\_north\_otp | ~511 |
| bus\_speeds\_summary | ~157,000 |

**Total available:** ~6.1M+ rows
**Used in training:** ~3.25M (via 11 loaders that derive delay-factor labels)

---

## Incremental Improvement Path

1. **Current (April 2026):** LightGBM trained on GTFS bootstrap +
   3.25M MTA open data.  14 v3 features with cyclical encodings.
   R² 0.715, MAE 0.122, 95.2% ETA accuracy.

2. **Next — Optuna tune:** Run `--tune` for Bayesian hyperparameter
   search (30 trials × 3-fold CV on 500K subsample).  Typical
   improvement: +0.5–1% accuracy.

3. **Week 2+ (recency warm-up):** SIRI observations fill Redis.
   Recency delta starts correcting per-stop behaviour.

4. **Month 1 (first real-data retrain):** Export Redis observations →
   CSV, retrain with `--real-data`.  Real samples (weight=1.0) dominate
   bootstrap (weight=0.5).

5. **Ongoing:** Automatic nightly GTFS refresh triggers model re-upload
   to Supabase.  All cold-start containers download the latest model
   automatically.
