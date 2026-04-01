#!/usr/bin/env python3
"""Auto-fix lines > 79 characters in scripts/*.py files.

Run from TrackBackend/:
    python scripts/_fix_long_lines.py
"""

from __future__ import annotations

import re
import textwrap
from pathlib import Path

MAX = 79
SCRIPTS_DIR = Path(__file__).resolve().parent


def _indent(line: str) -> str:
    """Return the leading whitespace of *line*."""
    return line[: len(line) - len(line.lstrip())]


def _fix_separator_comment(line: str) -> str | None:
    """Truncate # ═══…═══  (or ─── or ┌── etc.) separator lines."""
    stripped = line.lstrip()
    if stripped.startswith("#") and len(line) > MAX:
        # Check if the content after # is mostly box-drawing chars
        after_hash = stripped[1:].strip()
        box_chars = set("═─╔╗╚╝║┌┐└┘│├┤┬┴┼")
        if (
            after_hash
            and sum(1 for c in after_hash if c in box_chars) / max(len(after_hash), 1)
            > 0.6
        ):
            indent = _indent(line)
            # Truncate to fit
            budget = MAX - len(indent) - 2  # "# " prefix
            return indent + "# " + after_hash[:budget]
    return None


def _fix_long_comment(line: str) -> list[str] | None:
    """Wrap a long # comment at word boundaries."""
    stripped = line.lstrip()
    if not stripped.startswith("#"):
        return None
    if len(line) <= MAX:
        return None
    indent = _indent(line)
    # Extract the comment text (after # or #  )
    m = re.match(r"#(\s*)", stripped)
    if not m:
        return None
    space_after = m.group(1) or " "
    if len(space_after) > 2:
        space_after = "  "
    prefix = indent + "#" + space_after
    text = stripped[len("#" + space_after) :]
    # Wrap at word boundaries
    width = MAX - len(prefix)
    if width < 20:
        return None
    wrapped = textwrap.wrap(text, width=width)
    if not wrapped:
        return None
    return [prefix + w for w in wrapped]


def _fix_long_import(line: str) -> list[str] | None:
    """Break long 'from ... import a, b, c' into multi-line."""
    stripped = line.lstrip()
    if not stripped.startswith("from ") or " import " not in stripped:
        return None
    if len(line) <= MAX:
        return None
    indent = _indent(line)
    m = re.match(r"(from\s+\S+\s+import\s+)", stripped)
    if not m:
        return None
    prefix = m.group(1)
    names_str = stripped[len(prefix) :]
    names = [n.strip() for n in names_str.split(",")]
    # Build multi-line with parentheses
    result = [indent + prefix + "("]
    cont_indent = indent + "    "
    current = cont_indent
    for i, name in enumerate(names):
        addition = name + (", " if i < len(names) - 1 else ",")
        if len(current + addition) > MAX and current.strip():
            result.append(current.rstrip())
            current = cont_indent + addition
        else:
            current += addition
    if current.strip():
        result.append(current.rstrip())
    result.append(indent + ")")
    return result


def _fix_long_print_fstring(line: str) -> list[str] | None:
    """Break long print(f\"...\") into multi-line."""
    stripped = line.lstrip()
    if len(line) <= MAX:
        return None
    indent = _indent(line)

    # Match print(f"..." ) or print("...")
    m = re.match(r'(print\()(f?")(.*?)(")\)\s*$', stripped)
    if not m:
        m = re.match(r"(print\()(f?')(.*?)(')\)\s*$", stripped)
    if not m:
        return None

    call_prefix = m.group(1)  # "print("
    f_quote = m.group(2)  # 'f"' or '"'
    content = m.group(3)
    close_quote = m.group(4)

    is_fstring = f_quote.startswith("f")

    # Try to split the content at a space boundary
    # Target: each line should be <= MAX
    lines = []
    cont_indent = indent + "    "
    budget = MAX - len(cont_indent) - len(f_quote) - len(close_quote) - 1
    if budget < 20:
        return None

    # Split on spaces, keeping f-string {expr} together
    pieces = _split_fstring_content(content, budget)
    if len(pieces) <= 1:
        return None

    lines.append(indent + call_prefix)
    for i, piece in enumerate(pieces):
        q = f_quote if is_fstring else '"'
        if i < len(pieces) - 1:
            line_text = cont_indent + q + piece + close_quote
        else:
            line_text = cont_indent + q + piece + close_quote
        lines.append(line_text)
    lines.append(indent + ")")
    # Validate all lines fit
    if all(len(ln) <= MAX for ln in lines):
        return lines
    return None


