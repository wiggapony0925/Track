// Static lookup tables for LIRR branch names and Metro-North line names.
// Maps numeric route IDs to human-readable display names.

import Foundation

// MARK: - Branch Name Lookup

/// Maps a LIRR/MNR route_id (e.g. "LIRR_9") to a human-readable branch name
/// (e.g. "Port Washington Branch"). Falls back to stripMTAPrefix for subway/bus.
enum BranchNames {

    /// LIRR numeric route ID → human-readable branch name
    static let lirr: [String: String] = [
        "1": "Babylon Branch",
        "2": "Hempstead Branch",
        "3": "Oyster Bay Branch",
        "4": "Ronkonkoma Branch",
        "5": "Montauk Branch",
        "6": "Long Beach Branch",
        "7": "Far Rockaway Branch",
        "8": "West Hempstead Branch",
        "9": "Port Washington Branch",
        "10": "Port Jefferson Branch",
        "11": "Belmont Park",
        "12": "City Terminal Zone",
        "13": "Greenport Service",
    ]

    /// Metro-North numeric route ID → human-readable line name
    static let mnr: [String: String] = [
        "1": "Hudson Line",
        "2": "Harlem Line",
        "3": "New Haven Line",
        "4": "New Canaan Line",
        "5": "Danbury Line",
        "6": "Waterbury Line",
    ]

    /// Resolves a route ID to a user-facing display name.
    /// For LIRR/MNR, maps numeric IDs to branch/line names.
    /// For subway/bus, strips the MTA prefix via `stripMTAPrefix()` from FormatUtils.swift.
    nonisolated static func resolveDisplayName(routeId: String, mode: String) -> String {
        if mode == "lirr" {
            let numeric = normalizeMTARouteToken(routeId)
            return lirr[numeric] ?? stripMTAPrefix(routeId)
        }
        if mode == "mnr" {
            let numeric = normalizeMTARouteToken(routeId)
            return mnr[numeric] ?? stripMTAPrefix(routeId)
        }
        return stripMTAPrefix(routeId)
    }
}
