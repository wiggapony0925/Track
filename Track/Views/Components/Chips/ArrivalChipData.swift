// Pure data model for an arrival chip — the value bag rendered by
// `ArrivalChipView`.  Lives separately from the view so:
//   1. The logic can be unit-tested without SwiftUI.
//   2. Widgets and Live Activities can construct chip data without
//      pulling in the full chip view stack.
//   3. The view file stays focused on layout.
//
// All chip behavior (dedup, NOW gating, marker requirement) is
// concentrated in `ArrivalChipLogic.swift` so there is exactly one
// source of truth for those decisions.

import Foundation

struct ArrivalChipData: Identifiable, Equatable {
    let id: String
    let minutesRemaining: Int
    let secondsRemaining: Double
    /// True when ArrivalETAEngine confirms the vehicle's GPS is within
    /// 50 m of the stop — strongest possible "the bus is here" signal.
    let isAtStop: Bool
    /// True when the arrival is backed by a real-time feed (GTFS-RT
    /// or SIRI) rather than purely static GTFS schedule.
    let isRealTime: Bool
    let isCancelled: Bool
    /// True when this arrival has no real-time data at all and is
    /// shown purely from the static GTFS schedule.
    let isScheduled: Bool
    /// True when the backend reports a tracked trip but no GPS
    /// position is available yet (SIRI without position, or feed
    /// latency).  Distinct from `isScheduled` — the trip IS active,
    /// we just don't know where it is on a map.
    var isTrackedOnly: Bool = false
    /// True when a corresponding map marker exists for this arrival.
    /// Required for `isNow` to return true with `vehicleId` present —
    /// guards against "NOW with no bus" rendering.
    var hasMapMarker: Bool = false
    let arrivalTimestamp: Int?
    let vehicleId: String?
    let tripId: String?
    /// Raw route ID from the arrival (e.g. "7X", "6X") — used to
    /// detect express service via legacy heuristic.
    var routeId: String? = nil
    /// Server-provided express flag — true for subway express routes
    /// (A, B, D, E, 2-5, N, Q, Z, 6X, 7X, FX) and SBS / express /
    /// limited buses.  Falls back to client-side detection for
    /// backward compat.
    var isExpressFromServer: Bool = false
    /// Typed service variant for pill rendering.  When `.showsPill`
    /// is true the chip renders the `ServiceVariantPill` and
    /// suppresses the legacy "Exp" diamond.
    var serviceVariant: ServiceVariant = .unknown
    /// Optional override label for the variant pill (e.g.
    /// "Super Exp via Madison Av").
    var variantLabel: String? = nil
    /// Stop the arrival is predicted at — used by chip taps to
    /// scroll the parent's Stops list to the matching row.
    var stopId: String? = nil
    /// Mode tag (`"bus"`, `"subway"`, `"lirr"`, `"mnr"`).  Bus chips
    /// surface their `vehicleId` as a tertiary label since bus
    /// vehicle IDs are visible to riders on the front of the bus
    /// (route 1234, etc.); train IDs are not.
    var mode: String = "subway"

    // MARK: - Legacy express fallback (kept for backward compat)

    /// Express subway variants end in "X" (6X, 7X, FX).
    private static let expressVariants: Set<String> = ["6X", "7X", "FX"]

    /// True when this arrival should render the express indicator,
    /// honoring the server flag first and falling back to a route-id
    /// heuristic for old backends.  Suppressed when a richer
    /// `serviceVariant.showsPill` will render instead.
    var isExpress: Bool {
        if isExpressFromServer { return true }
        guard let rid = routeId?.uppercased() else { return false }
        return Self.expressVariants.contains(rid)
    }

    /// Convenience: departure date derived from timestamp or projected.
    var departureDate: Date {
        if let ts = arrivalTimestamp {
            return Date(timeIntervalSince1970: Double(ts))
        }
        return Date().addingTimeInterval(Double(minutesRemaining) * 60)
    }

    /// Bus-only display ID surfaced as a tertiary chip label.
    /// Returns the trailing 4 digits of the vehicle ID (matches the
    /// number painted on the bus exterior) or `nil` when not a bus
    /// or no vehicle ID is known.
    var busDisplayId: String? {
        guard mode == "bus", let vid = vehicleId, !vid.isEmpty else { return nil }
        // GTFS bus vehicleIds are typically "MTA NYCT_1234" or "1234".
        // Strip non-digits and keep the trailing 4 chars to match the
        // physical bus number riders see.
        let digits = vid.filter { $0.isNumber }
        if digits.isEmpty { return vid }
        return String(digits.suffix(4))
    }

    /// Show "NOW" only when the vehicle is genuinely about to be at
    /// (or already at) the stop AND there is a corresponding marker
    /// the user can see.  Past behavior allowed "NOW" to render on
    /// chips that had no map marker — producing the "NOW NOW twice"
    /// bug where two grey/tracked chips both showed NOW with no bus
    /// visible on the map.  See `ArrivalChipLogic.canShowNow` for
    /// the canonical decision.
    var isNow: Bool {
        ArrivalChipLogic.canShowNow(self)
    }
}
