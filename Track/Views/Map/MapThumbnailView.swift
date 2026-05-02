// MapThumbnailView.swift
// Track
//
// A SwiftUI view that renders a static map thumbnail for a coordinate using
// MLNMapSnapshotter — no live MLNMapView needed. Thumbnails are cached
// in-memory by coordinate + size + dark-mode, so repeated renders of the
// same place (e.g., Favorites cards) are instant after the first load.
//
// Usage:
//   MapThumbnailView(
//       coordinate: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
//       zoom: 14,
//       size: CGSize(width: 120, height: 80)
//   )

import CoreLocation
import MapLibre
import SwiftUI

// MARK: - Cache

/// Thread-safe in-memory cache for rendered map snapshots.
/// Key: "lat,lon@zoom-WxH-dark" — deterministic from inputs.
@MainActor
final class MapThumbnailCache {
    static let shared = MapThumbnailCache()
    private init() {}

    private var cache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Maximum number of cached images. LRU eviction once exceeded.
    private let maxEntries = 60
    private var insertionOrder: [String] = []

    func thumbnail(
        for coordinate: CLLocationCoordinate2D,
        zoom: Double,
        size: CGSize,
        isDark: Bool
    ) async -> UIImage? {
        let key = cacheKey(coordinate, zoom: zoom, size: size, isDark: isDark)

        // 1. Cache hit — instant return
        if let cached = cache[key] { return cached }

        // 2. Already generating — await the same task to avoid duplicate snapshots
        if let existing = inFlight[key] { return await existing.value }

        // 3. Launch a new snapshot task
        let task: Task<UIImage?, Never> = Task { [weak self] in
            let image = await self?.generateSnapshot(
                coordinate: coordinate,
                zoom: zoom,
                size: size,
                isDark: isDark
            )
            if let image {
                await MainActor.run {
                    self?.store(image, key: key)
                }
            }
            await MainActor.run { self?.inFlight.removeValue(forKey: key) }
            return image
        }
        inFlight[key] = task
        return await task.value
    }

    private func generateSnapshot(
        coordinate: CLLocationCoordinate2D,
        zoom: Double,
        size: CGSize,
        isDark: Bool
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = MLNMapSnapshotOptions(
                styleURL: MapLibreStyleConfig.styleURL(isDarkMode: isDark),
                camera: {
                    let cam = MLNMapCamera()
                    cam.centerCoordinate = coordinate
                    // altitude that roughly corresponds to the requested zoom
                    // MapLibre: altitude ≈ 78_271_484 / 2^zoom (meters at equator)
                    cam.altitude = 78_271_484 / pow(2.0, zoom)
                    return cam
                }(),
                size: size
            )
            let snapshotter = MLNMapSnapshotter(options: options)
            snapshotter.start { snapshot, error in
                if let error {
                    #if DEBUG
                    print("[MapThumbnail] Snapshot error: \(error.localizedDescription)")
                    #endif
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: snapshot?.image)
                }
            }
        }
    }

    private func store(_ image: UIImage, key: String) {
        // LRU-style eviction
        if cache.count >= maxEntries, let oldest = insertionOrder.first {
            cache.removeValue(forKey: oldest)
            insertionOrder.removeFirst()
        }
        cache[key] = image
        insertionOrder.append(key)
    }

    private func cacheKey(
        _ coord: CLLocationCoordinate2D,
        zoom: Double,
        size: CGSize,
        isDark: Bool
    ) -> String {
        // 4 decimal places ≈ 11m precision — fine for card thumbnails
        String(
            format: "%.4f,%.4f@%.1f-%.0fx%.0f-%@",
            coord.latitude, coord.longitude, zoom,
            size.width, size.height,
            isDark ? "dark" : "light"
        )
    }
}

// MARK: - SwiftUI View

/// A fixed-size SwiftUI view that renders a static map snapshot for a given
/// coordinate. Shows a shimmer placeholder while the snapshot is generating.
///
/// Example:
/// ```swift
/// MapThumbnailView(
///     coordinate: station.coordinate,
///     zoom: 14,
///     size: CGSize(width: 120, height: 80)
/// )
/// .cornerRadius(10)
/// .clipped()
/// ```
struct MapThumbnailView: View {
    let coordinate: CLLocationCoordinate2D
    var zoom: Double = 14.0
    var size: CGSize = CGSize(width: 120, height: 80)

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    @State private var isLoading = true

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                shimmer
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: "\(coordinate.latitude),\(coordinate.longitude),\(isDark)") {
            isLoading = true
            image = nil
            let result = await MapThumbnailCache.shared.thumbnail(
                for: coordinate,
                zoom: zoom,
                size: size,
                isDark: isDark
            )
            withAnimation(.easeIn(duration: 0.2)) {
                image = result
                isLoading = false
            }
        }
    }

    // MARK: - Shimmer placeholder

    private var shimmer: some View {
        RoundedRectangle(cornerRadius: 0)
            .fill(AppTheme.Colors.cardInset.opacity(0.6))
            .shimmer(active: isLoading)
    }
}
