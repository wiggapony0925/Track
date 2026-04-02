// OpenStreetMap tile source configuration for MapLibre GL.
// Supports MapTiler vector tiles (free tier) with a muted transit
// style that mirrors the Apple Maps "standard muted" look.
// The app uses OSM data through MapTiler's vector tile API, which
// provides pre-rendered OpenStreetMap tiles optimized for mobile
// rendering via MapLibre's GPU-accelerated pipeline.
// References:
// - MapTiler API: https://docs.maptiler.com/cloud/api/maps/
// - MapLibre Style Spec: https://maplibre.org/maplibre-style-spec/
// - OSM tile usage: https://wiki.openstreetmap.org/wiki/Raster_tile_providers

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

    /// MapTiler Streets v2 Light — clean modern base with good road hierarchy
    /// and subtle building footprints. Better typography than pastel and
    /// enough detail for navigation without competing with transit overlays.
    static var lightStyleURL: URL? {
        let base = "https://api.maptiler.com/maps"
        return URL(
            string: "\(base)/streets-v2-light/style.json?key=\(mapTilerAPIKey)"
        )
    }

    /// MapTiler Streets v2 Dark — rich dark blue-gray base with clear road
    /// contrast and visible water features. Transit lines pop against the
    /// dark background with excellent readability.
    static var darkStyleURL: URL? {
        let base = "https://api.maptiler.com/maps"
        return URL(
            string: "\(base)/streets-v2-dark/style.json?key=\(mapTilerAPIKey)"
        )
    }

    /// The default style URL used by the app.
    /// Uses Streets v2 Light if a valid API key exists, otherwise nil
    /// (triggers OSM raster tile fallback in MapLibreMapView).
    static var defaultStyleURL: URL? {
        guard hasAPIKey else { return nil }
        return lightStyleURL
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
        guard let data = try? JSONSerialization.data(
            withJSONObject: style,
            options: .prettyPrinted
        ) else {
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
        return isDarkMode ? darkStyleURL : lightStyleURL
    }

    // MARK: - Transit-Style Rendering Configuration
    //
    // Premium transit map rendering — bolder than Apple Maps, cleaner than
    // Transit, smoother than Uber/Lyft.  Every expression is tuned for a
    // "floating neon" effect: saturated colored fills float above soft
    // translucent casings, with buttery exponential zoom scaling.

    /// Subway fill line width — bold and prominent at every zoom.
    /// Tuned to match MTA app visual weight on both light and dark basemaps.
    /// Slightly wider than before at medium zooms (10–13) for better
    /// readability on light OSM tiles where contrast is lower.
    /// Exponential base 1.6 gives a natural acceleration curve.
    static let subwayFillWidthStops: [(zoom: Double, width: Double)] = [
        (8,  1.0),
        (9,  1.3),
        (10, 1.8),
        (11, 2.4),
        (12, 3.0),
        (13, 3.6),
        (14, 4.2),
        (15, 5.0),
        (16, 5.8),
        (17, 6.8),
        (18, 7.8),
    ]

    static let subwayFillWidth = zoomInterpolate(
        base: subwayLineInterpolationBase,
        stops: Dictionary(uniqueKeysWithValues: subwayFillWidthStops.map { ($0.zoom, $0.width) })
    )

    /// Subway casing width — soft border that gives lines a floating-above-map feel.
    /// The casing-to-fill ratio is ~1.6×, creating a subtle halo.
    /// Slightly wider to complement the increased fill widths.
    static let subwayCasingWidth = zoomInterpolate(
        base: subwayLineInterpolationBase,
        stops: [
            8: 1.8, 9: 2.4, 10: 3.4, 11: 4.2,
            12: 5.2, 13: 6.2, 14: 7.2, 15: 8.4,
            16: 10.0, 17: 11.5, 18: 13.5
        ]
    )

    /// Subway casing blur — feathers the casing edge outward for a soft
    /// "floating above map" effect.  Scales with zoom so it stays subtle
    /// at overview zooms and becomes a visible soft glow when zoomed in.
    static let subwayCasingBlur = zoomInterpolate(
        base: 1.4,
        stops: [8: 0.4, 10: 0.6, 12: 0.8, 14: 1.0, 16: 1.2, 18: 1.5]
    )

    /// Elevated casing blur — slightly stronger than subway for depth.
    static let elevatedCasingBlur = zoomInterpolate(
        base: 1.4,
        stops: [10: 0.8, 12: 1.0, 14: 1.2, 16: 1.5, 18: 2.0]
    )

    /// Elevated shadow blur — very diffuse for a natural drop-shadow.
    static let elevatedShadowBlur = zoomInterpolate(
        base: 1.4,
        stops: [10: 1.5, 12: 2.0, 14: 2.5, 16: 3.0, 18: 4.0]
    )

    /// Elevated line fill width — matches subway for visual consistency.
    static let elevatedFillWidth = subwayFillWidth

    /// Elevated casing width — extra-wide for a pronounced shadow/depth effect
    /// that distinguishes above-ground structure from tunnels.
    static let elevatedCasingWidth = zoomInterpolate(
        base: 1.6,
        stops: [10: 3.5, 11: 4.2, 12: 5.2, 13: 6.2, 14: 7.5, 15: 8.8, 16: 10.5, 17: 12.5, 18: 15.0]
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

    /// Commuter rail casing blur — lighter blur than subway since commuter
    /// lines are thinner and dashed; too much blur dissolves the pattern.
    static let commuterCasingBlur = zoomInterpolate(
        base: 1.4,
        stops: [10: 0.3, 12: 0.5, 14: 0.7, 16: 0.9, 18: 1.2]
    )

    /// Active route fill width (when a specific route is selected) — extra bold
    /// so the selected route clearly dominates the dimmed system map.
    /// Must stay wider than subway fill for clear visual hierarchy.
    static let routeFillWidth = zoomInterpolate(
        base: 1.6,
        stops: [10: 4.0, 12: 5.5, 14: 7.5, 16: 9.0, 18: 11.0]
    )

    /// Active route casing width — generous border for a premium floating effect.
    static let routeCasingWidth = zoomInterpolate(
        base: 1.6,
        stops: [10: 6.0, 12: 8.5, 14: 11.0, 16: 13.0, 18: 15.5]
    )

    /// Active route casing blur — generous blur for an elevated, premium feel
    /// on the selected route. Slightly stronger than subway since the route
    /// dominates the screen and benefits from more visual weight.
    static let routeCasingBlur = zoomInterpolate(
        base: 1.4,
        stops: [10: 0.5, 12: 0.8, 14: 1.0, 16: 1.4, 18: 1.8]
    )

    /// Station circle dot radius — single-line stops, visible from zoom 11.
    /// Scaled to match MTA app station dot prominence on both light and dark basemaps.
    static let stationDotRadius = zoomInterpolate(
        base: 1.4,
        stops: [11: 2.0, 12: 3.0, 13: 3.8, 14: 4.5, 15: 5.5, 16: 7.0, 17: 8.5, 18: 10.0]
    )

    /// Station dot stroke width — bold enough to be visible on light basemaps.
    static let stationDotStrokeWidth = zoomInterpolate(
        base: 1.3,
        stops: [11: 0.8, 12: 1.0, 13: 1.2, 15: 1.5, 17: 2.0, 18: 2.4]
    )

    /// Transfer pill icon size — zoom-interpolated scale factor applied to
    /// the runtime-generated capsule image. Images are rendered at 3x the
    /// display size so GL always scales *down* (crisp, no pixelation).
    /// `base: 1.0` (linear) gives visually uniform scaling across zooms.
    static let transferPillIconSize = zoomInterpolate(
        base: 1.0,
        stops: [
            10: 0.12, 11: 0.18, 12: 0.25,
            13: 0.32, 14: 0.38, 15: 0.45,
            16: 0.55, 17: 0.65, 18: 0.80
        ]
    )

    /// Station label font size — legible from zoom 14.
    static let stationLabelFontSize = zoomInterpolate(
        base: 1.0,
        stops: [14: 9.0, 15: 10.0, 16: 11.0, 17: 12.0, 18: 13.0]
    )

    // MARK: - Transfer Pill Image Generation

    /// Base pill height in points (short axis of the capsule).
    static let transferPillHeight: CGFloat = 10
    /// Border thickness for pill images — bolder for light-mode visibility.
    static let transferPillStroke: CGFloat = 1.8
    /// Pill widths keyed by colorGroupCount (number of distinct trunk-color groups).
    static let transferPillWidths: [Int: CGFloat] = [
        2: 18,
        3: 24,
        4: 30,
        5: 36,
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

    // MARK: - Base Style Cleanup
    //
    // MapTiler streets-v2 styles ship with hundreds of layers including
    // POI icons (restaurants, shops, gas stations), road shields, highway
    // numbers, and transit labels that clash with our custom transit overlays.
    //
    // All customization values are loaded from JSON files at:
    //   Resources/MapStyles/map_style_light.json
    //   Resources/MapStyles/map_style_dark.json
    //
    // After the style loads we strip everything that doesn't serve a
    // transit navigation app, then tint the remaining base layers to
    // harmonize with the app's purple/indigo palette.

    /// Applies the full suite of transit-app customizations to a loaded
    /// MapTiler base style: strips clutter, dims low-priority layers, and
    /// recolors surviving layers to match the app's palette.
    ///
    /// All colors and patterns are driven by the JSON style files under
    /// `Resources/MapStyles/` — edit those to tweak the map theme without
    /// touching Swift code.
    ///
    /// Call once from `didFinishLoading style:` after the style is ready.
    /// Customise the base map style: strip POI clutter, dim low-priority
    /// layers, and recolour surviving layers to match the app’s palette.
    ///
    /// When `routeColor` is non-nil the palette is pre-blended towards a
    /// desaturated version of the route colour — Transit-app-style ambient
    /// wash baked into the same single pass. No second iteration needed.
    static func customizeBaseStyle(
        _ style: MLNStyle,
        isDarkMode: Bool,
        routeColor: UIColor? = nil
    ) {
        guard let config = MapStyleLoader.config(isDarkMode: isDarkMode) else {
            #if DEBUG
            print(
                "[MapLibreStyleConfig] No map style JSON loaded"
                + " — skipping base style customization"
            )
            #endif
            return
        }

        // \u2500\u2500 Pre-compute palette (with optional route-colour wash) \u2500\u2500
        let water: UIColor
        let park: UIColor
        let land: UIColor
        let road: UIColor
        let roadCasing: UIColor
        let building: UIColor
        let roadLabel: UIColor
        let placeLabel: UIColor

        if let rc = routeColor {
            let wash = desaturateForTint(rc, isDarkMode: isDarkMode)
            water      = blendColor(
                base: config.waterColor,
                overlay: wash, t: config.tintWater
            )
            park       = blendColor(base: config.parkColor,       overlay: wash, t: config.tintPark)
            land       = blendColor(base: config.landColor,       overlay: wash, t: config.tintLand)
            road       = blendColor(base: config.roadColor,       overlay: wash, t: config.tintRoad)
            roadCasing = blendColor(base: config.roadCasingColor, overlay: wash, t: config.tintRoad)
            building   = blendColor(
                base: config.buildingColor,
                overlay: wash, t: config.tintBuilding
            )
            roadLabel  = blendColor(
                base: config.roadLabelColor,
                overlay: wash, t: config.tintRoadLabel
            )
            placeLabel = blendColor(
                base: config.placeLabelColor,
                overlay: wash, t: config.tintPlaceLabel
            )
        } else {
            water      = config.waterColor
            park       = config.parkColor
            land       = config.landColor
            road       = config.roadColor
            roadCasing = config.roadCasingColor
            building   = config.buildingColor
            roadLabel  = config.roadLabelColor
            placeLabel = config.placeLabelColor
        }

        let layers = style.layers

        // ── 1. Strip unwanted layers ──
        for layer in layers {
            let id = layer.identifier.lowercased()
            if config.strippedLayerPatterns.contains(where: { id.contains($0) }) {
                style.removeLayer(layer)
            }
        }

        // ── 1b. Kill ALL remaining symbol layers that aren't road/place labels ──
        // MapTiler streets-v2 has dozens of icon/text layers for schools,
        // gas stations, shops, etc. under unpredictable IDs. An allowlist
        // approach ensures ONLY transit-relevant text survives.
        let allowedSymbolPatterns: Set<String> = [
            "road", "street", "highway", "motorway",  // road labels
            "place", "city", "town", "village",       // place labels
            "state", "country", "continent",           // geo labels
            "borough", "neighbourhood", "neighborhood",
            "water"                                     // water labels
        ]
        for layer in style.layers {
            guard layer is MLNSymbolStyleLayer else { continue }
            let id = layer.identifier.lowercased()
            let isAllowed = allowedSymbolPatterns.contains(where: { id.contains($0) })
            if !isAllowed {
                style.removeLayer(layer)
            }
        }

        // ── 2 & 3. Dim + recolor in a SINGLE pass ──
        // Consolidates what was previously 2 separate layer iterations
        // into one pass for faster style load times.
        for layer in style.layers {
            let id = layer.identifier.lowercased()

            // Dim low-priority layers
            if config.dimmedPatterns.contains(where: { id.contains($0) }) {
                if let fill = layer as? MLNFillStyleLayer {
                    fill.fillOpacity = NSExpression(forConstantValue: config.dimmedOpacity)
                } else if let line = layer as? MLNLineStyleLayer {
                    line.lineOpacity = NSExpression(forConstantValue: config.dimmedOpacity)
                }
            }

            // Water
            if id.contains("water") {
                if let fill = layer as? MLNFillStyleLayer {
                    fill.fillColor = NSExpression(forConstantValue: water)
                } else if let line = layer as? MLNLineStyleLayer {
                    line.lineColor = NSExpression(forConstantValue: water)
                }
            }

            // Parks / green spaces
            if id.contains("park") || id.contains("green") || id.contains("grass")
                || id.contains("forest") || id.contains("wood") || id.contains("vegetation")
                || id.contains("garden") || id.contains("cemetery") || id.contains("scrub") {
                if let fill = layer as? MLNFillStyleLayer {
                    fill.fillColor = NSExpression(forConstantValue: park)
                }
            }

            // Land / background
            if id.contains("landcover") || id.contains("landuse")
                || id == "background" || id.contains("earth") || id.contains("land") {
                let isSpecific = id.contains("park") || id.contains("green")
                    || id.contains("forest") || id.contains("wood")
                    || id.contains("cemetery") || id.contains("garden")
                if !isSpecific {
                    if let fill = layer as? MLNFillStyleLayer {
                        fill.fillColor = NSExpression(forConstantValue: land)
                    } else if let bg = layer as? MLNBackgroundStyleLayer {
                        bg.backgroundColor = NSExpression(forConstantValue: land)
                    }
                }
            }

            // Roads
            if id.contains("road") || id.contains("street") || id.contains("highway")
                || id.contains("motorway") || id.contains("trunk") || id.contains("path")
                || id.contains("bridge") || id.contains("tunnel") {
                if let fill = layer as? MLNFillStyleLayer {
                    fill.fillColor = NSExpression(forConstantValue: road)
                } else if let line = layer as? MLNLineStyleLayer {
                    if !id.contains("label") && !id.contains("name") {
                        // Road casings get a distinct darker color for depth
                        let color = id.contains("casing") ? roadCasing : road
                        line.lineColor = NSExpression(forConstantValue: color)
                    }
                }
            }

            // Road labels — keep but restyle to be subdued
            if (id.contains("road") || id.contains("street") || id.contains("highway"))
                && (id.contains("label") || id.contains("name")) {
                if let symbol = layer as? MLNSymbolStyleLayer {
                    symbol.textColor = NSExpression(forConstantValue: roadLabel)
                    symbol.textHaloColor = NSExpression(forConstantValue: config.roadLabelHaloColor)
                    symbol.textHaloWidth = NSExpression(forConstantValue: config.roadLabelHaloWidth)
                    symbol.textHaloBlur = NSExpression(forConstantValue: config.roadLabelHaloBlur)
                }
            }

            // Place / neighborhood / borough labels — keep but theme-match
            if id.contains("place") && (id.contains("label") || id.contains("name")) {
                if let symbol = layer as? MLNSymbolStyleLayer {
                    symbol.textColor = NSExpression(forConstantValue: placeLabel)
                    symbol.textHaloColor = NSExpression(
                        forConstantValue: config.placeLabelHaloColor
                    )
                    symbol.textHaloWidth = NSExpression(
                        forConstantValue: config.placeLabelHaloWidth
                    )
                    symbol.textHaloBlur = NSExpression(forConstantValue: config.placeLabelHaloBlur)
                }
            }

            // Buildings
            if id.contains("building") {
                if let fill = layer as? MLNFillStyleLayer {
                    fill.fillColor = NSExpression(forConstantValue: building)
                }
            }
        }

        // Tint 3D building extrusion if present
        if let rc = routeColor {
            let wash = desaturateForTint(rc, isDarkMode: isDarkMode)
            let tintedBldg3D = blendColor(
                base: isDarkMode ? buildingColorDark : buildingColorLight,
                overlay: wash, t: config.tintBuilding
            )
            if let extrusion = style.layer(
                withIdentifier: layerBuilding3D
            ) as? MLNFillExtrusionStyleLayer {
                extrusion.fillExtrusionColor = NSExpression(forConstantValue: tintedBldg3D)
            }
        }
    }

    // MARK: - Route Color Tinting (merged into customizeBaseStyle)
    //
    // Transit-app-style colour wash: when a route is selected,
    // `customizeBaseStyle(_:isDarkMode:routeColor:)` pre-blends the
    // palette with a desaturated version of the route colour in a
    // SINGLE pass — no separate iteration, instant on style load.
    //
    // Per-element tint strengths are defined in the JSON style configs
    // (tintStrengths section) so water/parks barely shift while
    // buildings/land absorb more of the route character.

    /// Desaturates and lightens (light mode) or softens (dark mode) a
    /// colour so it works as an ambient map wash instead of a neon overlay.
    ///
    /// Uses sqrt-compressed saturation for perceptually uniform results —
    /// very saturated subway colours (red, green, blue) get dampened more
    /// aggressively while already-muted colours stay proportional.
    static func desaturateForTint(_ color: UIColor, isDarkMode: Bool) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if isDarkMode {
            // Very muted glow — low saturation, capped brightness
            // so dark base colours aren't washed out.
            let newSat = s * 0.22
            let newBri = min(b * 0.55, 0.38)
            return UIColor(hue: h, saturation: newSat, brightness: newBri, alpha: 1.0)
        } else {
            // Light pastel wash — sqrt curve compresses loud colours,
            // brightness pushed high for an airy, integrated feel.
            let newSat = sqrt(s) * 0.18
            let newBri = min(b * 0.4 + 0.55, 0.90)
            return UIColor(hue: h, saturation: newSat, brightness: newBri, alpha: 1.0)
        }
    }

    /// Compares two UIColors by their RGBA float components.
    static func colorsEqualRGBA(_ a: UIColor?, _ b: UIColor?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let eps: CGFloat = 0.002
        return abs(ar - br) < eps && abs(ag - bg) < eps
            && abs(ab - bb) < eps && abs(aa - ba) < eps
    }

    /// Blends two UIColors in RGB space.
    static func blendColor(base: UIColor, overlay: UIColor, t: CGFloat) -> UIColor {
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        var or: CGFloat = 0, og: CGFloat = 0, ob: CGFloat = 0, oa: CGFloat = 0
        base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        overlay.getRed(&or, green: &og, blue: &ob, alpha: &oa)
        return UIColor(
            red:   br + (or - br) * t,
            green: bg + (og - bg) * t,
            blue:  bb + (ob - bb) * t,
            alpha: 1.0
        )
    }

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
    static let srcSubwayCasing = "subway-casing-src"
    static let srcElevated = "elevated-src"
    static let srcElevatedCasing = "elevated-casing-src"
    static let srcTransferConn = "transfer-conn-src"
    static let srcStations = "stations-src"

    // MARK: - 3D Buildings

    /// Minimum zoom level at which 3D building extrusions become visible.
    /// Lowered to 14.0 so buildings appear earlier during zoom-in for a
    /// more immersive street-level transition.
    static let building3DMinZoom: Double = 14.0

    /// Building fill color (light mode) — subtle purple-tinted gray that
    /// harmonizes with the app's lavender theme without stealing focus
    /// from transit overlays.
    static let buildingColorLight = UIColor(red: 0.85, green: 0.82, blue: 0.92, alpha: 1.0)

    /// Building fill color (dark mode) — muted indigo that matches the
    /// native streets-v2-dark palette with a subtle purple tint.
    static let buildingColorDark = UIColor(red: 0.14, green: 0.15, blue: 0.25, alpha: 1.0)

    /// Building extrusion opacity — fades in smoothly from minZoom to z16.
    /// Pumped up for a richer, more immersive 3D cityscape.
    static let buildingOpacity = zoomInterpolate(
        base: 1.0,
        stops: [14.0: 0.0, 14.5: 0.30, 15: 0.50, 16: 0.68, 17: 0.78, 18: 0.85]
    )

    /// Building extrusion opacity (dark mode) — slightly lower but still
    /// prominent enough to give the dark map visual depth.
    static let buildingOpacityDark = zoomInterpolate(
        base: 1.0,
        stops: [14.0: 0.0, 14.5: 0.22, 15: 0.40, 16: 0.58, 17: 0.68, 18: 0.75]
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
        // Render at 3× the logical size so MapLibre always scales DOWN,
        // producing crisp pills at every zoom level without pixelation.
        let scale: CGFloat = 3.0
        let w = (transferPillWidths[clamped] ?? 18) * scale
        let h = transferPillHeight * scale
        let sw = transferPillStroke * scale
        // Extra padding for the subtle outer shadow
        let padding: CGFloat = 3.0 * scale
        let totalW = w + padding * 2
        let totalH = h + padding * 2

        // Force scale=1 so the renderer draws at exact pixel size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: totalW, height: totalH),
            format: format
        )

        return renderer.image { ctx in
            let rect = CGRect(x: padding + sw / 2, y: padding + sw / 2,
                              width: w - sw, height: h - sw)
            let cornerRadius = h / 2
            let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)

            // Subtle drop shadow for depth
            let cgCtx = ctx.cgContext
            cgCtx.saveGState()
            let shadowColor: UIColor = isDark
                ? UIColor.black.withAlphaComponent(0.50)
                : UIColor.black.withAlphaComponent(0.15)
            cgCtx.setShadow(
                offset: CGSize(width: 0, height: 1.0 * scale),
                blur: 2.0 * scale,
                color: shadowColor.cgColor
            )

            let fill: UIColor = isDark
                ? UIColor(white: 0.20, alpha: 1)
                : .white
            fill.setFill()
            path.fill()
            cgCtx.restoreGState()

            // Refined stroke — high-contrast on light mode for basemap visibility
            let stroke: UIColor = isDark
                ? UIColor(white: 0.72, alpha: 0.85)
                : UIColor(white: 0.15, alpha: 0.70)
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
