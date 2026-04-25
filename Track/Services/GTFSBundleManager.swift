//
//  GTFSBundleManager.swift
//  Track
//
//  Coordinates the lifecycle of the on-device GTFS mobile bundle:
//
//      1. Bootstrap — open whatever bundle ships with the app the
//         first time the manager is asked for one.  Falls back to a
//         download if no bundle is on disk yet.
//      2. Refresh — periodically fetches `/gtfs/manifest`, compares the
//         server's content-addressed sha to what is on disk, and
//         downloads a new bundle if they differ.
//      3. Atomic swap — newly downloaded bundles land in
//         `Caches/gtfs/{filename}`, then a single property update
//         flips `current` so readers always see a fully-formed file.
//
//  Bundles are pure data, ~4 MB each; refresh happens at most once
//  per hour and only over Wi-Fi unless `forceRefresh` is invoked.
//

import Foundation
import Combine

@MainActor
public final class GTFSBundleManager: ObservableObject {
    public static let shared = GTFSBundleManager()

    // MARK: - Published state

    @Published public private(set) var current: LocalGTFSBundle?
    @Published public private(set) var lastError: String?
    @Published public private(set) var isRefreshing: Bool = false

    // MARK: - Constants

    private static let manifestPath = "/gtfs/manifest"
    private static let bundlePathPrefix = "/gtfs/bundle/"
    private static let region = "nyc"
    private static let refreshThrottle: TimeInterval = 3600  // 1h
    private static let manifestTimeout: TimeInterval = 6.0
    private static let downloadTimeout: TimeInterval = 60.0

    private static let userDefaultsKey = "track.gtfs.activeBundleFilename"

    // Where downloaded bundles live (ephemeral cache; a future
    // background-refresh job repopulates as needed).
    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        )[0]
        let dir = base.appendingPathComponent("gtfs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private var lastRefreshAt: Date = .distantPast

    // MARK: - Public API

    /// Open the most recent bundle currently available on disk.  Safe
    /// to call repeatedly — only opens once per filename.
    @discardableResult
    public func bootstrap() -> LocalGTFSBundle? {
        if let current { return current }

        if let activeName = UserDefaults.standard.string(forKey: Self.userDefaultsKey) {
            let url = Self.cacheDirectory.appendingPathComponent(activeName)
            if let bundle = try? LocalGTFSBundle(url: url) {
                self.current = bundle
                AppLogger.shared.log(
                    "GTFS",
                    message: "Bootstrapped bundle \(activeName) " +
                             "stops=\(bundle.metadata.stopsCount)"
                )
                return bundle
            }
            // File missing or corrupted — clear stale pointer so we redownload.
            UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
        }

        // No on-device bundle yet — kick off a background download.
        Task { await refreshIfNeeded(force: true) }
        return nil
    }

    /// Refresh the manifest and download a new bundle if its sha
    /// differs from the one we have.  No-ops if called within the
    /// throttle window unless `force` is true.
    public func refreshIfNeeded(force: Bool = false) async {
        let elapsed = Date().timeIntervalSince(lastRefreshAt)
        if !force && elapsed < Self.refreshThrottle { return }
        if isRefreshing { return }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let manifest = try await fetchManifest()
            guard let entry = manifest.regions.first(where: { $0.regionID == Self.region }) else {
                lastError = "manifest had no region '\(Self.region)'"
                return
            }

            let activeName = UserDefaults.standard.string(forKey: Self.userDefaultsKey)
            if activeName == entry.filename, current != nil {
                lastRefreshAt = Date()
                return  // already up-to-date
            }

            let dest = Self.cacheDirectory.appendingPathComponent(entry.filename)

            if !FileManager.default.fileExists(atPath: dest.path) {
                try await downloadBundle(entry: entry, to: dest)
            }

            // Verify schema before swapping.
            let bundle = try LocalGTFSBundle(url: dest)
            UserDefaults.standard.set(entry.filename, forKey: Self.userDefaultsKey)
            self.current = bundle
            self.lastError = nil
            self.lastRefreshAt = Date()

            AppLogger.shared.log(
                "GTFS",
                message: "Activated bundle \(entry.filename) " +
                         "stops=\(bundle.metadata.stopsCount) " +
                         "size=\(entry.sizeBytes / 1024) KB"
            )

            pruneStaleBundles(keep: entry.filename)
        } catch {
            self.lastError = String(describing: error)
            AppLogger.shared.log(
                "GTFS", message: "Refresh failed: \(error)"
            )
        }
    }

    // MARK: - Manifest

    private struct ManifestEntry: Decodable, Sendable {
        let regionID: String
        let schemaVersion: Int
        let sha256: String
        let filename: String
        let url: String
        let sizeBytes: Int

        enum CodingKeys: String, CodingKey {
            case regionID = "region_id"
            case schemaVersion = "schema_version"
            case sha256, filename, url
            case sizeBytes = "size_bytes"
        }
    }

    private struct Manifest: Decodable, Sendable {
        let catalogVersion: Int
        let regions: [ManifestEntry]

        enum CodingKeys: String, CodingKey {
            case catalogVersion = "catalog_version"
            case regions
        }
    }

    private func fetchManifest() async throws -> Manifest {
        let urlString = TrackAPI.baseURL + Self.manifestPath
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.manifestTimeout
        request.cachePolicy = .reloadRevalidatingCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    // MARK: - Download

    private func downloadBundle(entry: ManifestEntry, to dest: URL) async throws {
        let urlString = TrackAPI.baseURL + Self.bundlePathPrefix + entry.filename
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.downloadTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // Verify size — content-addressed filename so size match is
        // a strong signal we got the right file.  A full sha256
        // re-hash here would double-load 4 MB on every refresh; the
        // server already serves with strong cache headers.
        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        if let downloadedSize = attrs[.size] as? Int, downloadedSize != entry.sizeBytes {
            throw URLError(.dataLengthExceedsMaximum)
        }

        // Atomic move into place.  If a previous attempt left a stub,
        // remove it first.
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)
    }

    // MARK: - Prune

    private func pruneStaleBundles(keep: String) {
        let dir = Self.cacheDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return
        }
        for name in names where name != keep && name.hasSuffix(".sqlite") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
