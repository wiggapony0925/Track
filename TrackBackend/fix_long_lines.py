#!/usr/bin/env python3
"""Fix remaining lines > 79 chars that autopep8 missed.

Handles: docstrings, f-string asserts, @patch decorators,
long conditionals, comments, and other patterns.
No backslash continuations.
"""

from __future__ import annotations

import re
import textwrap
from pathlib import Path

MAX = 79
TEST_DIR = Path(__file__).parent / "tests"

FILES = [
    "test_bus_routes.py",
    "test_contract.py",
    "test_nearby.py",
    "test_route_shapes.py",
    "test_all_endpoints.py",
    "test_cross_stack_contract.py",
    "test_polyline_quality.py",
    "test_coverage.py",
    "test_predict.py",
    "test_corridor_offsets.py",
    "test_mta_client.py",
    "health_check.py",
]


def get_indent(line: str) -> str:
    return line[: len(line) - len(line.lstrip())]


def is_in_triple_quote_block(lines, idx):
    """Check if line idx is inside a triple-quoted string."""
    count = 0
    for i in range(idx):
        count += lines[i].count('"""')
        count += lines[i].count("'''")
    # If count is odd, we're inside a triple-quoted string
    return count % 2 == 1


def fix_long_docstring_line(line, indent):
    """Wrap a long line that's inside a docstring."""
    stripped = line.strip()
    # Don't break URLs
    if "http://" in stripped or "https://" in stripped:
        return None
    wrap_width = MAX - len(indent)
    if wrap_width < 20:
        return None
    wrapped = textwrap.fill(
        stripped,
        width=wrap_width,
        subsequent_indent="",
        break_long_words=False,
        break_on_hyphens=False,
    )
    if wrapped == stripped:
        return None
    result_lines = []
    for wl in wrapped.split("\n"):
        result_lines.append(indent + wl)
    return result_lines


def fix_assert_fstring(line, indent):
    """Fix: assert X, f\"long message\"  ->  multiline with parens."""
    # Match assert with f-string message
    m = re.match(r'^(\s*assert\s+.+?),\s+(f["\'].+["\'])\s*$', line)
    if m:
        assert_part = m.group(1)
        msg = m.group(2)
        # Check if just splitting at the comma works
        line1 = assert_part + ","
        line2 = indent + "    " + msg
        if len(line1) <= MAX and len(line2) <= MAX:
            return [line1, line2]
        # Try with parentheses
        line1 = assert_part + ", ("
        line2 = indent + "    " + msg
        line3 = indent + ")"
        if len(line1) <= MAX and len(line2) <= MAX:
            return [line1, line2, line3]
        # Message itself is too long - try breaking it
        if len(line1) <= MAX:
            # Break the f-string using implicit concatenation
            inner_indent = indent + "    "
            avail = MAX - len(inner_indent)
            if avail > 20:
                parts = _break_fstring(msg, avail)
                if parts:
                    result = [line1]
                    for p in parts:
                        result.append(inner_indent + p)
                    result.append(indent + ")")
                    if all(len(r) <= MAX for r in result):
                        return result
    return None


def _break_fstring(fstr, max_width):
    """Break an f-string into multiple parts using concatenation."""
    # Remove the f" prefix and trailing "
    if fstr.startswith('f"') and fstr.endswith('"'):
        quote = '"'
        inner = fstr[2:-1]
    elif fstr.startswith("f'") and fstr.endswith("'"):
        quote = "'"
        inner = fstr[2:-1]
    else:
        return None

    # Find good break points (spaces not inside {})
    parts = []
    current = ""
    brace_depth = 0
    for ch in inner:
        if ch == "{":
            brace_depth += 1
        elif ch == "}":
            brace_depth -= 1
        current += ch
        if ch == " " and brace_depth == 0 and len(current) > max_width // 3:
            parts.append(current)
            current = ""
    if current:
        parts.append(current)

    if len(parts) <= 1:
        return None

    result = []
    for i, p in enumerate(parts):
        if i == 0:
            result.append(f"f{quote}{p}{quote}")
        else:
            result.append(f"f{quote}{p}{quote}")

    return result


