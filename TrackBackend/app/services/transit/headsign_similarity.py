"""Headsign similarity & terminus clustering.

Given a list of arrivals heading in the same compass direction, decide
whether their destination headsigns describe the *same* terminus
(should be merged into one tab) or *different* termini (should be
split into separate branch tabs).

Examples:
    "Flushing"            ≈ "Flushing-Main St"        → merge
    "Astoria-Ditmars Blvd" ≈ "Ditmars Blvd"           → merge
    "Inwood-207 St"        ≠ "Far Rockaway-Mott Av"   → split
    "Ozone Park-Lefferts"  ≠ "Far Rockaway-Mott Av"   → split

This module is mode-agnostic and pure-logic so it can be unit-tested in
isolation.

Algorithm:
    1. Normalise: uppercase, drop punctuation, drop service-variant
       prefixes ("LIMITED", "LTD", "SBS", "SELECT BUS SERVICE",
       "SUPER EXPRESS"), drop "via X" suffixes, collapse whitespace.
    2. Compare the normalised forms:
        a. exact match → same terminus
        b. one is a prefix of the other → same terminus  (handles
           "FLUSHING" vs "FLUSHING MAIN ST")
        c. one is fully contained in the other (substring) → same
           terminus  (handles "ASTORIA DITMARS BLVD" vs "DITMARS BLVD")
        d. token Jaccard similarity ≥ 0.6 → same terminus  (handles
           re-orderings and minor spelling differences)
        e. otherwise → different termini.
"""

from __future__ import annotations

import re
from collections import defaultdict


# Service-variant tokens stripped before comparison so two headsigns
# that differ only by "Limited"/"Local"/"SBS" still merge.
_VARIANT_PREFIX_RE = re.compile(
    r"^("
    r"LIMITED|LTD|"
    r"LOCAL|"
    r"SBS|SELECT\s+BUS(?:\s+SERVICE)?|"
    r"SUPER\s+EXPRESS|EXPRESS|EXP|"
    r"SHUTTLE|"
    r"RUSH"
    r")\s+",
    re.IGNORECASE,
)

# Suffixes that describe the *route* of a trip (corridor) rather than
# the destination — e.g. "KINGS PLAZA via FLATBUSH AV".  We compare
# only the part before "via" so two trips to the same terminus via
# different corridors merge.
_VIA_SUFFIX_RE = re.compile(r"\s+VIA\s+.*$", re.IGNORECASE)

# Punctuation to strip before tokenising.
_PUNCT_RE = re.compile(r"[\-\u2013\u2014/.,()'`]+")

# Token-similarity threshold for case (d) above.  Tuned conservatively:
# 0.6 catches "FLUSHING MAIN ST" vs "MAIN ST FLUSHING" but rejects
# "INWOOD 207 ST" vs "FAR ROCKAWAY MOTT AV".
_JACCARD_THRESHOLD: float = 0.6


def normalise_headsign(text: str | None) -> str:
    """Reduce a destination/headsign string to its comparable form."""
    if not text:
        return ""

    upper = text.upper().strip()

    # Drop "via X" suffix; we only care about the terminus name.
    upper = _VIA_SUFFIX_RE.sub("", upper).strip()

    # Strip leading variant prefix iteratively (some feeds stack them,
    # e.g. "LIMITED RUSH KINGS PLAZA").
    while True:
        new = _VARIANT_PREFIX_RE.sub("", upper, count=1).strip()
        if new == upper:
            break
        upper = new

    # Replace punctuation with spaces, collapse whitespace.
    upper = _PUNCT_RE.sub(" ", upper)
    upper = re.sub(r"\s+", " ", upper).strip()
    return upper


def _tokens(text: str) -> set[str]:
    """Return the set of meaningful tokens in a normalised headsign."""
    if not text:
        return set()
    # Drop very short tokens (ST, AV, RD, etc.) and pure digits — they
    # rarely add signal and inflate Jaccard noise for street suffixes.
    return {
        tok for tok in text.split()
        if len(tok) > 2 and not tok.isdigit()
    }


