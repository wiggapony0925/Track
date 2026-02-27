#
# export_observations.py
# app/ml/export_observations.py
#
# ══════════════════════════════════════════════════════════════════
# RETRAIN LINK  — exports live Redis recency data to a CSV file
# that train_model.py can ingest via --real-data.
#
# Usage:
#   python -m app.ml.export_observations                   # → observations.csv
#   python -m app.ml.export_observations -o my_data.csv   # custom path
#   python -m app.ml.export_observations --min-obs 5      # require ≥5 obs/key
#
# The CSV produced has columns expected by load_real_observations():
#   route_id, stop_id, hour, dow, weather, mode, actual_factor, deviation_s
#
# ── How actual_factor is derived ──────────────────────────────────
#
#   Redis stores raw deviation_s (seconds late/early) recorded by
#   recency_model.py.  The ML model predicts a multiplicative delay
#   *factor* (1.0 = on-time, 2.0 = double the predicted time).
#
#   We convert:
#       actual_factor = 1.0 + clamp(deviation_s, 0, MAX_LATE_S) / BASE_S
#       BASE_S  = 300  (5 minutes — typical stop-to-stop travel time)
#       MAX_LATE_S = 300  (cap at factor=2.0 as the model is clamped there)
#
#   Early trains (negative deviation_s) → factor = 1.0 (no speedup modelled).
#   This is intentional: the model only predicts *additional wait* time, not
#   optimistic compression.
#
# ── Redis key format ──────────────────────────────────────────────
#   track:recency:obs:{route}:{stop_id}:{dow}:{hour}
#      ZSET  score=unix_ts  value=deviation_s
#
# ── Requires ──────────────────────────────────────────────────────
#   REDIS_URL env var (same as backend).  Safe to run against prod
#   Redis — read-only; does not modify any keys.
# ══════════════════════════════════════════════════════════════════
#

from __future__ import annotations

import argparse
import asyncio
import csv
import os
import sys
import time
from pathlib import Path

# ── Constants ──────────────────────────────────────────────────────────────
_OBS_PREFIX   = "track:recency:obs"
_SCAN_MATCH   = f"{_OBS_PREFIX}:*"
_SCAN_COUNT   = 200       # hint for Redis SCAN — larger = fewer round-trips
BASE_S        = 300.0     # 5-minute baseline for factor conversion
MAX_LATE_S    = 300.0     # caps factor at 2.0 — matches model clamp in train_model.py
MAX_EARLY_S   = 600.0     # ignore extreme early readings (likely bad GTFS data)
MAX_OBS_AGE_H = 24.0      # discard observations older than 24 h


# ── Redis helpers ──────────────────────────────────────────────────────────

def _get_redis_url() -> str:
    url = os.environ.get("REDIS_URL", "").strip()
    if not url:
        raise SystemExit(
            "ERROR: REDIS_URL is not set.\n"
            "Export it before running:\n"
            "  export REDIS_URL=redis://localhost:6379\n"
            "or set it to your Render Redis internal URL."
        )
    return url


async def _collect_observations(
    redis_url: str,
    min_obs: int,
    max_age_hours: float,
) -> list[dict]:
    """Scan all obs keys from Redis and return a flat list of observation dicts."""
    try:
        import redis.asyncio as aioredis  # type: ignore
    except ImportError:
        raise SystemExit(
            "ERROR: redis package not installed.  Run:  pip install redis"
        )

    rows: list[dict] = []
    cutoff_ts = time.time() - max_age_hours * 3600

    client = aioredis.from_url(
        redis_url,
        encoding="utf-8",
        decode_responses=True,
        socket_connect_timeout=10,
        socket_timeout=30,
    )

    try:
        total_keys = 0
        skipped_few = 0
        skipped_age = 0

        async for key in client.scan_iter(match=_SCAN_MATCH, count=_SCAN_COUNT):
            total_keys += 1

            # ── Parse key: track:recency:obs:{route}:{stop_id}:{dow}:{hour}
            parts = key.split(":")
            # Minimum: track(0) recency(1) obs(2) route(3) stop(4) dow(5) hour(6)
            if len(parts) < 7:
                continue

            route_id   = parts[3]
            # stop_id may contain colons — everything between route and the last 2 fields
            hour_str   = parts[-1]
            dow_str    = parts[-2]
            stop_id    = ":".join(parts[4:-2])

            try:
                hour = int(hour_str)
                dow  = int(dow_str)
            except ValueError:
                continue

            # ── Fetch ZSET with scores (scores = unix timestamps)
            # Returns list of (value, score) pairs sorted by score ascending
            raw = await client.zrange(key, 0, -1, withscores=True)
            if len(raw) < min_obs:
                skipped_few += 1
                continue

            # ── Emit one row per observation (richer training signal than aggregating)
            key_rows = 0
            for dev_str, ts in raw:
                if ts < cutoff_ts:
                    skipped_age += 1
                    continue
                try:
                    deviation_s = float(dev_str)
                except ValueError:
                    continue

                # Discard implausible early readings
                if deviation_s < -MAX_EARLY_S:
                    continue

                # Convert to factor
                clamped = max(0.0, min(MAX_LATE_S, deviation_s))
                actual_factor = round(1.0 + clamped / BASE_S, 4)

                rows.append({
                    "route_id":      route_id,
                    "stop_id":       stop_id,
                    "hour":          hour,
                    "dow":           dow,
                    "weather":       "clear",   # not stored in Redis — use neutral default
                    "mode":          _infer_mode(route_id),
                    "actual_factor": actual_factor,
                    "deviation_s":   round(deviation_s, 2),
                })
                key_rows += 1

        print(
            f"  Scanned {total_keys} keys | "
            f"skipped {skipped_few} (< {min_obs} obs) | "
            f"skipped {skipped_age} stale observations",
            flush=True,
        )

    finally:
        await client.aclose()

    return rows


