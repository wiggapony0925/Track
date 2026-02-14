//
//  TransitWidgetModels.swift
//  Shared
//
//  Shared models for all widgets in the Track ecosystem.
//

import Foundation

/// Unique arrival entry for widget display
struct NearbyArrival: Hashable {
    let routeId: String
    let stopName: String
    let direction: String
    let minutesAway: Int
    let status: String
    let mode: String // "subway" or "bus"
    
    /// The absolute time of arrival, used for live countdown text in widgets.
    let arrivalTime: Date

    var isBus: Bool { mode == "bus" }

    /// Strips "MTA NYCT_" prefix for display.
    var displayName: String {
        if routeId.hasPrefix("MTA NYCT_") {
            return String(routeId.dropFirst(9))
        }
        return routeId
    }
}

/// Lightweight Codable model for decoding the /nearby API response in widgets
struct WidgetNearbyResponse: Codable {
    let routeId: String
    let stopName: String
    let direction: String
    let minutesAway: Int
    let status: String
    let mode: String

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case stopName = "stop_name"
        case direction
        case minutesAway = "minutes_away"
        case status
        case mode
    }
}
