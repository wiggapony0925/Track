// LocationContext.swift
// Single source of truth for *which* coordinate the app should treat as
// the user's "current" location at any moment.
//
// The app has two competing inputs:
//   1.  GPS — the device's actual location (`LocationManager.currentLocation`).
//   2.  Dropped pin — when the user drags the Home map and confirms a
//       "search here" pin, they're effectively telling the app "pretend
//       I'm standing at this spot".
//
// Before this type, every feature (Home dashboard, Chat bias, Plan origin,
// MetroMind backend payload) had to re-derive that decision on its own.
// That meant Chat would say "Bias to: dropped pin" while the Plan tab
// quietly used GPS, or MetroMind would phrase answers as if the user were
// at their real GPS spot even when a pin was active.
//
// `LocationContext` centralises the resolution so every consumer agrees
// on:
//   • what coordinate to use,
//   • which source produced it (so UI can show a badge),
//   • a short human-readable label for prompts / chips.

import CoreLocation
import Foundation
import Observation

/// Where the *effective* coordinate came from.
enum LocationSource: String, Sendable {
    case gps
    case droppedPin = "map_pin"

    /// Short human label suitable for UI chips and LLM prompts.
    var displayLabel: String {
        switch self {
        case .gps: return "current location"
        case .droppedPin: return "dropped pin"
        }
    }

    /// SF Symbol used in chips/badges.
    var symbolName: String {
        switch self {
        case .gps: return "location.fill"
        case .droppedPin: return "mappin.circle.fill"
        }
    }
}

@Observable
@MainActor
final class LocationContext {

    // MARK: - Inputs (set by views as inputs change)

    /// The latest GPS coordinate from `LocationManager`.  Nil if location
    /// services are denied or no fix yet.
    private(set) var gpsCoordinate: CLLocationCoordinate2D?

    /// The user's settled drag-search pin, if any.  When non-nil this
    /// *overrides* the GPS coordinate as the effective location.
    private(set) var droppedPin: CLLocationCoordinate2D?

    // MARK: - Resolved outputs (read by features)

    /// Which input is currently driving the effective coordinate.
    var source: LocationSource {
        droppedPin != nil ? .droppedPin : .gps
    }

    /// `true` when the user has explicitly dropped a search pin and it
    /// is overriding GPS.  Useful for showing badges or branching logic.
    var isUsingDroppedPin: Bool { droppedPin != nil }

    /// The coordinate every feature should treat as the user's location.
    /// Returns `nil` only if there's neither a pin *nor* a GPS fix.
    var effectiveCoordinate: CLLocationCoordinate2D? {
        droppedPin ?? gpsCoordinate
    }

    /// Convenience wrapper.
    var effectiveLocation: CLLocation? {
        guard let c = effectiveCoordinate else { return nil }
        return CLLocation(latitude: c.latitude, longitude: c.longitude)
    }

    /// Short label describing the active source — used in chat chips,
    /// MetroMind payloads, and origin pickers.
    var displayLabel: String { source.displayLabel }

    // MARK: - Mutators

    func setGPSCoordinate(_ coordinate: CLLocationCoordinate2D?) {
        // Avoid pointless invalidations when nothing meaningfully changed.
        if let new = coordinate, let cur = gpsCoordinate {
            // ~5 m threshold so tiny GPS jitter doesn't churn observers.
            let dLat = abs(new.latitude - cur.latitude)
            let dLon = abs(new.longitude - cur.longitude)
            if dLat < 0.00005 && dLon < 0.00005 { return }
        } else if coordinate == nil && gpsCoordinate == nil {
            return
        }
        gpsCoordinate = coordinate
    }

    func setDroppedPin(_ coordinate: CLLocationCoordinate2D?) {
        if coordinate == nil && droppedPin == nil { return }
        if let new = coordinate, let cur = droppedPin,
           new.latitude == cur.latitude, new.longitude == cur.longitude {
            return
        }
        droppedPin = coordinate
    }

    func clearDroppedPin() {
        guard droppedPin != nil else { return }
        droppedPin = nil
    }
}
