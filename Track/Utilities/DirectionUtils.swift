// Single source of truth for compass-direction constants, labels,
// and matching helpers used throughout the app (HomeViewModel, API
// sync, route detail sheet, grouped rows, etc.).

import Foundation

// MARK: - Canonical Data

/// All compass / generic direction codes the backend may send.
/// Used by `isCompassDirection(_:)` and the filter in `filteredGroupedTransit`.
enum DirectionConstants {

    // MARK: Code → Long Label

    /// Compass code → human-readable label (matches backend `_DIRECTION_LABELS`).
    nonisolated static let labels: [String: String] = [
        "N": "Northbound",
        "S": "Southbound",
        "E": "Eastbound",
        "W": "Westbound",
        "NE": "Northeast",
        "NW": "Northwest",
        "SE": "Southeast",
        "SW": "Southwest",
        "INBOUND": "Inbound",
        "OUTBOUND": "Outbound",
    ]

    /// Short arrow-prefixed labels for compact UI (tab chips, badges).
    nonisolated static let shortLabels: [String: String] = [
        "N": "↑ North",
        "S": "↓ South",
        "E": "→ East",
        "W": "← West",
        "NE": "↗ NE",
        "NW": "↖ NW",
        "SE": "↘ SE",
        "SW": "↙ SW",
        "INBOUND": "↑ Inbound",
        "OUTBOUND": "↓ Outbound",
    ]

    // MARK: Compass Expansion (for GTFS-RT matching)

    /// Maps a single-char compass code to all uppercased aliases that
    /// should be treated as equivalent when matching vehicles to direction
    /// tabs.  Includes the code itself so callers can `formUnion` directly.
    ///
    /// Example: "N" → {"N", "NORTHBOUND", "UPTOWN"}
    static let compassExpansions: [String: Set<String>] = [
        "N":  ["N", "NORTHBOUND", "UPTOWN"],
        "S":  ["S", "SOUTHBOUND", "DOWNTOWN"],
        "E":  ["E", "EASTBOUND"],
        "W":  ["W", "WESTBOUND"],
        "NE": ["NE", "NORTHBOUND", "EASTBOUND"],
        "NW": ["NW", "NORTHBOUND", "WESTBOUND"],
        "SE": ["SE", "SOUTHBOUND", "EASTBOUND"],
        "SW": ["SW", "SOUTHBOUND", "WESTBOUND"],
    ]

    /// Reverse lookup: long label → single-char compass code.
    static let reverseCompass: [String: String] = [
        "NORTHBOUND": "N", "UPTOWN": "N",
        "SOUTHBOUND": "S", "DOWNTOWN": "S",
        "EASTBOUND": "E", "WESTBOUND": "W",
    ]

    // MARK: Fallback Detection

    /// The full set of uppercased direction strings that are considered
    /// compass/generic fallbacks (not real destination names).
    /// Includes codes, long forms, numeric placeholders, and special keys.
    ///
    /// NOTE: "INBOUND" and "OUTBOUND" are intentionally EXCLUDED.
    /// Many MTA bus routes (e.g. Q80, Q37) use "Outbound" as their
    /// primary reverse-direction label — it IS a real direction, not
    /// a placeholder.  Treating it as fallback caused those directions
    /// to vanish from the home row swipe tabs.
    static let fallbackDirectionStrings: Set<String> = {
        var s = Set<String>()
        // Compass codes + their long labels (excluding Inbound/Outbound)
        for (code, label) in labels {
            let upper = code.uppercased()
            // Skip INBOUND/OUTBOUND — they are real MTA bus direction names
            if upper == "INBOUND" || upper == "OUTBOUND" { continue }
            s.insert(upper)
            s.insert(label.uppercased())
        }
        // Generic / numeric / special
        s.formUnion([
            "DIRECTION A", "DIRECTION B", "DIRECTION C", "DIRECTION D",
            "ALL DIRECTIONS", "LOOP", "OPPOSITE DIRECTION",
            "N/A", "0", "1", "2", "3",
        ])
        return s
    }()

    /// Returns `true` when the direction string is a compass code, a long
    /// compass label, or any other generic fallback — NOT a real destination.
    static func isFallbackDirection(_ direction: String) -> Bool {
        fallbackDirectionStrings.contains(direction.uppercased())
    }
}

// MARK: - Free Functions (backward-compatible API)

/// Converts a raw direction code (e.g. "N", "S", "SW") to a full human-readable label.
///
/// - Parameter direction: Raw direction string from the backend.
/// - Returns: e.g. "Northbound", "Southbound", or the original string if not a compass code.
nonisolated func directionLabel(_ direction: String) -> String {
    DirectionConstants.labels[direction.uppercased()] ?? direction
}

/// Converts a raw direction code to a short arrow-prefixed label.
///
/// - Parameter direction: Raw direction string from the backend.
/// - Returns: e.g. "↑ North", "↓ South", or the original string.
nonisolated func shortDirectionLabel(_ direction: String) -> String {
    DirectionConstants.shortLabels[direction.uppercased()] ?? direction
}
