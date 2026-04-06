// Single source of truth for MTA agency prefix stripping.
// Used by both the main app and widget extension.
// MTA agencies and their route ID prefixes:
//   • MTA NYCT_   — NYC Transit (Manhattan, Brooklyn, SI buses + subway)
//   • MTABC_      — MTA Bus Company (Queens, Bronx, Express buses)
//   • MTA BUS_    — MTA Bus (some SIRI/OBA edge cases)
//   • LIRR_       — Long Island Rail Road
//   • MNR_        — Metro-North Railroad
//   • MTA_        — Shared stop ID prefix (e.g. "MTA_308214")
// If the MTA introduces a new agency prefix, add it here once
// and every callsite across the app + widgets picks it up.

import Foundation

// MARK: - Agency Prefixes (ordered longest-first to avoid partial matches)

/// All known MTA agency prefixes, ordered from longest to shortest
/// so that "MTA NYCT_" is tested before "MTA_" (which would match too early).
let mtaAgencyPrefixes: [(prefix: String, length: Int)] = [
    ("MTA NYCT_", 9),
    ("MTA BUS_",  8),
    ("MTABC_",    6),
    ("LIRR_",     5),
    ("MNR_",      4),
    ("MTA_",      4),
]

// MARK: - Route ID Stripping

/// Strips any MTA agency prefix from a route ID for display.
///
/// Examples:
///   - `"MTA NYCT_B63"` → `"B63"`
///   - `"MTABC_Q10"`    → `"Q10"`
///   - `"MTA BUS_Q58"`  → `"Q58"`
///   - `"LIRR_9"`       → `"9"`
///   - `"MNR_2"`        → `"2"`
///   - `"L"`            → `"L"` (unchanged)
///
/// Also strips stray `+` characters that occasionally appear in
/// GTFS-RT feeds (e.g. `_L+"` → `"L"`).
nonisolated func stripMTAAgencyPrefix(_ id: String) -> String {
    for (prefix, length) in mtaAgencyPrefixes {
        if id.hasPrefix(prefix) {
            return String(id.dropFirst(length)).replacingOccurrences(of: "+", with: "")
        }
    }
    return id.replacingOccurrences(of: "+", with: "")
}

// MARK: - Stop ID Stripping

/// Strips MTA agency prefixes from a stop ID for comparison.
///
/// Uses `.replacingOccurrences` instead of `hasPrefix` because stop IDs
/// can contain multiple prefixed segments (rare but observed in OBA data).
///
/// Examples:
///   - `"MTA NYCT_305423"` → `"305423"`
///   - `"MTA_308214"`      → `"308214"`
///   - `"MTABC_550042"`    → `"550042"`
nonisolated func stripMTAStopPrefix(_ id: String) -> String {
    var result = id
    // Order matters: strip longest prefixes first
    for (prefix, _) in mtaAgencyPrefixes {
        result = result.replacingOccurrences(of: prefix, with: "")
    }
    return result
}

// MARK: - Route Token Normalization

/// Returns a canonical route token for matching across mixed ID formats.
///
/// Strips known agency prefixes, removes spaces, removes the `-SBS` suffix
/// (grouped API uses `"M23-SBS"` while GTFS stop IDs use `"MTA NYCT_M23+"`),
/// and uppercases the result so both representations compare equal.
///
/// Also handles the `+SBS` variant: `stripMTAAgencyPrefix` converts `+` to
/// nothing, leaving a bare `SBS` suffix — we strip trailing `SBS` to match.
///
/// Examples:
///   - "MTA NYCT_Q10"       -> "Q10"
///   - "MTABC_Q10"          -> "Q10"
///   - "M23-SBS"            -> "M23"
///   - "MTA NYCT_M23+"      -> "M23"
///   - "MTA NYCT_M14A+SBS"  -> "M14A"
///   - "M14A-SBS"           -> "M14A"
///   - "LIRR_9"             -> "9"
///   - "mnr_1"              -> "1"
nonisolated func normalizeMTARouteToken(_ id: String) -> String {
    var result = stripMTAAgencyPrefix(id)
        .replacingOccurrences(of: "-SBS", with: "", options: .caseInsensitive)
        .replacingOccurrences(of: " ", with: "")
        .uppercased()

    // Strip trailing "SBS" that remains when the input used the +SBS form.
    // stripMTAAgencyPrefix removes all "+" chars, so "M14A+SBS" → "M14ASBS".
    // The "-SBS" replacement above doesn't catch that — handle it here.
    if result.hasSuffix("SBS") {
        result = String(result.dropLast(3))
    }

    // Strip leading zeros from the numeric portion.
    // GTFS shape data zero-pads some route numbers ("MTABC_Q09" → "Q09")
    // while the grouped API uses unpadded forms ("Q9").  Normalise both
    // to the unpadded form so enrichment matching succeeds.
    if let firstDigit = result.firstIndex(where: \.isNumber) {
        let alpha = result[result.startIndex..<firstDigit]
        var numeric = String(result[firstDigit...])
        while numeric.count > 1 && numeric.first == "0" {
            numeric.removeFirst()
        }
        result = String(alpha) + numeric
    }

    return result
}

// MARK: - Stop ID Normalization

/// Strips MTA agency prefixes AND trailing N/S direction suffixes from a stop ID.
///
/// This is the canonical stop-ID normalization used for direction assignment
/// and stop matching across the app.  Combines `stripMTAStopPrefix` with
/// direction-suffix removal so both bus and subway stop IDs reduce to a
/// stable parent-station key.
///
/// Examples:
///   - `"MTA NYCT_120N"` → `"120"`
///   - `"MTA_305423"`    → `"305423"`
///   - `"A31S"`          → `"A31"`
///   - `"GS"`            → `"GS"` (unchanged — not a direction suffix)
nonisolated func normalizeStopId(_ raw: String) -> String {
    let stripped = stripMTAStopPrefix(raw)
    guard stripped.count > 1, let last = stripped.last, last == "N" || last == "S" else {
        return stripped
    }
    let penultimate = stripped[stripped.index(before: stripped.index(before: stripped.endIndex))]
    if penultimate.isNumber || penultimate.isLowercase {
        return String(stripped.dropLast())
    }
    return stripped
}
