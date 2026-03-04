//
//  TrackActivityAttributes.swift
//  Track
//
//  ActivityKit model defining the data for Live Activities.
//  Used by both the main app (to start/update activities) and
//  the widget extension (to render the Dynamic Island & Lock Screen).
//
//  ✅ SINGLE SOURCE OF TRUTH — lives in Shared/ so both the Track target
//  and the TrackWidgetsExtension target compile the same definition.
//  Do NOT duplicate this file in Track/Models/ or TrackWidgets/Shared/.

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

        /// Minutes away (0 = at station, nil = unknown).
        var minutesAway: Int?

        /// Minutes until the next 2–3 arrivals after the tracked one.
        var nextArrivals: [Int]

        /// Minutes remaining to walk to the station.
        var walkMinutes: Int?

        /// Whether the user needs to "Hurry up" to catch the trip.
        var isHurryUp: Bool

        /// Dynamic proximity label derived from minutes-away.
        /// e.g. "3 min away", "1 min away", "Arriving", "At station".
        var proximityText: String {
            if let walk = walkMinutes {
                return walk <= 2 ? "Run now!" : "Walk to station"
            }
            guard let minutes = minutesAway else { return statusText }
            return TrackingTimeSync.proximityText(minutesAway: minutes)
        }

        private enum CodingKeys: String, CodingKey {
            case statusText
            case arrivalTime
            case progress
            case minutesAway
            case stopsAway   // backward-compat: older payloads may encode minutes as "stopsAway"
            case nextArrivals
            case walkMinutes
            case isHurryUp
        }

        init(
            statusText: String,
            arrivalTime: Date,
            progress: Double,
            minutesAway: Int?,
            nextArrivals: [Int],
            walkMinutes: Int?,
            isHurryUp: Bool
        ) {
            self.statusText = statusText
            self.arrivalTime = arrivalTime
            self.progress = progress
            self.minutesAway = minutesAway
            self.nextArrivals = nextArrivals
            self.walkMinutes = walkMinutes
            self.isHurryUp = isHurryUp
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            statusText = try container.decode(String.self, forKey: .statusText)
            arrivalTime = try container.decode(Date.self, forKey: .arrivalTime)
            progress = try container.decode(Double.self, forKey: .progress)
            minutesAway = try container.decodeIfPresent(Int.self, forKey: .minutesAway)
                ?? container.decodeIfPresent(Int.self, forKey: .stopsAway)
            nextArrivals = try container.decode([Int].self, forKey: .nextArrivals)
            walkMinutes = try container.decodeIfPresent(Int.self, forKey: .walkMinutes)
            isHurryUp = try container.decode(Bool.self, forKey: .isHurryUp)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(statusText, forKey: .statusText)
            try container.encode(arrivalTime, forKey: .arrivalTime)
            try container.encode(progress, forKey: .progress)
            try container.encodeIfPresent(minutesAway, forKey: .minutesAway)
            try container.encode(nextArrivals, forKey: .nextArrivals)
            try container.encodeIfPresent(walkMinutes, forKey: .walkMinutes)
            try container.encode(isHurryUp, forKey: .isHurryUp)
        }
    }

    /// The transit line identifier (e.g. "L", "4", "B63").
    var lineId: String

    /// The destination name (e.g. "Manhattan", "Canarsie").
    var destination: String

    /// Whether this is a bus (true) or subway (false) trip.
    var isBus: Bool
}
