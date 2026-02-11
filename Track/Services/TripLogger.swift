//
//  TripLogger.swift
//  Track
//
//  Records trip start/end data for building the delay prediction model.
//

import Foundation
import SwiftData

struct TripLogger {
    /// Starts a new trip log when the user begins a trip.
    ///
    /// - Parameters:
    ///   - context: The SwiftData model context
    ///   - routeID: Route identifier
    ///   - originStationID: Starting station ID
    ///   - destinationStationID: Destination station ID
    ///   - mtaPredictedTime: MTA's predicted arrival time
    ///   - weather: Current weather condition
    /// - Returns: The created TripLog
    @discardableResult
    static func startTrip(
        context: ModelContext,
        routeID: String,
        originStationID: String,
        destinationStationID: String,
        mtaPredictedTime: Date,
        weather: WeatherCondition
    ) -> TripLog {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)

        let log = TripLog(
            routeID: routeID,
            originStationID: originStationID,
            destinationStationID: destinationStationID,
            timeOfDay: hour,
            dayOfWeek: weekday,
            weatherCondition: weather,
            mtaPredictedTime: mtaPredictedTime,
            tripDate: now
        )

        context.insert(log)
        return log
    }

    /// Completes a trip log when the user arrives at the destination.
    ///
    /// - Parameters:
    ///   - tripLog: The TripLog to complete
    ///   - arrivalTime: The actual arrival time
    static func endTrip(tripLog: TripLog, arrivalTime: Date = Date()) {
        tripLog.actualArrivalTime = arrivalTime
        let delta = arrivalTime.timeIntervalSince(tripLog.mtaPredictedTime)
        tripLog.delaySeconds = Int(delta)
    }

    /// Fetches historic delays for matching conditions.
    ///
    /// - Parameters:
    ///   - context: The SwiftData model context
    ///   - routeID: Route identifier to match
    ///   - timeOfDay: Hour to match (±1 hour window)
    ///   - dayOfWeek: Day of week to match
    /// - Returns: Array of delay values in seconds
    static func fetchHistoricDelays(
        context: ModelContext,
        routeID: String,
        timeOfDay: Int,
        dayOfWeek: Int
    ) -> [Int] {
        let minHour = max(0, timeOfDay - 1)
        let maxHour = min(23, timeOfDay + 1)

        let predicate = #Predicate<TripLog> { log in
            log.routeID == routeID &&
            log.dayOfWeek == dayOfWeek &&
            log.timeOfDay >= minHour &&
            log.timeOfDay <= maxHour &&
            log.actualArrivalTime != nil
        }

        let descriptor = FetchDescriptor<TripLog>(predicate: predicate)

        do {
            let logs = try context.fetch(descriptor)
            return logs.map { $0.delaySeconds }
        } catch {
            return []
        }
    }
}
