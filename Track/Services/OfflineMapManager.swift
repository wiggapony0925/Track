//
//  OfflineMapManager.swift
//  Track
//
//  Phase C — pre-downloads NYC base-map tiles, sprites, and glyphs into
//  MapLibre's built-in offline storage so the map renders fully when
//  the device is offline.  Uses `MLNOfflineStorage` and
//  `MLNTilePyramidOfflineRegion`, which are part of the MapLibre Native
//  iOS SDK already linked into the app — no MBTiles or extra backend
//  endpoint needed.
//
//  Behavior:
//      • On first launch (or when no NYC pack exists), enqueues a low-
//        priority background download of the NYC bbox at zoom 10–15.
//        That covers neighborhood detail without ballooning the cache
//        beyond ~80 MB on disk.
//      • Idempotent — calling `bootstrap()` repeatedly is a no-op once
//        the pack is downloading or complete.
//      • The base style URL is the same one the live map uses
//        (`MapLibreStyleConfig.lightStyleURL`), so the offline cache
//        seamlessly serves the same tiles MapLibre would otherwise
//        fetch from the network.
//
//  We deliberately do NOT swap to a different "offline style" — the
//  remote style URL is the cache key, and once the pack downloads it,
//  MapLibre serves the tiles from disk transparently when the network
//  is unreachable.
//

import Foundation
import MapLibre

@MainActor
public final class OfflineMapManager: NSObject {
    public static let shared = OfflineMapManager()

    /// NYC bounding box — Staten Island SW corner to north Bronx NE.
    /// Slightly padded so panning to the river edges still hits cache.
    private static let nycBounds = MLNCoordinateBounds(
        sw: CLLocationCoordinate2D(latitude: 40.45, longitude: -74.30),
        ne: CLLocationCoordinate2D(latitude: 40.95, longitude: -73.65)
    )

    /// Zoom range — 10 covers the whole metro, 15 is street-level detail.
    /// Going higher than 15 doubles the tile count per step and is
    /// rarely needed for transit search.
    private static let minZoom: Double = 10
    private static let maxZoom: Double = 15

    /// User-defined region context (stored inside the pack so we can
    /// recognise "our" pack on subsequent launches).
    private static let regionName = "nyc-basemap-v1"

    private var didBootstrap = false
    private var observer: NSObjectProtocol?

    /// Idempotent.  Call once from `TrackApp` init.  If the NYC pack
    /// already exists this returns immediately; otherwise it kicks off
    /// a background download.
    public func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        let storage = MLNOfflineStorage.shared
        // `packs` is populated lazily; ask MapLibre to load them now.
        storage.reloadPacks()

        // `reloadPacks` is asynchronous (it dispatches a load on a
        // background queue) — give it a moment, then check.  We use
        // KVO-friendly notification rather than blocking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let existing = (storage.packs ?? []).first { pack in
                Self.contextName(from: pack.context) == Self.regionName
            }
            if let existing {
                let pct = existing.progress.maximumResourcesExpected > 0
                    ? Int(100.0 * Double(existing.progress.countOfResourcesCompleted)
                        / Double(existing.progress.maximumResourcesExpected))
                    : 0
                NSLog("[OfflineMap] pack already exists — state=\(existing.state.rawValue) progress=\(pct)%")
                if existing.state != .complete {
                    existing.resume()
                }
                return
            }
            self.createPack()
        }

        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.MLNOfflinePackProgressChanged,
            object: nil,
            queue: .main
        ) { note in
            guard let pack = note.object as? MLNOfflinePack,
                  Self.contextName(from: pack.context) == Self.regionName else { return }
            let p = pack.progress
            if p.countOfResourcesCompleted == p.maximumResourcesExpected,
               p.maximumResourcesExpected > 0 {
                NSLog("[OfflineMap] ✓ NYC base-map pack downloaded — \(p.countOfResourcesCompleted) tiles, \(p.countOfBytesCompleted / (1024*1024)) MB")
            }
        }
    }

    private func createPack() {
        guard let styleURL = MapLibreStyleConfig.lightStyleURL else {
            NSLog("[OfflineMap] no style URL — skipping offline pack")
            return
        }

        let region = MLNTilePyramidOfflineRegion(
            styleURL: styleURL,
            bounds: Self.nycBounds,
            fromZoomLevel: Self.minZoom,
            toZoomLevel: Self.maxZoom
        )

        let context = Self.makeContext(name: Self.regionName)

        MLNOfflineStorage.shared.addPack(
            for: region,
            withContext: context
        ) { pack, error in
            if let error {
                NSLog("[OfflineMap] addPack failed: \(error.localizedDescription)")
                return
            }
            guard let pack else { return }
            NSLog("[OfflineMap] starting NYC base-map download (zoom \(Int(Self.minZoom))–\(Int(Self.maxZoom)))")
            pack.resume()
        }
    }

    // MARK: - Context (de)serialisation

    /// MapLibre stores arbitrary `Data` per pack so we can recognise
    /// our own pack and avoid duplicate downloads.  Stash a JSON
    /// `{ "name": "nyc-basemap-v1" }` blob.
    private static func makeContext(name: String) -> Data {
        let payload: [String: String] = ["name": name]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    private static func contextName(from data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return obj["name"]
    }
}
