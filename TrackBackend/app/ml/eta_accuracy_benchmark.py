"""ETA Accuracy Benchmark — inspired by Transit App's open-source methodology.
https://github.com/TransitApp/ETA-Accuracy-Benchmark

Measures prediction accuracy using Transit App's industry-standard approach:
- Time-bucketed accuracy (0-3, 3-6, 6-10, 10-15 min)
- Asymmetric thresholds (early arrivals penalized more than late)
- Weighted average across buckets

This gives Track a production-grade accuracy metric comparable to what
Transit App uses internally, enabling direct benchmarking against them.

── Time Buckets & Thresholds ──────────────────────────────────────────

Bucket (min)   Early Tolerance   Late Tolerance
0–3 min        30 sec            90 sec
3–6 min        60 sec           150 sec
6–10 min       60 sec           210 sec
10–15 min       90 sec           270 sec

A prediction is "accurate" if:
actual_arrival - predicted_arrival ∈ [-early_tolerance, +late_tolerance]

Negative = arrived earlier than predicted (bad: rider misses it)
Positive = arrived later than predicted  (less bad: rider waits)."""

from __future__ import annotations

import collections
from dataclasses import dataclass, field
from typing import Any

# ── Transit App's ETA Accuracy Benchmark thresholds ──────────────────────


@dataclass(frozen=True)
class TimeBucket:
    """A time bucket with asymmetric accuracy thresholds (seconds)."""

    name: str
    min_seconds: int  # inclusive: >= this
    max_seconds: int  # exclusive: < this
    early_tolerance: int  # max seconds early (negative deviation)
    late_tolerance: int  # max seconds late  (positive deviation)


# Directly from Transit App's ETA-Accuracy-Benchmark specification
BUCKETS: list[TimeBucket] = [
    TimeBucket("0-3 min", 0, 180, 30, 90),
    TimeBucket("3-6 min", 180, 360, 60, 150),
    TimeBucket("6-10 min", 360, 600, 60, 210),
    TimeBucket("10-15 min", 600, 900, 90, 270),
]


@dataclass
class BucketResult:
    """Accuracy stats for one time bucket."""

    bucket_name: str
    total: int = 0
    accurate: int = 0
    early_miss: int = 0  # arrived too early (rider missed it)
    late_miss: int = 0  # arrived too late (beyond tolerance)

    @property
    def accuracy(self) -> float:
        return self.accurate / self.total if self.total > 0 else 0.0

    @property
    def early_miss_rate(self) -> float:
        return self.early_miss / self.total if self.total > 0 else 0.0

    @property
    def late_miss_rate(self) -> float:
        return self.late_miss / self.total if self.total > 0 else 0.0


@dataclass
class PredictionSample:
    """A single prediction vs actual observation.

    Attributes:
        predicted_arrival_ts: When we told the user the vehicle would arrive (epoch s)
        actual_arrival_ts:    When the vehicle actually arrived (epoch s)
        sample_ts:            When the prediction was generated (epoch s)
        route_id:             Route identifier
        stop_id:              Stop identifier
        source:               Prediction source ("model", "heuristic", "recency", etc.)
    """

    predicted_arrival_ts: float
    actual_arrival_ts: float
    sample_ts: float
    route_id: str = ""
    stop_id: str = ""
    source: str = ""


@dataclass
class BenchmarkResult:
    """Complete benchmark result with per-bucket and overall accuracy."""

    bucket_results: list[BucketResult] = field(default_factory=list)
    total_samples: int = 0
    samples_in_range: int = 0  # samples within 0-15 min range
    samples_out_of_range: int = 0  # samples outside 0-15 min (excluded)

    @property
    def overall_accuracy(self) -> float:
        """Equally-weighted average of bucket accuracies.

        Transit App's methodology: straight average of the 4 bucket-level
        percentages, which gives additional weight to smaller (closer) buckets
        since they contain fewer predictions.
        """
        bucket_accuracies = [b.accuracy for b in self.bucket_results if b.total > 0]
        if not bucket_accuracies:
            return 0.0
        return sum(bucket_accuracies) / len(bucket_accuracies)

    def to_dict(self) -> dict[str, Any]:
        """Serialize for API/logging."""
        return {
            "overall_accuracy": round(self.overall_accuracy, 4),
            "total_samples": self.total_samples,
            "samples_in_range": self.samples_in_range,
            "samples_out_of_range": self.samples_out_of_range,
            "buckets": [
                {
                    "bucket": b.bucket_name,
                    "total": b.total,
                    "accurate": b.accurate,
                    "accuracy": round(b.accuracy, 4),
                    "early_miss": b.early_miss,
                    "early_miss_rate": round(b.early_miss_rate, 4),
                    "late_miss": b.late_miss,
                    "late_miss_rate": round(b.late_miss_rate, 4),
                }
                for b in self.bucket_results
            ],
        }


# ── Core benchmark computation ──────────────────────────────────────────


