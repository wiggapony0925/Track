#
# cache_registry.py
# app/utils/cache_registry.py
#
# Central registry for @lru_cache'd functions.
#
# Problem: gtfs_refresh.py had to import 17 individual cached functions by
# name just to call .cache_clear() on each one.  Adding a new cache anywhere
# required remembering to update the import list — easy to forget.
#
# Solution (inspired by Transit App's config patterns): a decorator that
# wraps functools.lru_cache AND auto-registers the wrapped function.
# Clearing all caches is now a single call: clear_all_caches().
#

from __future__ import annotations

import functools
from typing import Any, Callable, TypeVar

F = TypeVar("F", bound=Callable[..., Any])

# Global list of every function decorated with @tracked_cache
_REGISTRY: list[Any] = []


def tracked_cache(maxsize: int | None = 128, typed: bool = False) -> Callable[[F], F]:
    """Drop-in replacement for @lru_cache that also registers the function.

    Usage:
        @tracked_cache(maxsize=1)
        def expensive_load():
            ...

    Then later:
        from app.utils.cache_registry import clear_all_caches
        clear_all_caches()   # clears every tracked cache at once
    """
    def decorator(fn: F) -> F:
        wrapped = functools.lru_cache(maxsize=maxsize, typed=typed)(fn)
        _REGISTRY.append(wrapped)
        return wrapped  # type: ignore[return-value]
    return decorator


def clear_all_caches() -> int:
    """Clear every registered cache. Returns the number of caches cleared."""
    cleared = 0
    for fn in _REGISTRY:
        if hasattr(fn, "cache_clear"):
            fn.cache_clear()
            cleared += 1
    return cleared


def cache_stats() -> list[dict[str, Any]]:
    """Return cache_info() for every registered cache — useful for /debug."""
    stats = []
    for fn in _REGISTRY:
        if hasattr(fn, "cache_info"):
            info = fn.cache_info()
            stats.append({
                "function": fn.__wrapped__.__qualname__ if hasattr(fn, "__wrapped__") else fn.__qualname__,
                "hits": info.hits,
                "misses": info.misses,
                "maxsize": info.maxsize,
                "currsize": info.currsize,
            })
    return stats
