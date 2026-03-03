//
//  TransitSessionCache.swift
//  Track
//
//  Persists the most recent grouped transit response to the App Group
//  container so the next cold launch can display route cards instantly
//  (~5ms disk read) instead of skeleton placeholders for 5+ seconds.
//
//  Data flow:
//    1. After each successful /nearby/grouped fetch → `save()`
//    2. On next cold launch → `load()` returns cached route cards
//    3. ViewModel sets hasLoadedOnce = true → skeletons never appear
//    4. Background network fetch silently replaces stale data
//

import Foundation

enum TransitSessionCache {
    private static let fileName = "session_grouped_transit.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: kAppGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    // MARK: - Save

    /// Persist grouped transit data to disk after a successful API fetch.
    /// Encoding + write runs on a background queue to avoid blocking the main thread.
    static func save(_ groups: [GroupedNearbyTransitResponse]) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(groups) else { return }

        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Load

    /// Load cached grouped transit from disk.
    /// Synchronous read (~1-5ms for typical 100-route payloads) — safe to call
    /// on the main thread during app init for instant display.
    static func load() -> [GroupedNearbyTransitResponse]? {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }
        return try? JSONDecoder().decode([GroupedNearbyTransitResponse].self, from: data)
    }

    // MARK: - Clear

    /// Remove the cache file (e.g. on sign-out or cache reset).
    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
