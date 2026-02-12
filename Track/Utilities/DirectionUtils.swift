//
//  DirectionUtils.swift
//  Track
//
//  Shared direction formatting utilities for transit directions.
//  Consolidates the direction label logic used in RouteDetailSheet,
//  GroupedRouteRow, and other components.
//

import Foundation

/// Converts a raw direction code (e.g. "N", "S") to a full human-readable label.
///
/// - Parameter direction: Raw direction string from the backend.
/// - Returns: e.g. "Northbound", "Southbound", or the original string if not a compass code.
func directionLabel(_ direction: String) -> String {
    switch direction.uppercased() {
    case "N": return "Northbound"
    case "S": return "Southbound"
    case "E": return "Eastbound"
    case "W": return "Westbound"
    default: return direction
    }
}

/// Converts a raw direction code to a short arrow-prefixed label.
///
/// - Parameter direction: Raw direction string from the backend.
/// - Returns: e.g. "↑ North", "↓ South", or the original string.
func shortDirectionLabel(_ direction: String) -> String {
    switch direction.uppercased() {
    case "N": return "↑ North"
    case "S": return "↓ South"
    case "E": return "→ East"
    case "W": return "← West"
    default: return direction
    }
}
