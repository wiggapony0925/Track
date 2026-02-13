//
//  RouteAnalyticsManager.swift
//  Track
//
//  Tracks user interactions with transit routes to surface frequently used
//  lines in the widget and smart suggestions.
//  Uses App Group UserDefaults to share data with the Widget.
//

import Foundation

class RouteAnalyticsManager {
    static let shared = RouteAnalyticsManager()
    
    private let defaults = UserDefaults(suiteName: "group.com.track.shared") ?? UserDefaults.standard
    private let key = "route_interaction_stats"
    
    // In-memory cache
    private var stats: [String: Int] = [:]
    
    private init() {
        self.stats = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
    }
    
    /// Increments the interaction count for a given route.
    /// Call this when the user taps on a route or views its details.
    func logInteraction(routeId: String) {
        let currentCount = stats[routeId] ?? 0
        stats[routeId] = currentCount + 1
        save()
    }
    
    /// Returns the interaction count for a given route.
    func getCount(for routeId: String) -> Int {
        return stats[routeId] ?? 0
    }
    
    /// Returns all stats.
    func getAllStats() -> [String: Int] {
        return stats
    }
    
    private func save() {
        defaults.set(stats, forKey: key)
    }
}
