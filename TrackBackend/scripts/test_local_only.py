"""Quick script to test local_only_stop_ids from the local shape endpoint."""

import json
import sys
import urllib.request


def main():
    base = "http://127.0.0.1:8000"
    routes = ["E", "A", "7", "D", "N", "2"]

    for route_id in routes:
        url = f"{base}/subway/shape?route_id={route_id}"
        try:
            with urllib.request.urlopen(url, timeout=15) as resp:
                data = json.load(resp)
        except Exception as exc:
            print(f"[{route_id}] ERROR: {exc}")
            continue

        print(f"=== {route_id} ===")
        for d in data.get("directions", []):
            ids = d.get("local_only_stop_ids", [])
            print(
                f"  Dir {d['direction_id']} ({d['headsign']}): "
                f"{len(d['stops'])} stops, "
                f"{len(d['polylines'])} polylines, "
                f"{len(ids)} local-only"
            )
            if ids:
                # Show the stop names for local-only IDs
                stop_map = {s["id"]: s["name"] for s in d["stops"]}
                names = [stop_map.get(sid, sid) for sid in ids]
                print(f"    Skipped stops: {names}")
        print()


if __name__ == "__main__":
    main()
