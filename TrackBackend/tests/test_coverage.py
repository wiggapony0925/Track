from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from pathlib import Path

import pyfiglet
from colorama import Back, Fore, Style, init

# Ensure we can import app
sys.path.append(os.getcwd())

from app.clients.bus_client import get_stops, resolve_bus_id
from app.services.mapping.subway_shapes import get_subway_route_shape
from app.utils.transit_utils import get_all_subway_lines, get_subway_color

init(autoreset=True)


class LegendaryTester:
    def __init__(self):
        self.stats = {
            "subway": {"pass": 0, "fail": 0, "total": 0},
            "bus": {"pass": 0, "fail": 0, "total": 0},
            "rail": {"pass": 0, "fail": 0, "total": 0},
            "healing": {"pass": 0, "fail": 0, "total": 0},
        }
        self.failures = []
        self.start_time = 0

    def print_banner(self):
        banner = pyfiglet.figlet_format("TRACK  NYC", font="slant")
        print(f"{Fore.CYAN}{Style.BRIGHT}{banner}")
        print(
            f"{Fore.WHITE}{Back.BLUE}{Style.BRIGHT}  SYSTEM INTEGRITY & FULL COVERAGE TEST  "
        )
        print(f"{Style.DIM}Local Time: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")

    async def test_subways(self):
        print(f"{Fore.YELLOW}🚇 TESTING SUBWAY INFRASTRUCTURE...")
        lines = get_all_subway_lines()

        # Internal mapping for tests where OBA/GTFS IDs differ from display IDs
        aliases = {"SR": "H"}

        self.stats["subway"]["total"] = len(lines)

        for line in lines:
            try:
                # Try original, then alias
                res = get_subway_route_shape(line)
                if not (res and len(res[1]) > 0) and line in aliases:
                    res = get_subway_route_shape(aliases[line])

                if res and len(res[1]) > 0:
                    print(
                        f"  {Fore.GREEN}✅ {line}: {len(res[1])} stops, {len(res[0])} polylines"
                    )
                    self.stats["subway"]["pass"] += 1
                else:
                    print(f"  {Fore.RED}❌ {line}: Missing shape or stops")
                    self.stats["subway"]["fail"] += 1
                    self.failures.append(f"Subway Line {line}: No data found")
            except Exception as e:
                print(f"  {Fore.RED}💥 {line}: ERROR - {e}")
                self.stats["subway"]["fail"] += 1
                self.failures.append(f"Subway Line {line}: {e}")
        print("")

    async def test_buses(self):
        """Test EVERY route in our discovery map."""
        print(f"{Fore.YELLOW}🚌 TESTING FULL BUS DISCOVERY (ALL ROUTES)...")

        map_path = Path("app/data/early_2026_buses_tag.json")
        if not map_path.exists():
            print(f"{Fore.RED}❌ FAILED: early_2026_buses_tag.json not found!")
            return

        with open(map_path) as f:
            categorized = json.load(f)

        test_routes = []
        for cat, routes in categorized.items():
            for sn, oid in routes.items():
                test_routes.append((sn, oid, cat))

        total_routes = len(test_routes)
        self.stats["bus"]["total"] = total_routes
        print(f"   (Queueing {total_routes} routes for verification...)")

        # Lower concurrency to avoid 403 Forbidden from MTA rate limiter
        semaphore = asyncio.Semaphore(5)

        async def check_route(short_name, official_id, cat):
            async with semaphore:
                # Be respectful to the API
                await asyncio.sleep(0.1)

                retries = 2
                for attempt in range(retries + 1):
                    try:
                        stops = await get_stops(official_id)
                        if stops and len(stops) > 0:
                            return True, None
                        return (
                            False,
                            f"Bus {short_name}: {official_id} returned 0 stops",
                        )
                    except Exception as e:
                        if "403" in str(e) and attempt < retries:
                            await asyncio.sleep(3.0 * (attempt + 1))  # Back off on 403
                            continue
                        return False, f"Bus {short_name} ({official_id}): {e}"
            return None

        tasks = [check_route(sn, oid, cat) for sn, oid, cat in test_routes]
        results = await asyncio.gather(*tasks)

        passed_count = sum(1 for success, error in results if success)
        failed_results = [error for success, error in results if not success]

        print(f"  {Fore.GREEN}✅ {passed_count} routes passed verification.")
        if failed_results:
            print(f"  {Fore.RED}❌ {len(failed_results)} routes failed.")
            for error in failed_results[:10]:  # Only show first 10 failures
                print(f"    - {error}")

            for error in failed_results:
                self.failures.append(error)

        self.stats["bus"]["pass"] = passed_count
        self.stats["bus"]["fail"] = len(failed_results)
        print("")

    async def test_self_healing(self):
        print(f"{Fore.YELLOW}🛡️  TESTING SELF-HEALING DISCOVERY...")
        test_unknown = "Q50"
        self.stats["healing"]["total"] = 1
        try:
            start = time.time()
            resolved = await resolve_bus_id(test_unknown)
            end = time.time()
            if resolved and "_" in resolved:
                print(
                    f"  {Fore.GREEN}✨ SUCCESS: Self-healed '{test_unknown}' -> '{resolved}' in {end-start:.2f}s"
                )
                self.stats["healing"]["pass"] += 1
            else:
                print(
                    f"  {Fore.RED}❌ FAILED: Could not self-heal unknown route '{test_unknown}'"
                )
                self.stats["healing"]["fail"] += 1
                self.failures.append(f"Self-Healing: Failed for {test_unknown}")
        except Exception as e:
            print(f"  {Fore.RED}💥 ERROR: {e}")
            self.stats["healing"]["fail"] += 1
            self.failures.append(f"Self-Healing Error: {e}")
        print("")

    async def test_commuter_rail(self):
        print(f"{Fore.YELLOW}🚆 TESTING COMMUTER RAIL (LIRR & METRO-NORTH)...")

        # 1. Color Check
        branches = [
            "Babylon Branch",
            "Harlem Line",
            "Hudson Line",
            "Ronkonkoma Branch",
            "Port Washington Branch",
        ]
        self.stats["rail"]["total"] = len(branches) + 1  # +1 for feed check

        for br in branches:
            if get_subway_color(br) != "#808183":
                print(f"  {Fore.GREEN}✅ {br}: Color verified")
                self.stats["rail"]["pass"] += 1
            else:
                print(f"  {Fore.RED}❌ {br}: Color fallback triggered")
                self.stats["rail"]["fail"] += 1
                self.failures.append(f"Rail: {br} color fallback triggered")

        # 2. Live Feed Check
        try:
            from app.routers.lirr import lirr_arrivals
            from app.routers.mnr import mnr_arrivals

            print(f"  {Fore.CYAN}📡 Checking LIRR Real-time Feed...")
            larrivals = await lirr_arrivals()
            print(
                f"  {Fore.GREEN}✅ LIRR Feed: Reachable ({len(larrivals)} active arrivals)"
            )

            print(f"  {Fore.CYAN}📡 Checking Metro-North Real-time Feed...")
            marrivals = await mnr_arrivals()
            print(
                f"  {Fore.GREEN}✅ Metro-North Feed: Reachable ({len(marrivals)} active arrivals)"
            )

            self.stats["rail"]["pass"] += 1
        except Exception as e:
            print(f"  {Fore.RED}❌ LIRR Feed: Error - {e}")
            self.stats["rail"]["fail"] += 1
            self.failures.append(f"LIRR Feed: {e}")
        print("")

    def print_summary(self):
        end_time = time.time()
        duration = end_time - self.start_time

        print(
            f"\n{Fore.WHITE}{Back.MAGENTA}{Style.BRIGHT}  FINAL SYSTEM-WIDE TEST SUMMARY  "
        )

        for category, data in self.stats.items():
            p = data["pass"]
            f = data["fail"]
            t = data["total"]
            if t == 0:
                continue

            percentage = p / t * 100
            color = Fore.GREEN if f == 0 else Fore.YELLOW
            if percentage < 50:
                color = Fore.RED

            bar_len = 30
            passes = int((p / t) * bar_len)
            bar = f"{Fore.GREEN}{'█' * passes}{Fore.RED}{'█' * (bar_len - passes)}"

            print(
                f"{category.capitalize():<10} | {bar} | {color}{percentage:>6.1f}% ({p}/{t})"
            )

        print(f"\n{Fore.CYAN}Total Execution Time: {duration:.2f}s")

        if self.failures:
            print(
                f"\n{Fore.RED}{Style.BRIGHT}⚠️ ISSUES DETECTED ({len(self.failures)}):"
            )
            unique_failures = list(dict.fromkeys(self.failures))
            for fail in unique_failures[:10]:
                print(f"  - {fail}")
            if len(unique_failures) > 10:
                print(f"  ... and {len(unique_failures)-10} more unique issues")
        else:
            print(
                f"\n{Fore.GREEN}{Style.BRIGHT}🏆 LEGENDARY STATUS: ALL NYC TRANSIT SYSTEMS NOMINAL! 🏆"
            )

    async def run(self):
        self.start_time = time.time()
        self.print_banner()

        await self.test_subways()
        await self.test_commuter_rail()
        await self.test_buses()
        await self.test_self_healing()

        self.print_summary()


if __name__ == "__main__":
    tester = LegendaryTester()
    asyncio.run(tester.run())
