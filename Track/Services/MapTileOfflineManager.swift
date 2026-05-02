// Manages MapLibre offline base-map tile packs for the NYC Metro area.
// Downloads and stores MapTiler vector tiles locally so the base map
// renders even when the device has no network connectivity.
//
// Works alongside OfflineCacheManager (transit data) to give the app
// full offline capability — map tiles here, GTFS data there.
//
// Offline pack region: NYC Metro bounding box, zoom 8–15
//   SW: (40.4774, -74.2591)  NE: (40.9176, -73.7004)
//   Estimated compressed size: ~25–45 MB

import Combine
import CoreLocation
import Foundation
import MapLibre
import Network

// MARK: - Continuation Guard

/// Thread-safe once-only flag preventing a CheckedContinuation from being
/// resumed more than once when the path-update and timeout race.
final class ContinuationBox: Sendable {
    private let _lock = NSLock()
    // nonisolated(unsafe) is safe here: the lock serialises all access.
    nonisolated(unsafe) private var _resumed = false

    nonisolated init(_ continuation: CheckedContinuation<Bool, Never>) {}

    nonisolated func tryResume() -> Bool {
        _lock.lock()
        defer { _lock.unlock() }
        guard !_resumed else { return false }
        _resumed = true
        return true
    }
}

// MARK: - Download State

