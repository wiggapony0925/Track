//
//  SmartSuggester.swift
//  Track
//
//  Widget-only subset of the SmartSuggester.
//  Contains only the suggestedRoute method needed by the widget's TimelineProvider.
//
//  NOTE: Shared copy — must stay in sync with Track/Services/SmartSuggester.swift

import Foundation
import SwiftData

struct RouteSuggestion {
    let routeID: String
    let direction: String
    let destinationName: String
    let score: Double
}

struct SmartSuggester {
    /// Returns the most likely route ID for the current time of day.
    /// Used by the Widget's TimelineProvider to show smart predictions.
    ///
    /// - Parameter context: SwiftData model context
    /// - Returns: The predicted route suggestion, or nil if no match
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
