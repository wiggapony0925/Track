//
//  ServiceModels.swift
//  Track
//
//  Data models for service alerts, accessibility status, and bus routes
//  matching the TrackBackend JSON output.
//

import Foundation

/// A critical MTA service alert returned by /alerts.
struct TransitAlert: Identifiable, Codable {
    var id: String { (routeId ?? "system") + title }

    let routeId: String?
    let title: String
    let description: String
    let severity: String

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case title
        case description
        case severity
    }
}

/// An elevator or escalator currently out of service, returned by /accessibility.
struct ElevatorStatus: Identifiable, Codable {
    var id: String { station + equipmentType }

    let station: String
    let equipmentType: String
    let description: String
    let outageSince: String?

    enum CodingKeys: String, CodingKey {
        case station
        case equipmentType = "equipment_type"
        case description
        case outageSince = "outage_since"
    }
}

/// A normalized MTA bus route returned by /bus/routes.
struct BusRoute: Identifiable, Codable {
    let id: String
    let shortName: String
    let longName: String
    let color: String
    let description: String

    enum CodingKeys: String, CodingKey {
        case id
        case shortName = "short_name"
        case longName = "long_name"
        case color
        case description
    }
}
