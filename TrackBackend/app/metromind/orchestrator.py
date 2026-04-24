"""Agent loop for MetroMind — LLM ↔ tools ↔ stream.

High level flow per user turn::

    [history + user] → LLM
                        ├── final text →  stream it, done.
                        └── tool_calls → run tools in parallel → loop.

The orchestrator keeps iterating until either the LLM returns a final
message or ``settings.max_tool_iterations`` is hit (defensive cap).
"""

from __future__ import annotations

import asyncio
import hashlib
import json
from typing import Any, AsyncIterator

from app.metromind.config import get_metromind_settings
from app.metromind.conversation_state import extract_state
from app.metromind.llm import LLMClient, LLMError
from app.metromind.logger import get_logger
from app.metromind.model_router import pick_model
from app.metromind.prompts import render_system_prompt
from app.metromind.schemas import (
    ChatMessage,
    SSEDoneEvent,
    SSEErrorEvent,
    SSESuggestionsEvent,
    SSEToolCallEvent,
    SSEToolResultEvent,
    SSETokenEvent,
    SuggestedAction,
    UserContext,
)
from app.metromind.suggestions import build_suggestions, parse_tool_payload
from app.metromind.tools import dispatch, tool_schemas

logger = get_logger("orchestrator")


def _format_history(
    system_prompt: str,
    history: list[ChatMessage],
    user_message: str,
    *,
    window: int,
    image_data_url: str | None = None,
) -> list[dict[str, Any]]:
    """Build the OpenAI messages list for a single turn.

    When ``image_data_url`` is provided the *current* user turn becomes
    a multimodal message (list of content parts). Past history images
    are passed through too if their ``image_data_url`` is set.
    """
    messages: list[dict[str, Any]] = [{"role": "system", "content": system_prompt}]

    # Keep only the last `window` history messages to bound tokens.
    trimmed = history[-window:] if window > 0 else history
    for msg in trimmed:
        past_image = getattr(msg, "image_data_url", None)
        if past_image and msg.role == "user":
            messages.append({
                "role": msg.role,
                "content": [
                    {"type": "text", "text": msg.content or ""},
                    {"type": "image_url", "image_url": {"url": past_image}},
                ],
            })
        else:
            messages.append({"role": msg.role, "content": msg.content})

    if image_data_url:
        messages.append({
            "role": "user",
            "content": [
                {"type": "text", "text": user_message},
                {"type": "image_url", "image_url": {"url": image_data_url}},
            ],
        })
    else:
        messages.append({"role": "user", "content": user_message})
    return messages


async def _run_tool_calls(
    tool_calls: list[Any],
    context: UserContext | None,
) -> list[tuple[Any, Any]]:
    """Execute all tool calls from a single assistant turn in parallel.

    Returns ``[(tool_call, tool_result), ...]`` in the original order.
    """
    async def _one(call: Any) -> Any:
        return await dispatch(
            call.function.name,
            call.function.arguments or "{}",
            context=context,
        )

    results = await asyncio.gather(*[_one(c) for c in tool_calls])
    return list(zip(tool_calls, results, strict=True))


def _call_signature(name: str, arguments_json: str | None) -> str:
    """Stable hash of (tool_name, normalised_args) for per-turn dedupe.

    Two tool calls with the same name and same argument values — even
    if key order differs — collapse to the same signature so the
    orchestrator can short-circuit a duplicate call instead of letting
    the model spin in a replan loop.
    """
    try:
        args = json.loads(arguments_json or "{}") if arguments_json else {}
    except json.JSONDecodeError:
        args = {"_raw": arguments_json or ""}
    canon = json.dumps(args, sort_keys=True, separators=(",", ":"))
    h = hashlib.sha1(f"{name}|{canon}".encode("utf-8")).hexdigest()[:16]
    return h


DUPLICATE_CALL_NOTE = (
    "You already called this tool with these exact arguments earlier in "
    "this turn — the previous result is still in your context. Do not "
    "call it again; use what you have to answer the user now."
)


# ── Non-streaming entry point ─────────────────────────────────────────

