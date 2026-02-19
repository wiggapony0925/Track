//
//  ScheduledItem.swift
//  Track
//
//  A unified scheduled departure model that works across all transit modes
//  (bus, subway, LIRR, Metro-North). Used to display greyed-out scheduled
//  times when no live vehicles are on route yet.
//

import Foundation

struct ScheduledItem: Identifiable {
    let id: String
    let minutesAway: Int
    let departureDate: Date
    let stopName: String
    let headsign: String

    /// Formatted departure time (e.g. "9:15 AM")
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: departureDate)
    }

    // MARK: - Factory: from BusScheduledDeparture

    static func from(_ departure: BusScheduledDeparture) -> ScheduledItem {
        ScheduledItem(
            id: departure.id,
            minutesAway: departure.minutesAway,
            departureDate: departure.departureDate,
            stopName: departure.stopName,
            headsign: departure.headsign
        )
    }

    // MARK: - Factory: from TrainArrival

    static func from(_ arrival: TrainArrival) -> ScheduledItem {
        ScheduledItem(
            id: arrival.tripId ?? "\(arrival.routeID)_\(arrival.estimatedTime.timeIntervalSince1970)",
            minutesAway: max(0, Int(arrival.estimatedTime.timeIntervalSinceNow / 60)),
            departureDate: arrival.estimatedTime,
            stopName: arrival.stationName,
            headsign: arrival.destination ?? arrival.direction
        )
    }
}
