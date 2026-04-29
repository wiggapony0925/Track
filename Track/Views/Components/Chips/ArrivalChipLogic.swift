// Single source of truth for chip-level decisions.
//
// Pulled out of `ArrivalChipData` and `ArrivalChipView` so that
// the logic for "is this chip NOW", "is this chip live", and
// "should two chips be deduped" is written exactly once and can be
// unit-tested without touching SwiftUI.
//
// Add new chip behavior here, never inline in the view.

import Foundation

enum ArrivalChipLogic {

    // MARK: - NOW gating

    /// Window (in seconds) for treating a real-time arrival without
    /// GPS as "NOW".  Aligned with `RouteDetailSheet.nowThreshold`
    /// so the chip strip's "two NOW max" cap and the chip's own
    /// `isNow` agree.
    static let nowSecondsWindow: Double = 15

    /// Decide whether a chip should render "NOW".  Rules:
    ///   1. Never show NOW for cancelled, scheduled, or tracked-only
    ///      chips — those render in the grey bucket and a "NOW" word
    ///      next to a "Sched" tag is a contradiction.
    ///   2. Require a live map marker. Feed countdowns can hit zero early;
    ///      the user should only see NOW when there is something visible.
    ///   3. Require the ETA source to be `.vehiclePosition`, which means
    ///      the marker itself was checked against the tracked stop.
    ///   4. Require `isAtStop`, so nearby-but-not-arrived vehicles still
    ///      show a minute value instead of NOW.
    static func canShowNow(_ chip: ArrivalChipData) -> Bool {
        if chip.isCancelled || chip.isScheduled || chip.isTrackedOnly {
            return false
        }
        return chip.isRealTime
            && chip.hasMapMarker
            && chip.etaSource == .vehiclePosition
            && chip.isAtStop
    }

    // MARK: - Live / sched bucketing

    /// Classifies a chip into one of three visual buckets:
    ///   - `.live`      → colored card, has a real GPS marker
    ///   - `.tracked`   → grey card, real-time but no marker yet
    ///   - `.scheduled` → grey card, static GTFS only
    enum Kind { case live, tracked, scheduled }

    static func kind(for chip: ArrivalChipData) -> Kind {
        if chip.isScheduled { return .scheduled }
        if chip.isTrackedOnly || !chip.hasMapMarker { return .tracked }
        return .live
    }

    // MARK: - NOW strip cap

    /// Caps the number of "NOW" chips visible at once.  GTFS-RT
    /// occasionally publishes duplicate trip entries for the same
    /// physical train with slightly different trip IDs — without
    /// this cap, four ghost NOWs can render side by side.
    static let maxNowChipsVisible: Int = 1
}
