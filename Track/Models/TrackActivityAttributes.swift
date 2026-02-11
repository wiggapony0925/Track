//
//  TrackActivityAttributes.swift
//  Track
//
//  ActivityKit model defining the data for Live Activities.
//  Used by both the main app (to start/update activities) and
//  the widget extension (to render the Dynamic Island & Lock Screen).
//

import Foundation
import ActivityKit

struct TrackActivityAttributes: ActivityAttributes {
    /// Dynamic state that updates over the lifetime of the Live Activity.
    public struct ContentState: Codable, Hashable {
        /// Human-readable status, e.g. "Arriving in 2 min" or "Approaching".
        var statusText: String

        /// The estimated arrival time (used for countdown rendering).
        var arrivalTime: Date

        /// Trip progress from 0.0 (just started) to 1.0 (arrived).
        var progress: Double
    }

    /// The transit line identifier (e.g. "L", "4", "B63").
    var lineId: String

    /// The destination name (e.g. "Manhattan", "Canarsie").
    var destination: String

    /// Whether this is a bus (true) or subway (false) trip.
    var isBus: Bool
}
