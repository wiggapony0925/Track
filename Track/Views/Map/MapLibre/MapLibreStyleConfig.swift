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
    // Following the Transit app's approach (https://transitapp.com/blog/a-technical-follow-up):
    // MapLibre's GL pipeline enables zoom-interpolated expressions for buttery-smooth
    // width/opacity/radius transitions — impossible with MapKit's static MKPolyline.

    /// Subway fill line width — smooth exponential scaling with zoom.
    /// At far zoom (z10), lines are hair-thin; at street level (z18), prominent.
    /// Exponential base 1.5 gives a natural-feeling acceleration curve.
    static let subwayFillWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 0.8, 11: 1.0, 12: 1.5, 13: 2.0, 14: 2.5, 15: 3.0, 16: 4.0, 17: 5.0, 18: 6.0]
    )

    /// Subway casing width — slightly wider than fill for a Transit-style border.
    /// This is THE signature look: lines float above the map with a subtle outline.
    static let subwayCasingWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 2.0, 11: 2.5, 12: 3.0, 13: 3.5, 14: 4.5, 15: 5.5, 16: 7.0, 17: 8.5, 18: 10.0]
    )

    /// Elevated line fill width — matches subway, but with offset for depth.
    static let elevatedFillWidth = subwayFillWidth

    /// Elevated casing width — wider gap for shadow/depth effect.
    static let elevatedCasingWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 2.5, 11: 3.0, 12: 3.5, 13: 4.5, 14: 5.5, 15: 6.5, 16: 8.0, 17: 10.0, 18: 12.0]
    )

    /// Commuter rail fill width — thinner than subway to denote secondary service.
    static let commuterFillWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 0.5, 12: 0.8, 14: 1.2, 16: 2.0, 18: 3.0]
    )

    /// Commuter rail casing width.
    static let commuterCasingWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 1.5, 12: 2.0, 14: 2.5, 16: 3.5, 18: 5.0]
    )

    /// Active route fill width (when a specific route is selected).
    static let routeFillWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 2.0, 12: 3.0, 14: 4.0, 16: 5.0, 18: 6.0]
    )

    /// Active route casing width.
    static let routeCasingWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 3.5, 12: 5.0, 14: 6.0, 16: 7.5, 18: 9.0]
    )

    /// Station circle dot radius (zoom-interpolated).
    /// Small at overview zoom, grows to visible dots at street level.
    static let stationDotRadius = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
        [11: 1.5, 12: 2.0, 13: 2.5, 14: 3.5, 15: 4.5, 16: 5.5, 17: 7.0, 18: 8.0]
    )

    /// Transfer station dot radius — larger than single-line stops.
    static let transferDotRadius = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
        [11: 2.0, 12: 3.0, 13: 3.5, 14: 4.5, 15: 5.5, 16: 7.0, 17: 8.5, 18: 10.0]
    )

    /// Station dot stroke width (zoom-interpolated).
    static let stationDotStrokeWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
        [11: 0.5, 14: 1.0, 16: 1.5, 18: 2.0]
    )

    /// Station label font size (zoom-interpolated).
    static let stationLabelFontSize = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
        [14: 8.0, 15: 9.0, 16: 10.0, 17: 11.0, 18: 12.0]
    )

    /// Walking route width.
    static let walkingRouteWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 2.0, 14: 3.0, 16: 4.0, 18: 5.0]
    )

    /// Walking route glow width (wider, translucent).
    static let walkingRouteGlowWidth = NSExpression(
        format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.5, %@)",
        [10: 4.0, 14: 6.0, 16: 8.0, 18: 10.0]
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
    static let layerStationDotsSingle = "station-dots-single"
    static let layerStationDotsTransfer = "station-dots-transfer"
    static let layerStationLabels = "station-labels"

    // Source IDs
    static let srcCommRail = "commuter-src"
    static let srcSubway = "subway-src"
    static let srcElevated = "elevated-src"
    static let srcTransferConn = "transfer-conn-src"
    static let srcStations = "stations-src"
}
