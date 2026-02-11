//
//  CommutePattern.swift
//  Track
//
//  SwiftData model tracking user commute patterns for the Smart Suggester.
//

import Foundation
import SwiftData

@Model
final class CommutePattern {
    var routeID: String
    var direction: String
    var startLatitude: Double
    var startLongitude: Double
    var destinationStationID: String
    var destinationName: String
    var timeOfDay: Int         // Hour 0-23
    var dayOfWeek: Int         // 1 (Sunday) - 7 (Saturday)
    var frequency: Int         // Number of times this pattern has been observed
    var lastUsed: Date

    init(
        routeID: String,
        direction: String,
        startLatitude: Double,
        startLongitude: Double,
        destinationStationID: String,
        destinationName: String,
        timeOfDay: Int,
        dayOfWeek: Int,
        frequency: Int = 1,
        lastUsed: Date = Date()
    ) {
        self.routeID = routeID
        self.direction = direction
        self.startLatitude = startLatitude
        self.startLongitude = startLongitude
        self.destinationStationID = destinationStationID
        self.destinationName = destinationName
        self.timeOfDay = timeOfDay
        self.dayOfWeek = dayOfWeek
        self.frequency = frequency
        self.lastUsed = lastUsed
    }
}
