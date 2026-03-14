//
//  MapLibreStyleConfig.swift
//  Track
//
//  OpenStreetMap tile source configuration for MapLibre GL.
//  Supports MapTiler vector tiles (free tier) with a muted transit
//  style that mirrors the Apple Maps "standard muted" look.
//
//  The app uses OSM data through MapTiler's vector tile API, which
//  provides pre-rendered OpenStreetMap tiles optimized for mobile
//  rendering via MapLibre's GPU-accelerated pipeline.
//
//  References:
//  - MapTiler API: https://docs.maptiler.com/cloud/api/maps/
//  - MapLibre Style Spec: https://maplibre.org/maplibre-style-spec/
//  - OSM tile usage: https://wiki.openstreetmap.org/wiki/Raster_tile_providers
//

import Foundation
import MapLibre
import UIKit

// MARK: - MapLibre Style Configuration

/// Centralized configuration for MapLibre GL tile sources and style URLs.
/// All OSM/MapTiler configuration lives here — no magic strings elsewhere.
enum MapLibreStyleConfig {

    // MARK: - Typed Expression Helpers

    /// Convenience: zoom-interpolated expression (exponential curve).
    /// Avoids the deprecated `mgl_interpolate:withCurveType:parameters:stops:`
    /// NSPredicate format string that triggers "forbidden" warnings on iOS 17+.
    private static func zoomInterpolate(
        base: Double,
        stops: [Double: Double]
    ) -> NSExpression {
        NSExpression(
            forMLNInterpolating: .zoomLevelVariable,
            curveType: base == 1.0
                ? .linear
                : .exponential,
            parameters: base == 1.0
                ? nil
                : NSExpression(forConstantValue: base),
            stops: NSExpression(forConstantValue: stops)
        )
    }

    // MARK: - API Key

    /// MapTiler API key for vector tile access.
    ///
    /// **Important**: Replace with your own key from https://cloud.maptiler.com/account/keys/
    /// The free tier includes 100k tile requests/month — sufficient for development.
    /// For production, use an environment variable or Info.plist entry.
    static var mapTilerAPIKey: String {
        // Check Info.plist first (production), fall back to hardcoded dev key
        if let key = Bundle.main.object(forInfoDictionaryKey: "MAPTILER_API_KEY") as? String,
           !key.isEmpty {
            return key
        }
        // Development fallback — replace with your key
        return "YOUR_MAPTILER_KEY"
    }

    // MARK: - Style URLs

    /// MapTiler Streets style — clean, OSM-powered vector tiles with transit POIs.
    /// Comparable to Apple Maps "standard" but using OpenStreetMap data.
    static var streetsStyleURL: URL? {
        URL(string: "https://api.maptiler.com/maps/streets-v2/style.json?key=\(mapTilerAPIKey)")
    }

    /// MapTiler Muted/Pastel style — reduced contrast, ideal for overlaying
    /// transit lines (similar to Apple Maps "muted" emphasis).
    static var mutedStyleURL: URL? {
        URL(string: "https://api.maptiler.com/maps/pastel/style.json?key=\(mapTilerAPIKey)")
    }

    /// MapTiler Dark style — for dark mode support.
    static var darkStyleURL: URL? {
        URL(string: "https://api.maptiler.com/maps/dataviz-dark/style.json?key=\(mapTilerAPIKey)")
    }

    /// The default style URL used by the app.
    /// Uses MapTiler pastel if a valid API key exists, otherwise nil
    /// (triggers OSM raster tile fallback in MapLibreMapView).
    static var defaultStyleURL: URL? {
        guard hasAPIKey else { return nil }
        return mutedStyleURL
    }

    // MARK: - Fallback Raster Tiles (no API key needed)

    /// OSM standard raster tile URL template — free, no key required.
    /// Used as a fallback if MapTiler API key is not configured.
    /// Note: Must comply with OSM tile usage policy (max 2 req/sec, proper User-Agent).
    static let osmRasterTileURL = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"