async def run_turn(
    *,
    client: LLMClient,
    history: list[ChatMessage],
    user_message: str,
    context: UserContext | None,
    image_data_url: str | None = None,
) -> tuple[str, list[str], list[SuggestedAction], str]:
    """Execute a single user turn.

    Returns ``(reply_text, tool_names_used, suggested_actions, model_used)``.
    """
    settings = get_metromind_settings()
    state = extract_state(history, user_message)
    system_prompt = render_system_prompt(context, state)
    messages = _format_history(
        system_prompt,
        history,
        user_message,
        window=settings.history_window,
        image_data_url=image_data_url,
    )
    tools = tool_schemas()
    used_tools: list[str] = []
    tool_payloads: dict[str, dict[str, Any] | None] = {}
    seen_signatures: set[str] = set()
    model, reason = pick_model(
        user_message=user_message,
        history=history,
        has_image=bool(image_data_url),
    )
    logger.info("model=%s reason=%s", model, reason)

    for _ in range(settings.max_tool_iterations + 1):
        response = await client.complete(messages=messages, tools=tools, model=model)
        choice = response.choices[0].message
        tool_calls = getattr(choice, "tool_calls", None) or []

        if not tool_calls:
            # Final assistant message.
            reply = (choice.content or "").strip()
            chips = build_suggestions(
                used_tools=used_tools,
                tool_payloads=tool_payloads,
                context=context,
            )
            return reply, used_tools, chips, model

        # Append the assistant's tool_call turn, then each tool result.
        messages.append(
            {
                "role": "assistant",
                "content": choice.content or "",
                "tool_calls": [
                    {
                        "id": tc.id,
                        "type": "function",
                        "function": {
                            "name": tc.function.name,
                            "arguments": tc.function.arguments,
                        },
                    }
                    for tc in tool_calls
                ],
            }
        )

        # Split into fresh calls vs. duplicates we've already executed
        # this turn. Duplicates get a synthetic "stop repeating yourself"
        # tool result so the model can move on instead of re-planning.
        fresh_calls: list[Any] = []
        for call in tool_calls:
            sig = _call_signature(call.function.name, call.function.arguments)
            if sig in seen_signatures:
                logger.info("Dedupe: %s called twice with same args", call.function.name)
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": call.id,
                        "content": json.dumps(
                            {"error": "duplicate_call", "note": DUPLICATE_CALL_NOTE}
                        ),
                    }
                )
                continue
            seen_signatures.add(sig)
            fresh_calls.append(call)

        if fresh_calls:
            pairs = await _run_tool_calls(fresh_calls, context)
            for call, result in pairs:
                used_tools.append(call.function.name)
                tool_payloads[call.function.name] = parse_tool_payload(
                    call.function.name, result.content
                )
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": call.id,
                        "content": result.content,
                    }
                )

    # Iteration cap hit. Instead of erroring out, force ONE final answer
    # with tool_choice="none" so the model commits to the best reply it
    # can give from the tool results already in context.
    logger.warning(
        "MetroMind hit max_tool_iterations (%d) \u2014 forcing final answer",
        settings.max_tool_iterations,
    )
    chips = build_suggestions(
        used_tools=used_tools, tool_payloads=tool_payloads, context=context
    )
    try:
        final = await client.complete(
            messages=messages, tools=tools, model=model, tool_choice="none"
        )
        reply = (final.choices[0].message.content or "").strip()
        if reply:
            return reply, used_tools, chips, model
    except LLMError as exc:
        logger.warning("Force-final completion failed: %s", exc)

    return (
        "I had trouble pulling everything together \u2014 try rephrasing or asking "
        "for one piece at a time?",
        used_tools,
        chips,
        model,
    )


# ── Streaming entry point ─────────────────────────────────────────────

