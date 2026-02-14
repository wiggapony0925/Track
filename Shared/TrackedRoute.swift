//
//  TrackedRoute.swift
//  Shared
//
//  Model for a user-selected route being tracked in the SingleRouteWidget.
//  Persisted to App Group UserDefaults for widget access.
//

import Foundation

struct TrackedRoute: Codable {
    let routeId: String
    let displayName: String
    let stopName: String
    let direction: String
    let destination: String?
    let mode: String // "bus" or "subway"
    let trackedAt: Date

    var isBus: Bool { mode == "bus" }

    /// Strips "MTA NYCT_" prefix for display.
    var cleanDisplayName: String {
        if displayName.hasPrefix("MTA NYCT_") {
            return String(displayName.dropFirst(9))
        }
        return displayName
    }

    // MARK: - Persistence

    private static let defaults = UserDefaults(suiteName: "group.com.track.shared") ?? UserDefaults.standard

    private enum Keys {
        static let routeId = "tracked_route_id"
        static let displayName = "tracked_route_display_name"
        static let stopName = "tracked_route_stop_name"
        static let direction = "tracked_route_direction"
        static let destination = "tracked_route_destination"
        static let mode = "tracked_route_mode"
        static let timestamp = "tracked_route_timestamp"
    }

    /// Load the currently tracked route from UserDefaults
    static func load() -> TrackedRoute? {
        guard let routeId = defaults.string(forKey: Keys.routeId),
              let displayName = defaults.string(forKey: Keys.displayName),
              let stopName = defaults.string(forKey: Keys.stopName),
              let direction = defaults.string(forKey: Keys.direction),
              let mode = defaults.string(forKey: Keys.mode),
              let trackedAt = defaults.object(forKey: Keys.timestamp) as? Date else {
            return nil
        }

        let destination = defaults.string(forKey: Keys.destination)

        return TrackedRoute(
            routeId: routeId,
            displayName: displayName,
            stopName: stopName,
            direction: direction,
            destination: destination,
            mode: mode,
            trackedAt: trackedAt
        )
    }

    /// Save this route as the tracked route in UserDefaults
    func save() {
        TrackedRoute.defaults.set(routeId, forKey: Keys.routeId)
        TrackedRoute.defaults.set(displayName, forKey: Keys.displayName)
        TrackedRoute.defaults.set(stopName, forKey: Keys.stopName)
        TrackedRoute.defaults.set(direction, forKey: Keys.direction)
        TrackedRoute.defaults.set(destination, forKey: Keys.destination)
        TrackedRoute.defaults.set(mode, forKey: Keys.mode)
        TrackedRoute.defaults.set(trackedAt, forKey: Keys.timestamp)
    }

    /// Clear the tracked route from UserDefaults
    static func clear() {
        defaults.removeObject(forKey: Keys.routeId)
        defaults.removeObject(forKey: Keys.displayName)
        defaults.removeObject(forKey: Keys.stopName)
        defaults.removeObject(forKey: Keys.direction)
        defaults.removeObject(forKey: Keys.destination)
        defaults.removeObject(forKey: Keys.mode)
        defaults.removeObject(forKey: Keys.timestamp)
    }
}
