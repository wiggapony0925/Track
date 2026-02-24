//
//  FormatUtils.swift
//  Track
//
//  Shared formatting utilities used across multiple views and components.
//  Consolidates duplicated formatting logic for arrival times, distances,
//  route names, and transit status colors.
//

import SwiftUI

// MARK: - Distance Unit Preference

/// Reads the user's chosen distance unit from UserDefaults.
/// Returns `"mi"` (imperial) or `"km"` (metric).
var preferredDistanceUnit: String {
    UserDefaults.standard.string(forKey: "distance_unit") ?? "mi"
}

/// Whether the user prefers metric (km) distances.
var isMetricDistance: Bool {
    preferredDistanceUnit == "km"
}

// MARK: - Distance Conversion Constants

/// Conversion factor: meters to miles (1 mile = 1609.344 meters)
let metersPerMile: Double = 1609.344

/// Conversion factor: meters to feet (1 meter = 3.28084 feet)
let feetPerMeter: Double = 3.28084

/// Converts meters to miles
func metersToMiles(_ meters: Double) -> Double {
    meters / metersPerMile
}

/// Converts miles to meters
func milesToMeters(_ miles: Double) -> Double {
    miles * metersPerMile
}

/// Converts meters to feet
func metersToFeet(_ meters: Double) -> Double {
    meters * feetPerMeter
}

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

/// Formats a distance in meters into a human-readable string,
/// respecting the user's preferred unit (miles or kilometers).
///
/// - Parameters:
///   - meters: Distance in meters.
///   - suffix: Optional suffix appended after the value (e.g. "away"). Defaults to "away".
/// - Returns: e.g. "250m away", "1.2km away" (metric) or "820 ft away", "0.3 mi away" (imperial)
func formatDistance(_ meters: Double, suffix: String = "away") -> String {
    if isMetricDistance {
        let value: String
        if meters < 1000 {
            value = "\(Int(meters))m"
        } else {
            value = String(format: "%.1fkm", meters / 1000)
        }
        return suffix.isEmpty ? value : "\(value) \(suffix)"
    } else {
        return formatDistanceImperial(meters, suffix: suffix)
    }
}

/// Formats a walking distance in meters with rounded precision,
/// respecting the user's preferred unit.
///
/// **Metric:** Under 100 m shows exact metres; 100–999 m rounds to nearest 10;
/// ≥ 1 km shows one decimal place.
///
/// **Imperial:** Under 528 ft (0.1 mi) shows feet rounded to nearest 10;
/// otherwise shows miles with one decimal.
///
/// - Parameters:
///   - meters: Distance in meters.
///   - suffix: Optional suffix (e.g. "away"). Defaults to "away".
/// - Returns: e.g. "82m away", "250m away", "1.2km away" or "270 ft away", "0.3 mi away"
func formatWalkingDistance(_ meters: Double, suffix: String = "away") -> String {
    if isMetricDistance {
        let value: String
        if meters < 100 {
            value = "\(Int(meters))m"
        } else if meters < 1000 {
            value = "\(Int(meters / 10) * 10)m"
        } else {
            value = String(format: "%.1fkm", meters / 1000.0)
        }
        return suffix.isEmpty ? value : "\(value) \(suffix)"
    } else {
        return formatDistanceImperial(meters, suffix: suffix)
    }
}

/// Formats a distance in meters for display on map radius labels
/// and settings UI, respecting the user's preferred unit.
///
/// - Parameter meters: Distance in meters.
/// - Returns: e.g. "0.5 mi", "1 mi", "2.5 mi" or "0.8 km", "2 km", "4.0 km"
func formatDistanceMiles(_ meters: Double) -> String {
    if isMetricDistance {
        let km = meters / 1000.0
        if km < 1.0 {
            return String(format: "%.1f km", km)
        }
        if km.truncatingRemainder(dividingBy: 1.0) < 0.1 {
            return String(format: "%.0f km", km)
        }
        return String(format: "%.1f km", km)
    } else {
        let miles = metersToMiles(meters)
        if miles < 1.0 {
            return String(format: "%.1f mi", miles)
        }
        // Drop decimal for clean whole-number miles (e.g. 1.0 → "1 mi")
        if miles.truncatingRemainder(dividingBy: 1.0) < 0.1 {
            return String(format: "%.0f mi", miles)
        }
        return String(format: "%.1f mi", miles)
    }
}

/// Formats a distance in meters using the user's preferred unit system
/// for display on route cards.
///
/// **Imperial:** Under 528 feet (0.1 mi) shows feet rounded to nearest 10.
/// Otherwise shows miles with one decimal.
///
/// **Metric:** Under 100 m shows exact metres. Otherwise shows km with one decimal.
///
/// - Parameters:
///   - meters: Distance in meters.
///   - suffix: Optional suffix (e.g. "away"). Defaults to empty.
/// - Returns: e.g. "320 ft", "0.3 mi" or "95m", "0.3 km"
func formatDistanceImperial(_ meters: Double, suffix: String = "") -> String {
    let value: String
    if isMetricDistance {
        if meters < 100 {
            value = "\(Int(meters))m"
        } else if meters < 1000 {
            value = "\(Int(meters / 10) * 10)m"
        } else {
            let km = meters / 1000.0
            if km < 10 {
                value = String(format: "%.1f km", km)
            } else {
                value = String(format: "%.0f km", km)
            }
        }
    } else {
        let feet = metersToFeet(meters)
        if feet < 528 {  // 528 ft ≈ 0.1 mi
            // Round to nearest 10 ft for a clean display
            let rounded = Int((feet / 10).rounded()) * 10
            value = "\(max(rounded, 10)) ft"
        } else {
            let miles = metersToMiles(meters)
            if miles < 10 {
                value = String(format: "%.1f mi", miles)
            } else {
                value = String(format: "%.0f mi", miles)
            }
        }
    }
    return suffix.isEmpty ? value : "\(value) \(suffix)"
}

// MARK: - MTA Route Name

/// Strips any MTA agency prefix from a route or stop ID.
/// Delegates to the shared `stripMTAAgencyPrefix` in `Shared/MTAPrefixes.swift`
/// so all prefix definitions live in one place.
func stripMTAPrefix(_ routeId: String) -> String {
    stripMTAAgencyPrefix(routeId)
}

// MARK: - Transit Status Color

/// Returns a compact ETA string suitable for map marker titles.
///
/// - Parameter minutesAway: Minutes until the vehicle arrives at its next stop, or nil.
/// - Parameter fallback: Text to show when `minutesAway` is nil.
/// - Returns: e.g. "3 min", "Now", or the fallback string.
func markerETALabel(minutesAway: Int?, fallback: String) -> String {
    guard let mins = minutesAway else { return fallback }
    if mins <= 0 { return "Now · \(fallback)" }
    return "\(mins) min · \(fallback)"
}

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
