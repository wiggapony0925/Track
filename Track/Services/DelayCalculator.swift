//
//  DelayCalculator.swift
//  Track
//
//  Calculates "Real Feel" delay adjustments based on historical trip data.
//  Uses a simple multiplier heuristic as a placeholder for a Core ML model.
//

import Foundation

struct DelayPrediction {
    let adjustedMinutes: Int
    let originalMinutes: Int
    let adjustmentReason: String?
    let delayFactor: Double
}

struct DelayCalculator {
    /// Calculates an adjusted arrival time based on historical delay patterns.
    ///
    /// - Parameters:
    ///   - mtaMinutes: MTA-predicted minutes until arrival
    ///   - routeID: The transit route identifier
    ///   - timeOfDay: Current hour (0-23)
    ///   - dayOfWeek: Day of week (1-7, Sunday=1)
    ///   - weather: Current weather condition
    ///   - historicDelays: Array of past delay values in seconds for matching conditions
    /// - Returns: A DelayPrediction with the adjusted time
    static func predict(
        mtaMinutes: Int,
        routeID: String,
        timeOfDay: Int,
        dayOfWeek: Int,
        weather: WeatherCondition,
        historicDelays: [Int]
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

        // Historic delay factor from logged data
        if !historicDelays.isEmpty {
            let averageDelay = Double(historicDelays.reduce(0, +)) / Double(historicDelays.count)
            let mtaSeconds = Double(mtaMinutes * 60)
            if mtaSeconds > 0 {
                let historicFactor = (mtaSeconds + averageDelay) / mtaSeconds
                // Blend historic factor with heuristic
                factor = (factor + historicFactor) / 2.0
            }
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