def _infer_mode(route_id: str) -> str:
    """Best-effort mode inference from route_id."""
    r = route_id.upper()
    # LIRR and Metro-North route IDs contain digits and are longer
    # Bus routes start with letters but typically contain more than 1 char
    if len(r) >= 4 and r[0].isalpha() and r[1:].isdigit():
        return "bus"
    lirr_prefixes = ("LIRR", "LI")
    mnr_prefixes  = ("MNR", "MNWHL", "MNCORR", "MNHARLEM", "MNMADISON")
    if any(r.startswith(p) for p in lirr_prefixes + mnr_prefixes):
        return "rail"
    return "subway"


def _write_csv(rows: list[dict], output_path: Path) -> None:
    fieldnames = ["route_id", "stop_id", "hour", "dow", "weather", "mode",
                  "actual_factor", "deviation_s"]
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


async def _main(args: argparse.Namespace) -> None:
    redis_url  = _get_redis_url()
    output     = Path(args.output)
    min_obs    = args.min_obs
    max_age_h  = args.max_age_hours

    print(f"Track observation exporter", flush=True)
    print(f"  Redis:    {redis_url[:40]}{'…' if len(redis_url) > 40 else ''}", flush=True)
    print(f"  Output:   {output}", flush=True)
    print(f"  Min obs:  {min_obs}  (keys with fewer observations are skipped)", flush=True)
    print(f"  Max age:  {max_age_h}h", flush=True)
    print(flush=True)

    print("Scanning Redis…", flush=True)
    rows = await _collect_observations(redis_url, min_obs=min_obs, max_age_hours=max_age_h)

    if not rows:
        print(
            "\nNo observations found.\n"
            "Make sure the backend has been running with live traffic and\n"
            "that REDIS_URL points to the correct instance.",
            flush=True,
        )
        sys.exit(0)

    _write_csv(rows, output)

    delayed    = sum(1 for r in rows if r["deviation_s"] > 30)
    early      = sum(1 for r in rows if r["deviation_s"] < -30)
    on_time    = len(rows) - delayed - early
    mean_dev   = sum(r["deviation_s"] for r in rows) / len(rows)
    mean_fac   = sum(r["actual_factor"] for r in rows) / len(rows)
    modes      = {}
    for r in rows:
        modes[r["mode"]] = modes.get(r["mode"], 0) + 1

    print(f"\n{'─' * 55}", flush=True)
    print(f"  Rows exported  : {len(rows):,}", flush=True)
    print(f"  Late (>30s)    : {delayed:,}  ({100*delayed/len(rows):.1f}%)", flush=True)
    print(f"  On-time        : {on_time:,}  ({100*on_time/len(rows):.1f}%)", flush=True)
    print(f"  Early (<-30s)  : {early:,}  ({100*early/len(rows):.1f}%)", flush=True)
    print(f"  Mean deviation : {mean_dev:+.1f}s", flush=True)
    print(f"  Mean factor    : {mean_fac:.3f}", flush=True)
    print(f"  Modes          : {modes}", flush=True)
    print(f"{'─' * 55}", flush=True)
    print(f"\n  Saved → {output}", flush=True)
    print(
        f"\nNext step:\n"
        f"  python -m app.ml.train_model --real-data {output}",
        flush=True,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description=(
            "Export Redis recency observations to a CSV file for ML retraining.\n\n"
            "Requires REDIS_URL to be set in the environment.\n\n"
            "Example:\n"
            "  export REDIS_URL=redis://localhost:6379\n"
            "  python -m app.ml.export_observations -o observations.csv\n"
            "  python -m app.ml.train_model --real-data observations.csv"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "-o", "--output",
        default="observations.csv",
        metavar="PATH",
        help="Output CSV file path (default: observations.csv)",
    )
    parser.add_argument(
        "--min-obs",
        type=int,
        default=3,
        metavar="N",
        help="Skip keys with fewer than N observations (default: 3)",
    )
    parser.add_argument(
        "--max-age-hours",
        type=float,
        default=MAX_OBS_AGE_H,
        metavar="H",
        help=f"Discard observations older than H hours (default: {MAX_OBS_AGE_H})",
    )
    asyncio.run(_main(parser.parse_args()))