def fix_patch_decorator(line, indent):
    """Fix long @patch('very.long.module.path') decorators."""
    m = re.match(r'^(\s*@patch\()(["\'])(.+?)\2(.*)\)\s*$', line)
    if m:
        prefix = m.group(1)
        q = m.group(2)
        path = m.group(3)
        rest = m.group(4)
        # Break the string path using implicit concatenation
        parts = path.split(".")
        if len(parts) >= 3:
            mid = len(parts) // 2
            p1 = ".".join(parts[:mid]) + "."
            p2 = ".".join(parts[mid:])
            inner_indent = indent + "    "
            str1 = f"{q}{p1}{q}"
            str2 = f"{q}{p2}{q}"
            result_line1 = f"{prefix}{str1}"
            result_line2 = f"{inner_indent}{str2}{rest})"
            if len(result_line1) <= MAX and len(result_line2) <= MAX:
                return [result_line1, result_line2]
    return None


def fix_isinstance_ternary(line, indent):
    """Fix: x = a if isinstance(...) else [a] patterns."""
    m = re.match(
        r"^(\s*)(\w+)\s*=\s*(.+?)\s+if\s+(isinstance\(.+?\))\s+else\s+(.+)$",
        line,
    )
    if m:
        ind = m.group(1)
        var = m.group(2)
        true_val = m.group(3)
        cond = m.group(4)
        false_val = m.group(5)
        line1 = f"{ind}{var} = ("
        line2 = f"{ind}    {true_val}"
        line3 = f"{ind}    if {cond}"
        line4 = f"{ind}    else {false_val}"
        line5 = f"{ind})"
        if all(len(ln) <= MAX for ln in [line1, line2, line3, line4, line5]):
            return [line1, line2, line3, line4, line5]
    return None


def fix_long_comment(line, indent):
    """Wrap a long # comment."""
    m = re.match(r"^(\s*#\s?)(.*)", line)
    if not m:
        return None
    prefix = m.group(1)
    text = m.group(2)
    if "http://" in text or "https://" in text:
        return None
    avail = MAX - len(prefix)
    if avail < 20:
        return None
    wrapped = textwrap.fill(
        text,
        width=avail,
        break_long_words=False,
        break_on_hyphens=False,
    )
    lines_out = wrapped.split("\n")
    if len(lines_out) <= 1:
        return None
    return [prefix + ln for ln in lines_out]


def fix_long_print_or_call(line, indent):
    """Fix long function calls like print(...) or assert func(...)."""
    # Generic: find first ( and try to break args
    stripped = line.rstrip()
    # Find the outermost opening paren
    paren_pos = None
    for i, ch in enumerate(stripped):
        if ch == "(":
            paren_pos = i
            break
    if paren_pos is None:
        return None

    prefix = stripped[: paren_pos + 1]
    rest = stripped[paren_pos + 1 :]

    # The rest should end with )
    if not rest.rstrip().endswith(")"):
        return None

    inner = rest.rstrip()[:-1]  # content between outer parens
    # Don't break if inner has nested parens (too complex)
    # Just try simple comma-separated args
    inner_indent = indent + "    "
    # Try putting args on next line
    line1 = prefix
    line2 = inner_indent + inner.strip()
    line3 = indent + ")"
    # Check if the inner part still fits
    if len(line1) <= MAX and len(line2) <= MAX and len(line3) <= MAX:
        return [line1, line2, line3]
    return None


def fix_backslash_continuation(lines, idx):
    """Replace backslash continuations with parens."""
    line = lines[idx].rstrip()
    if not line.endswith("\\"):
        return None, 0
    # Collect all continuation lines
    cont_lines = [line[:-1].rstrip()]
    j = idx + 1
    while j < len(lines) and lines[j].rstrip().endswith("\\"):
        cont_lines.append(lines[j].rstrip()[:-1].strip())
        j += 1
    if j < len(lines):
        cont_lines.append(lines[j].rstrip().strip())
        j += 1

    # Reconstruct with parens
    indent = get_indent(lines[idx])
    # Find a good split point
    " ".join(cont_lines)
    # Wrap in parens
    first = cont_lines[0]
    result = [indent + "(" + first.lstrip()]
    for cl in cont_lines[1:]:
        result.append(indent + "    " + cl)
    result[-1] = result[-1] + ")"

    if all(len(r) <= MAX for r in result):
        return result, j - idx
    return None, 0


