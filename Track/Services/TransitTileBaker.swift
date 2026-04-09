// Bakes flattened transit polylines into GeoJSON FeatureCollection files
// on disk so MapLibre can load them directly as vector tile sources.
//
// This eliminates the per-frame `buildPolylineFeatures()` loop that
// converts Swift structs → MLNPolylineFeature → MLNShapeCollectionFeature.
// Instead, MapLibre streams the GeoJSON file and tiles it internally on
// its background threads, freeing the main thread entirely.
//
// Baked files live in the App Group container alongside the flattened
// polyline cache. They are regenerated whenever the flattened cache is
// written (after a network refresh) and are stable across launches.
//
// Architecture:
// ┌──────────────────────────────────────┐
// │  flattenedSubwayPolylines            │
// │  flattenedCommuterRailPolylines      │
// │  cachedCrossings                     │
// │           ↓  TransitTileBaker.bake() │
// │  subway_fill.geojson                 │
// │  subway_casing.geojson               │
// │  elevated_fill.geojson               │
// │  elevated_casing.geojson             │
// │  commuter.geojson                    │
// │           ↓  MLNShapeSource(url:)    │
// │  MapLibre GPU pipeline               │
// └──────────────────────────────────────┘

import CoreLocation
import Foundation

/// Bakes flattened transit polylines into GeoJSON files for MapLibre.
///
/// All methods are `nonisolated` — they do pure I/O and JSON serialization
/// with no shared mutable state, safe for `Task.detached` background work.
///
/// Explicitly `nonisolated` to prevent Swift 6.2 from inferring `@MainActor`
/// isolation (the enum is referenced from `@MainActor` contexts but does
/// no UI work).
nonisolated enum TransitTileBaker {

    // MARK: - Public Types

    /// Input data for the bake pipeline.
    struct BakeInput {
        let subwayFill: [PolylineData]
        let subwayCasing: [PolylineData]
        let elevatedFill: [PolylineData]
        let elevatedCasing: [PolylineData]
        let commuter: [PolylineData]
    }

    /// Minimal polyline representation for baking — avoids importing
    /// MapSystemViewModel or SwiftUI Color into this pure-data module.
    struct PolylineData {
        let coordinates: [CLLocationCoordinate2D]
        let colorHex: String
        let trunkIndex: Int
        let laneOffset: Double
        let routeIds: [String]
        let isElevated: Bool
    }

    /// Result of a successful bake — file URLs for each layer source.
    struct BakedTileSet {
        let subwayFillURL: URL
        let subwayCasingURL: URL
        let elevatedFillURL: URL
        let elevatedCasingURL: URL
        let commuterURL: URL

        /// Whether all files exist on disk.
        var isValid: Bool {
            let fm = FileManager.default
            return fm.fileExists(atPath: subwayFillURL.path)
                && fm.fileExists(atPath: subwayCasingURL.path)
                && fm.fileExists(atPath: elevatedFillURL.path)
                && fm.fileExists(atPath: elevatedCasingURL.path)
                && fm.fileExists(atPath: commuterURL.path)
        }
    }

    // MARK: - Bus Tile Types

    /// Minimal bus route data for baking — coordinates + color.
    struct BusRouteData {
        let routeId: String
        let coordinates: [[CLLocationCoordinate2D]]
        let colorHex: String
    }

    /// Minimal bus stop data for baking — position + name.
    struct BusStopData {
        let stopId: String
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    /// Result of a bus tile bake — GeoJSON file URLs for routes and stops.
    struct BakedBusTileSet {
        let routesURL: URL
        let stopsURL: URL

        /// Whether all bus tile files exist on disk.
        var isValid: Bool {
            let fm = FileManager.default
            return fm.fileExists(atPath: routesURL.path)
                && fm.fileExists(atPath: stopsURL.path)
        }
    }

    // MARK: - File Names

    /// Bake version tag — combines a manual schema version with the
    /// pipeline fingerprint hash so baked tiles auto-invalidate whenever
    /// any flattening constant changes.  No manual bumps needed for
    /// algorithm tweaks; only bump `schemaVersion` when the GeoJSON
    /// *structure* changes (new properties, coordinate encoding, etc.).
    ///
    /// History:
    /// v2: Fixed polyline precision (1e6 → 1e5).
    /// v3: Client applies Catmull-Rom smoothing to server trunk polylines.
    /// v4: Tied to PipelineFingerprint — auto-invalidates on constant changes.
    private static let schemaVersion = 4
    private static var bakeTag: String {
        "v\(schemaVersion)_\(PipelineFingerprint.shortHash)"
    }

    private static var subwayFillFile: String { "baked_subway_fill_\(bakeTag).geojson" }
    private static var subwayCasingFile: String { "baked_subway_casing_\(bakeTag).geojson" }
    private static var elevatedFillFile: String { "baked_elevated_fill_\(bakeTag).geojson" }
    private static var elevatedCasingFile: String { "baked_elevated_casing_\(bakeTag).geojson" }
    private static var commuterFile: String { "baked_commuter_\(bakeTag).geojson" }
    private static var busRoutesFile: String { "baked_bus_routes_\(bakeTag).geojson" }
    private static var busStopsFile: String { "baked_bus_stops_\(bakeTag).geojson" }

    /// All file names for the current version.
    static var allFileNames: [String] {
        [
            subwayFillFile, subwayCasingFile,
            elevatedFillFile, elevatedCasingFile,
            commuterFile,
            busRoutesFile, busStopsFile,
        ]
    }

    // MARK: - Bake

    /// Converts flattened polylines into GeoJSON FeatureCollection files.
    ///
    /// This is a pure CPU + I/O operation — no MainActor, no UI.
    /// Call from `Task.detached(priority: .utility)`.
    ///
    /// - Parameters:
    ///   - input: The polyline data split by layer.
    ///   - directory: The directory to write GeoJSON files into.
    /// - Returns: A `BakedTileSet` with file URLs, or `nil` on failure.
    static func bake(_ input: BakeInput, to directory: URL) -> BakedTileSet? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Clean up old versions
        cleanOldVersions(in: directory)

        let subwayFillURL = directory.appendingPathComponent(subwayFillFile)
        let subwayCasingURL = directory.appendingPathComponent(subwayCasingFile)
        let elevatedFillURL = directory.appendingPathComponent(elevatedFillFile)
        let elevatedCasingURL = directory.appendingPathComponent(elevatedCasingFile)
        let commuterURL = directory.appendingPathComponent(commuterFile)

        // Build and write each GeoJSON file
        let pairs: [(url: URL, polylines: [PolylineData])] = [
            (subwayFillURL, input.subwayFill),
            (subwayCasingURL, input.subwayCasing),
            (elevatedFillURL, input.elevatedFill),
            (elevatedCasingURL, input.elevatedCasing),
            (commuterURL, input.commuter),
        ]

        for (url, polylines) in pairs {
            let geojson = buildGeoJSON(from: polylines)
            guard writeJSON(geojson, to: url) else { return nil }
        }

        return BakedTileSet(
            subwayFillURL: subwayFillURL,
            subwayCasingURL: subwayCasingURL,
            elevatedFillURL: elevatedFillURL,
            elevatedCasingURL: elevatedCasingURL,
            commuterURL: commuterURL
        )
    }

    /// Returns file URLs for previously baked tiles (nil if any file is missing).
    static func loadExisting(from directory: URL) -> BakedTileSet? {
        let tileSet = BakedTileSet(
            subwayFillURL: directory.appendingPathComponent(subwayFillFile),
            subwayCasingURL: directory.appendingPathComponent(subwayCasingFile),
            elevatedFillURL: directory.appendingPathComponent(elevatedFillFile),
            elevatedCasingURL: directory.appendingPathComponent(elevatedCasingFile),
            commuterURL: directory.appendingPathComponent(commuterFile)
        )
        return tileSet.isValid ? tileSet : nil
    }

    // MARK: - Bus Tile Baking

    /// Bakes all bus route polylines and stops into GeoJSON files.
    ///
    /// Designed for the bus system map: when the user switches to the
    /// Bus tab, MapLibre loads these files directly via its C++ parser
    /// for zero-lag rendering of the entire NYC bus network.
    ///
    /// - Parameters:
    ///   - routes: All bus route data (decoded polylines).
    ///   - stops: All bus stop data.
    ///   - directory: The directory to write GeoJSON files into.
    /// - Returns: A `BakedBusTileSet` with file URLs, or `nil` on failure.
    static func bakeBus(
        routes: [BusRouteData],
        stops: [BusStopData],
        to directory: URL
    ) -> BakedBusTileSet? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let routesURL = directory.appendingPathComponent(busRoutesFile)
        let stopsURL = directory.appendingPathComponent(busStopsFile)

        // Build bus routes GeoJSON
        let routesGeoJSON = buildBusRoutesGeoJSON(from: routes)
        guard writeJSON(routesGeoJSON, to: routesURL) else { return nil }

        // Build bus stops GeoJSON
        let stopsGeoJSON = buildBusStopsGeoJSON(from: stops)
        guard writeJSON(stopsGeoJSON, to: stopsURL) else { return nil }

        return BakedBusTileSet(routesURL: routesURL, stopsURL: stopsURL)
    }

    /// Returns file URLs for previously baked bus tiles (nil if any file missing).
    static func loadExistingBus(from directory: URL) -> BakedBusTileSet? {
        let tileSet = BakedBusTileSet(
            routesURL: directory.appendingPathComponent(busRoutesFile),
            stopsURL: directory.appendingPathComponent(busStopsFile)
        )
        return tileSet.isValid ? tileSet : nil
    }

    // MARK: - Bus GeoJSON Building

    /// Builds a GeoJSON FeatureCollection for bus routes.
    ///
    /// Each route's polyline segments become LineString features with
    /// properties: `route_id`, `color`.
    private static func buildBusRoutesGeoJSON(
        from routes: [BusRouteData]
    ) -> [String: Any] {
        var features: [[String: Any]] = []

        for route in routes {
            for polyline in route.coordinates {
                guard polyline.count >= 2 else { continue }

                let coords: [[Double]] = polyline.map {
                    [$0.longitude, $0.latitude]
                }

                let feature: [String: Any] = [
                    "type": "Feature",
                    "properties": [
                        "route_id": route.routeId,
                        "color": "#\(route.colorHex)",
                    ] as [String: Any],
                    "geometry": [
                        "type": "LineString",
                        "coordinates": coords,
                    ] as [String: Any],
                ]
                features.append(feature)
            }
        }

        return [
            "type": "FeatureCollection",
            "features": features,
        ]
    }

    /// Builds a GeoJSON FeatureCollection for bus stops.
    ///
    /// Each stop becomes a Point feature with properties: `stop_id`, `name`.
    private static func buildBusStopsGeoJSON(
        from stops: [BusStopData]
    ) -> [String: Any] {
        var features: [[String: Any]] = []
        features.reserveCapacity(stops.count)

        for stop in stops {
            let feature: [String: Any] = [
                "type": "Feature",
                "properties": [
                    "stop_id": stop.stopId,
                    "name": stop.name,
                ] as [String: Any],
                "geometry": [
                    "type": "Point",
                    "coordinates": [
                        stop.coordinate.longitude,
                        stop.coordinate.latitude,
                    ],
                ] as [String: Any],
            ]
            features.append(feature)
        }

        return [
            "type": "FeatureCollection",
            "features": features,
        ]
    }

    // MARK: - GeoJSON Building

    /// Builds a GeoJSON FeatureCollection dictionary from polyline data.
    ///
    /// Each polyline becomes a Feature with a LineString geometry and
    /// properties matching the attributes MapLibre layers expect:
    /// `color`, `trunk_index`, `lane_offset`, `isLIRR`, `isMNR`.
    private static func buildGeoJSON(
        from polylines: [PolylineData]
    ) -> [String: Any] {
        var features: [[String: Any]] = []
        features.reserveCapacity(polylines.count)

        for polyline in polylines {
            guard polyline.coordinates.count >= 2 else { continue }

            // GeoJSON coordinates are [longitude, latitude] (not lat/lon)
            let coords: [[Double]] = polyline.coordinates.map {
                [$0.longitude, $0.latitude]
            }

            let isLIRR = polyline.routeIds.contains {
                $0.uppercased().hasPrefix("LIRR")
            }
            let isMNR = polyline.routeIds.contains {
                $0.uppercased().hasPrefix("MNR")
            }

            let feature: [String: Any] = [
                "type": "Feature",
                "properties": [
                    "color": polyline.colorHex,
                    "trunk_index": polyline.trunkIndex,
                    "lane_offset": polyline.laneOffset,
                    "isLIRR": isLIRR,
                    "isMNR": isMNR,
                ] as [String: Any],
                "geometry": [
                    "type": "LineString",
                    "coordinates": coords,
                ] as [String: Any],
            ]
            features.append(feature)
        }

        return [
            "type": "FeatureCollection",
            "features": features,
        ]
    }

    // MARK: - Casing with Crossing Gaps

    /// Splits polylines at crossing points to create the over/under effect.
    ///
    /// This is the baked equivalent of `buildCasingFeatures()` in
    /// `MapLibreMapView` — the gaps are pre-computed and written into
    /// the GeoJSON so MapLibre never needs to compute them at render time.
    static func buildCasingPolylines(
        from polylines: [PolylineData],
        crossings: [CrossingData]
    ) -> [PolylineData] {
        guard !crossings.isEmpty else { return polylines }

        var result: [PolylineData] = []

        for polyline in polylines {
            guard polyline.coordinates.count >= 2 else { continue }

            // Find crossing indices where this trunk is the LOWER one
            var breakIndices: [Int] = []
            let coords = polyline.coordinates

            for crossing in crossings {
                guard crossing.trunkIndices.count >= 2 else { continue }
                let myTrunk = polyline.trunkIndex
                guard crossing.trunkIndices.contains(myTrunk) else { continue }
                let otherTrunk = crossing.trunkIndices
                    .first(where: { $0 != myTrunk }) ?? myTrunk
                // Only break the LOWER trunk's casing
                guard myTrunk < otherTrunk else { continue }

                // Find nearest vertex to crossing
                let cLat = crossing.lat
                let cLng = crossing.lng
                var bestDist = Double.infinity
                var bestIdx = -1

                for i in coords.indices {
                    let dLat = coords[i].latitude - cLat
                    let dLng = coords[i].longitude - cLng
                    let dist = dLat * dLat + dLng * dLng
                    if dist < bestDist {
                        bestDist = dist
                        bestIdx = i
                    }
                }

                // ~50m threshold (in degrees²: 0.00045² ≈ 2e-7)
                if bestDist < 2.0e-7 && bestIdx > 1 && bestIdx < coords.count - 2 {
                    breakIndices.append(bestIdx)
                }
            }

            if breakIndices.isEmpty {
                result.append(polyline)
            } else {
                // Split polyline at break points with small gaps
                let sorted = breakIndices.sorted()
                let gapSize = 2  // skip 2 vertices each side of crossing
                var segStart = 0

                for breakIdx in sorted {
                    let segEnd = max(segStart, breakIdx - gapSize)
                    if segEnd > segStart + 1 {
                        let segment = Array(coords[segStart...segEnd])
                        result.append(PolylineData(
                            coordinates: segment,
                            colorHex: polyline.colorHex,
                            trunkIndex: polyline.trunkIndex,
                            laneOffset: polyline.laneOffset,
                            routeIds: polyline.routeIds,
                            isElevated: polyline.isElevated
                        ))
                    }
                    segStart = min(coords.count - 1, breakIdx + gapSize)
                }

                // Emit trailing segment
                if segStart < coords.count - 1 {
                    let segment = Array(coords[segStart...])
                    result.append(PolylineData(
                        coordinates: segment,
                        colorHex: polyline.colorHex,
                        trunkIndex: polyline.trunkIndex,
                        laneOffset: polyline.laneOffset,
                        routeIds: polyline.routeIds,
                        isElevated: polyline.isElevated
                    ))
                }
            }
        }

        return result
    }

    /// Minimal crossing point data for baking (avoids importing SubwayModels).
    struct CrossingData {
        let lat: Double
        let lng: Double
        let trunkIndices: [Int]
    }

    // MARK: - File I/O

    /// Writes a JSON dictionary to a file atomically.
    private static func writeJSON(_ dict: [String: Any], to url: URL) -> Bool {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: dict,
                options: []  // No pretty-print — smaller file, faster parse
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Removes baked GeoJSON files from older versions.
    private static func cleanOldVersions(in directory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        let currentFiles = Set(allFileNames)
        for file in contents where file.hasPrefix("baked_") && file.hasSuffix(".geojson") {
            if !currentFiles.contains(file) {
                try? fm.removeItem(
                    at: directory.appendingPathComponent(file)
                )
            }
        }
    }
}
