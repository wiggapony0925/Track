//
//  DelayCalculator.swift
//  Track
//
//  Calculates "Real Feel" delay adjustments.
//  Prefers the server-side /predict/delay endpoint (which can be upgraded
//  to ML without an app update), falling back to a local heuristic when
//  the network is unavailable.
//

import Foundation

struct DelayPrediction {
    let adjustedMinutes: Int
    let originalMinutes: Int
    let adjustmentReason: String?
    let delayFactor: Double
}

struct DelayCalculator {

    /// Fetches a delay prediction from the backend, falling back to the
    /// local heuristic on network failure.
    static func predict(
        mtaMinutes: Int,
        routeID: String,
        timeOfDay: Int,
        dayOfWeek: Int,
        weather: WeatherCondition
    ) async -> DelayPrediction {
        // Try backend first
        do {
            let response = try await TrackAPI.fetchDelayPrediction(
                minutesAway: mtaMinutes,
                routeId: routeID,
                hour: timeOfDay,
                dayOfWeek: dayOfWeek,
                weather: weather.rawValue
            )
            return DelayPrediction(
                adjustedMinutes: response.adjustedMinutes,
                originalMinutes: response.originalMinutes,
                adjustmentReason: response.adjustmentReason,
                delayFactor: response.delayFactor
            )
        } catch {
            // Fall back to local heuristic
            return predictLocally(
                mtaMinutes: mtaMinutes,
                routeID: routeID,
                timeOfDay: timeOfDay,
                dayOfWeek: dayOfWeek,
                weather: weather
            )
        }
    }

    /// Local heuristic fallback (same logic that was originally the only path).
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
