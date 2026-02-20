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
    let mode: String // "subway", "bus", "lirr", or "mnr"
    
    /// The absolute time of arrival, used for live countdown text in widgets.
    let arrivalTime: Date

    var isBus: Bool { mode == "bus" }
    var isLIRR: Bool { mode == "lirr" }
    var isMNR: Bool { mode == "mnr" }
    var isCommuterRail: Bool { isLIRR || isMNR }

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
    /// Feed's predicted Unix epoch for this arrival — used for a precise
    /// live countdown (same approach as ArrivalETAEngine feedTimestamp path).
    let arrivalTs: Int?

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case stopName = "stop_name"
        case direction
        case minutesAway = "minutes_away"
        case status
        case mode
        case arrivalTs = "arrival_ts"
    }

    /// The best available absolute arrival date.
    /// Prefer the feed's arrivalTs epoch; fall back to minutesAway offset.
    var resolvedArrivalTime: Date {
        if let ts = arrivalTs, ts > 0 {
            return Date(timeIntervalSince1970: Double(ts))
        }
        return Date().addingTimeInterval(Double(minutesAway) * 60)
    }
}
