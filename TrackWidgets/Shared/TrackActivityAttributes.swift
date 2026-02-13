//
//  TrackActivityAttributes.swift
//  Track
//
//  ActivityKit model defining the data for Live Activities.
//  Used by both the main app (to start/update activities) and
//  the widget extension (to render the Dynamic Island & Lock Screen).
//
//  NOTE: This is a shared copy that must stay in sync with Track/Models/TrackActivityAttributes.swift

import Foundation
import ActivityKit

struct TrackActivityAttributes: ActivityAttributes {
    /// Dynamic state that updates over the lifetime of the Live Activity.
    public struct ContentState: Codable, Hashable {
        /// Human-readable status, e.g. "Arriving in 2 min" or "Approaching".
        var statusText: String

        /// The estimated arrival time (used for countdown rendering).
        /// When updated (sooner or later), the countdown adjusts automatically.
        var arrivalTime: Date

        /// Trip progress from 0.0 (just started) to 1.0 (arrived).
        var progress: Double

        /// Number of stops away (0 = at station, nil = unknown).
        var stopsAway: Int?

        /// Minutes until the next 2–3 arrivals after the tracked one.
        var nextArrivals: [Int]

        /// Dynamic proximity label derived from stopsAway.
        /// e.g. "3 stops away", "1 stop away", "Arriving", "At station".
        var proximityText: String {
            guard let stops = stopsAway else { return statusText }
            switch stops {
            case 0:  return "At station"
            case 1:  return "Arriving"
            default: return "\(stops) stops away"
            }
        }
    }

    /// The transit line identifier (e.g. "L", "4", "B63").
    var lineId: String

    /// The destination name (e.g. "Manhattan", "Canarsie").
    var destination: String

    /// Whether this is a bus (true) or subway (false) trip.
    var isBus: Bool
}
