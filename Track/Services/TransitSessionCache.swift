// Persists the most recent grouped transit response to the App Group
// container so the next cold launch can display route cards instantly
// (~5ms disk read) instead of skeleton placeholders for 5+ seconds.
// Data flow:
//   1. After each successful /nearby/grouped fetch → `save()`
//   2. On next cold launch → `load()` returns cached route cards
//   3. ViewModel sets hasLoadedOnce = true → skeletons never appear
//   4. Background network fetch silently replaces stale data
// Location awareness:
//   The cache envelope stores the GPS coordinates and timestamp of the
//   data.  On load, the caller can compare the cached location against
//   the current GPS fix.  If the user has moved significantly (e.g.
//   phone was off, commuted home), the cache is still returned for
//   instant display but flagged so the caller knows to force-refresh.

import CoreLocation
import Foundation

enum TransitSessionCache {
    private static let fileName = "session_grouped_transit_v2.json"

    /// Lightweight envelope that wraps the transit data with provenance
    /// metadata so we can detect stale-location caches on load.
    private struct CacheEnvelope: Codable {
        let latitude: Double
        let longitude: Double
        let savedAt: Date
        let groups: [GroupedNearbyTransitResponse]
    }

    /// Result returned by ``load(near:significantDistance:maxAge:)`` that
    /// tells the caller whether the cached data matches the current location.
    struct LoadResult {
        let groups: [GroupedNearbyTransitResponse]
        /// Approximate distance in meters between the cached location and
        /// the provided reference location.  `nil` if no reference given.
        let distanceFromCurrent: Double?
        /// Whether the data was captured at a significantly different
        /// location from the current GPS fix — caller should force-refresh.
        let isLocationStale: Bool
        /// Age of the cached data in seconds.
        let age: TimeInterval
        /// The GPS location where this data was captured.
        let cachedLocation: CLLocation
    }

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    // MARK: - Save

    /// Persist grouped transit data to disk after a successful API fetch.
    /// Encoding + write runs on a background queue to avoid blocking the main thread.
    ///
    /// - Parameters:
    ///   - groups: The transit groups from the API.
    ///   - location: The GPS coordinate used for the fetch.
    static func save(_ groups: [GroupedNearbyTransitResponse], location: CLLocation? = nil) {
        guard let url = fileURL else { return }
        let lat = location?.coordinate.latitude ?? 0
        let lon = location?.coordinate.longitude ?? 0
        let envelope = CacheEnvelope(
            latitude: lat,
            longitude: lon,
            savedAt: Date(),
            groups: groups
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(envelope) else { return }

        DispatchQueue.global(qos: .utility).async {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                #if DEBUG
                print("[CACHE] Failed to save session cache: \(error.localizedDescription)")
                #endif
            }
        }
    }

    // MARK: - Load

    /// Load cached grouped transit from disk with location + age awareness.
    ///
    /// - Parameters:
    ///   - currentLocation: The user's current GPS fix (if available).
    ///   - significantDistance: Distance in meters beyond which the cache
    ///     is considered location-stale.  Defaults to 400m (≈3 long blocks).
    ///   - maxAge: Maximum age in seconds before the cache is discarded
    ///     entirely.  Defaults to **7 days** (604 800 s).  Stale route
    ///     cards (even days old) are far better than skeleton
    ///     placeholders — they show the user which routes serve their
    ///     area while fresh data loads in the background.  Transit app
    ///     uses the same approach: cached structure renders instantly,
    ///     live times replace "--" within 1-3 seconds.
    ///
    ///     The previous 24-hour TTL caused the cache to be discarded
    ///     after a single day of not opening the app, forcing a full
    ///     cold-start load from the backend (60-150 s on Render).
    ///     Route structure (which lines serve an area) barely changes
    ///     week-to-week, so 7 days is safe.  The live-times within
    ///     each card are always refreshed on the first network fetch.
    ///
    /// - Returns: A ``LoadResult`` with the groups and staleness flags,
    ///   or `nil` if the cache file is missing, corrupt, or too old.
    static func load(
        near currentLocation: CLLocation? = nil,
        significantDistance: Double = 400,
        maxAge: TimeInterval = 604_800  // 7 days
    ) -> LoadResult? {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        // Try the v2 envelope first
        if let envelope = try? decoder.decode(CacheEnvelope.self, from: data) {
            let age = Date().timeIntervalSince(envelope.savedAt)
            // Discard entirely stale data (e.g. from yesterday)
            guard age < maxAge else {
                #if DEBUG
                let reason = "(\(Int(age))s > \(Int(maxAge))s)"
                print("[CACHE] 🗑️ Session cache too old \(reason) — discarding")
                #endif
                return nil
            }
            let cachedLoc = CLLocation(latitude: envelope.latitude, longitude: envelope.longitude)
            var distance: Double? = nil
            var locationStale = false
            if let current = currentLocation, envelope.latitude != 0 {
                distance = current.distance(from: cachedLoc)
                locationStale = distance! >= significantDistance
            }
            return LoadResult(
                groups: envelope.groups,
                distanceFromCurrent: distance,
                isLocationStale: locationStale,
                age: age,
                cachedLocation: cachedLoc
            )
        }

        // Fall back to legacy format (plain [GroupedNearbyTransitResponse])
        if let groups = try? JSONDecoder().decode([GroupedNearbyTransitResponse].self, from: data),
           !groups.isEmpty {
            // Legacy data has no location/time — assume stale-location
            let fallbackLoc = CLLocation(latitude: 0, longitude: 0)
            return LoadResult(
                groups: groups,
                distanceFromCurrent: nil,
                isLocationStale: true,
                age: .infinity,
                cachedLocation: fallbackLoc
            )
        }

        return nil
    }

    /// Simple load returning just the groups (backward-compat convenience).
    static func loadGroups() -> [GroupedNearbyTransitResponse]? {
        return load()?.groups
    }

    // MARK: - Clear

    /// Remove the cache file (e.g. on sign-out or cache reset).
    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
        // Also clean up legacy file
        if let legacyURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("session_grouped_transit.json") {
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }
}