def headsigns_describe_same_terminus(a: str | None, b: str | None) -> bool:
    """True when two headsigns refer to the same terminus.

    See module docstring for the full algorithm.  Always returns True
    when both inputs are equal after normalisation, and False when
    either input is empty.
    """
    na, nb = normalise_headsign(a), normalise_headsign(b)
    if not na or not nb:
        return False
    if na == nb:
        return True

    # Prefix / substring match handles
    # "FLUSHING" ⊂ "FLUSHING MAIN ST" and
    # "DITMARS BLVD" ⊂ "ASTORIA DITMARS BLVD".
    short, long = (na, nb) if len(na) <= len(nb) else (nb, na)
    if long.startswith(short) or long.endswith(short) or f" {short} " in f" {long} ":
        return True

    # Token Jaccard similarity for re-orderings / minor differences.
    ta, tb = _tokens(na), _tokens(nb)
    if not ta or not tb:
        return False
    inter = len(ta & tb)
    union = len(ta | tb)
    return (inter / union) >= _JACCARD_THRESHOLD


def cluster_headsigns(headsigns: list[str]) -> list[list[int]]:
    """Cluster headsigns by terminus.

    Args:
        headsigns: List of raw destination strings.  Order is preserved.

    Returns:
        A list of clusters, each cluster being a list of *indices* into
        the input.  Clusters are sorted by their smallest member index
        so the output is deterministic.

    The clustering is greedy / single-link: a headsign joins an
    existing cluster if it matches *any* existing member.  This is
    fine for the small N we see per direction (typically ≤ 5).
    """
    clusters: list[list[int]] = []
    # Empty / missing-headsign arrivals all merge into one shared
    # "unknown terminus" cluster so we don't proliferate ghost branch
    # tabs when the upstream feed drops the destination field for one
    # or two trips (Wave 11 — fixed 7-train sometimes showing 4
    # directions because empty headsigns each spawned their own
    # singleton cluster).
    empty_cluster: list[int] | None = None
    for idx, hs in enumerate(headsigns):
        if not normalise_headsign(hs):
            if empty_cluster is None:
                empty_cluster = [idx]
                clusters.append(empty_cluster)
            else:
                empty_cluster.append(idx)
            continue
        joined = False
        for cluster in clusters:
            # Skip the empty-headsign cluster — it can only accept
            # other empty entries.
            if cluster is empty_cluster:
                continue
            if any(
                headsigns_describe_same_terminus(hs, headsigns[j])
                for j in cluster
            ):
                cluster.append(idx)
                joined = True
                break
        if not joined:
            clusters.append([idx])
    clusters.sort(key=lambda c: c[0])
    return clusters


def cluster_arrivals_by_terminus(
    arrivals: list,  # list[NearbyTransitArrival] — runtime-typed
    *,
    key: str = "destination",
) -> list[list]:
    """Convenience wrapper that clusters arrivals by their headsign field.

    Args:
        arrivals: List of arrival objects (must have ``destination`` or
            ``direction`` attribute).
        key: Attribute name to read the headsign from.  Defaults to
            ``destination`` because that's where MTA puts the terminal
            station name; falls back to ``direction`` when the chosen
            key is empty.

    Returns:
        A list of arrival sub-lists, one per terminus.
    """
    if not arrivals:
        return []

    def _hs(a) -> str:
        primary = getattr(a, key, "") or ""
        if primary.strip():
            return primary
        # Fallback to the other label so we always have something.
        other = "direction" if key == "destination" else "destination"
        return (getattr(a, other, "") or "").strip()

    headsigns = [_hs(a) for a in arrivals]
    clusters = cluster_headsigns(headsigns)
    # Group arrivals matching the index buckets.
    grouped: list[list] = []
    by_idx: dict[int, list] = defaultdict(list)
    for cluster_id, cluster in enumerate(clusters):
        for member in cluster:
            by_idx[cluster_id].append(arrivals[member])
    for cluster_id in sorted(by_idx.keys()):
        grouped.append(by_idx[cluster_id])
    return grouped


__all__ = [
    "normalise_headsign",
    "headsigns_describe_same_terminus",
    "cluster_headsigns",
    "cluster_arrivals_by_terminus",
]
