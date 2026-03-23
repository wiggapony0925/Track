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

    // MTA Mercury extension fields
    let alertType: String?              // e.g. "Delays", "Planned - Suspended"
    let sortOrder: Int                  // MTA severity rank (higher = more severe)
    let displayBeforeActive: Int?       // seconds before active_period to show (null = don't show in status box)
    let activePeriodEnd: Int?           // epoch seconds – when the alert expires

    enum CodingKeys: String, CodingKey {
        case routeId = "route_id"
        case title
        case description
        case severity
        case mode
        case updatedAt = "updated_at"
        case affectedRoutes = "affected_routes"
        case alertType = "alert_type"
        case sortOrder = "sort_order"
        case displayBeforeActive = "display_before_active"
        case activePeriodEnd = "active_period_end"
    }
    
    init(routeId: String? = nil, title: String, description: String, severity: String, mode: String, updatedAt: Int? = nil, affectedRoutes: [String]? = nil, alertType: String? = nil, sortOrder: Int = 0, displayBeforeActive: Int? = nil, activePeriodEnd: Int? = nil) {
        self.routeId = routeId
        self.title = title
        self.description = description
        self.severity = severity
        self.mode = mode
        self.updatedAt = updatedAt
        self.affectedRoutes = affectedRoutes ?? (routeId.map { [$0] } ?? [])
        self.alertType = alertType
        self.sortOrder = sortOrder
        self.displayBeforeActive = displayBeforeActive
        self.activePeriodEnd = activePeriodEnd
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
        alertType = try container.decodeIfPresent(String.self, forKey: .alertType)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        displayBeforeActive = try container.decodeIfPresent(Int.self, forKey: .displayBeforeActive)
        activePeriodEnd = try container.decodeIfPresent(Int.self, forKey: .activePeriodEnd)
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
    /// Drops alerts whose `activePeriodEnd` has already passed.
    /// Alerts without an expiry are kept (they're considered indefinite).
    func excludingExpired() -> [TransitAlert] {
        let now = Int(Date().timeIntervalSince1970)
        return filter { alert in
            guard let end = alert.activePeriodEnd else { return true }
            return end > now
        }
    }

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
        let queryNormalized = normalizeMTARouteToken(routeId).lowercased()
        
        return filter { alert in
            // MUST be the same transit mode — this is the key guard
            guard alert.mode.lowercased() == queryMode else { return false }
            
            let alertRoute = (alert.routeId ?? "").lowercased()
            let affected = alert.affectedRoutes.map { $0.lowercased() }
            
            // Exact match
            if alertRoute == query || affected.contains(query) { return true }

            // Prefix-agnostic match via shared route token normalization
            if normalizeMTARouteToken(alertRoute).lowercased() == queryNormalized { return true }
            if affected.contains(where: { normalizeMTARouteToken($0).lowercased() == queryNormalized }) {
                return true
            }
            
            return false
        }
    }
    
    /// Sort alerts by MTA sort_order (highest/most severe first), then recency.
    /// Falls back to severity string when sort_order is unavailable.
    func sortedBySeverityAndTime() -> [TransitAlert] {
        sorted { a, b in
            // Primary: MTA sort_order (higher = more severe → sort descending)
            if a.sortOrder != b.sortOrder { return a.sortOrder > b.sortOrder }
            // Secondary: legacy severity string
            let aSev = a.severity == "severe" ? 0 : 1
            let bSev = b.severity == "severe" ? 0 : 1
            if aSev != bSev { return aSev < bSev }
            // Tertiary: newest first
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