def _split_fstring_content(content: str, budget: int) -> list[str]:
    """Split an f-string content into pieces ≤ budget chars."""
    if len(content) <= budget:
        return [content]

    pieces = []
    current = ""
    i = 0
    while i < len(content):
        # If inside {expr}, grab the whole expression
        if content[i] == "{":
            j = content.index("}", i) + 1 if "}" in content[i:] else len(content)
            expr = content[i:j]
            if len(current) + len(expr) > budget and current:
                # Try to break at last space in current
                sp = current.rfind(" ")
                if sp > 0:
                    pieces.append(current[: sp + 1])
                    current = current[sp + 1 :] + expr
                else:
                    pieces.append(current)
                    current = expr
            else:
                current += expr
            i = j
        else:
            current += content[i]
            i += 1
            # Check if we should break
            if len(current) > budget:
                sp = current.rfind(" ")
                if sp > 0:
                    pieces.append(current[: sp + 1])
                    current = current[sp + 1 :]

    if current:
        pieces.append(current)
    return pieces


def _fix_long_string_in_call(line: str) -> list[str] | None:
    """Break a long string argument in a function call."""
    stripped = line.lstrip()
    if len(line) <= MAX:
        return None
    indent = _indent(line)

    # Match: something(f"..." ) or something("...")
    # or out.append("...")
    m = re.match(r'(\w[\w.]*\()(f?")(.*?)(")\)\s*$', stripped)
    if not m:
        m = re.match(r"(\w[\w.]*\()(f?')(.*?)(')\)\s*$", stripped)
    if not m:
        # Try .method() form
        m = re.match(
            r'(\w[\w.]*\.(?:append|extend|add)\()(f?")(.*?)(")\)\s*$',
            stripped,
        )
    if not m:
        return None

    call = m.group(1)
    f_quote = m.group(2)
    content = m.group(3)
    close_quote = m.group(4)
    is_fstring = f_quote.startswith("f")

    cont_indent = indent + "    "
    budget = MAX - len(cont_indent) - len(f_quote) - len(close_quote)
    if budget < 15:
        return None

    pieces = _split_fstring_content(content, budget)
    if len(pieces) <= 1:
        return None

    lines = [indent + call]
    for piece in pieces:
        q = f_quote if is_fstring else '"'
        lines.append(cont_indent + q + piece + close_quote)
    lines.append(indent + ")")
    if all(len(ln) <= MAX for ln in lines):
        return lines
    return None


def fix_file(filepath: Path, dry_run: bool = False) -> int:
    """Fix all lines > MAX in *filepath*. Returns count fixed."""
    with open(filepath) as f:
        original_lines = f.readlines()

    new_lines: list[str] = []
    fixed = 0

    i = 0
    while i < len(original_lines):
        raw = original_lines[i].rstrip("\n")
        if len(raw) <= MAX:
            new_lines.append(original_lines[i])
            i += 1
            continue

        # Try each fixer in order
        result = None

        # 1. Separator comments (═══, ───, etc.)
        result = _fix_separator_comment(raw)
        if isinstance(result, str):
            new_lines.append(result + "\n")
            fixed += 1
            i += 1
            continue

        # 2. Regular comments
        result = _fix_long_comment(raw)
        if result:
            for r in result:
                new_lines.append(r + "\n")
            fixed += 1
            i += 1
            continue

        # 3. Import statements
        result = _fix_long_import(raw)
        if result:
            for r in result:
                new_lines.append(r + "\n")
            fixed += 1
            i += 1
            continue

        # Keep as-is if no fixer matched
        new_lines.append(original_lines[i])
        i += 1

    if not dry_run and fixed > 0:
        with open(filepath, "w") as f:
            f.writelines(new_lines)

    return fixed


def main() -> None:
    total = 0
    for fp in sorted(SCRIPTS_DIR.glob("*.py")):
        if fp.name == "_fix_long_lines.py":
            continue
        fixed = fix_file(fp)
        if fixed:
            print(f"  {fp.name}: {fixed} lines fixed")
            total += fixed
    print(f"\nTotal auto-fixed: {total}")


if __name__ == "__main__":
    main()
