"""Test _trip_route_token function."""

from __future__ import annotations

from app.routers.bus import _trip_route_token

cases = [
    ("MTA NYCT_MV_A6-Weekday-SDon-036000_M11_601", "M11"),
    ("MTA NYCT_MV_A6-Weekday-SDon-128000_M104_126_1774921620", "M104"),
    ("MTA NYCT_MV_A6-Weekday-SDon-044700_M104_106", "M104"),
    ("MTA NYCT_OF_A6-Weekday-SDon-010000_M7_201", "M7"),
    ("MTABC_44438909-YOPA6-YO_A6-Weekday-01", None),
    ("MTA NYCT_MV_A6-Weekday-SDon-036000_B63_401", "B63"),
    ("MTA NYCT_MV_A6-Weekday-SDon-036000_BX12_401", "BX12"),
    ("MTA NYCT_MV_A6-Weekday-SDon-036000_M34+SBS_401", "M34-SBS"),
    ("MTA NYCT_MV_A6-Weekday-SDon-036000_S79-SBS_401", "S79-SBS"),
    ("", None),
    ("no_underscored_route", None),
]

all_pass = True
for trip_id, expected in cases:
    result = _trip_route_token(trip_id)
    status = "PASS" if result == expected else "FAIL"
    if status == "FAIL":
        all_pass = False
    short = trip_id[-50:] if len(trip_id) > 50 else trip_id
    print(f"  {status}: ...{short!r} -> {result!r} (expected {expected!r})")

print()
print("All tests passed!" if all_pass else "SOME TESTS FAILED!")
