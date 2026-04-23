// On-disk cache for the Plan tab's "rarely-changing" data
// (saved places, recent trips, saved trip templates, recommendations).
//
// Goal: eliminate the slow first-paint of PlanView. The user's saved
// locations almost never change, so we persist the last server response
// per-user in App Group UserDefaults. PlanViewModel reads this
// synchronously on configure() — the UI renders instantly while a
// background refresh runs in parallel (stale-while-revalidate).

import Foundation

/// Per-user snapshot of the four planner endpoints.
struct PlannerSnapshot: Codable {
    var savedPlaces: [PlannerSavedPlaceRecord]
    var recentTrips: [PlannerRecentTripRecord]
    var savedTripTemplates: [PlannerSavedTripRecord]
    var recommendations: [PlannerRecommendation]

    /// When each bucket was last refreshed from the server.
    var savedPlacesAt: Date
    var recentTripsAt: Date
    var savedTripTemplatesAt: Date
    var recommendationsAt: Date

    static let empty = PlannerSnapshot(
        savedPlaces: [],
        recentTrips: [],
        savedTripTemplates: [],
        recommendations: [],
        savedPlacesAt: .distantPast,
        recentTripsAt: .distantPast,
        savedTripTemplatesAt: .distantPast,
        recommendationsAt: .distantPast
    )
}

/// Disk-backed cache for planner data, keyed by user ID.
///
/// Reads are synchronous and cheap (single UserDefaults hit + JSON decode
/// of a small payload). Safe to call from the main actor on view setup.
@MainActor
final class PlannerDataCache {
    static let shared = PlannerDataCache()

    /// Per-bucket freshness windows. Anything older than this is considered
    /// stale and the prefetch service will refresh it on app foreground.
    enum TTL {
        /// Saved Home/Work/etc. — users rarely change these.
        static let savedPlaces: TimeInterval = 60 * 60          // 1 hour
        /// Saved trip templates ("Daily Commute") — change occasionally.
        static let savedTripTemplates: TimeInterval = 30 * 60   // 30 minutes
        /// Recent trips — updated whenever the user plans a trip.
        static let recentTrips: TimeInterval = 5 * 60           // 5 minutes
        /// Recommendations — depend on time-of-day + calendar.
        static let recommendations: TimeInterval = 10 * 60      // 10 minutes
    }

    private let defaults: UserDefaults
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        self.defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    // MARK: - Read

    /// Synchronously load the cached snapshot for a user, or `.empty` if none.
    func snapshot(for userID: String) -> PlannerSnapshot {
        guard let data = defaults.data(forKey: Self.key(userID)) else {
            return .empty
        }
        return (try? decoder.decode(PlannerSnapshot.self, from: data)) ?? .empty
    }

    /// Whether *any* cached planner data exists for this user.
    /// Used by PlanViewModel.configure() to decide whether to skip the
    /// initial loading state entirely.
    func hasAnyData(for userID: String) -> Bool {
        let snap = snapshot(for: userID)
        return !snap.savedPlaces.isEmpty
            || !snap.recentTrips.isEmpty
            || !snap.savedTripTemplates.isEmpty
            || !snap.recommendations.isEmpty
    }

    // MARK: - Write

    /// Replace the entire snapshot for a user.
    func save(_ snapshot: PlannerSnapshot, for userID: String) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key(userID))
    }

    /// Update only the saved-places bucket (and its timestamp).
    func updateSavedPlaces(_ places: [PlannerSavedPlaceRecord], for userID: String) {
        var snap = snapshot(for: userID)
        snap.savedPlaces = places
        snap.savedPlacesAt = Date()
        save(snap, for: userID)
    }

    /// Update only the recent-trips bucket (and its timestamp).
    func updateRecentTrips(_ trips: [PlannerRecentTripRecord], for userID: String) {
        var snap = snapshot(for: userID)
        snap.recentTrips = trips
        snap.recentTripsAt = Date()
        save(snap, for: userID)
    }

    /// Update only the saved-trip-templates bucket (and its timestamp).
    func updateSavedTripTemplates(_ templates: [PlannerSavedTripRecord], for userID: String) {
        var snap = snapshot(for: userID)
        snap.savedTripTemplates = templates
        snap.savedTripTemplatesAt = Date()
        save(snap, for: userID)
    }

    /// Update only the recommendations bucket (and its timestamp).
    func updateRecommendations(_ recs: [PlannerRecommendation], for userID: String) {
        var snap = snapshot(for: userID)
        snap.recommendations = recs
        snap.recommendationsAt = Date()
        save(snap, for: userID)
    }

    /// Clear all cached planner data for a user (e.g. on sign-out).
    func clear(for userID: String) {
        defaults.removeObject(forKey: Self.key(userID))
    }

    // MARK: - Freshness

    /// Whether the saved-places bucket needs a refresh.
    func isStale(_ bucket: KeyPath<PlannerSnapshot, Date>, ttl: TimeInterval, for userID: String) -> Bool {
        let snap = snapshot(for: userID)
        return Date().timeIntervalSince(snap[keyPath: bucket]) > ttl
    }

    // MARK: - Private

    private static func key(_ userID: String) -> String {
        "planner_snapshot_v1_\(userID)"
    }
}
