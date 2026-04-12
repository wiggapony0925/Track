## API contract and operating principles

This API is designed for a mobile client that needs fast, resilient, explainable transit data. When extending the backend, keep these contract rules in mind.

### Response design rules
- **Prefer graceful degradation over hard failure** for realtime endpoints. Empty arrays, stale cache, and schedule backfill are usually better than a fatal `500` for rider-facing screens.
- **Use typed response models** so the portal remains a reliable onboarding tool.
- **Return explanatory fields, not just raw upstream values.** Examples include `color_hex`, `bus_service_type`, `status`, `alert_type`, and `schedule_note`.
- **Keep payloads frontend-ready.** The iOS app should not have to reconstruct official route colors, service-type labels, or per-mode presentation logic from scratch.

### Error semantics
- **`400`** means the client sent invalid or conflicting parameters.
- **`403`** means the route is intentionally restricted, usually to localhost-only operational actions.
- **`404`** means the requested route, line, or resource identifier is unknown.
- **`502`** means an upstream provider is failing in a way this route chooses to expose.
- **`503`** usually means warmup or temporary service unavailability, and should include a `Retry-After` hint when possible.

### Cache and freshness philosophy
- **Static geometry** should be heavily cacheable.
- **Realtime arrivals** should prefer short freshness windows plus `stale-while-revalidate` behavior.
- **Operational/admin endpoints** should favor accuracy over long caching.
- **The portal docs should explain freshness expectations** so new developers understand whether an endpoint is static, semi-static, realtime, or warmup-gated.

### Reading order for new developers
1. Read the overview and upstream dependency tables.
2. Read the tag-to-surface matrix below.
3. Inspect the `nearby`, `subway`, `bus`, and `engine` tags in the portal.
4. Use the `system` tag to validate warmup, cache, and refresh behavior during local development.

### Documentation source of truth
The top-level portal description is assembled from the following files:

{{DOCS_FILE_INDEX}}
