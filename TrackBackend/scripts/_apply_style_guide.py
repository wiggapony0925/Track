#!/usr/bin/env python3
"""Apply Google Python Style Guide changes across the TrackBackend codebase.

Transformations:
  1. Convert # block-comment file headers to triple-quoted module docstrings.
  2. Add ``from __future__ import annotations`` where missing.
  3. Preserve shebangs, existing docstrings, and all other content.
"""

from __future__ import annotations

import re
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parent.parent

# Files/dirs to skip
_SKIP_NAMES = {".venv", "__pycache__", ".git", "node_modules"}

# Pattern: a line that is only a `#` comment (with optional trailing spaces)
_COMMENT_LINE_RE = re.compile(r"^#(.*)$")

# Known project-name lines to strip from the header
_PROJECT_NAMES = {"TrackBackend", "TrackBackend/tests", "Track"}


def _collect_py_files(root: Path) -> list[Path]:
    """Recursively collect .py files, skipping virtual-envs and caches."""
    results: list[Path] = []
    for child in sorted(root.iterdir()):
        if child.name in _SKIP_NAMES:
            continue
        if child.is_dir():
            results.extend(_collect_py_files(child))
        elif child.suffix == ".py":
            results.append(child)
    return results


def _parse_header_block(lines: list[str]) -> tuple[str, str, list[str]]:
    """Parse leading shebang, # block header, and remaining content.

    Returns:
        A tuple of (shebang_line_or_empty, docstring_text, remaining_lines).
    """
    idx = 0
    shebang = ""

    # 1. Consume optional shebang
    if lines and lines[0].startswith("#!"):
        shebang = lines[0]
        idx += 1

    # 2. Consume contiguous # comment block (and blank lines between them)
    header_comment_lines: list[str] = []
    while idx < len(lines):
        stripped = lines[idx].rstrip()
        m = _COMMENT_LINE_RE.match(stripped)
        if m is not None:
            header_comment_lines.append(m.group(1))
            idx += 1
        elif stripped == "" and header_comment_lines:
            # Allow one blank line inside/after the block, but peek ahead
            # to see if more # lines follow.
            if idx + 1 < len(lines) and _COMMENT_LINE_RE.match(lines[idx + 1].rstrip()):
                header_comment_lines.append("")
                idx += 1
            else:
                break
        else:
            break

    # 3. Build description text from the comment lines
    # Strip decoration: leading/trailing empty `#` lines, filename line,
    # project-name line.
    cleaned: list[str] = []
    for raw in header_comment_lines:
        text = raw.strip()
        # Skip empty border lines
        if text == "":
            if cleaned:
                cleaned.append("")
            continue
        # Skip lines that look like "filename.py"
        if text.endswith(".py"):
            continue
        # Skip project name lines
        if text in _PROJECT_NAMES:
            continue
        # Skip lines of pure decoration (e.g. "── section ──")
        if set(text) <= {"─", "—", "=", "-", " "}:
            continue
        cleaned.append(text)

    # Trim leading/trailing blank entries
    while cleaned and cleaned[0] == "":
        cleaned.pop(0)
    while cleaned and cleaned[-1] == "":
        cleaned.pop()

    docstring_text = "\n".join(cleaned)

    # Remaining lines (skip leading blank lines right after the header)
    remaining = lines[idx:]
    while remaining and remaining[0].strip() == "":
        remaining.pop(0)

    return shebang, docstring_text, remaining


def _has_module_docstring(lines: list[str]) -> bool:
    """Return True if the file already has a module-level docstring."""
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        return stripped.startswith(('"""', "'''"))
    return False


def _has_future_annotations(text: str) -> bool:
    return "from __future__ import annotations" in text


def _format_docstring(text: str) -> str:
    """Format text as a proper PEP 257 module docstring."""
    if not text:
        return ""
    lines = text.split("\n")
    if len(lines) == 1 and len(lines[0]) <= 72:
        return (
            f'"""{lines[0]}."""\n'
            if not lines[0].endswith(".")
            else f'"""{lines[0]}"""\n'
        )
    # Multi-line
    if not lines[-1].endswith((".", "!", "?")):
        lines[-1] = lines[-1] + "."
    body = "\n".join(lines)
    return f'"""{body}"""\n'


def transform_file(filepath: Path) -> bool:
    """Apply style-guide transformations to a single file.

    Returns True if the file was modified.
    """
    original = filepath.read_text(encoding="utf-8")
    lines = original.splitlines(keepends=True)

    if not lines:
        return False

    # Normalise to plain strings for parsing (strip newlines), then rebuild.
    raw_lines = [ln.rstrip("\n").rstrip("\r") for ln in lines]

    # Check if file already has a docstring (skip # header conversion)
    already_has_docstring = _has_module_docstring(raw_lines)

    # If there's a # header block AND no docstring yet, convert it.
    new_parts: list[str] = []

    if not already_has_docstring:
        shebang, docstring_text, remaining = _parse_header_block(raw_lines)

        if shebang:
            new_parts.append(shebang + "\n")

        if docstring_text:
            new_parts.append(_format_docstring(docstring_text))
            new_parts.append("\n")

        # Add future annotations if missing
        if not _has_future_annotations(original):
            new_parts.append("from __future__ import annotations\n")
            new_parts.append("\n")

        # Add remaining content
        for rl in remaining:
            new_parts.append(rl + "\n")
    else:
        # Already has a docstring — only add future annotations if missing
        if not _has_future_annotations(original):
            # Insert after the docstring
            result_lines: list[str] = []
            inserted = False
            in_docstring = False
            docstring_ended = False
            for _i, rl in enumerate(raw_lines):
                result_lines.append(rl + "\n")
                stripped = rl.strip()
                if not inserted and not in_docstring and not docstring_ended:
                    # Skip blanks and comments before docstring
                    if stripped.startswith(("#!", "#")) or stripped == "":
                        continue
                    if stripped.startswith(('"""', "'''")):
                        quote = stripped[:3]
                        if stripped.count(quote) >= 2 and len(stripped) > 3:
                            # Single-line docstring
                            docstring_ended = True
                        else:
                            in_docstring = True
                        continue
                    # Not a docstring — insert before first real code
                    result_lines.insert(
                        len(result_lines) - 1,
                        "from __future__ import annotations\n\n",
                    )
                    inserted = True
                elif in_docstring:
                    if '"""' in stripped or "'''" in stripped:
                        in_docstring = False
                        docstring_ended = True
                elif docstring_ended and not inserted:
                    if stripped == "":
                        continue
                    # Insert future annotations here
                    result_lines.insert(
                        len(result_lines) - 1,
                        "\nfrom __future__ import annotations\n\n",
                    )
                    inserted = True
            new_parts = result_lines
        else:
            # Nothing to change
            return False

    new_text = "".join(new_parts)

    # Ensure file ends with exactly one newline
    new_text = new_text.rstrip("\n") + "\n"

    if new_text == original:
        return False

    filepath.write_text(new_text, encoding="utf-8")
    return True


def main() -> None:
    root = _BACKEND_ROOT
    py_files = _collect_py_files(root)

    # Also include top-level scripts
    for name in ("run.py", "fix_long_lines.py"):
        p = root / name
        if p.exists() and p not in py_files:
            py_files.append(p)

    modified = 0
    for f in py_files:
        rel = f.relative_to(root)
        if transform_file(f):
            print(f"  MODIFIED  {rel}")
            modified += 1
        else:
            print(f"  ok        {rel}")

    print(f"\n{modified}/{len(py_files)} files modified.")


if __name__ == "__main__":
    main()
