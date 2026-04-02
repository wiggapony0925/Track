#!/usr/bin/env python3
"""Strip Xcode boilerplate file headers from Swift files.

Removes the standard 4-line Xcode header (// / filename / target / //)
and converts any remaining description lines to a proper module docstring
if they contain meaningful content. Files with only "Created by" boilerplate
have the entire header removed.

Usage:
    python3 scripts/strip_headers.py
"""

import os
import re


def process_swift_file(filepath: str) -> bool:
    """Process a single Swift file to strip boilerplate headers.

    Args:
        filepath: Path to the Swift file.

    Returns:
        True if the file was modified.
    """
    with open(filepath, "r") as f:
        lines = f.readlines()

    if len(lines) < 4:
        return False

    # Check if the file starts with the standard Xcode header pattern:
    # Line 1: //
    # Line 2: //  FileName.swift
    # Line 3: //  TargetName (Track, Shared, TrackWidgets, etc.)
    # Line 4: //
    if not (
        lines[0].rstrip() == "//"
        and lines[1].rstrip().startswith("//  ")
        and lines[1].rstrip().endswith(".swift")
        and lines[2].rstrip().startswith("//  ")
        and lines[3].rstrip() == "//"
    ):
        return False

    # Find the end of the comment block (contiguous // lines)
    header_end = 4
    for i in range(4, len(lines)):
        stripped = lines[i].rstrip()
        if stripped.startswith("//"):
            header_end = i + 1
        else:
            break

    # Extract description lines (lines 5 through end of header,
    # excluding the closing bare //)
    description_lines = []
    for i in range(4, header_end):
        stripped = lines[i].rstrip()
        if stripped == "//":
            continue  # Skip bare separators
        # Remove the "//  " prefix
        content = stripped
        if content.startswith("//  "):
            content = content[4:]
        elif content.startswith("// "):
            content = content[3:]
        elif content == "//":
            continue
        # Skip "Created by" lines
        if content.startswith("Created by"):
            continue
        description_lines.append(content)

    # Skip blank lines after header
    content_start = header_end
    while content_start < len(lines) and lines[content_start].strip() == "":
        content_start += 1

    # Build new file content
    new_lines = []

    # Only add module docstring if there are meaningful description lines
    if description_lines:
        # Check if description is substantial enough to keep
        # (more than just the type name or very short phrases)
        total_desc = " ".join(description_lines).strip()
        if len(total_desc) > 10:
            for desc_line in description_lines:
                new_lines.append(f"// {desc_line}\n")
            new_lines.append("\n")

    # Add the rest of the file content
    new_lines.extend(lines[content_start:])

    with open(filepath, "w") as f:
        f.writelines(new_lines)

    return True


def main() -> None:
    """Process all Swift files in the project."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dirs_to_process = [
        os.path.join(root, "Shared"),
        os.path.join(root, "Track"),
        os.path.join(root, "TrackWidgets"),
    ]

    modified_count = 0
    total_count = 0

    for dir_path in dirs_to_process:
        for dirpath, _, filenames in os.walk(dir_path):
            for filename in filenames:
                if not filename.endswith(".swift"):
                    continue
                filepath = os.path.join(dirpath, filename)
                total_count += 1
                if process_swift_file(filepath):
                    modified_count += 1
                    print(f"  Modified: {os.path.relpath(filepath, root)}")

    print(f"\nProcessed {total_count} files, modified {modified_count}")


if __name__ == "__main__":
    main()
