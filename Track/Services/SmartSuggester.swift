//
//  SmartSuggester.swift
//  Track
//
//  Predicts the user's likely destination using a Frequency-Recency Heuristic.
//  Aggregates current context (location, time) to produce route suggestions.
//

import Foundation
import SwiftData
import CoreLocation

struct RouteSuggestion {
    let routeID: String
    let direction: String
    let destinationName: String
    let score: Double
}

struct SmartSuggester {
    /// Predicts the most likely route for the user based on commute patterns.
    ///
    /// Algorithm:
    /// 1. Fetch all CommutePattern logs from SwiftData
    /// 2. Filter where startLocation is within the configured match radius of current location
    /// 3. Filter where timeOfDay is within ±1 hour of current time
    /// 4. Rank by frequency (higher = more likely)
    ///
    /// - Parameters:
    ///   - context: SwiftData model context
    ///   - currentLocation: User's current GPS location
    ///   - currentTime: Current date/time
    /// - Returns: The top-ranked RouteSuggestion, or nil if no match
    static func predict(
        context: ModelContext,
        currentLocation: CLLocation?,
        currentTime: Date = Date()
    ) -> RouteSuggestion? {
        let calendar = Calendar.current
        let currentHour = calendar.component(.hour, from: currentTime)
        let minHour = max(0, currentHour - 1)
        let maxHour = min(23, currentHour + 1)

        let predicate = #Predicate<CommutePattern> { pattern in
            pattern.timeOfDay >= minHour && pattern.timeOfDay <= maxHour
        }

        let descriptor = FetchDescriptor<CommutePattern>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.frequency, order: .reverse)]
        )

        do {
            let patterns = try context.fetch(descriptor)

            // Filter by proximity (200m radius) if location available
            let filtered: [CommutePattern]
            if let location = currentLocation {
                let matchRadius = AppSettings.shared.commutePatternMatchRadiusMeters
                filtered = patterns.filter { pattern in
                    let patternLocation = CLLocation(
                        latitude: pattern.startLatitude,
                        longitude: pattern.startLongitude
                    )
                    return location.distance(from: patternLocation) <= matchRadius
                }
            } else {
                filtered = patterns
            }

            guard let top = filtered.first else { return nil }

            return RouteSuggestion(
                routeID: top.routeID,
                direction: top.direction,
                destinationName: top.destinationName,
                score: Double(top.frequency)
            )
        } catch {
            return nil
        }
    }

    /// Records a commute pattern when the user starts a trip.
    static func recordPattern(
        context: ModelContext,
        routeID: String,
        direction: String,
        startLocation: CLLocation,
        destinationStationID: String,
        destinationName: String
    ) {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)

        // Check for existing matching pattern
        let lat = startLocation.coordinate.latitude
        let lon = startLocation.coordinate.longitude

        let predicate = #Predicate<CommutePattern> { pattern in
            pattern.routeID == routeID &&
            pattern.direction == direction &&
            pattern.destinationStationID == destinationStationID
        }

        let descriptor = FetchDescriptor<CommutePattern>(predicate: predicate)

        do {
            let existing = try context.fetch(descriptor)

            // Find one within the configured match radius
            let matchRadius = AppSettings.shared.commutePatternMatchRadiusMeters
            let match = existing.first { pattern in
                let patternLoc = CLLocation(
                    latitude: pattern.startLatitude,
                    longitude: pattern.startLongitude
                )
                return startLocation.distance(from: patternLoc) <= matchRadius
            }

            if let match = match {
                match.frequency += 1
                match.lastUsed = now
            } else {
                let newPattern = CommutePattern(
                    routeID: routeID,
                    direction: direction,
                    startLatitude: lat,
                    startLongitude: lon,
                    destinationStationID: destinationStationID,
                    destinationName: destinationName,
                    timeOfDay: hour,
                    dayOfWeek: weekday
                )
                context.insert(newPattern)
            }
        } catch {
            // Insert new if query fails
            let newPattern = CommutePattern(
                routeID: routeID,
                direction: direction,
                startLatitude: lat,
                startLongitude: lon,
                destinationStationID: destinationStationID,
                destinationName: destinationName,
                timeOfDay: hour,
                dayOfWeek: weekday
            )
            context.insert(newPattern)
        }
    }

    // MARK: - Widget Suggestion

    /// Returns the most likely route ID for the current time of day.
    /// Used by the Widget's TimelineProvider to show smart predictions.
    ///
    /// Algorithm:
    /// 1. Get current hour and weekday.
    /// 2. Query CommutePattern within ±1 hour of now.
    /// 3. Return the routeID with the highest frequency.
    /// 4. Fallback: Returns nil if no history exists.
    ///
    /// - Parameter context: SwiftData model context
    /// - Returns: The predicted route ID, or nil if no match
    static func suggestedRoute(context: ModelContext) -> RouteSuggestion? {
        let calendar = Calendar.current
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)
        let minHour = max(0, currentHour - 1)
        let maxHour = min(23, currentHour + 1)

        let predicate = #Predicate<CommutePattern> { pattern in
            pattern.timeOfDay >= minHour && pattern.timeOfDay <= maxHour
        }

        let descriptor = FetchDescriptor<CommutePattern>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.frequency, order: .reverse)]
        )

        do {
            let patterns = try context.fetch(descriptor)
            guard let top = patterns.first else { return nil }

            return RouteSuggestion(
                routeID: top.routeID,
                direction: top.direction,
                destinationName: top.destinationName,
                score: Double(top.frequency)
            )
        } catch {
            return nil
        }
    }
}
