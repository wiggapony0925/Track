// Model representing a suggested route based on commute patterns.
// Used by SmartSuggester for predictions and SmartSuggestionCard for display.

import Foundation

/// Represents a suggested transit route based on user commute patterns.
struct RouteSuggestion {
    let routeID: String
    let direction: String
    let destinationName: String
    let score: Double
}
