// Shared timing helpers for tracking surfaces (app + widgets + live activity).
// Keeps countdown, progress, and "next arrivals" logic consistent everywhere.

import Foundation

enum TrackingTimeSync {
    nonisolated static func remainingSeconds(until arrivalTime: Date, now: Date = .now) -> Double {
        max(0, arrivalTime.timeIntervalSince(now))
    }

    nonisolated static func remainingMinutes(until arrivalTime: Date, now: Date = .now) -> Int {
        max(0, Int(ceil(remainingSeconds(until: arrivalTime, now: now) / 60)))
    }

    /// Progress in [0, 1], where 0 = far and 1 = arriving.
    /// Uses a 20-minute default window to match existing tracking UI semantics.
    nonisolated static func progress(
        until arrivalTime: Date,
        maxWindowMinutes: Double = 20,
        now: Date = .now
    ) -> Double {
        let maxSeconds = max(60, maxWindowMinutes * 60)
        let remaining = min(maxSeconds, remainingSeconds(until: arrivalTime, now: now))
        return max(0, min(1, 1 - (remaining / maxSeconds)))
    }

    nonisolated static func statusText(until arrivalTime: Date, now: Date = .now) -> String {
        let seconds = remainingSeconds(until: arrivalTime, now: now)
        if seconds <= 30 { return "Arriving" }
        let mins = max(1, Int(ceil(seconds / 60)))
        return "\(mins) min away"
    }

    nonisolated static func proximityText(minutesAway: Int) -> String {
        if minutesAway <= 0 { return "Arriving now" }
        if minutesAway <= 2 { return "Arriving shortly" }
        return "Waiting for next vehicle..."
    }

    /// Returns upcoming arrival minutes after a current tracked arrival.
    nonisolated static func nextArrivalMinutes(
        arrivalTimes: [Date],
        after currentArrival: Date,
        limit: Int = 2,
        now: Date = .now
    ) -> [Int] {
        arrivalTimes
            .filter { $0 > currentArrival }
            .sorted()
            .map { remainingMinutes(until: $0, now: now) }
            .prefix(limit)
            .map { $0 }
    }
}
enum LiveTrackingClock {
    static let vehiclePollIntervalSeconds: TimeInterval = 25

    static var vehiclePollSleepNanoseconds: UInt64 {
        UInt64(vehiclePollIntervalSeconds * 1_000_000_000)
    }
}
