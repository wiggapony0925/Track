# MetroMind 🧠🚇

Conversational AI layer for the **Track** NYC transit app.

MetroMind lives inside the existing TrackBackend service — it reuses the
route engine, alerts pipeline, and GTFS catalogue as **tools** the LLM
can call to answer questions with real-time data.

> **Why a shared backend and not a separate service?** The bot is only
> useful when it can call `plan_route`, `get_service_alerts`, etc. Those
> already live here as in-process Python functions. One deploy, one
> auth layer, one log stream.

---

## Folder layout

```
metromind/
├── __init__.py
├── config.py         # MetroMindSettings (model, temp, history window, flags)
├── logger.py         # Scoped 'track.metromind.*' logger
├── schemas.py        # Pydantic request/response + SSE events
├── prompts/
│   └── system_prompts.py
├── llm/
│   └── client.py     # AsyncOpenAI wrapper w/ retries + streaming
├── tools/
│   ├── registry.py   # Dispatcher (name → schema + runner)
│   ├── plan.py       # plan_route
│   ├── alerts.py     # get_service_alerts
│   └── stations.py   # search_stations
├── orchestrator.py   # Agent loop: LLM ↔ tools ↔ stream
├── router.py         # FastAPI /metromind/chat + /health
└── tests/
    ├── test_tools.py
    └── test_orchestrator.py
```

---

## Endpoints

### `GET /metromind/health`

Reports whether the module is configured and reachable.

```json
{
  "enabled": true,
  "model": "gpt-4o-mini",
  "streaming_enabled": true,
  "llm": "ready"
}
```

### `POST /metromind/chat`

Request body (all fields except `message` are optional):

```json
{
  "message": "Fastest way from Times Sq to Brooklyn Bridge?",
  "history": [
    { "role": "user", "content": "Hi" },
    { "role": "assistant", "content": "Hi! How can I help?" }
  ],
  "context": {
    "lat": 40.7580,
    "lon": -73.9855,
    "timezone": "America/New_York"
  },
  "stream": true
}
```

When `stream=true` (default) the response is **Server-Sent Events**.
Each event is a single JSON blob on a `data:` line:

| `type`        | Payload                                      | When |
|---------------|----------------------------------------------|------|
| `token`       | `{ text: "…" }`                              | Assistant text chunk |
| `tool_call`   | `{ name, label }`                            | Model called a tool |
| `tool_result` | `{ name, ok }`                               | Tool finished |
| `done`        | `{ tool_calls: [...] }`                      | Stream complete |
| `error`       | `{ message }`                                | Fatal error |

When `stream=false` the response is a single JSON blob:

```json
{ "reply": "Here are your best options…", "tool_calls": ["plan_route"] }
```

---

## Tools

| Tool | Purpose |
|------|---------|
| `plan_route` | Ranked itineraries via `TrackEngineService.plan()` |
| `get_service_alerts` | MTA alerts via `realtime_parser.get_alerts()` |
| `search_stations` | Fuzzy GTFS stop lookup via `search_stops()` |

Tools are declared in `tools/registry.py`. Add a new tool by:

1. Creating `tools/my_tool.py` with a `SCHEMA` dict and `async def run(args, context)` coroutine.
2. Registering it in `registry._REGISTRY`.

---

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `OPENAI_API_KEY` | *(required)* | API key for the LLM |
| `METROMIND_MODEL` | `gpt-4o-mini` | Override model |
| `METROMIND_TEMPERATURE` | `0.3` | Sampling temperature |
| `METROMIND_MAX_OUTPUT_TOKENS` | `800` | Max tokens per reply |
| `METROMIND_MAX_TOOL_ITERATIONS` | `4` | Hard cap on tool hops per turn |
| `METROMIND_STREAMING_ENABLED` | `true` | Disable to force JSON responses |
| `METROMIND_ENABLED` | `true` | Master kill switch |

---

## Running locally

```bash
cd TrackBackend
export OPENAI_API_KEY=sk-...
python run.py
```

Health check:

```bash
curl -s localhost:8000/metromind/health | jq
```

Non-streaming chat (easy for debugging):

```bash
curl -sN localhost:8000/metromind/chat \
  -H 'content-type: application/json' \
  -d '{"message":"Any L train delays?","stream":false}' | jq
```

Streaming chat:

```bash
curl -N localhost:8000/metromind/chat \
  -H 'content-type: application/json' \
  -d '{"message":"How do I get from Times Sq to Union Sq?"}'
```

## Running tests

```bash
cd TrackBackend
pytest app/metromind/tests -v
```

---

## Not yet (v1.1+ ideas)

- `find_nearby_stops` tool (using the existing `/nearby` logic)
- `next_arrivals` tool
- Persist conversation history per user in Supabase
- On-device fallback with Foundation Models for offline simple Qs
