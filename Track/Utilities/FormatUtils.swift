//
//  FormatUtils.swift
//  Track
//
//  Shared formatting utilities used across multiple views and components.
//  Consolidates duplicated formatting logic for arrival times, distances,
//  route names, and transit status colors.
//

import SwiftUI

// MARK: - Arrival Time Formatting

/// Shared DateFormatter for arrival time display (e.g. "3:45 PM").
/// Created once and reused to avoid the cost of repeated allocation.
private let arrivalTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f
}()

/// Formats an arrival time from minutes away into a human-readable string.
///
/// - Parameter minutesAway: Minutes until the arrival.
/// - Returns: e.g. "Arriving now", "In 1 minute", "In 5 min — 3:45 PM"
func formatArrivalTime(minutesAway: Int) -> String {
    if minutesAway <= 0 {
        return "Arriving now"
    } else if minutesAway == 1 {
        let time = Date().addingTimeInterval(60)
        return "In 1 minute — \(arrivalTimeFormatter.string(from: time))"
    } else {
        let time = Date().addingTimeInterval(Double(minutesAway) * 60)
        return "In \(minutesAway) min — \(arrivalTimeFormatter.string(from: time))"
    }
}

/// Formats an arrival time from a specific `Date` into a human-readable string.
///
/// - Parameter date: The expected arrival time (optional).
/// - Parameter fallback: Fallback text when the date is nil.
/// - Returns: e.g. "Arriving now", "In 5 min — 3:45 PM"
func formatArrivalTime(date: Date?, fallback: String = "—") -> String {
    guard let date = date else { return fallback }
    let minutes = Int(date.timeIntervalSinceNow / 60)
    if minutes <= 0 {
        return "Arriving now"
    }
    return "In \(minutes) min — \(arrivalTimeFormatter.string(from: date))"
}

// MARK: - Distance Formatting

/// Formats a distance in meters into a human-readable string.
///
/// - Parameters:
///   - meters: Distance in meters.
///   - suffix: Optional suffix appended after the value (e.g. "away"). Defaults to "away".
/// - Returns: e.g. "250m away", "1.2km away", "250m", "1.2km"
func formatDistance(_ meters: Double, suffix: String = "away") -> String {
    let value: String
    if meters < 1000 {
        value = "\(Int(meters))m"
    } else {
        value = String(format: "%.1fkm", meters / 1000)
    }
    return suffix.isEmpty ? value : "\(value) \(suffix)"
}

// MARK: - MTA Route Name

/// Strips the "MTA NYCT_" prefix from MTA route IDs for display.
///
/// - Parameter routeId: Full route identifier (e.g. "MTA NYCT_B63").
/// - Returns: Display name (e.g. "B63").
func stripMTAPrefix(_ routeId: String) -> String {
    if routeId.hasPrefix("MTA NYCT_") {
        return String(routeId.dropFirst(9)).replacingOccurrences(of: "+", with: "")
    }
    return routeId.replacingOccurrences(of: "+", with: "")
}

// MARK: - Transit Status Color

/// Returns the appropriate color for a transit status string.
///
/// - Parameter status: Status text (e.g. "On Time", "Approaching", "Delayed").
/// - Returns: A themed color reflecting the status severity.
func transitStatusColor(for status: String) -> Color {
    let lower = status.lowercased()
    if lower.contains("on time") || lower.contains("approaching") || lower.contains("at stop") {
        return AppTheme.Colors.successGreen
    } else if lower.contains("delayed") || lower.contains("late") {
        return AppTheme.Colors.alertRed
    } else if lower.contains("1 stop") {
        return AppTheme.Colors.warningYellow
    }
    return AppTheme.Colors.mtaBlue
}

/// Returns a short status label and color for a given minutes-away value.
///
/// - Parameter minutesAway: Minutes until arrival.
/// - Returns: A tuple of (label, color).
func arrivalStatusPill(minutesAway: Int) -> (label: String, color: Color) {
    if minutesAway <= 0 {
        return ("Now", AppTheme.Colors.alertRed)
    } else if minutesAway <= 2 {
        return ("Approaching", AppTheme.Colors.warningYellow)
    }
    return ("On Time", AppTheme.Colors.successGreen)
}
