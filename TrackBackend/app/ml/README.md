# Track ML — Delay Prediction System

## Overview

The Track ML system corrects MTA's raw `minutes_away` values before they reach the iOS app. Instead of displaying whatever the MTA GTFS-RT feed reports, every arrival time is passed through a four-stage pipeline that accounts for chronic route patterns, current service alerts, and recent real-world observations at the specific stop.

The result is a single corrected integer (still called `minutes_away`) that the iOS app uses directly — no frontend changes required.

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
│  Step 2 ── GBR contextual factor  delay_model.py         │
│            f(route, hour, dow, mode, deviation_s)        │
│            range: [0.90, 2.0]                            │
│                                                          │
│  Step 3 ── Recency delta          recency_model.py       │
│            EWMA of observed stop errors (±5 min cap)     │
│            from Redis ZSET                               │
│                                                          │
│  Step 4 ── Blend + horizon cap                           │
│            base_s  = raw_s + recency_delta               │
│            factor  = min(2.0, gbr × (1 + alert_boost))  │
│            result  = base_s × factor / 60               │
│            capped at ±2/3/4 min depending on horizon     │
└──────────────────────────────────────────────────────────┘
        │
        ▼
  corrected minutes_away  →  iOS app
```

---

## Module Reference

### `delay_model.py` — GBR Contextual Factor

**Purpose:** Predict a multiplicative delay factor for a given transit context using a GradientBoostingRegressor trained on GTFS-derived synthetic data and (eventually) real observations.

#### Feature Vector (8 features)

| # | Name | Type | Description |
|---|------|------|-------------|
| 0 | `route_reliability` | int 0–4 | Reliability tier. 0=most reliable (L, SI), 4=chronically late (G). |
| 1 | `hour` | int 0–23 | Current UTC hour of request. |
| 2 | `dow` | int 1–7 | Day of week. Mon=2, Sun=1 (legacy convention). |
| 3 | `weather_enc` | int 0–2 | Encoded weather: clear=0, rain=1, snow=2. |
| 4 | `mode_enc` | int 0–3 | Transit mode: subway=0, bus=1, lirr=2, mnr=3. |
| 5 | `is_rush` | int 0/1 | 1 if weekday 7–9 AM or 5–7 PM. |
| 6 | `is_weekend` | int 0/1 | 1 if Saturday or Sunday. |
| 7 | `delay_minutes` | float | Live schedule deviation from SIRI (clamped ±10 min). Encodes momentum: a train already 3 min late is likely to arrive even later. |

> **Weather note:** Feature 3 (`weather_enc`) is always passed as `clear` (0) inside `_ml_corrected()`. Weather's real-time impact is already captured by feature 7 (`delay_minutes`) — SIRI `schedule_deviation_s` reflects actual running time including weather conditions. Keeping weather as a feature preserves the model's learned seasonal patterns for bootstrap training.

#### Output

`predict_factor()` returns `(factor: float, source: str)`:

- **`factor`** is clamped to `[0.90, 2.0]`. Factor < 1.0 allows early-arrival predictions for very reliable off-peak routes.
- **`source`** is `"model"` when the GBR file is loaded, `"heuristic"` when it falls back to rule-based logic (no pkl file present, or load error).

#### Model File

- Path: `app/data/delay_model.pkl`
- Format: joblib-serialised `sklearn.ensemble.GradientBoostingRegressor`
- Size: ~487 KB
- Loaded once on first request (singleton), then cached in memory (~5 µs per inference)

---

### `recency_model.py` — Per-Stop EWMA Recency Correction

**Purpose:** Correct for chronic stop-level delays that the GBR factor alone cannot capture — e.g. a specific stop on the Q train that consistently runs 90 seconds late between 8–9 AM.

#### How Observations Enter Redis

Two observation paths feed the same Redis sorted sets:

**Path A — GTFS-RT snapshots** (`observe_trip_updates`)
- Called after each protobuf parse in `data_cleaner.py`
- Detects stops that disappeared between consecutive snapshots (vehicle passed them)
- Records `error_s = now − predicted_arrival_ts`
- Fires ~every 30 seconds for active trips

**Path B — SIRI direct deviation** (`observe_siri_delay`)
- Called on every SIRI StopMonitoring / VehicleMonitoring poll in `bus_client.py`
- `deviation_s = ExpectedArrivalTime − AimedArrivalTime`
- Fires immediately — no need to wait for a stop to disappear
- Produces 10–30× more signal than Path A for bus routes

Both paths write to the same Redis sorted set structure:

```
track:recency:obs:{ROUTE}:{stop_id}:{dow}:{hour}
  ZSET  score=unix_timestamp  value=error_seconds
  TTL=25h  max_cardinality=50
