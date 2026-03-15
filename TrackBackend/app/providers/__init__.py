#
# providers/__init__.py
# TrackBackend
#
# Provider registry.
#
# Import and register every supported transit provider here.
# The rest of the codebase calls ``get_provider()`` to obtain
# region-specific constants without hard-coding them.
#

from __future__ import annotations

from app.providers.base import TransitProvider

_providers: dict[str, TransitProvider] = {}
_default_id: str = "mta"


def register_provider(provider: TransitProvider) -> None:
    """Register a provider instance (called at import time)."""
    _providers[provider.provider_id] = provider


def get_provider(provider_id: str | None = None) -> TransitProvider:
    """Return the provider for *provider_id* (default: ``"mta"``)."""
    pid = provider_id or _default_id
    if pid not in _providers:
        raise KeyError(
            f"Unknown transit provider: {pid!r}. "
            f"Registered: {list(_providers)}"
        )
    return _providers[pid]


def set_default_provider(provider_id: str) -> None:
    """Change the default provider returned by ``get_provider()``."""
    global _default_id
    if provider_id not in _providers:
        raise KeyError(
            f"Cannot set default — unknown provider: {provider_id!r}. "
            f"Registered: {list(_providers)}"
        )
    _default_id = provider_id


# ── Auto-register built-in providers on first import ─────────────────────

from app.providers.mta import MtaProvider  # noqa: E402

register_provider(MtaProvider())