async def stream_turn(
    *,
    client: LLMClient,
    history: list[ChatMessage],
    user_message: str,
    context: UserContext | None,
    image_data_url: str | None = None,
    thread_id: str | None = None,
) -> AsyncIterator[dict[str, Any]]:
    """Yield SSE event dicts for a single user turn.

    Each yielded dict is a Pydantic-ready payload (see ``schemas.SSE*``)
    that the FastAPI layer serialises to ``data: {...}\\n\\n``.
    """
    settings = get_metromind_settings()
    state = extract_state(history, user_message)
    system_prompt = render_system_prompt(context, state)
    messages = _format_history(
        system_prompt,
        history,
        user_message,
        window=settings.history_window,
        image_data_url=image_data_url,
    )
    tools = tool_schemas()
    used_tools: list[str] = []
    tool_payloads: dict[str, dict[str, Any] | None] = {}
    seen_signatures: set[str] = set()
    model, reason = pick_model(
        user_message=user_message,
        history=history,
        has_image=bool(image_data_url),
    )
    logger.info("stream model=%s reason=%s", model, reason)

    try:
        for iteration in range(settings.max_tool_iterations + 1):
            # Buffers for this iteration's streaming output.
            content_buf: list[str] = []
            # Aggregated tool calls by index (OpenAI streams fragments).
            tool_calls_buf: dict[int, dict[str, Any]] = {}

            async for chunk in client.stream(messages=messages, tools=tools, model=model):
                delta = chunk.choices[0].delta if chunk.choices else None
                if delta is None:
                    continue

                # Text token.
                token = getattr(delta, "content", None)
                if token:
                    content_buf.append(token)
                    yield SSETokenEvent(text=token).model_dump()

                # Tool-call fragments.
                for tc_delta in getattr(delta, "tool_calls", None) or []:
                    idx = tc_delta.index
                    slot = tool_calls_buf.setdefault(
                        idx,
                        {"id": None, "name": None, "arguments": ""},
                    )
                    if tc_delta.id:
                        slot["id"] = tc_delta.id
                    fn = getattr(tc_delta, "function", None)
                    if fn is not None:
                        if getattr(fn, "name", None):
                            slot["name"] = fn.name
                        if getattr(fn, "arguments", None):
                            slot["arguments"] += fn.arguments

            if not tool_calls_buf:
                # Done — no tool calls, stream ended. Emit suggestions then done.
                chips = build_suggestions(
                    used_tools=used_tools,
                    tool_payloads=tool_payloads,
                    context=context,
                )
                if chips:
                    yield SSESuggestionsEvent(actions=chips).model_dump()
                yield SSEDoneEvent(
                    tool_calls=used_tools,
                    model_used=model,
                    thread_id=thread_id,
                ).model_dump()
                return

            # Append assistant turn with tool_calls.
            messages.append(
                {
                    "role": "assistant",
                    "content": "".join(content_buf),
                    "tool_calls": [
                        {
                            "id": slot["id"],
                            "type": "function",
                            "function": {
                                "name": slot["name"] or "",
                                "arguments": slot["arguments"] or "{}",
                            },
                        }
                        for slot in sorted(tool_calls_buf.values(), key=lambda s: s.get("id") or "")
                    ],
                }
            )

            # Emit tool-call UI events + run them.
            # Split into fresh vs duplicate calls so we don't replay the
            # exact same tool with the exact same args inside one turn.
            fresh_indices: list[int] = []
            for idx in sorted(tool_calls_buf):
                slot = tool_calls_buf[idx]
                name = slot["name"] or "unknown"
                sig = _call_signature(name, slot.get("arguments"))
                if sig in seen_signatures:
                    logger.info("Stream dedupe: %s called twice with same args", name)
                    messages.append(
                        {
                            "role": "tool",
                            "tool_call_id": slot["id"],
                            "content": json.dumps(
                                {"error": "duplicate_call", "note": DUPLICATE_CALL_NOTE}
                            ),
                        }
                    )
                    continue
                seen_signatures.add(sig)
                fresh_indices.append(idx)
                yield SSEToolCallEvent(
                    name=name,
                    label=_pretty_label(name, slot.get("arguments")),
                ).model_dump()

            if not fresh_indices:
                # Every call this round was a duplicate — let the next
                # iteration produce a final answer from existing context.
                continue

            # Run in parallel.
            async def _run(slot: dict[str, Any]) -> Any:
                return await dispatch(
                    slot["name"] or "unknown",
                    slot["arguments"] or "{}",
                    context=context,
                )

            results = await asyncio.gather(
                *[_run(tool_calls_buf[i]) for i in fresh_indices]
            )

            for idx, result in zip(fresh_indices, results, strict=True):
                slot = tool_calls_buf[idx]
                used_tools.append(result.name)
                parsed = parse_tool_payload(result.name, result.content)
                tool_payloads[result.name] = parsed
                yield SSEToolResultEvent(
                    name=result.name,
                    ok=result.ok,
                    payload=_payload_for_ui(result.name, result.content),
                ).model_dump()
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": slot["id"],
                        "content": result.content,
                    }
                )

        # Iteration cap hit. Try ONE non-streaming completion with
        # tool_choice="none" so the model commits to a final answer
        # from whatever tool results are already in context, instead
        # of erroring.
        logger.warning("Stream hit max iterations \u2014 forcing final answer")
        try:
            final = await client.complete(
                messages=messages, tools=tools, model=model, tool_choice="none"
            )
            forced_text = (final.choices[0].message.content or "").strip()
        except LLMError as exc:
            logger.warning("Force-final failed: %s", exc)
            forced_text = ""

        if forced_text:
            yield SSETokenEvent(text=forced_text).model_dump()
            chips = build_suggestions(
                used_tools=used_tools,
                tool_payloads=tool_payloads,
                context=context,
            )
            if chips:
                yield SSESuggestionsEvent(actions=chips).model_dump()
            yield SSEDoneEvent(
                tool_calls=used_tools,
                model_used=model,
                thread_id=thread_id,
            ).model_dump()
            return

        yield SSEErrorEvent(
            message="I had trouble pulling everything together \u2014 try rephrasing or asking for one piece at a time?"
        ).model_dump()
    except LLMError as exc:
        logger.warning("Stream aborted: %s", exc)
        yield SSEErrorEvent(message=str(exc)).model_dump()
    except Exception as exc:  # noqa: BLE001
        logger.exception("Stream crashed")
        yield SSEErrorEvent(message=f"Internal error: {exc}").model_dump()


