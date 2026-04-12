#!/usr/bin/env python3
"""Smoke-check a trip-planning request against a Track backend.

Usage examples:

python3 scripts/check_engine_trip.py
python3 scripts/check_engine_trip.py --base-url http://127.0.0.1:8000 --endpoint go
python3 scripts/check_engine_trip.py --expect-mode bus --max-transfers 2 --num-itineraries 10
"""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
from typing import Any


DEFAULT_BASE_URL = "https://track-vkrr.onrender.com"
DEFAULT_DEPART_AT_TS = 1775958540  # 2026-04-11 21:49:00 America/New_York


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate a Track planner request against local or production.",
    )
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--endpoint", choices=("plan", "go"), default="plan")
    parser.add_argument("--origin-label", default="Penn Station")
    parser.add_argument("--origin-lat", type=float, default=40.750568)
    parser.add_argument("--origin-lon", type=float, default=-73.993519)
    parser.add_argument("--destination-label", default="Home")
    parser.add_argument("--destination-lat", type=float, default=40.685396)
    parser.add_argument("--destination-lon", type=float, default=-73.825970)
    parser.add_argument("--depart-at-ts", type=int, default=DEFAULT_DEPART_AT_TS)
    parser.add_argument("--now-ts", type=int, default=DEFAULT_DEPART_AT_TS)
    parser.add_argument("--max-transfers", type=int, default=1)
    parser.add_argument("--num-itineraries", type=int, default=10)
    parser.add_argument("--max-origin-walk-m", type=int, default=1200)
    parser.add_argument("--max-destination-walk-m", type=int, default=1200)
    parser.add_argument("--max-transfer-walk-m", type=int, default=250)
    parser.add_argument(
        "--modes",
        nargs="+",
        default=["subway", "bus", "lirr", "mnr"],
    )
    parser.add_argument(
        "--expect-mode",
        action="append",
        default=[],
        help="Fail unless at least one returned itinerary contains this mode.",
    )
    parser.add_argument(
        "--allow-insecure-tls",
        action="store_true",
        help="Disable TLS certificate verification for local/self-signed testing.",
    )
    parser.add_argument(
        "--show-json",
        action="store_true",
        help="Print the raw JSON response after the summary.",
    )
    return parser


def _request_json(url: str, payload: dict[str, Any], *, insecure: bool) -> dict[str, Any]:
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    context = ssl._create_unverified_context() if insecure else None
    with urllib.request.urlopen(request, context=context, timeout=60) as response:
        return json.load(response)


def _legs_from_response(response: dict[str, Any], endpoint: str) -> list[list[dict[str, Any]]]:
    if endpoint == "go":
        trips = []
        primary = response.get("primary_trip")
        if isinstance(primary, dict):
            trips.append(primary)
        trips.extend(
            alt for alt in response.get("alternatives", []) if isinstance(alt, dict)
        )
        return [
            trip.get("itinerary", {}).get("legs", [])
            for trip in trips
            if isinstance(trip.get("itinerary", {}).get("legs", []), list)
        ]
    return [
        itinerary.get("legs", [])
        for itinerary in response.get("itineraries", [])
        if isinstance(itinerary.get("legs", []), list)
    ]


def _leg_label(leg: dict[str, Any]) -> str:
    mode = str(leg.get("mode", "unknown"))
    route = (
        leg.get("route_short_name")
        or leg.get("route_id")
        or leg.get("headsign")
        or "walk"
    )
    return f"{mode}:{route}"


def _print_summary(response: dict[str, Any], endpoint: str) -> None:
    schedule_note = response.get("schedule_note")
    print(f"schedule_note={schedule_note}")

    if endpoint == "go":
        primary = response.get("primary_trip")
        if isinstance(primary, dict):
            print(
                "primary="
                f"{primary.get('duration_label')} "
                f"{primary.get('leave_label')}->{primary.get('arrive_label')}"
            )
        alternatives = response.get("alternatives", [])
        print(f"alternatives={len(alternatives) if isinstance(alternatives, list) else 0}")
    else:
        itineraries = response.get("itineraries", [])
        print(f"itineraries={len(itineraries) if isinstance(itineraries, list) else 0}")

    for index, legs in enumerate(_legs_from_response(response, endpoint), start=1):
        leg_labels = " | ".join(_leg_label(leg) for leg in legs)
        print(f"{index}. {leg_labels}")


def _assert_expected_modes(
    response: dict[str, Any],
    endpoint: str,
    expected_modes: list[str],
) -> None:
    if not expected_modes:
        return

    returned_modes = {
        str(leg.get("mode", ""))
        for legs in _legs_from_response(response, endpoint)
        for leg in legs
    }
    missing = [mode for mode in expected_modes if mode not in returned_modes]
    if missing:
        joined_missing = ", ".join(missing)
        joined_returned = ", ".join(sorted(mode for mode in returned_modes if mode))
        raise SystemExit(
            f"Expected mode(s) missing: {joined_missing}. Returned modes: {joined_returned}"
        )


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    payload: dict[str, Any] = {
        "origin": {
            "label": args.origin_label,
            "lat": args.origin_lat,
            "lon": args.origin_lon,
        },
        "destination": {
            "label": args.destination_label,
            "lat": args.destination_lat,
            "lon": args.destination_lon,
        },
        "depart_at_ts": args.depart_at_ts,
        "max_transfers": args.max_transfers,
        "num_itineraries": args.num_itineraries,
        "max_origin_walk_m": args.max_origin_walk_m,
        "max_destination_walk_m": args.max_destination_walk_m,
        "max_transfer_walk_m": args.max_transfer_walk_m,
        "modes": args.modes,
        "record_recent": False,
    }
    if args.endpoint == "go":
        payload["now_ts"] = args.now_ts

    url = f"{args.base_url.rstrip('/')}/engine/{args.endpoint}"
    print(f"POST {url}")
    print(json.dumps(payload, indent=2))

    try:
        response = _request_json(
            url,
            payload,
            insecure=args.allow_insecure_tls,
        )
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        print(f"HTTP {exc.code} from {url}", file=sys.stderr)
        print(body, file=sys.stderr)
        return 1
    except urllib.error.URLError as exc:
        print(f"Request failed: {exc}", file=sys.stderr)
        return 1

    _print_summary(response, args.endpoint)
    _assert_expected_modes(response, args.endpoint, args.expect_mode)

    if args.show_json:
        print(json.dumps(response, indent=2))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
