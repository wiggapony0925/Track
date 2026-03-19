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

    /// Shared exponential base for subway line-width interpolation.
    /// Lane offsets reuse the same curve so spacing tracks the live
    /// rendered fill width between zoom stops instead of only at them.
    static let subwayLineInterpolationBase: Double = 1.6

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

    /// Mirrors MapLibre's exponential stop interpolation for a single value.
    /// Used by station-dot screen-space offsets so they track the line layer.
    private static func interpolatedStopValue(
        at zoom: Double,
        base: Double,
        stops: [(zoom: Double, value: Double)]
    ) -> Double {
        guard let first = stops.first else { return 0 }
        if zoom <= first.zoom { return first.value }

        for idx in 1..<stops.count {
            let prev = stops[idx - 1]
            let next = stops[idx]
            if zoom <= next.zoom {
                let span = next.zoom - prev.zoom
                guard span > 0 else { return next.value }
                let progress = max(0.0, min(zoom - prev.zoom, span))
                let t: Double
                if abs(base - 1.0) < 1e-9 {
                    t = progress / span
                } else {
                    let numerator = pow(base, progress) - 1.0
                    let denominator = pow(base, span) - 1.0
                    t = denominator == 0 ? 0 : numerator / denominator
                }
                return prev.value + (next.value - prev.value) * t
            }
        }

        return stops.last?.value ?? 0
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
    /// Includes stops from zoom 8 so lines remain visible at city-overview level.
    static let subwayFillWidthStops: [(zoom: Double, width: Double)] = [
        (8,  0.6),
        (9,  0.8),
        (10, 1.2),
        (11, 1.6),
        (12, 2.2),
        (13, 2.8),
        (14, 3.5),
        (15, 4.2),
        (16, 5.0),
        (17, 6.0),
        (18, 7.0),
    ]

    static let subwayFillWidth = zoomInterpolate(
        base: subwayLineInterpolationBase,
        stops: Dictionary(uniqueKeysWithValues: subwayFillWidthStops.map { ($0.zoom, $0.width) })
    )

    /// Subway casing width — soft border that gives lines a floating-above-map feel.
    /// The casing-to-fill ratio is ~1.6×, creating a subtle halo rather than a harsh edge.
    /// Extended to zoom 8 to match fill width coverage.
    static let subwayCasingWidth = zoomInterpolate(
        base: subwayLineInterpolationBase,
        stops: [8: 1.2, 9: 1.6, 10: 2.4, 11: 3.0, 12: 4.0, 13: 5.0, 14: 6.0, 15: 7.0, 16: 8.5, 17: 10.0, 18: 12.0]
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
    /// Matched to Transit-app-level thickness for a premium, confident feel.
    static let routeFillWidth = zoomInterpolate(
        base: 1.6,
        stops: [10: 3.5, 12: 5.0, 14: 7.0, 16: 8.5, 18: 10.0]
    )

    /// Active route casing width — generous border for a premium floating effect.
    static let routeCasingWidth = zoomInterpolate(
        base: 1.6,
        stops: [10: 5.5, 12: 8.0, 14: 10.5, 16: 12.5, 18: 14.0]
    )

    /// Station circle dot radius — single-line stops only, visible from zoom 12.
    static let stationDotRadius = zoomInterpolate(
        base: 1.4,
        stops: [12: 1.8, 13: 2.5, 14: 3.2, 15: 4.0, 16: 5.5, 17: 7.0, 18: 8.5]
    )

    /// Station dot stroke width — thin crisp border.
    static let stationDotStrokeWidth = zoomInterpolate(
        base: 1.3,
        stops: [12: 0.5, 13: 0.7, 15: 1.0, 17: 1.5, 18: 1.8]
    )

    /// Transfer pill icon size — zoom-interpolated scale factor applied to
    /// the runtime-generated capsule image.
    static let transferPillIconSize = zoomInterpolate(
        base: 1.4,
        stops: [10: 0.25, 11: 0.38, 12: 0.52, 13: 0.65, 14: 0.8, 15: 1.0, 16: 1.3, 17: 1.6, 18: 2.0]
    )

    /// Station label font size — legible from zoom 14.
    static let stationLabelFontSize = zoomInterpolate(
        base: 1.0,
        stops: [14: 9.0, 15: 10.0, 16: 11.0, 17: 12.0, 18: 13.0]
    )

    // MARK: - Transfer Pill Image Generation

    /// Base pill height in points (short axis of the capsule).
    static let transferPillHeight: CGFloat = 12
    /// Border thickness for pill images.
    static let transferPillStroke: CGFloat = 1.5
    /// Pill widths keyed by colorGroupCount (number of distinct trunk-color groups).
    static let transferPillWidths: [Int: CGFloat] = [
        2: 20,
        3: 26,
        4: 32,
        5: 38,
    ]

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
    // float from the server, typically ±1-2.5). We use it only as a
    // visual aid to keep parallel trunks readable when a shared corridor
    // collapses toward a single screen-space path.
    //
    // To keep adjacent lanes visually touching, the centerline spacing
    // should be almost exactly one fill-width. We stay 2% under the fill
    // width to avoid hairline gaps from fractional-pixel antialiasing.
    static let laneOffsetTouchRatio: Double = 0.98

    /// Minimum lane-offset multiplier at very low zoom levels.
    /// Even when fill width shrinks to sub-pixel, parallel corridors need
    /// at least this much pixel separation to remain distinguishable.
    /// Without this floor, parallel lines collapse into a single line
    /// at zoom 8-9 because 0.6 × 0.98 ≈ 0.59 px of separation is
    /// invisible. The 0.8 px floor keeps corridors visually separate.
    private static let laneOffsetMinMultiplier: Double = 0.8

    static let laneOffsetStops: [(zoom: Double, multiplier: Double)] =
        subwayFillWidthStops.map { stop in
            let raw = stop.width * laneOffsetTouchRatio
            return (zoom: stop.zoom, multiplier: max(raw, laneOffsetMinMultiplier))
        }

    static func laneOffsetMultiplier(at zoom: Double) -> Double {
        interpolatedStopValue(
            at: zoom,
            base: subwayLineInterpolationBase,
            stops: laneOffsetStops.map { (zoom: $0.zoom, value: $0.multiplier) }
        )
    }

    static func laneOffsetPixels(for laneOffset: CGFloat, at zoom: Double) -> CGFloat {
        CGFloat(Double(laneOffset) * laneOffsetMultiplier(at: zoom))
    }

    /// Composite expression: top-level zoom interpolation where each stop
    /// multiplies the feature's `lane_offset` by a zoom-dependent factor.
    ///
    /// Tracks the rendered subway fill width so adjacent corridors stay
    /// visibly parallel while still touching edge-to-edge at close zoom.
    static let laneOffsetExpression: NSExpression = {
        var json: [Any] = [
            "interpolate",
            ["exponential", subwayLineInterpolationBase],
            ["zoom"],
        ]
        for stop in laneOffsetStops {
            json.append(stop.zoom)
            json.append(["*", ["get", "lane_offset"], stop.multiplier])
        }
        return NSExpression(mglJSONObject: json)
    }()

    // MARK: - Transit Layer IDs (z-ordering)
    //
    // Rendering order (bottom to top):
    // 1. Commuter rail casing + fill
    // 2. Subway casing + fill (shared source, lineOffset for corridors)
    // 3. Elevated shadow + casing + fill (shared source)
    // 4. Transfer connectors
    // 5. Station dots (single-line circles) + transfer pills (capsule icons)
    // 6. Station labels (text at high zoom)
    // 7. Route layers (selected route on top)
    // 8. Vehicle markers

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
    static let buildingColorLight = UIColor(red: 0.84, green: 0.82, blue: 0.88, alpha: 1.0)

    /// Building fill color (dark mode) — muted blue-gray for contrast against
    /// the dark base map without being distracting.
    static let buildingColorDark = UIColor(red: 0.12, green: 0.15, blue: 0.21, alpha: 1.0)

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

    // MARK: - Transfer Pill Image Factory

    /// Generates a capsule/pill `UIImage` for transfer station markers.
    ///
    /// The image is horizontal (wider than tall) so MapLibre's
    /// `iconRotation` can orient it perpendicular to the track.
    ///
    /// - Parameters:
    ///   - colorGroupCount: Number of distinct trunk-color groups (determines width).
    ///   - isDark: Whether to render for dark mode.
    /// - Returns: A `UIImage` suitable for `style.setImage(_:forName:)`.
    static func transferPillImage(colorGroupCount: Int, isDark: Bool) -> UIImage {
        let clamped = min(max(colorGroupCount, 2), 5)
        let w = transferPillWidths[clamped] ?? 20
        let h = transferPillHeight
        let sw = transferPillStroke

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: w, height: h),
            format: UIGraphicsImageRendererFormat.preferred()
        )

        return renderer.image { _ in
            let rect = CGRect(x: sw / 2, y: sw / 2,
                              width: w - sw, height: h - sw)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: h / 2)

            let fill: UIColor = isDark
                ? UIColor(white: 0.18, alpha: 1)
                : .white
            let stroke: UIColor = isDark
                ? UIColor(white: 0.85, alpha: 1)
                : UIColor(white: 0.12, alpha: 1)

            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = sw
            path.stroke()
        }
    }

    /// Style-image name for a given transfer pill variant.
    static func transferPillImageName(colorGroupCount: Int) -> String {
        "transfer-pill-\(min(max(colorGroupCount, 2), 5))"
    }

    /// Registers all transfer pill images into the given MapLibre style.
    /// Call once on first setup, and again when dark mode changes.
    static func registerTransferPillImages(style: MLNStyle, isDark: Bool) {
        for count in 2...5 {
            let name = transferPillImageName(colorGroupCount: count)
            let img = transferPillImage(colorGroupCount: count, isDark: isDark)
            style.setImage(img, forName: name)
        }
    }
}
