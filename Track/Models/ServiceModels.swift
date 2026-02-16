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
    var id: String { (routeId ?? "system") + "-" + mode + "-" + title }

    let routeId: String?
    let title: String
    let description: String
    let severity: String
    let mode: String
    let updatedAt: Int?           // epoch seconds – active_period start
    let affectedRoutes: [String]  // all route_ids this alert touches

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case title
        case description
        case severity
        case mode
        case updatedAt = "updated_at"
        case affectedRoutes = "affected_routes"
    }
    
    init(routeId: String? = nil, title: String, description: String, severity: String, mode: String, updatedAt: Int? = nil, affectedRoutes: [String]? = nil) {
        self.routeId = routeId
        self.title = title
        self.description = description
        self.severity = severity
        self.mode = mode
        self.updatedAt = updatedAt
        self.affectedRoutes = affectedRoutes ?? (routeId.map { [$0] } ?? [])
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        routeId = try container.decodeIfPresent(String.self, forKey: .routeId)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        severity = try container.decode(String.self, forKey: .severity)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "subway"
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
        affectedRoutes = try container.decodeIfPresent([String].self, forKey: .affectedRoutes) ?? (routeId.map { [$0] } ?? [])
    }

    /// SF Symbol icon matching the app's tab icons.
    var modeIcon: String {
        switch mode {
        case "bus":   return "bus.fill"
        case "lirr":  return "train.side.front.car"
        case "mnr":   return "train.side.rear.car"
        default:      return "tram.fill"
        }
    }

    /// Human-readable mode label.
    var modeLabel: String {
        switch mode {
        case "bus":   return "Bus"
        case "lirr":  return "LIRR"
        case "mnr":   return "Metro-North"
        default:      return "Subway"
        }
    }
}

// MARK: - Filtering & Sorting

extension Array where Element == TransitAlert {
    /// Filter alerts by the selected transport mode.
    /// The `.nearby` mode returns all alerts; specific modes return only matching alerts.
    func filtered(for mode: TransportMode) -> [TransitAlert] {
        switch mode {
        case .nearby:  return self
        case .subway:  return filter { $0.mode == "subway" }
        case .bus:     return filter { $0.mode == "bus" }
        case .lirr:    return filter { $0.mode == "lirr" }
        case .mnr:     return filter { $0.mode == "mnr" }
        }
    }
    
    /// Alerts matching a specific route ID (checks both `routeId` and `affectedRoutes`).
    func matching(routeId: String) -> [TransitAlert] {
        filter { alert in
            alert.affectedRoutes.contains(routeId) ||
            alert.routeId == routeId
        }
    }
    
    /// Sort alerts: severe first, then by recency (newest first).
    func sortedBySeverityAndTime() -> [TransitAlert] {
        sorted { a, b in
            let aSev = a.severity == "severe" ? 0 : 1
            let bSev = b.severity == "severe" ? 0 : 1
            if aSev != bSev { return aSev < bSev }
            return (a.updatedAt ?? 0) > (b.updatedAt ?? 0)
        }
    }
}

/// An elevator or escalator currently out of service, returned by /accessibility.
struct ElevatorStatus: Identifiable, Codable {
    var id: String { station + "-" + equipmentType }

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
