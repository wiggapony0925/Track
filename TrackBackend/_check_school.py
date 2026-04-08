"""Quick script: find school bus routes in GTFS data and check classifier coverage."""
import csv
from pathlib import Path

data_root = Path("app/data")
school_routes = []

# Borough-level NYCT feeds
for d in sorted((data_root / "bus").iterdir()):
    if not d.is_dir():
        continue
    rt_file = d / "routes.txt"
    if not rt_file.exists():
        continue
    with rt_file.open(encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            rid = row.get("route_id", "")
            name = row.get("route_short_name", "") or row.get("route_long_name", "")
            desc = row.get("route_desc", "")
            lname = row.get("route_long_name", "")
            if "school" in desc.lower() or "school" in lname.lower() or "school" in rid.lower():
                school_routes.append((rid, name, desc[:80], lname[:80], str(d.name)))

# MTABC feed
mtabc = data_root / "MTA Bus Company"
if mtabc.is_dir():
    rt_file = mtabc / "routes.txt"
    if rt_file.exists():
        with rt_file.open(encoding="utf-8-sig") as f:
            for row in csv.DictReader(f):
                rid = row.get("route_id", "")
                name = row.get("route_short_name", "") or row.get("route_long_name", "")
                desc = row.get("route_desc", "")
                lname = row.get("route_long_name", "")
                if "school" in desc.lower() or "school" in lname.lower() or "school" in rid.lower():
                    school_routes.append((rid, name, desc[:80], lname[:80], "MTA Bus Company"))

print(f"\n=== Found {len(school_routes)} school routes in GTFS ===")
for rid, name, desc, lname, src in school_routes[:30]:
    print(f"  {name:>10}  route_id={rid:<20}  desc={desc:<40}  long={lname}")

# Now test the classifier on these
print("\n=== Classifier results for school routes ===")
from app.routers.nearby import _classify_bus_service_type
for rid, name, desc, lname, src in school_routes[:30]:
    result = _classify_bus_service_type(name)
    print(f"  {name:>10}  →  {result}")

# Also check: are there any route names that look like school routes by OBA naming patterns?
# Typical OBA/SIRI names for school routes: look at what the API actually sends
print("\n=== All route_desc values (unique) ===")
all_descs = set()
for d in sorted((data_root / "bus").iterdir()):
    if not d.is_dir():
        continue
    rt_file = d / "routes.txt"
    if not rt_file.exists():
        continue
    with rt_file.open(encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            desc = row.get("route_desc", "").strip()
            if desc:
                all_descs.add(desc)
if mtabc.is_dir() and (mtabc / "routes.txt").exists():
    with (mtabc / "routes.txt").open(encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            desc = row.get("route_desc", "").strip()
            if desc:
                all_descs.add(desc)
for d in sorted(all_descs):
    print(f"  {d}")
