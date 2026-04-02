// Response model for the /predict/delay backend endpoint.
// Maps the server's snake_case JSON to Swift camelCase properties.

import Foundation

/// Delay-adjusted arrival prediction returned by the ML backend.
struct DelayPrediction: Codable, Sendable {
    /// Minutes until arrival after applying the delay factor.
    let adjustedMinutes: Int
    /// Original MTA-predicted minutes (before adjustment).
    let originalMinutes: Int
    /// Multiplicative factor applied (1.0 = no change, 1.2 = 20% slower).
    let delayFactor: Double
    /// Human-readable explanation, e.g. "Adjusted for rain (+1m)".
    let adjustmentReason: String?
    /// Source of the prediction: "model", "heuristic", "l1_hit", "disabled", etc.
    let modelSource: String
    /// Signed correction from the recency model in seconds (+ = late).
    let recencyErrorSeconds: Double

    enum CodingKeys: String, CodingKey {
        case adjustedMinutes = "adjusted_minutes"
        case originalMinutes = "original_minutes"
        case delayFactor = "delay_factor"
        case adjustmentReason = "adjustment_reason"
        case modelSource = "model_source"
        case recencyErrorSeconds = "recency_error_seconds"
    }
}
