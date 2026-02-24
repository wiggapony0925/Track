//
//  DelayCalculator.swift
//  Track
//
//  Calculates "Real Feel" delay adjustments using a local heuristic
//  based on time-of-day, day-of-week, and weather conditions.
//

import Foundation

struct DelayPrediction {
    let adjustedMinutes: Int
    let originalMinutes: Int
    let adjustmentReason: String?
    let delayFactor: Double
}

struct DelayCalculator {

    /// Local heuristic for delay prediction.
    static func predictLocally(
        mtaMinutes: Int,
        routeID: String,
        timeOfDay: Int,
        dayOfWeek: Int,
        weather: WeatherCondition
    ) -> DelayPrediction {
        var factor = 1.0
        var reasons: [String] = []

        // Rush hour adjustment (7-9 AM, 5-7 PM on weekdays)
        let isWeekday = dayOfWeek >= 2 && dayOfWeek <= 6
        let isMorningRush = timeOfDay >= 7 && timeOfDay <= 9
        let isEveningRush = timeOfDay >= 17 && timeOfDay <= 19
        if isWeekday && (isMorningRush || isEveningRush) {
            factor += 0.1
            reasons.append("rush hour")
        }

        // Weather adjustment
        switch weather {
        case .rain:
            factor += 0.1
            reasons.append("rain")
        case .snow:
            factor += 0.2
            reasons.append("snow")
        case .clear:
            break
        }

        let adjustedMinutes = Int(ceil(Double(mtaMinutes) * factor))
        let reason = reasons.isEmpty ? nil : "Adjusted for \(reasons.joined(separator: ", "))"

        return DelayPrediction(
            adjustedMinutes: adjustedMinutes,
            originalMinutes: mtaMinutes,
            adjustmentReason: reason,
            delayFactor: factor
        )
    }
}