    /// Builds a MapLibre style JSON for OSM raster tiles and writes it
    /// to a temporary file. Returns the file URL that MapLibre can load.
    /// This is more reliable than data: URIs which some MapLibre versions reject.
    static func osmRasterStyleJSON() -> URL? {
        let style: [String: Any] = [
            "version": 8,
            "name": "OSM Raster",
            "sources": [
                "osm-raster": [
                    "type": "raster",
                    "tiles": [osmRasterTileURL],
                    "tileSize": 256,
                    "attribution": osmAttribution
                ] as [String: Any]
            ],
            "layers": [
                [
                    "id": "osm-raster-layer",
                    "type": "raster",
                    "source": "osm-raster",
                    "minzoom": 0,
                    "maxzoom": 19
                ] as [String: Any]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: style, options: .prettyPrinted) else {
            return nil
        }
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("osm_raster_style.json")
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    /// Attribution string required by OSM tile usage policy.
    static let osmAttribution = "© OpenStreetMap contributors"

    /// MapTiler attribution (required by their ToS).
    static let mapTilerAttribution = "© MapTiler © OpenStreetMap contributors"

    // MARK: - Zoom Limits

    /// Minimum zoom level (fully zoomed out — shows whole NYC metro).
    static let minZoom: Double = 8.0

    /// Maximum zoom level (street-level detail).
    static let maxZoom: Double = 20.0

    /// Default zoom level for initial view (neighborhood overview).
    static let defaultZoom: Double = 13.0

    // MARK: - Helpers

    /// Whether a valid MapTiler API key is configured.
    static var hasAPIKey: Bool {
        mapTilerAPIKey != "YOUR_MAPTILER_KEY" && !mapTilerAPIKey.isEmpty
    }

    /// Returns the correct style URL based on dark mode preference.
    static func styleURL(isDarkMode: Bool) -> URL? {
        guard hasAPIKey else { return nil }
        return isDarkMode ? darkStyleURL : mutedStyleURL
    }

    // MARK: - Transit-Style Rendering Configuration
    //
    // Premium transit map rendering — bolder than Apple Maps, cleaner than
    // Transit, smoother than Uber/Lyft.  Every expression is tuned for a
    // "floating neon" effect: saturated colored fills float above soft
    // translucent casings, with buttery exponential zoom scaling.

    /// Subway fill line width — bold and prominent at every zoom.
    /// Wider than Transit app for better readability with dense NYC coverage.
    /// Exponential base 1.6 gives a natural acceleration curve.
    static let subwayFillWidth = zoomInterpolate(
        base: 1.6,
        stops: [10: 1.2, 11: 1.6, 12: 2.2, 13: 2.8, 14: 3.5, 15: 4.2, 16: 5.0, 17: 6.0, 18: 7.0]
    )

    /// Subway casing width — soft border that gives lines a floating-above-map feel.
    /// The casing-to-fill ratio is ~1.6×, creating a subtle halo rather than a harsh edge.
    static let subwayCasingWidth = zoomInterpolate(
        base: 1.6,
        stops: [10: 2.4, 11: 3.0, 12: 4.0, 13: 5.0, 14: 6.0, 15: 7.0, 16: 8.5, 17: 10.0, 18: 12.0]
    )

    /// Elevated line fill width — matches subway for visual consistency.
    static let elevatedFillWidth = subwayFillWidth

    /// Elevated casing width — extra-wide for a pronounced shadow/depth effect
    /// that distinguishes above-ground structure from tunnels.
    static let elevatedCasingWidth = zoomInterpolate(
        base: 1.6,
        stops: [10: 3.0, 11: 3.5, 12: 4.5, 13: 5.5, 14: 7.0, 15: 8.0, 16: 10.0, 17: 12.0, 18: 14.0]
    )

    /// Commuter rail fill width — thinner than subway to establish visual hierarchy.
    /// Still bold enough to be clearly visible at overview zoom.
    static let commuterFillWidth = zoomInterpolate(
        base: 1.5,
        stops: [10: 0.8, 11: 1.0, 12: 1.5, 13: 2.0, 14: 2.5, 16: 3.5, 18: 4.5]
    )

    /// Commuter rail casing width — border for dashed commuter lines.
    static let commuterCasingWidth = zoomInterpolate(
        base: 1.5,
        stops: [10: 1.8, 11: 2.2, 12: 3.0, 13: 3.5, 14: 4.5, 16: 6.0, 18: 7.5]
    )

    /// Active route fill width (when a specific route is selected) — extra bold
    /// so the selected route clearly dominates the dimmed system map.
    static let routeFillWidth = zoomInterpolate(
        base: 1.6,
        stops: [10: 2.5, 12: 3.5, 14: 5.0, 16: 6.0, 18: 7.5]
    )

    /// Active route casing width — generous border for a premium floating effect.
    static let routeCasingWidth = zoomInterpolate(
        base: 1.6,
        stops: [10: 4.0, 12: 6.0, 14: 8.0, 16: 9.5, 18: 11.0]
    )

    /// Station circle dot radius — starts visible earlier, grows to prominent dots.
    static let stationDotRadius = zoomInterpolate(
        base: 1.4,
        stops: [11: 1.8, 12: 2.5, 13: 3.2, 14: 4.0, 15: 5.0, 16: 6.5, 17: 8.0, 18: 9.5]
    )

    /// Transfer station dot radius — noticeably larger than single-line stops
    /// to highlight important interchange stations.
    static let transferDotRadius = zoomInterpolate(
        base: 1.4,
        stops: [11: 2.5, 12: 3.5, 13: 4.5, 14: 5.5, 15: 7.0, 16: 8.5, 17: 10.0, 18: 12.0]
    )

    /// Station dot stroke width — crisp border at all zoom levels.
    static let stationDotStrokeWidth = zoomInterpolate(
        base: 1.3,
        stops: [11: 0.8, 13: 1.2, 15: 1.8, 17: 2.2, 18: 2.5]
    )

    /// Station label font size — legible even at zoom 14.
    static let stationLabelFontSize = zoomInterpolate(
        base: 1.0,
        stops: [14: 9.0, 15: 10.0, 16: 11.0, 17: 12.0, 18: 13.0]
    )

    /// Walking route width — dashed line for pedestrian directions.
    static let walkingRouteWidth = zoomInterpolate(
        base: 1.5,
        stops: [10: 2.5, 14: 3.5, 16: 4.5, 18: 5.5]
    )

    /// Walking route glow width (wider, translucent for depth).
    static let walkingRouteGlowWidth = zoomInterpolate(
        base: 1.5,
        stops: [10: 5.0, 14: 7.0, 16: 9.0, 18: 11.0]
    )

    // MARK: - Dynamic Corridor Lane Offset
    //
    // Each polyline feature carries a `lane_offset` attribute (signed
    // float from the server, typically ±1-2.5).  We multiply it by a
    // zoom-interpolated factor to push parallel trunk groups apart.
    //
    // v4: the server now sends NON-OFFSET polylines that pass through
    // station positions.  ALL corridor separation is handled here via
    // MapLibre's pixel-space `lineOffset` paint property, which pushes
    // lines perpendicular to their draw direction in screen points.
    // This guarantees polylines always touch their station dots.

    /// Composite expression: top-level zoom interpolation where each stop
    /// multiplies the feature's `lane_offset` by a zoom-dependent factor.
    ///
    /// At zoom 10 each lane_offset unit produces 3.5 pt of perpendicular
    /// shift.  A typical corridor trunk has lane_offset ≈ ±1.5, giving
    /// ≈ 5.25 pt separation per side (10.5 pt total gap) — enough to
    /// distinguish the coloured lines at city-wide zoom.
    ///
    /// v4: pixel offset now extends through ALL zoom levels (never drops
    /// to 0).  The server exports non-offset polylines that pass through
    /// station dots, so all corridor separation is purely visual.
    ///
    /// Built via `NSExpression(mglJSONObject:)` (raw MapLibre GL style-spec
    /// expression) because the `forMLNInterpolating` convenience puts the
    /// zoom variable at the top level — MapLibre requires this; nesting
    /// `$zoomLevel` inside `multiply:by:` is disallowed.
    static let laneOffsetExpression: NSExpression = {
        // Style-spec JSON — v4: full-range pixel offset (no geographic offset).
        //
        // Server now exports NON-OFFSET polylines (coordinates pass through
        // station dots).  All visual corridor separation is handled here via
        // MapLibre ``lineOffset``.  The multiplier scales with line width so
        // parallel trunks maintain proportional separation at every zoom.
        //
        // The multiplier tapers from large at low zoom (lines are thin,
        // need more px separation) to smaller at high zoom (lines are
        // thicker, less px needed because the geographic track spacing
        // provides natural separation between corridors).
        let json: [Any] = [
            "interpolate", ["linear"], ["zoom"],
            10,   ["*", ["get", "lane_offset"], 3.5],
            11,   ["*", ["get", "lane_offset"], 3.0],
            12,   ["*", ["get", "lane_offset"], 2.5],
            13,   ["*", ["get", "lane_offset"], 2.0],
            14,   ["*", ["get", "lane_offset"], 1.8],
            15,   ["*", ["get", "lane_offset"], 1.5],
            16,   ["*", ["get", "lane_offset"], 1.2],
            17,   ["*", ["get", "lane_offset"], 1.0],
            18,   ["*", ["get", "lane_offset"], 0.8],
        ]
        return NSExpression(mglJSONObject: json)
    }()

    // MARK: - Transit Layer IDs (z-ordering)
    //
    // Rendering order (bottom to top), Transit App–style per-trunk layering:
    //
    // 1.  Commuter rail casing
    // 2.  Commuter rail fill
    // 3.  Subway trunk 0 (Red 1/2/3) casing → fill
    // 4.  Subway trunk 1 (Green 4/5/6) casing → fill
    //     … (one casing + fill pair per trunk group, 11 total)
    // 5.  Elevated trunk 0 shadow → casing → fill
    //     … (one shadow + casing + fill triple per trunk, 11 total)
    // 6.  Transfer connectors
    // 7.  Station dots (single-line + transfer circles)
    // 8.  Station labels (text at high zoom)
    // 9.  Route layers (selected route on top)
    // 10. Vehicle markers
    //
    // Per-trunk layering prevents cross-trunk z-ordering issues:
    // each trunk's casing only appears below its own fill, and
    // trunk fills never occlude each other within the same GL draw call.

    static let layerCommRailCasing = "commuter-casing"
    static let layerCommRailFill = "commuter-fill"
    static let layerTransferConn = "transfer-connectors"
    static let layerStationDotsShadow = "station-dots-shadow"
    static let layerStationDotsSingle = "station-dots-single"
    static let layerStationDotsTransfer = "station-dots-transfer"
    static let layerStationLabels = "station-labels"

    // 3D Building Layer
    static let layerBuilding3D = "building-3d-extrusion"

    // Source IDs
    static let srcCommRail = "commuter-src"
    static let srcTransferConn = "transfer-conn-src"
    static let srcStations = "stations-src"

    // MARK: - Per-Trunk Layer IDs (Transit App–style separation)
    //
    // Instead of putting all subway polylines into a single shared layer
    // (which causes same-layer z-ordering issues — later features draw
    // over earlier ones with no per-feature z-index control), we split
    // each trunk group into its own source + casing + fill layers.
    //
    // This eliminates cross-trunk overlap: each trunk's casing sits
    // below only its own fill, and trunk fills never occlude each other.
    // Transit App uses the same per-line layer approach for clean
    // parallel rendering in corridors.

    /// Number of trunk groups (must match TRUNK_GROUPS in both
    /// MapSystemViewModel and the backend corridor_pipeline.py).
    static let subwayTrunkCount = 11

    static func subwayTrunkSourceID(_ index: Int) -> String {
        "subway-trunk-\(index)-src"
    }
    static func subwayTrunkCasingLayerID(_ index: Int) -> String {
        "subway-trunk-\(index)-casing"
    }
    static func subwayTrunkFillLayerID(_ index: Int) -> String {
        "subway-trunk-\(index)-fill"
    }
    static func elevatedTrunkSourceID(_ index: Int) -> String {
        "elevated-trunk-\(index)-src"
    }
    static func elevatedTrunkShadowLayerID(_ index: Int) -> String {
        "elevated-trunk-\(index)-shadow"
    }
    static func elevatedTrunkCasingLayerID(_ index: Int) -> String {
        "elevated-trunk-\(index)-casing"
    }
    static func elevatedTrunkFillLayerID(_ index: Int) -> String {
        "elevated-trunk-\(index)-fill"
    }

    // MARK: - 3D Buildings

    /// Minimum zoom level at which 3D building extrusions become visible.
    /// Below this zoom, buildings are too small to be meaningful.
    static let building3DMinZoom: Double = 14.5

    /// Building fill color (light mode) — subtle warm gray so buildings
    /// add depth without competing with transit overlays.
    static let buildingColorLight = UIColor(red: 0.85, green: 0.83, blue: 0.80, alpha: 1.0)

    /// Building fill color (dark mode) — muted blue-gray for contrast against
    /// the dark base map without being distracting.
    static let buildingColorDark = UIColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1.0)

    /// Building extrusion opacity — fades in smoothly from minZoom to z16.
    static let buildingOpacity = zoomInterpolate(
        base: 1.0,
        stops: [14.5: 0.0, 15: 0.35, 16: 0.55, 17: 0.65, 18: 0.7]
    )

    /// Building extrusion opacity (dark mode) — slightly lower for subtlety.
    static let buildingOpacityDark = zoomInterpolate(
        base: 1.0,
        stops: [14.5: 0.0, 15: 0.25, 16: 0.45, 17: 0.55, 18: 0.6]
    )
}
