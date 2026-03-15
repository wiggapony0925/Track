//
//  ArrivalHelpers.swift
//  Track
//
//  Single source of truth for arrival-related logic shared between
//  GroupedRouteRow (home screen) and RouteDetailSheet (route detail).
//  Keeps both views in perfect sync — same ETA, same direction label,
//  same nearest-stop selection, same sorting.
//

import CoreLocation
import Foundation

// MARK: - Shared Arrival Utilities

enum ArrivalHelpers {

    // MARK: - ETA Resolution

    /// Resolves the smart ETA for an arrival.
    /// Delegates to the shared `smartETAProvider` when available (uses live
    /// vehicle position + polyline), otherwise falls back to a static
    /// computation from `arrivalTs` / `minutesAway`.
    static func resolvedETA(
        for arrival: NearbyTransitResponse,
        provider: ((NearbyTransitResponse) -> SmartETA)? = nil
    ) -> SmartETA {
        if let provider { return provider(arrival) }
        return ArrivalETAEngine.computeETA(
            vehicleCoord: nil,
            vehicleKey: nil,
            stopCoord: nil,
            arrivalTs: arrival.arrivalTs,
            staticMinutes: arrival.minutesAway,
            mode: arrival.mode
        )
    }

    // MARK: - Sorting

    /// Sorts arrivals by smart ETA: live (isRealTime) first, then scheduled,
    /// each sub-group ordered by ascending seconds remaining.
    static func sortedByETA(
        _ arrivals: [NearbyTransitResponse],
        provider: ((NearbyTransitResponse) -> SmartETA)? = nil
    ) -> [NearbyTransitResponse] {
        guard arrivals.count > 1 else { return arrivals }
        // Pre-compute ETAs so sorting is O(N) ETA calls, not O(N log N).
        let etaMap = Dictionary(
            arrivals.map { ($0.id, resolvedETA(for: $0, provider: provider)) },
            uniquingKeysWith: { first, _ in first }
        )
        return arrivals.sorted { lhs, rhs in
            // Partition: live always before scheduled
            if lhs.isRealTime != rhs.isRealTime { return lhs.isRealTime }
            let left  = etaMap[lhs.id]?.secondsRemaining ?? .infinity
            let right = etaMap[rhs.id]?.secondsRemaining ?? .infinity
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Direction Label

    /// Resolves the best human-readable label for a direction.
    ///
    /// Priority (when shape data IS provided — detail sheet):
    ///  1. GTFS headsign from `shapeHeadsign`
    ///  2. Last stop name from `shapeLastStopName`
    ///  3. First live arrival's destination
    ///  4. First non-placeholder arrival's destination
    ///  5. Compass fallback
    ///
    /// Priority (when shape data is NOT provided — home row):
    ///  1. `directionLabel` from the backend
    ///  2. First live arrival's destination
    ///  3. First non-placeholder arrival's destination
    ///  4. Compass fallback
    ///
    /// Both the home row and the route detail sheet call this so labels
    /// never diverge.
    ///
    /// - Parameters:
    ///   - shapeHeadsign: GTFS headsign from `routeShape.matchedDirection()`.
    ///   - shapeLastStopName: Name of the last stop in the route shape's stop list.
    ///   - skipBackendLabel: When `true`, skip `directionLabel` from the backend.
    ///     The detail sheet sets this because subway `directionLabel` concatenates
    ///     ALL branch destinations ("Far Rockaway / Lefferts Blvd"), producing
    ///     overly long labels.
    ///   - useShortCompass: Use short compass labels ("↑ North") instead of full
    ///     ("Northbound") for the fallback.
    static func resolveDirectionLabel(
        for direction: DirectionArrivalsResponse,
        shapeHeadsign: String? = nil,
        shapeLastStopName: String? = nil,
        skipBackendLabel: Bool = false,
        useShortCompass: Bool = false
    ) -> String {
        // 1. GTFS headsign (most reliable when available)
        if let hs = shapeHeadsign, !hs.isEmpty {
            return cleanBusHeadsign(hs)
        }

        // 2. Last stop in route shape
        if let name = shapeLastStopName, !name.isEmpty {
            return cleanBusHeadsign(name)
        }

        // 3. Backend directionLabel (skipped by detail sheet for subway)
        //    Also skip when the label is a generic compass/fallback name
        //    ("Eastbound", "Southwest", etc.) — those don't tell the user
        //    where the bus actually goes.  We'll try arrival destinations
        //    or the raw direction string first.
        //    Handles both plain "Eastbound" and compound "Eastbound → Terminal".
        if !skipBackendLabel, let label = direction.directionLabel, !label.isEmpty {
            let cleaned = cleanBusHeadsign(label)
            let base = cleaned.components(separatedBy: " → ").first ?? cleaned
            if !DirectionConstants.isFallbackDirection(base) {
                return cleaned
            }
            // If it has a "→ destination" part, use just the destination
            let parts = cleaned.components(separatedBy: " → ")
            if parts.count >= 2, let dest = parts.last, !dest.isEmpty {
                return cleanBusHeadsign(dest)
            }
            // Pure compass label like "Eastbound" — skip to next fallback
        }

        // 4. First live arrival's destination
        if let dest = direction.liveArrivals.first?.destination, !dest.isEmpty {
            return dest
        }

        // 5. First non-placeholder arrival's destination
        if let dest = direction.arrivals.first(where: { arrival in
            guard !arrival.isPlaceholder, let d = arrival.destination, !d.isEmpty else { return false }
            return true
        })?.destination {
            return dest
        }

        // 6. Compass or raw-direction fallback
        //    If the raw direction is a descriptive name (not a compass code),
        //    title-case it for display.  Otherwise map compass codes to labels.
        let raw = direction.direction
        if DirectionConstants.isFallbackDirection(raw) {
            return useShortCompass
                ? shortDirectionLabel(raw)
                : directionLabel(raw)
        }
        // Descriptive direction name (e.g. "EAST SIDE YORK AV CROSSTOWN") → title case
        return raw.localizedCapitalized
    }

    // MARK: - Countdown Candidate

    /// Returns the soonest arrival for display in a countdown, preferring
    /// the user's nearest stop.
    ///
    /// Used by GroupedRouteRow and can be used by any view that needs
    /// a single "best" arrival for a direction.
    ///
    /// Resolution:
    ///  1. `liveArrivals` filtered by non-past ETA.
    ///  2. Falls back to ALL non-placeholder arrivals with valid future ETA
    ///     (covers scheduled-only directions that have `arrivalTs`).
    ///  3. Within candidates, finds nearest stop by distance, then returns
    ///     the soonest arrival at that stop.
    static func countdownArrival(
        for direction: DirectionArrivalsResponse,
        userLocation: CLLocation? = nil,
        provider: ((NearbyTransitResponse) -> SmartETA)? = nil
    ) -> NearbyTransitResponse? {
        // Build candidate list: live first, then scheduled fallback
        var candidates = direction.liveArrivals.filter {
            !resolvedETA(for: $0, provider: provider).isPastArrival
        }
        if candidates.isEmpty {
            candidates = direction.arrivals.filter { arrival in
                guard !arrival.isPlaceholder else { return false }
                let eta = resolvedETA(for: arrival, provider: provider)
                return !eta.isPastArrival && eta.minutesRemaining >= 0
            }
        }
        guard !candidates.isEmpty else { return nil }

        // Find nearest stop by distance
        if let loc = userLocation {
            var nearestStopKey: String?
            var nearestDistance: CLLocationDistance = .greatestFiniteMagnitude

            for arrival in candidates {
                let dist: CLLocationDistance
                if let dm = arrival.distanceM {
                    dist = dm
                } else if let lat = arrival.stopLat, let lon = arrival.stopLon {
                    dist = loc.distance(from: CLLocation(latitude: lat, longitude: lon))
                } else {
                    dist = .greatestFiniteMagnitude
                }
                if dist < nearestDistance {
                    nearestDistance = dist
                    nearestStopKey = arrival.stopId ?? arrival.stopName
                }
            }

            if let key = nearestStopKey {
                let atNearestStop = candidates.filter {
                    ($0.stopId ?? $0.stopName) == key
                }
                if let first = sortedByETA(atNearestStop, provider: provider).first {
                    return first
                }
            }
        }

        return sortedByETA(candidates, provider: provider).first
    }

    // MARK: - Soonest Scheduled Minutes

    /// Returns the soonest scheduled minutes for a direction when only
    /// placeholder/scheduled arrivals exist.
    /// Uses `resolvedETA` (from `arrivalTs`) instead of raw `minutesAway`
    /// to avoid stale-countdown "No Service" false positives.
    static func soonestScheduledMinutes(
        for direction: DirectionArrivalsResponse,
        provider: ((NearbyTransitResponse) -> SmartETA)? = nil
    ) -> Int? {
        direction.arrivals
            .filter { !$0.isPlaceholder }
            .compactMap { arrival -> Int? in
                let eta = resolvedETA(for: arrival, provider: provider)
                guard !eta.isPastArrival else { return nil }
                let mins = eta.minutesRemaining
                return mins >= 0 ? mins : nil
            }
            .min()
    }

    // MARK: - Bus Headsign Cleaning

    /// Cleans OBA / GTFS bus headsigns for display in direction pills.
    ///
    /// MTA bus headsigns carry scheduling cruft that's meaningless to riders:
    ///   "RUSH JFK AIRPORT via LEFFERTS BL via 130 ST"
    ///     → strips "RUSH " prefix (rush-hour/limited service designator)
    ///     → strips " via ..." suffixes (routing detail, not destination)
    ///     → smart title-cases while preserving transit acronyms
    ///   Result: "JFK Airport"
    ///
    /// Also handles:
    ///   "LTD …" (Limited service prefix)
    ///   ALL-CAPS OBA names → Title Case (with acronym preservation)
    static func cleanBusHeadsign(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return s }

        // Strip MTA scheduling prefixes (case-insensitive)
        let prefixes = ["RUSH ", "LTD ", "LIMITED "]
        for prefix in prefixes {
            if s.uppercased().hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
            }
        }

        // Strip " via ..." suffixes (keeps destination only)
        if let viaRange = s.range(of: " via ", options: .caseInsensitive) {
            s = String(s[s.startIndex..<viaRange.lowerBound])
        }

        // Also strip " VIA " (all caps variant)
        if let viaRange = s.range(of: " VIA ", options: .literal) {
            s = String(s[s.startIndex..<viaRange.lowerBound])
        }

        s = s.trimmingCharacters(in: .whitespaces)

        // Smart title-case if ALL-CAPS: preserves known transit acronyms
        // ("JFK", "SBS", "LIRR") while lowercasing normal words.
        if s == s.uppercased(), s.count > 2 {
            s = smartTitleCase(s)
        }

        return s
    }

    // MARK: - Smart Title Case

    /// Known transit / geographic acronyms that should stay uppercased
    /// when title-casing ALL-CAPS headsigns.
    private static let preservedAcronyms: Set<String> = [
        "JFK", "SBS", "LIRR", "MNR", "NJ", "NY", "NYC",
        "LGA", "EWR", "PABT", "GCT", "WTC", "MTA",
        "AV", "AVE", "BL", "BLVD", "ST", "PL", "DR",
        "RD", "CT", "HWY", "FWY", "PKWY", "TPK", "TPKE",
        "NW", "NE", "SW", "SE",
        "II", "III", "IV",
    ]

    /// Title-cases a string while preserving known acronyms.
    ///   "JFK AIRPORT" → "JFK Airport"
    ///   "WOODHAVEN BLVD" → "Woodhaven Blvd"
    private static func smartTitleCase(_ input: String) -> String {
        input.split(separator: " ").map { word in
            let upper = word.uppercased()
            if preservedAcronyms.contains(upper) {
                return upper
            }
            // Preserve numbers and number+suffix combos ("130", "130TH")
            if word.first?.isNumber == true {
                return String(word)
            }
            return word.capitalized
        }.joined(separator: " ")
    }
}
