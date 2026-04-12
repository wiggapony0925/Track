# Documentation package

This folder contains the backend documentation assets that feed the private API portal.

## Files
- `openapi_overview.md` — high-level backend overview shown at the top of the portal
- `api_principles.md` — API contract, error, caching, and contributor guidance
- `endpoint_playbook.md` — product-surface usage guide for common client flows
- `tag_docs.py` — OpenAPI tag metadata and tag-to-surface table helpers
- `url_docs.py` — upstream URL explanations rendered from `settings.json`
- `render_openapi.py` — combines markdown fragments and generated tables into the final top-level OpenAPI description
- `docs_auth.py` — docs portal auth and `/openapi.json` protection

## Goal
Keep developer-facing documentation close to the code, but out of runtime-heavy application files such as `app/main.py`.