enum MapTileDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Float)
    case downloaded(date: Date)
    case failed(reason: String)

    static func == (lhs: MapTileDownloadState, rhs: MapTileDownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.notDownloaded, .notDownloaded): return true
        case (.downloading(let a), .downloading(let b)): return a == b
        case (.downloaded(let a), .downloaded(let b)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - MapTileOfflineManager

/// Singleton managing the MapLibre offline tile pack for the NYC Metro area.
/// Mirrors the structure of `OfflineCacheManager` — Observable, @MainActor.
@MainActor
final class MapTileOfflineManager: ObservableObject {
    static let shared = MapTileOfflineManager()

    // MARK: - Published State

    @Published private(set) var downloadState: MapTileDownloadState = .notDownloaded
    @Published private(set) var packSizeBytes: UInt64 = 0

    // MARK: - Constants

    /// Context tag written into every offline pack so we can find our pack
    /// among others that might be stored by MapLibre internals.
    private static let PACK_CONTEXT_TAG = "track-nyc-metro-v1"

    /// Redownload after 30 days so tiles stay reasonably up to date.
    private static let PACK_MAX_AGE: TimeInterval = 30 * 24 * 3600

    /// NYC Metro bounding box — all 5 boroughs + inner suburbs.
    static let nycBounds = MLNCoordinateBounds(
        sw: CLLocationCoordinate2D(latitude: 40.4774, longitude: -74.2591),
        ne: CLLocationCoordinate2D(latitude: 40.9176, longitude: -73.7004)
    )

    /// Zoom 8 (metro overview) through 15 (street-level navigation).
    private static let MIN_ZOOM: Double = 8
    private static let MAX_ZOOM: Double = 15

    // MARK: - Private

    private let userDefaults: UserDefaults
    private var progressObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let monitorQueue = DispatchQueue(label: "com.track.tileoffline.netmon")

    // UserDefaults keys
    private enum CacheKey {
        static let downloadedAt = "map_tile_pack_downloaded_at"
    }

    // MARK: - Init

    private init() {
        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            self.userDefaults = groupDefaults
        } else {
            self.userDefaults = .standard
        }

        // Restore state from disk on launch
        if let date = userDefaults.object(forKey: CacheKey.downloadedAt) as? Date {
            downloadState = .downloaded(date: date)
        }

        registerPackObservers()
    }

    deinit {
        if let obs = progressObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = errorObserver   { NotificationCenter.default.removeObserver(obs) }
        monitor.cancel()
    }

    // MARK: - Public API

    /// Call once on app launch. Downloads the pack only if:
    ///   - No valid pack exists on disk
    ///   - Or the existing pack is older than PACK_MAX_AGE
    ///   - And the device is on Wi-Fi
    func ensurePackDownloaded() async {
        guard MapLibreStyleConfig.hasAPIKey else {
            // No MapTiler key → offline tiles don't apply
            return
        }

        // Already downloading — don't double-queue
        if case .downloading = downloadState { return }

        // Fresh existing pack → skip
        if let date = userDefaults.object(forKey: CacheKey.downloadedAt) as? Date,
           Date().timeIntervalSince(date) < Self.PACK_MAX_AGE {
            downloadState = .downloaded(date: date)
            return
        }

        // Wait for Wi-Fi before downloading (respect user's data plan)
        let isOnWifi = await checkWifiAvailable()
        guard isOnWifi else {
            #if DEBUG
            print("[MapTileOfflineManager] Skipping download — not on Wi-Fi")
            #endif
            return
        }

        await downloadPack()
    }

    /// Explicitly trigger a tile pack download (e.g. from a Settings screen).
    func downloadPack() async {
        guard MapLibreStyleConfig.hasAPIKey else { return }
        guard case .downloading = downloadState else {
            startDownload()
            return
        }
    }

    /// Remove the offline pack from disk. Called from `OfflineCacheManager.clearCache()`.
    func deletePack() {
        let storage = MLNOfflineStorage.shared
        let packs = storage.packs ?? []
        for pack in packs {
            if isOurPack(pack) {
                storage.removePack(pack) { error in
                    Task { @MainActor in
                        let mgr = MapTileOfflineManager.shared
                        if let error {
                            #if DEBUG
                            print("[MapTileOfflineManager] Delete error: \(error)")
                            #endif
                        } else {
                            mgr.userDefaults.removeObject(forKey: CacheKey.downloadedAt)
                            mgr.downloadState = .notDownloaded
                            mgr.packSizeBytes = 0
                            #if DEBUG
                            print("[MapTileOfflineManager] ✅ Pack deleted")
                            #endif
                        }
                    }
                }
                return
            }
        }
        // No pack found on disk — just reset state
        userDefaults.removeObject(forKey: CacheKey.downloadedAt)
        downloadState = .notDownloaded
        packSizeBytes = 0
    }

    // MARK: - Private Helpers

    private func startDownload() {
        guard let styleURL = MapLibreStyleConfig.styleURL(isDarkMode: false) else { return }

        let region = MLNTilePyramidOfflineRegion(
            styleURL: styleURL,
            bounds: Self.nycBounds,
            fromZoomLevel: Self.MIN_ZOOM,
            toZoomLevel: Self.MAX_ZOOM
        )

        let contextData = Self.PACK_CONTEXT_TAG.data(using: .utf8) ?? Data()

        downloadState = .downloading(progress: 0)

        MLNOfflineStorage.shared.addPack(for: region, withContext: contextData) { [weak self] pack, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.downloadState = .failed(reason: error.localizedDescription)
                    #if DEBUG
                    print("[MapTileOfflineManager] ❌ addPack error: \(error)")
                    #endif
                    return
                }
                pack?.resume()
                #if DEBUG
                print("[MapTileOfflineManager] 🚀 Download started")
                #endif
            }
        }
    }

    private func registerPackObservers() {
        progressObserver = NotificationCenter.default.addObserver(
            forName: .MLNOfflinePackProgressChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract the pack reference on the calling thread (main queue)
            // to avoid capturing the non-Sendable Notification across actors.
            let pack = notification.object as? MLNOfflinePack
            Task { @MainActor [weak self] in
                guard let self, let pack else { return }
                self.handleProgressUpdate(pack: pack)
            }
        }

        errorObserver = NotificationCenter.default.addObserver(
            forName: .MLNOfflinePackError,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pack = notification.object as? MLNOfflinePack
            let userInfo = notification.userInfo
            let error = userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError
            Task { @MainActor [weak self] in
                guard let self, let pack, self.isOurPack(pack) else { return }
                let reason = error?.localizedDescription ?? "Unknown error"
                self.downloadState = .failed(reason: reason)
                #if DEBUG
                print("[MapTileOfflineManager] ❌ Download error: \(reason)")
                #endif
            }
        }
    }

    private func handleProgressUpdate(pack: MLNOfflinePack) {
        guard isOurPack(pack) else { return }

        let progress = pack.progress
        let completed = progress.countOfResourcesCompleted
        let expected = progress.countOfResourcesExpected

        packSizeBytes = progress.countOfBytesCompleted

        guard expected > 0 else { return }

        let pct = Float(completed) / Float(expected)

        if pack.state == .complete {
            let now = Date()
            userDefaults.set(now, forKey: CacheKey.downloadedAt)
            downloadState = .downloaded(date: now)
            #if DEBUG
            let mb = String(format: "%.1f", Double(packSizeBytes) / 1_048_576)
            print("[MapTileOfflineManager] ✅ Download complete — \(mb) MB")
            #endif
        } else {
            downloadState = .downloading(progress: pct)
        }
    }

    /// Identifies a pack as belonging to Track using the context tag.
    private func isOurPack(_ pack: MLNOfflinePack) -> Bool {
        guard let tag = String(data: pack.context, encoding: .utf8) else { return false }
        return tag == Self.PACK_CONTEXT_TAG
    }

    private func checkWifiAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
            // nonisolated actor box so the flag survives cross-thread access
            let box = ContinuationBox(continuation)
            wifiMonitor.pathUpdateHandler = { path in
                guard box.tryResume() else { return }
                wifiMonitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            wifiMonitor.start(queue: DispatchQueue(label: "com.track.tileoffline.wifi-check"))
            // 2-second timeout if no path update fires
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                guard box.tryResume() else { return }
                wifiMonitor.cancel()
                continuation.resume(returning: false)
            }
        }
    }
}
