// Model representing a single upcoming train arrival at a station.
// Used by TransitRepository and displayed in the subway dashboard.

import Foundation

/// Represents a single upcoming train arrival at a station.
struct TrainArrival: Identifiable, Equatable, Hashable {
    /// Deterministic identity so SwiftUI can diff arrivals across polls
    /// without destroying and recreating every row each time.
    let id: String
    let routeID: String
    let stationID: String
    let stationName: String
    let stopLat: Double?
    let stopLon: Double?
    let direction: String
    let scheduledTime: Date
    let estimatedTime: Date
    let minutesAway: Int
    let destination: String?
    let status: String
    let tripId: String?
    /// True when GTFS-RT reports this trip/stop as cancelled.
    var isCancelled: Bool = false

    /// Custom Equatable — compare by data fields so SwiftUI skips re-renders
    /// when only minutesAway (countdown) drifts but the train hasn't changed.
    static func == (lhs: TrainArrival, rhs: TrainArrival) -> Bool {
        lhs.routeID == rhs.routeID
            && lhs.stationID == rhs.stationID
            && lhs.direction == rhs.direction
            && lhs.scheduledTime == rhs.scheduledTime
            && lhs.tripId == rhs.tripId
            && lhs.isCancelled == rhs.isCancelled
    }

    /// Must be consistent with custom == above.
    func hash(into hasher: inout Hasher) {
        hasher.combine(routeID)
        hasher.combine(stationID)
        hasher.combine(direction)
        hasher.combine(scheduledTime)
        hasher.combine(tripId)
        hasher.combine(isCancelled)
    }
}