```

#### Query: `get_weighted_error(route_id, stop_id, dow, hour)`

1. Fetches the **exact** `(route, stop, dow, hour)` bucket from Redis.
2. Also fetches **adjacent hours** `(hour−1)` and `(hour+1)` at half weight, for more signal in low-traffic periods.
3. Applies **exponential decay** with `λ=0.5` (half-life ≈ 1.4 hours):
   ```
   w = exp(−0.5 × age_hours)
   ```
   An observation from 10 minutes ago weighs ~7× more than one from 3 hours ago.
4. Returns the weighted mean error in seconds, or `None` if fewer than 3 observations exist.

#### Graceful Degradation

Every Redis call is wrapped in `try/except`. If Redis is unavailable, `observe_*` is a no-op and `get_weighted_error` returns `None`. The pipeline in `_ml_corrected()` treats `None` as zero delta — seamless fallback with no user impact.

---

### `train_model.py` — Training Pipeline

**Purpose:** Bootstrap the GBR from GTFS data, and optionally blend in real observations as they accumulate.

#### Phase 1 — Bootstrap (zero extra data needed)

Reads `transit_schedule.db` (8M+ rows) to extract per-route facts:
- Average stop count per trip (proxy for delay exposure)
- Operating hours (from `stop_times.departure_time`)
- Mode assignment from GTFS `route_type` and route ID prefix

Generates synthetic training samples using MTA on-time performance priors (NYC Transit 2024 public reports):

| Tier | Routes | Base factor |
|------|--------|-------------|
| 0 | L, SI | 1.02 |
| 1 | 7, W, SIR | 1.04 |
| 2 | Most lines, LIRR, MNR | 1.07 |
| 3 | A, C, 4, 5, 6, J | 1.10 |
| 4 | G | 1.16 |

Rush-hour additive: +0.10 (subway), +0.20 (bus)  
Weather additive (subway): rain +0.05, snow +0.20  
Weather additive (bus): rain +0.15, snow +0.30  
Gaussian noise σ=0.03 on each sample prevents overfitting to exact priors.

Bootstrap samples carry `sample_weight=0.5`. Real observations use `weight=1.0` so they dominate quickly.

#### Phase 2 — Real Observations (automatic over time)

As the app runs in production, `recency_model.py` logs observations to Redis every ~30 seconds. Export them to CSV and retrain:

```bash
# Export Redis observations to CSV
python -m app.ml.export_observations

# Retrain blending real + bootstrap data
python -m app.ml.train_model --real-data observations.csv

# Hot-swap the model on the live server (no restart needed)
curl -X POST https://track-vkrr.onrender.com/predict/reload-model
```

Expected CSV format:
```
route_id,stop_id,hour,dow,weather,mode,actual_factor,deviation_s
A,404231,8,3,clear,subway,1.18,142.0
```

#### Model Hyperparameters

| Param | Value | Rationale |
|-------|-------|-----------|
| `n_estimators` | 200 | Enough trees to capture multi-way interactions |
| `max_depth` | 4 | Shallow — prevents overfitting on bootstrap data |
| `learning_rate` | 0.05 | Slow rate + more trees = better generalisation |
| `subsample` | 0.8 | Stochastic GBR reduces variance |
| `min_samples_leaf` | 10 | Each leaf must cover ≥10 samples |

#### Validation Output (current bootstrap)

```
Feature importances:
  delay_minutes        0.312  ████████████
  hour                 0.241  █████████▌
  route_reliability    0.198  ███████▉
  is_rush              0.089  ███▌
  mode                 0.067  ██▋
  dow                  0.051  ██
  weather              0.028  █
  is_weekend           0.014  ▌
```

`delay_minutes` being the top feature confirms the model has successfully learned momentum — a train already running late is a strong predictor of how late it will arrive.

---

### `alert_service.py` — Service Alert Boost

**Purpose:** Apply a multiplicative boost when MTA reports active service disruptions for a route, without adding any per-request latency.

| Alert severity | Boost multiplier | Applied as |
|---|---|---|
| `SEVERE` | ×1.25 | +25% on top of GBR factor |
| `WARNING` | ×1.10 | +10% on top of GBR factor |
| None | ×1.00 | No change |

Alert state is refreshed every 2 minutes in the background using a non-blocking asyncio lock. A read takes O(1) from an in-process dict — zero Redis, zero HTTP on the hot path. Data comes from the existing `data_cleaner.get_alerts()` function already used by `/status/alerts`.

---

## The Correction Pipeline in Detail

`_ml_corrected(minutes_away, route_id, mode, stop_id, deviation_s)` in `app/routers/nearby.py`:

```python
# Step 1 — alert boost (non-blocking, O(1))
await _maybe_refresh_alerts()
alert_boost = _get_alert_boost(route_id)          # 0.0 / 0.10 / 0.25

