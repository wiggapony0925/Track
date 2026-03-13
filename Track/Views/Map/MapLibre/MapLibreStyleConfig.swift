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
import UIKit

// MARK: - MapLibre Style Configuration

/// Centralized configuration for MapLibre GL tile sources and style URLs.
/// All OSM/MapTiler configuration lives here — no magic strings elsewhere.
enum MapLibreStyleConfig {

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
    static let subwayFillWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.6, %@)",
        [10: 1.2, 11: 1.6, 12: 2.2, 13: 2.8, 14: 3.5, 15: 4.2, 16: 5.0, 17: 6.0, 18: 7.0]
    )

    /// Subway casing width — soft border that gives lines a floating-above-map feel.
    /// The casing-to-fill ratio is ~1.6×, creating a subtle halo rather than a harsh edge.
    static let subwayCasingWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.6, %@)",
        [10: 2.4, 11: 3.0, 12: 4.0, 13: 5.0, 14: 6.0, 15: 7.0, 16: 8.5, 17: 10.0, 18: 12.0]
    )

    /// Elevated line fill width — matches subway for visual consistency.
    static let elevatedFillWidth = subwayFillWidth

    /// Elevated casing width — extra-wide for a pronounced shadow/depth effect
    /// that distinguishes above-ground structure from tunnels.
    static let elevatedCasingWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.6, %@)",
        [10: 3.0, 11: 3.5, 12: 4.5, 13: 5.5, 14: 7.0, 15: 8.0, 16: 10.0, 17: 12.0, 18: 14.0]
    )

    /// Commuter rail fill width — thinner than subway to establish visual hierarchy.
    /// Still bold enough to be clearly visible at overview zoom.
    static let commuterFillWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 0.8, 11: 1.0, 12: 1.5, 13: 2.0, 14: 2.5, 16: 3.5, 18: 4.5]
    )

    /// Commuter rail casing width — border for dashed commuter lines.
    static let commuterCasingWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 1.8, 11: 2.2, 12: 3.0, 13: 3.5, 14: 4.5, 16: 6.0, 18: 7.5]
    )

    /// Active route fill width (when a specific route is selected) — extra bold
    /// so the selected route clearly dominates the dimmed system map.
    static let routeFillWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.6, %@)",
        [10: 2.5, 12: 3.5, 14: 5.0, 16: 6.0, 18: 7.5]
    )

    /// Active route casing width — generous border for a premium floating effect.
    static let routeCasingWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.6, %@)",
        [10: 4.0, 12: 6.0, 14: 8.0, 16: 9.5, 18: 11.0]
    )

    /// Station circle dot radius — starts visible earlier, grows to prominent dots.
    static let stationDotRadius = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.4, %@)",
        [11: 1.8, 12: 2.5, 13: 3.2, 14: 4.0, 15: 5.0, 16: 6.5, 17: 8.0, 18: 9.5]
    )

    /// Transfer station dot radius — noticeably larger than single-line stops
    /// to highlight important interchange stations.
    static let transferDotRadius = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.4, %@)",
        [11: 2.5, 12: 3.5, 13: 4.5, 14: 5.5, 15: 7.0, 16: 8.5, 17: 10.0, 18: 12.0]
    )

    /// Station dot stroke width — crisp border at all zoom levels.
    static let stationDotStrokeWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.3, %@)",
        [11: 0.8, 13: 1.2, 15: 1.8, 17: 2.2, 18: 2.5]
    )

    /// Station label font size — legible even at zoom 14.
    static let stationLabelFontSize = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
        [14: 9.0, 15: 10.0, 16: 11.0, 17: 12.0, 18: 13.0]
    )

    /// Walking route width — dashed line for pedestrian directions.
    static let walkingRouteWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 2.5, 14: 3.5, 16: 4.5, 18: 5.5]
    )

    /// Walking route glow width (wider, translucent for depth).
    static let walkingRouteGlowWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 5.0, 14: 7.0, 16: 9.0, 18: 11.0]
    )

    // MARK: - Transit Layer IDs (z-ordering)
    //
    // Rendering order (bottom to top), following Transit's parallel-line approach:
    // 1. Commuter rail casing
    // 2. Commuter rail fill
    // 3. Subway casing (white border — Transit signature look)
    // 4. Subway fill (colored lines)
    // 5. Elevated casing (wider border + shadow offset)
    // 6. Elevated fill (colored lines, translated for depth)
    // 7. Transfer connectors
    // 8. Station dots (single-line + transfer circles)
    // 9. Station labels (text at high zoom)
    // 10. Route layers (selected route on top)
    // 11. Vehicle markers

    static let layerCommRailCasing = "commuter-casing"
    static let layerCommRailFill = "commuter-fill"
    static let layerSubwayCasing = "subway-casing"
    static let layerSubwayFill = "subway-fill"
    static let layerElevatedShadow = "elevated-shadow"
    static let layerElevatedCasing = "elevated-casing"
    static let layerElevatedFill = "elevated-fill"
    static let layerTransferConn = "transfer-connectors"
    static let layerStationDotsShadow = "station-dots-shadow"
    static let layerStationDotsSingle = "station-dots-single"
    static let layerStationDotsTransfer = "station-dots-transfer"
    static let layerStationLabels = "station-labels"

    // 3D Building Layer
    static let layerBuilding3D = "building-3d-extrusion"

    // Source IDs
    static let srcCommRail = "commuter-src"
    static let srcSubway = "subway-src"
    static let srcElevated = "elevated-src"
    static let srcTransferConn = "transfer-conn-src"
    static let srcStations = "stations-src"

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
    static let buildingOpacity = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
        [14.5: 0.0, 15: 0.35, 16: 0.55, 17: 0.65, 18: 0.7]
    )

    /// Building extrusion opacity (dark mode) — slightly lower for subtlety.
    static let buildingOpacityDark = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
        [14.5: 0.0, 15: 0.25, 16: 0.45, 17: 0.55, 18: 0.6]
    )
}
