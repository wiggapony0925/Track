"""Scoped logger for MetroMind.

Uses the app's ``TrackLogger`` under the hood so log lines flow through
the same JSON/file/console formatting as the rest of the backend.
"""

from __future__ import annotations

import logging


def get_logger(name: str = "MetroMind") -> logging.Logger:
    """Return a named logger under the ``track.metromind`` tree.

    All MetroMind code uses ``get_logger(__name__.split('.')[-1])`` so
    the per-module scope is preserved in log lines.
    """
    full_name = name if name.startswith("track.metromind") else f"track.metromind.{name}"
    return logging.getLogger(full_name)


__all__ = ["get_logger"]
