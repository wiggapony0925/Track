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
    /// Performs case-insensitive **exact** matching only.
    /// Does NOT do substring/containment matching to prevent cross-mode leaks
    /// (e.g. an "L" subway alert incorrectly matching "LIRR_9").
    func matching(routeId: String) -> [TransitAlert] {
        let query = routeId.lowercased()
        
        return filter { alert in
            let alertRoute = (alert.routeId ?? "").lowercased()
            let affected = alert.affectedRoutes.map { $0.lowercased() }
            
            // Exact match (case-insensitive)
            return alertRoute == query || affected.contains(query)
        }
    }
    
    /// Alerts matching a specific route within a given transit mode.
    /// This is the **preferred** method — it first filters to the correct mode,
    /// then checks route IDs including LIRR_/MNR_ prefix variants so
    /// "LIRR_9" matches an alert with routeId "9" in mode "lirr" (and vice versa).
    ///
    /// This prevents cross-mode leaks:
    /// - Subway "L" alert will NOT appear on LIRR routes
    /// - Subway "1" alert will NOT appear on LIRR route "LIRR_1"
    /// - Bus "B63" alert will NOT appear on subway "B" route
    func matching(routeId: String, mode: String) -> [TransitAlert] {
        let query = routeId.lowercased()
        let queryMode = mode.lowercased()
        
        // For LIRR/MNR, also prepare the bare numeric and prefixed forms
        let bareId: String? = {
            if query.hasPrefix("lirr_") { return String(query.dropFirst(5)) }
            if query.hasPrefix("mnr_") { return String(query.dropFirst(4)) }
            return nil
        }()
        let prefixedId: String? = {
            if queryMode == "lirr" && !query.hasPrefix("lirr_") { return "lirr_\(query)" }
            if queryMode == "mnr" && !query.hasPrefix("mnr_") { return "mnr_\(query)" }
            return nil
        }()
        
        return filter { alert in
            // MUST be the same transit mode — this is the key guard
            guard alert.mode.lowercased() == queryMode else { return false }
            
            let alertRoute = (alert.routeId ?? "").lowercased()
            let affected = alert.affectedRoutes.map { $0.lowercased() }
            
            // Exact match
            if alertRoute == query || affected.contains(query) { return true }
            
            // Stripped prefix: "LIRR_9" query matches alert routeId "9" in lirr mode
            if let bare = bareId {
                if alertRoute == bare || affected.contains(bare) { return true }
            }
            
            // Added prefix: "9" query matches alert routeId "LIRR_9" in lirr mode
            if let pf = prefixedId {
                if alertRoute == pf || affected.contains(pf) { return true }
            }
            
            return false
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
