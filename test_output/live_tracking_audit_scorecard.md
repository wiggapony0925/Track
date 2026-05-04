# Track Live Tracking Proof Scorecard

Generated at: `1777925189`
Track backend: `https://track-vkrr.onrender.com`

Verdict: **not_proven_yet**

Track has strong measured tracking gates, but this run does not prove it is better than Transit.

## Measured Summary

- Track vehicles sampled: `250`
- Stable identity rate: `100.0%`
- Valid position rate: `100.0%`
- Confidence metadata rate: `100.0%`
- Stale position rate: `2.0%`
- Average Track live endpoint latency: `160ms`
- Transit comparison latency: `not measured`

## Proof Gates

| Gate | Result | Evidence |
| --- | --- | --- |
| `stable_marker_identity` | PASS | 250/250 sampled vehicles expose stable vehicle_id/trip_id |
| `valid_marker_positions` | PASS | 250/250 sampled vehicles expose usable lat/lon |
| `confidence_transparency` | PASS | 250/250 sampled vehicles expose position_confidence |
| `freshness_control` | PASS | 5/250 sampled vehicles are stale |
| `frontend_contract_errors` | PASS | 0 error-level contract issues found |
| `track_endpoint_latency` | PASS | average Track live endpoint latency is 160ms |
| `measured_transit_latency_advantage` | FAIL | Transit API sample unavailable; cannot prove this category yet |

## Track Endpoint Samples

| Mode | Route | Vehicles | Positions | IDs | Confidence | Stale | Sources | Latency | Issues |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| bus | MTA NYCT_B63 | 22 | 22 | 22 | 22 | 0 | gps:22 | 224ms | 0 |
| subway | E | 48 | 48 | 48 | 48 | 1 | stop_anchor:48 | 160ms | 2 |
| subway | A | 48 | 48 | 48 | 48 | 1 | stop_anchor:48 | 213ms | 2 |
| subway | 7 | 19 | 19 | 19 | 19 | 1 | stop_anchor:19 | 105ms | 2 |
| subway | L | 19 | 19 | 19 | 19 | 0 | stop_anchor:19 | 115ms | 0 |
| subway | N | 36 | 36 | 36 | 36 | 0 | stop_anchor:36 | 188ms | 0 |
| subway | Q | 36 | 36 | 36 | 36 | 2 | stop_anchor:36 | 132ms | 4 |
| subway | 1 | 22 | 22 | 22 | 22 | 0 | stop_anchor:22 | 143ms | 0 |

## What This Proves

This run proves Track's sampled live marker contract is strong when the gates pass: stable marker identity, usable positions, explicit confidence metadata, stale-position handling, and acceptable endpoint latency.

It does not prove Track is better than Transit unless a Transit API sample is included and the Transit comparison gate passes. That is intentional: the app should earn that claim with evidence, not vibes.
