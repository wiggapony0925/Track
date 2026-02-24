//
//  MTAPrefixes.swift
//  Shared
//
//  Single source of truth for MTA agency prefix stripping.
//  Used by both the main app and widget extension.
//
//  MTA agencies and their route ID prefixes:
//    • MTA NYCT_   — NYC Transit (Manhattan, Brooklyn, SI buses + subway)
//    • MTABC_      — MTA Bus Company (Queens, Bronx, Express buses)
//    • MTA BUS_    — MTA Bus (some SIRI/OBA edge cases)
//    • LIRR_       — Long Island Rail Road
//    • MNR_        — Metro-North Railroad
//    • MTA_        — Shared stop ID prefix (e.g. "MTA_308214")
//
//  If the MTA introduces a new agency prefix, add it here once
//  and every callsite across the app + widgets picks it up.
//

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
/// GTFS-RT feeds (e.g. `"MTA NYCT_L+"` → `"L"`).
func stripMTAAgencyPrefix(_ id: String) -> String {
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
func stripMTAStopPrefix(_ id: String) -> String {
    var result = id
    // Order matters: strip longest prefixes first
    for (prefix, _) in mtaAgencyPrefixes {
        result = result.replacingOccurrences(of: prefix, with: "")
    }
    return result
}
