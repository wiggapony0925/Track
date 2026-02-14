//
//  TripLog.swift
//  Shared
//
//  SwiftData model for logging trip data used by the Delay Predictor.
//  Captures the delta between MTA-predicted and actual arrival times.
//

import Foundation
import SwiftData

@Model
final class TripLog {
    var routeID: String
    var originStationID: String
    var destinationStationID: String
    var timeOfDay: Int         // Hour 0-23
    var dayOfWeek: Int         // 1 (Sunday) - 7 (Saturday)
    var weatherCondition: String // WeatherCondition raw value
    var mtaPredictedTime: Date
    var actualArrivalTime: Date?
    var delaySeconds: Int      // Actual - Predicted in seconds
    var tripDate: Date

    init(
        routeID: String,
        originStationID: String,
        destinationStationID: String,
        timeOfDay: Int,
        dayOfWeek: Int,
        weatherCondition: WeatherCondition,
        mtaPredictedTime: Date,
        actualArrivalTime: Date? = nil,
        delaySeconds: Int = 0,
        tripDate: Date = Date()
    ) {
        self.routeID = routeID
        self.originStationID = originStationID
        self.destinationStationID = destinationStationID
        self.timeOfDay = timeOfDay
        self.dayOfWeek = dayOfWeek
        self.weatherCondition = weatherCondition.rawValue
        self.mtaPredictedTime = mtaPredictedTime
        self.actualArrivalTime = actualArrivalTime
        self.delaySeconds = delaySeconds
        self.tripDate = tripDate
    }
}
