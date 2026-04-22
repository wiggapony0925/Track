"""Quick smoke-test for all user model endpoints.

Usage:
    python scripts/test_user_endpoints.py

Requires the local server to be running on port 8000.
Auth-protected routes are tested without a token (expect 401).
Public routes are tested normally (expect 200).
"""

import json
import sys
import urllib.error
import urllib.request

BASE = "http://localhost:8000"
PASS_COUNT = 0
FAIL_COUNT = 0


def check(path: str, expect: int = 200, method: str = "GET", headers: dict | None = None, timeout: int = 30):
    global PASS_COUNT, FAIL_COUNT
    req = urllib.request.Request(BASE + path, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            status = r.status
            body = json.loads(r.read())
    except urllib.error.HTTPError as e:
        status = e.code
        try:
            body = json.loads(e.read())
        except Exception:
            body = {}

    ok = status == expect
    tag = "PASS" if ok else "FAIL"
    if ok:
        PASS_COUNT += 1
    else:
        FAIL_COUNT += 1
    print(f"  [{tag}] {status} (expected {expect})  {method} {path}")
    if not ok:
        print(f"         body: {json.dumps(body)[:120]}")
    return status, body


print("\n── Public endpoints (no auth) ──────────────────────────────")
check("/health")
check("/nearby/grouped?lat=40.748&lon=-73.985")

print("\n── Auth-protected — no token → 401 ────────────────────────")
check("/user/me", expect=401)
check("/user/profile", expect=401)
check("/engine/places", expect=401)
check("/engine/trips/saved", expect=401)
check("/engine/trips/recent", expect=401)
check("/engine/recommendations", expect=401)

print("\n── Auth-protected — garbage token → 401 (or 503 if JWT secret missing) ─")
bad = {"Authorization": "Bearer notavalidtoken"}
# Without SUPABASE_JWT_SECRET, server returns 503 (not configured).
# With it set, a bad token returns 401. Both are acceptable here.
s, _ = check("/user/me", expect=401, headers=bad)
if s == 503:
    print("         ↳ 503 = SUPABASE_JWT_SECRET not set; add it to .env to enable full auth")
    PASS_COUNT += 1  # adjust: 503 is acceptable when JWT secret is missing
    FAIL_COUNT -= 1
s, _ = check("/user/profile", expect=401, headers=bad)
if s == 503:
    PASS_COUNT += 1
    FAIL_COUNT -= 1

print(f"\n── Results: {PASS_COUNT} passed, {FAIL_COUNT} failed ──────────────────────\n")
sys.exit(0 if FAIL_COUNT == 0 else 1)
