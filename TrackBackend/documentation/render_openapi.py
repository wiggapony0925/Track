"""Renderer that builds the final OpenAPI description markdown."""

from __future__ import annotations

from pathlib import Path

from app.config import get_settings
from documentation.tag_docs import render_tag_matrix
from documentation.url_docs import render_upstream_urls

_DOCS_ROOT = Path(__file__).resolve().parent
_MARKDOWN_FILES = [
    _DOCS_ROOT / "openapi_overview.md",
    _DOCS_ROOT / "api_principles.md",
    _DOCS_ROOT / "data_lifecycle.md",
    _DOCS_ROOT / "endpoint_playbook.md",
]


def build_api_description() -> str:
    """Compose markdown fragments into the top-level OpenAPI description."""
    template = "\n\n".join(path.read_text(encoding="utf-8").strip() for path in _MARKDOWN_FILES)
    settings = get_settings()
    return (
        template.replace("{{UPSTREAM_URLS_TABLE}}", render_upstream_urls(settings))
        .replace("{{TAG_MATRIX_TABLE}}", render_tag_matrix())
        .replace("{{DOCS_FILE_INDEX}}", render_docs_file_index())
    )


def render_docs_file_index() -> str:
    """Return a markdown list of the human-authored docs fragments."""
    return "\n".join(f"- `{path.name}`" for path in _MARKDOWN_FILES)
