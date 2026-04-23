"""Shared types for MetroMind tools.

Lives in its own module so tool implementations can import ``ToolError``
and ``ToolResult`` without creating a cycle through ``registry``.
"""

from __future__ import annotations

from dataclasses import dataclass


class ToolError(RuntimeError):
    """Raised when a tool execution fails in a way worth surfacing."""


@dataclass(slots=True)
class ToolResult:
    """Result of a tool invocation, ready to feed back to the LLM."""

    name: str
    content: str  # Serialised JSON (or a short human string for errors).
    ok: bool = True
    ui_label: str = ""


__all__ = ["ToolError", "ToolResult"]
