"""Tool implementations for MetroMind.

Each file in this package exposes a single tool following the shape
expected by OpenAI's function-calling API:

    {
        "name": "plan_route",
        "description": "...",
        "parameters": {...JSON schema...},
    }

and a matching ``run(arguments: dict)`` coroutine that executes it.
The dispatcher in :mod:`.registry` wires tool names to their
``(schema, run)`` pairs.
"""

from .registry import (
    ToolError,
    ToolResult,
    dispatch,
    tool_schemas,
)

__all__ = ["ToolError", "ToolResult", "dispatch", "tool_schemas"]
