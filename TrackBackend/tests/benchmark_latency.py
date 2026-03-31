
import asyncio
import time
import httpx
from app.clients.mta_client import fetch_protobuf
from app.config import get_feed_url
from app.services.gtfs.realtime_parser import get_arrivals_for_line

# Benchmark settings
TEST_LINE = "L"
ITERATIONS = 5

async def benchmark_mta_fetch():
    print(f"🚀 Starting Backend Latency Benchmark for Line '{TEST_LINE}'...")
    print(f"--------------------------------------------------")
    
    total_time = 0
    
    for i in range(ITERATIONS):
        start = time.perf_counter()
        
        # 1. Simulate the exact call the router makes
        try:
            arrivals = await get_arrivals_for_line(TEST_LINE)
            end = time.perf_counter()
            duration = (end - start) * 1000 # ms
            total_time += duration
            
            print(f"Run {i+1}: {duration:.2f} ms | Found {len(arrivals)} trains")
            
            # Check for precision
            if arrivals:
                sample = arrivals[0]
                has_ts = sample.arrival_ts > 0
                print(f"   > Sample Train: {sample.destination} in {sample.minutes_away}m (Precision TS: {has_ts})")
                
        except Exception as e:
            print(f"Run {i+1} FAILED: {e}")

    avg_time = total_time / ITERATIONS
    print(f"--------------------------------------------------")
    print(f"⚡️ Average Latency: {avg_time:.2f} ms")
    print(f"--------------------------------------------------")

    if avg_time < 200:
        print("✅ Backend Status: BLAZING FAST (Real-time ready)")
    elif avg_time < 500:
        print("⚠️ Backend Status: FAST (Acceptable)")
    else:
        print("❌ Backend Status: SLOW (Needs optimization)")

if __name__ == "__main__":
    asyncio.run(benchmark_mta_fetch())