# Step 2 — GBR factor (~5 µs, sync)
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
# Prevents over-inflation on long-horizon arrivals (diagnosed +2.4 min bias
# on 25–50 min arrivals; GBR ×1.15 on 1800–3000s raw adds 4–8 min).
max_delta = 2 if minutes_away <= 10 else (3 if minutes_away <= 25 else 4)
result    = max(minutes_away - max_delta, min(minutes_away + max_delta, result))
return max(0, result)
```

### Benchmark Results (10 NYC locations, 444 matched pairs)

| Metric | Before ML | After ML |
|---|---|---|
| Mean signed bias | 0.0 min (raw MTA) | +1.48 min |
| P90 correction | 0 min | 3 min |
| Early predictions | 0% | 13% (recency catching habitually-early routes) |
| Model source | — | 87% `model`, 13% `heuristic` (no pkl yet on cold container) |

The +1.48 min positive bias is intentional in the current bootstrap phase: it is always better to show a user "5 min" when the train arrives in 4 min than to show "3 min" when the train is actually 5 min away. As real SIRI observations accumulate in Redis, the recency delta will pull the bias toward zero for frequently-served stops.

---

## API Endpoint

### `GET /predict/delay`

Direct access to the GBR factor for a given context. Used by the iOS app's `DelayCalculator` fallback and for debugging.

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

# Bootstrap only (works now, no extra data needed)
python -m app.ml.train_model

# With real observations blended in
python -m app.ml.train_model --real-data path/to/observations.csv
```

### Hot-Swap on Live Server (no restart)

```bash
curl -X POST https://track-vkrr.onrender.com/predict/reload-model
```

The singleton in `delay_model.py` resets `_model_loaded = False`, triggering a fresh `joblib.load()` on the next inference request.

### View Model Status

```bash
curl https://track-vkrr.onrender.com/predict/delay?route_id=4&mode=subway&minutes_away=8&hour=8&day_of_week=2
# model_source: "model"  ← GBR loaded
# model_source: "heuristic"  ← pkl missing or failed to load
```

### Run Benchmark (10 NYC locations vs live SIRI)

```bash
cd TrackBackend
source .venv/bin/activate
python scripts/benchmark.py
```

```
AGGREGATE RESULTS — 10 locations
  Matched pairs        : 444
  Avg correction       : 1.93 min
  Median               : 2.0 min
  P90                  : 3 min
  Mean signed bias     : +1.477 min
```

### Run Point Accuracy Check (single location)

```bash
python scripts/accuracy_test.py --lat 40.7085 --lon -73.8318 --watch 3
# Checks Kew Gardens 3 times, ~30s apart
```

---

## File Map

```
app/ml/
├── README.md               ← this file
├── __init__.py
├── delay_model.py          ← GBR singleton, feature encoding, predict_factor()
├── recency_model.py        ← Redis EWMA per-stop error tracker
└── train_model.py          ← bootstrap + retrain pipeline

app/services/
└── alert_service.py        ← in-process alert boost dict, 2-min refresh

app/routers/
└── nearby.py               ← _ml_corrected() wires all 4 steps together

app/data/
└── delay_model.pkl         ← trained GBR artefact (joblib, ~487 KB)
                              • ships in Docker image (fallback)
                              • also in Supabase gtfs-data bucket (production download)

scripts/
├── accuracy_test.py        ← single-location Track vs SIRI diff
└── benchmark.py            ← 10-location aggregate bias measurement
```

---

## Incremental Improvement Path

1. **Now (bootstrap):** GBR trained on synthetic GTFS-derived data. Good for chronic route/time patterns. Mean bias +1.48 min.
2. **Week 1–2 (recency warm-up):** SIRI observations fill Redis. Recency delta starts correcting per-stop behaviour. Bias drifts toward 0 for high-frequency stops.
3. **Month 1 (first retrain):** Export Redis observations → CSV, retrain with `--real-data`. Real samples (weight=1.0) dominate bootstrap (weight=0.5). Feature importances shift from `hour/reliability` toward `delay_minutes`.
4. **Ongoing:** Automatic nightly GTFS refresh triggers `delay_model.tar.gz` re-upload to Supabase. All cold-start containers download the latest model automatically.