def classify_prediction(sample: PredictionSample) -> tuple[str | None, bool]:
    """Classify a single prediction as accurate/inaccurate within its bucket.

    Args:
        sample: A prediction observation with predicted and actual timestamps.

    Returns:
        (bucket_name, is_accurate) or (None, False) if outside all buckets.
    """
    # "time to actual" = seconds between when prediction was sampled and
    # when the vehicle actually arrived.
    time_to_actual = sample.actual_arrival_ts - sample.sample_ts

    # Time variance: how far off the prediction was.
    # Positive = vehicle arrived later than predicted (late)
    # Negative = vehicle arrived earlier than predicted (early)
    time_variance = sample.actual_arrival_ts - sample.predicted_arrival_ts

    for bucket in BUCKETS:
        if bucket.min_seconds <= time_to_actual < bucket.max_seconds:
            is_accurate = (
                -bucket.early_tolerance <= time_variance <= bucket.late_tolerance
            )
            return bucket.name, is_accurate

    return None, False


def run_benchmark(samples: list[PredictionSample]) -> BenchmarkResult:
    """Run the Transit App ETA Accuracy Benchmark on a set of prediction samples.

    This implements the full 5-step methodology from
    https://github.com/TransitApp/ETA-Accuracy-Benchmark:
      1. Create a sample of predictions and actual arrivals
      2. Categorize each as "accurate" or "inaccurate"
      3. Bucket each into the appropriate time bucket
      4. Calculate accuracy % per bucket
      5. Calculate overall accuracy as equally-weighted average of buckets

    Args:
        samples: List of PredictionSample objects.

    Returns:
        BenchmarkResult with per-bucket and overall accuracy.
    """
    bucket_map: dict[str, BucketResult] = {
        b.name: BucketResult(bucket_name=b.name) for b in BUCKETS
    }

    out_of_range = 0
    for sample in samples:
        time_variance = sample.actual_arrival_ts - sample.predicted_arrival_ts

        bucket_name, is_accurate = classify_prediction(sample)
        if bucket_name is None:
            out_of_range += 1
            continue

        br = bucket_map[bucket_name]
        br.total += 1
        if is_accurate:
            br.accurate += 1
        elif time_variance < 0:
            br.early_miss += 1  # arrived before predicted (rider missed it)
        else:
            br.late_miss += 1  # arrived too late beyond tolerance

    return BenchmarkResult(
        bucket_results=list(bucket_map.values()),
        total_samples=len(samples),
        samples_in_range=sum(b.total for b in bucket_map.values()),
        samples_out_of_range=out_of_range,
    )


def run_benchmark_by_route(
    samples: list[PredictionSample],
) -> dict[str, BenchmarkResult]:
    """Run the benchmark grouped by route_id.

    Returns {route_id: BenchmarkResult} dict, sorted by accuracy (worst first).
    """
    by_route: dict[str, list[PredictionSample]] = {}
    for s in samples:
        by_route.setdefault(s.route_id, []).append(s)

    results = {
        route_id: run_benchmark(route_samples)
        for route_id, route_samples in by_route.items()
    }

    # Sort worst-performing first
    return dict(
        sorted(
            results.items(),
            key=lambda kv: kv[1].overall_accuracy,
        )
    )


def run_benchmark_by_source(
    samples: list[PredictionSample],
) -> dict[str, BenchmarkResult]:
    """Run the benchmark grouped by prediction source (model/heuristic/recency).

    Useful for comparing ML model vs rule-based vs recency correction.
    """
    by_source: dict[str, list[PredictionSample]] = {}
    for s in samples:
        by_source.setdefault(s.source or "unknown", []).append(s)

    return {
        source: run_benchmark(source_samples)
        for source, source_samples in by_source.items()
    }


# ── Redis-based observation collection ──────────────────────────────────

# Circular buffer of recent prediction-vs-actual pairs for benchmarking.
# Stored in module-level list (lightweight; for production use Redis ZSET).
_recent_observations: collections.deque[PredictionSample] = collections.deque(
    maxlen=10_000
)


def record_observation(
    predicted_arrival_ts: float,
    actual_arrival_ts: float,
    sample_ts: float,
    route_id: str = "",
    stop_id: str = "",
    source: str = "",
) -> None:
    """Record a prediction-vs-actual observation for future benchmarking.

    Called when we can determine the actual arrival (e.g., from GTFS-RT
    snapshot diffing in recency_model.py).
    """
    _recent_observations.append(
        PredictionSample(
            predicted_arrival_ts=predicted_arrival_ts,
            actual_arrival_ts=actual_arrival_ts,
            sample_ts=sample_ts,
            route_id=route_id,
            stop_id=stop_id,
            source=source,
        )
    )
    # deque(maxlen=…) handles eviction automatically.


def get_current_benchmark() -> dict[str, Any]:
    """Run the benchmark on all collected observations.

    Returns a dict suitable for JSON serialization / API response.
    """
    if not _recent_observations:
        return {
            "status": "no_observations",
            "message": "No prediction observations collected yet. "
            "Accuracy data accumulates as GTFS-RT feeds are polled.",
            "overall": None,
        }

    overall = run_benchmark(_recent_observations)
    by_route = run_benchmark_by_route(_recent_observations)
    by_source = run_benchmark_by_source(_recent_observations)

    return {
        "status": "ok",
        "observation_count": len(_recent_observations),
        "overall": overall.to_dict(),
        "by_route": {
            route_id: result.to_dict() for route_id, result in by_route.items()
        },
        "by_source": {source: result.to_dict() for source, result in by_source.items()},
    }