# Tools whose JSON content we forward to the client for rich rendering.
_UI_PAYLOAD_TOOLS = {
    "plan_route",
    "search_stations",
    "get_live_arrivals",
    "get_stop_info",
    "get_equipment_outages",
    "get_service_alerts",
}


def _payload_for_ui(name: str, content: str) -> dict | None:
    """Decode tool result JSON into a dict the UI can render as a card.

    Returns ``None`` for tools whose payload isn't meant for the client
    or when the content can't be parsed as JSON.
    """
    if name not in _UI_PAYLOAD_TOOLS:
        return None
    try:
        parsed = json.loads(content)
    except (json.JSONDecodeError, TypeError):
        return None
    return parsed if isinstance(parsed, dict) else None


def _pretty_label(name: str, arguments_json: str | None) -> str:
    """Build a short "Doing X…" label for the UI from tool arguments."""
    try:
        args = json.loads(arguments_json or "{}")
    except json.JSONDecodeError:
        args = {}

    if name == "plan_route":
        origin = args.get("origin_label") or "origin"
        dest = args.get("destination_label") or "destination"
        return f"Planning {origin} → {dest}"
    if name == "get_live_arrivals":
        route = args.get("route_id") or ""
        direction = (args.get("direction") or "").lower()
        bits = ["Checking live"]
        if direction in {"north", "south"}:
            bits.append(f"{direction}bound")
        if route:
            bits.append(route)
        bits.append("trains")
        return " ".join(bits)
    if name == "get_stop_info":
        sn = args.get("station_name") or args.get("stop_id") or "stop"
        return f"Looking up {sn}"
    if name == "get_equipment_outages":
        sf = args.get("station_filter")
        eq = args.get("equipment_type") or "both"
        if sf:
            return f"Checking outages near {sf}"
        return f"Checking {eq} outages"
    if name == "get_service_alerts":
        mode = args.get("mode")
        route = args.get("route_id")
        if route:
            return f"Checking alerts for {route}"
        if mode:
            return f"Checking {mode} alerts"
        return "Checking service alerts"
    if name == "search_stations":
        q = (args.get("query") or "").strip()
        if not q and args.get("lat") is not None and args.get("lon") is not None:
            r = args.get("radius_km") or 1.0
            return f"Finding stops within {r:g} km"
        if not q:
            return "Searching nearby stops"
        return f"Searching stations for '{q}'"
    if name == "get_user_places":
        return "Looking up your saved places"
    return name


__all__ = ["run_turn", "stream_turn"]
