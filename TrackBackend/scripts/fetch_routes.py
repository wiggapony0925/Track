from __future__ import annotations

import asyncio
import json

import httpx

from app.config import get_settings

# The two main agencies we care about, plus MTA BUS for completeness
AGENCIES = ["MTA NYCT", "MTABC", "MTA BUS"]


async def fetch_all_route_tags():
    settings = get_settings()
    api_key = settings.api_keys.mta_bus_key
    base_url = settings.urls.bus_oba_base + "/routes-for-agency"

    # Categorized Map - Misc removed for production-readiness
    categorized_map = {
        "Brooklyn": {},
        "Manhattan": {},
        "Queens": {},
        "Bronx": {},
        "Staten Island": {},
        "Express": {},
    }

    print("🚀 Starting scrape of valid Route IDs...")

    async with httpx.AsyncClient() as client:
        for agency in AGENCIES:
            agency_encoded = agency.replace(" ", "%20")
            url = f"{base_url}/{agency_encoded}.json"
            params = {"key": api_key}

            print(f"Fetching {agency}...")
            try:
                response = await client.get(url, params=params)
                if response.status_code != 200:
                    print(f"❌ Error fetching {agency}: {response.status_code}")
                    continue

                data = response.json()
                if not isinstance(data, dict):
                    print(f"❌ Invalid JSON response for {agency}")
                    continue

                if data.get("code") == 200:
                    routes_payload = data.get("data", {})
                    if not isinstance(routes_payload, dict):
                        print(f"❌ Missing 'data' object in {agency} response")
                        continue

                    routes = routes_payload.get("list", [])
                    print(f"✅ Found {len(routes)} raw items for {agency}")

                    for route in routes:
                        short_name = route.get("shortName", "")
                        official_id = route.get("id", "")

                        if short_name and official_id:
                            sn_upper = short_name.upper()

                            # CATEogrizaion Logic
                            if sn_upper.startswith(("QM", "BM", "BXM", "SIM", "X")):
                                categorized_map["Express"][short_name] = official_id
                            elif sn_upper.startswith("BX"):
                                categorized_map["Bronx"][short_name] = official_id
                            elif sn_upper.startswith("B") and not sn_upper.startswith(
                                "BX"
                            ):
                                # Ensure it's not a Manhattan or Bronx route misidentified
                                categorized_map["Brooklyn"][short_name] = official_id
                            elif sn_upper.startswith("M") and not sn_upper.startswith(
                                ("BM", "BXM")
                            ):
                                categorized_map["Manhattan"][short_name] = official_id
                            elif sn_upper.startswith("Q") and not sn_upper.startswith(
                                "QM"
                            ):
                                categorized_map["Queens"][short_name] = official_id
                            elif sn_upper.startswith("S") and not sn_upper.startswith(
                                "SIM"
                            ):
                                categorized_map["Staten Island"][
                                    short_name
                                ] = official_id
                            else:
                                # This filters out the "Misc" like D90, L90, etc.
                                continue

                else:
                    print(f"❌ Error fetching {agency}: {data}")

            except Exception as e:
                print(f"⚠️ Connection failed for {agency}: {e}")

    # Save to file
    output_path = "app/data/early_2026_buses_tag.json"
    import os

    os.makedirs("app/data", exist_ok=True)

    with open(output_path, "w") as f:
        json.dump(categorized_map, f, indent=4)

    total = sum(len(v) for v in categorized_map.values())
    print(f"\n🎉 Done! Saved {total} high-quality route tags to '{output_path}'")
    for cat, items in categorized_map.items():
        print(f"  - {cat}: {len(items)}")


if __name__ == "__main__":
    asyncio.run(fetch_all_route_tags())
