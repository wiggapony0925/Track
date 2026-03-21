//
//  GlobalFeedsCache.swift
//  Track
//
//  Persists alerts and accessibility data to disk so the next cold
//  launch can display alert banners and elevator outages instantly
//  instead of waiting 1-3s for the network.
//
//  Mirrors TransitSessionCache's approach: save after every successful
//  fetch, load on next cold launch, background refresh replaces stale data.
//
//  maxAge = 4 hours — alerts change more frequently than route structure,
//  so we keep a shorter window than TransitSessionCache (24h).
//

import Foundation

enum GlobalFeedsCache {

    // MARK: - File Names

    private static let alertsFileName = "session_alerts_v1.json"
    private static let accessibilityFileName = "session_accessibility_v1.json"

    // MARK: - Envelope

    private struct CacheEnvelope<T: Codable>: Codable {
        let savedAt: Date
        let data: T
    }

    // MARK: - File URLs

    private static var alertsURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: kAppGroupIdentifier)?
            .appendingPathComponent(alertsFileName)
    }

    private static var accessibilityURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: kAppGroupIdentifier)?
            .appendingPathComponent(accessibilityFileName)
    }

    // MARK: - Save

    /// Persist alerts to disk after a successful API fetch.
    static func saveAlerts(_ alerts: [TransitAlert]) {
        save(alerts, to: alertsURL, label: "alerts")
    }

    /// Persist accessibility outages to disk after a successful API fetch.
    static func saveAccessibility(_ outages: [ElevatorStatus]) {
        save(outages, to: accessibilityURL, label: "accessibility")
    }

    private static func save<T: Codable>(_ data: T, to url: URL?, label: String) {
        guard let url else { return }
        let envelope = CacheEnvelope(savedAt: Date(), data: data)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let encoded = try? encoder.encode(envelope) else { return }
        DispatchQueue.global(qos: .utility).async {
            try? encoded.write(to: url, options: [.atomic])
            #if DEBUG
            print("[CACHE] 💾 Saved \(label) (\(encoded.count / 1024)KB) to global feeds cache")
            #endif
        }
    }

    // MARK: - Load

    /// Load cached alerts from disk.
    /// Returns `nil` if the cache is missing, corrupt, or older than `maxAge`.
    static func loadAlerts(maxAge: TimeInterval = 14400) -> [TransitAlert]? {
        load(from: alertsURL, maxAge: maxAge, label: "alerts")
    }

    /// Load cached accessibility outages from disk.
    /// Returns `nil` if the cache is missing, corrupt, or older than `maxAge`.
    static func loadAccessibility(maxAge: TimeInterval = 14400) -> [ElevatorStatus]? {
        load(from: accessibilityURL, maxAge: maxAge, label: "accessibility")
    }

    private static func load<T: Codable>(from url: URL?, maxAge: TimeInterval, label: String) -> T? {
        guard let url,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        guard let envelope = try? decoder.decode(CacheEnvelope<T>.self, from: data) else {
            return nil
        }

        let age = Date().timeIntervalSince(envelope.savedAt)
        guard age < maxAge else {
            #if DEBUG
            print("[CACHE] 🗑️ \(label) cache too old (\(Int(age))s > \(Int(maxAge))s) — discarding")
            #endif
            return nil
        }

        #if DEBUG
        print("[CACHE] 📂 Restored \(label) from disk (\(Int(age))s old)")
        #endif

        return envelope.data
    }

    // MARK: - Clear

    static func clear() {
        if let url = alertsURL { try? FileManager.default.removeItem(at: url) }
        if let url = accessibilityURL { try? FileManager.default.removeItem(at: url) }
    }
}