def process_file(filepath):
    with open(filepath) as f:
        lines = f.readlines()

    new_lines = []
    i = 0
    in_docstring = False
    changes = 0

    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip("\n")

        # Track triple quotes for docstring detection
        tq_count = line.count('"""') + line.count("'''")

        if len(line) <= MAX:
            new_lines.append(raw)
            if tq_count % 2 == 1:
                in_docstring = not in_docstring
            i += 1
            continue

        indent = get_indent(line)
        fixed = None

        # 1) Try backslash continuation fix
        if line.rstrip().endswith("\\"):
            result, consumed = fix_backslash_continuation(lines, i)
            if result:
                for r in result:
                    new_lines.append(r + "\n")
                changes += 1
                i += consumed
                continue

        # 2) In a docstring? Wrap the text.
        if in_docstring:
            fixed = fix_long_docstring_line(line, indent)
            if fixed:
                for fl in fixed:
                    new_lines.append(fl + "\n")
                changes += 1
                if tq_count % 2 == 1:
                    in_docstring = not in_docstring
                i += 1
                continue

        # 3) Docstring open+content on same line
        stripped = line.strip()
        if (stripped.startswith('"""') and not stripped.endswith('"""')) or (
            stripped.startswith("'''") and not stripped.endswith("'''")
        ):
            in_docstring = True
            new_lines.append(raw)
            i += 1
            continue

        # One-line docstring
        if (
            stripped.startswith('"""')
            and stripped.endswith('"""')
            and stripped.count('"""') == 2
        ):
            # Wrap the docstring content
            inner = stripped[3:-3]
            wrap_w = MAX - len(indent) - 4  # for the indent
            if wrap_w > 20:
                wrapped = textwrap.fill(
                    inner,
                    width=wrap_w,
                    break_long_words=False,
                    break_on_hyphens=False,
                )
                wlines = wrapped.split("\n")
                if len(wlines) > 1:
                    result = [indent + '"""' + wlines[0]]
                    for wl in wlines[1:]:
                        result.append(indent + wl)
                    result.append(indent + '"""')
                    fixed = result
                elif len(indent + '"""' + wlines[0] + '"""') <= MAX:
                    fixed = [indent + '"""' + wlines[0] + '"""']
            if fixed:
                for fl in fixed:
                    new_lines.append(fl + "\n")
                changes += 1
                i += 1
                continue

        # 4) assert with f-string
        if "assert " in line and ("f'" in line or 'f"' in line):
            fixed = fix_assert_fstring(line, indent)
            if fixed:
                for fl in fixed:
                    new_lines.append(fl + "\n")
                changes += 1
                i += 1
                continue

        # 5) @patch decorator
        if stripped.startswith(("@patch(", "@patch.object(")):
            fixed = fix_patch_decorator(line, indent)
            if fixed:
                for fl in fixed:
                    new_lines.append(fl + "\n")
                changes += 1
                i += 1
                continue

        # 6) isinstance ternary
        if "isinstance(" in line and " if " in line and " else " in line:
            fixed = fix_isinstance_ternary(line, indent)
            if fixed:
                for fl in fixed:
                    new_lines.append(fl + "\n")
                changes += 1
                i += 1
                continue

        # 7) Comment
        if stripped.startswith("#"):
            fixed = fix_long_comment(line, indent)
            if fixed:
                for fl in fixed:
                    new_lines.append(fl + "\n")
                changes += 1
                i += 1
                continue

        # 8) Generic: try to break at a comma inside parens
        if "(" in line:
            # Find the best split point
            depth = 0
            best_split = None
            for ci, ch in enumerate(line):
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                elif ch == "," and depth == 1 and ci < MAX:
                    best_split = ci
            if best_split and best_split > 0:
                part1 = line[: best_split + 1]
                part2 = line[best_split + 1 :].strip()
                inner_indent = indent + "    "
                if len(part1) <= MAX and len(inner_indent + part2) <= MAX:
                    fixed = [part1, inner_indent + part2]

        if fixed:
            for fl in fixed:
                new_lines.append(fl + "\n")
            changes += 1
            i += 1
            continue

        # Couldn't fix - keep as-is
        new_lines.append(raw)
        if tq_count % 2 == 1:
            in_docstring = not in_docstring
        i += 1

    with open(filepath, "w") as f:
        f.writelines(new_lines)
    return changes


def main():
    total = 0
    for fname in FILES:
        fp = TEST_DIR / fname
        if fp.exists():
            n = process_file(fp)
            print(f"  {fname}: {n} fixes applied")
            total += n
    print(f"\nTotal fixes: {total}")

    # Verify remaining
    remaining = 0
    for fname in FILES:
        fp = TEST_DIR / fname
        if fp.exists():
            with open(fp) as f:
                for _lno, line in enumerate(f, 1):
                    if len(line.rstrip("\n")) > MAX:
                        remaining += 1
    print(f"Remaining violations: {remaining}")


if __name__ == "__main__":
    main()
