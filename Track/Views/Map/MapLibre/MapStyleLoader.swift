//
//  MapStyleLoader.swift
//  Track
//
//  Loads and parses the JSON-driven map style customizations from
//  Resources/MapStyles/. Provides a clean data model that
//  `MapLibreStyleConfig.customizeBaseStyle` uses instead of
//  hardcoded Swift constants.
//
//  File layout:
//    Resources/MapStyles/map_style_light.json
//    Resources/MapStyles/map_style_dark.json
//
//  Each JSON defines:
//    - strippedLayerPatterns  → layers to remove entirely
//    - dimmedLayers           → layers to reduce opacity on
//    - colors                 → base-map tint overrides
//

import UIKit

// MARK: - Parsed Style Model

/// Decoded representation of a map_style_*.json file.
struct MapStyleConfig {

    /// Layer ID substrings that should be removed from the base style.
    let strippedLayerPatterns: [String]

    /// Layer patterns to dim + the target opacity.
    let dimmedPatterns: [String]
    let dimmedOpacity: Float

    /// Base-map color overrides.
    let waterColor: UIColor
    let parkColor: UIColor
    let landColor: UIColor
    let roadColor: UIColor
    let roadCasingColor: UIColor
    let roadLabelColor: UIColor
    let roadLabelHaloColor: UIColor
    let roadLabelHaloWidth: CGFloat
    let roadLabelHaloBlur: CGFloat
    let placeLabelColor: UIColor
    let placeLabelHaloColor: UIColor
    let placeLabelHaloWidth: CGFloat
    let placeLabelHaloBlur: CGFloat
    let buildingColor: UIColor

    /// Per-element tint strengths — how much of the desaturated route
    /// colour bleeds into each element category. Water/parks stay low
    /// to preserve their natural identity; buildings absorb the most.
    let tintWater: CGFloat
    let tintPark: CGFloat
    let tintLand: CGFloat
    let tintRoad: CGFloat
    let tintBuilding: CGFloat
    let tintRoadLabel: CGFloat
    let tintPlaceLabel: CGFloat
}

// MARK: - Loader

enum MapStyleLoader {

    /// Cached configs — loaded once per app launch per mode.
    private static var lightConfig: MapStyleConfig?
    private static var darkConfig: MapStyleConfig?

    /// Returns the parsed style config for the given appearance.
    /// Loads from disk on first call, then returns the cached copy.
    static func config(isDarkMode: Bool) -> MapStyleConfig? {
        if isDarkMode {
            if darkConfig == nil {
                darkConfig = load(filename: "map_style_dark")
            }
            return darkConfig
        } else {
            if lightConfig == nil {
                lightConfig = load(filename: "map_style_light")
            }
            return lightConfig
        }
    }

    /// Invalidates the cache so the next call reloads from disk.
    /// Useful for hot-reload during development.
    static func invalidateCache() {
        lightConfig = nil
        darkConfig = nil
    }

    // MARK: - Private

    private static func load(filename: String) -> MapStyleConfig? {
        guard let url = Bundle.main.url(
            forResource: filename,
            withExtension: "json",
            subdirectory: "MapStyles"
        ) ?? Bundle.main.url(forResource: filename, withExtension: "json") else {
            #if DEBUG
            print("[MapStyleLoader] ⚠️ \(filename).json not found in bundle")
            #endif
            return nil
        }

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            #if DEBUG
            print("[MapStyleLoader] ⚠️ Failed to parse \(filename).json")
            #endif
            return nil
        }

        return parse(json)
    }

    private static func parse(_ json: [String: Any]) -> MapStyleConfig? {
        let stripped = json["strippedLayerPatterns"] as? [String] ?? []

        let dimmedDict = json["dimmedLayers"] as? [String: Any] ?? [:]
        let dimmedPatterns = dimmedDict["patterns"] as? [String] ?? []
        let dimmedOpacity = (dimmedDict["opacity"] as? NSNumber)?.floatValue ?? 0.25

        guard let colors = json["colors"] as? [String: Any] else {
            #if DEBUG
            print("[MapStyleLoader] ⚠️ Missing 'colors' key in style JSON")
            #endif
            return nil
        }

        // Per-element tint strengths (optional — sensible defaults)
        let tints = json["tintStrengths"] as? [String: Any] ?? [:]

        return MapStyleConfig(
            strippedLayerPatterns: stripped,
            dimmedPatterns: dimmedPatterns,
            dimmedOpacity: dimmedOpacity,
            waterColor: color(from: colors, key: "water"),
            parkColor: color(from: colors, key: "park"),
            landColor: color(from: colors, key: "land"),
            roadColor: color(from: colors, key: "road"),
            roadCasingColor: color(from: colors, key: "roadCasing", fallback: color(from: colors, key: "road")),
            roadLabelColor: color(from: colors, key: "roadLabel"),
            roadLabelHaloColor: color(from: colors, key: "roadLabelHalo"),
            roadLabelHaloWidth: cgFloat(from: colors, key: "roadLabelHaloWidth", fallback: 1.5),
            roadLabelHaloBlur: cgFloat(from: colors, key: "roadLabelHaloBlur", fallback: 0.0),
            placeLabelColor: color(from: colors, key: "placeLabel"),
            placeLabelHaloColor: color(from: colors, key: "placeLabelHalo"),
            placeLabelHaloWidth: cgFloat(from: colors, key: "placeLabelHaloWidth", fallback: 2.0),
            placeLabelHaloBlur: cgFloat(from: colors, key: "placeLabelHaloBlur", fallback: 0.0),
            buildingColor: color(from: colors, key: "building"),
            tintWater: cgFloat(from: tints, key: "water", fallback: 0.10),
            tintPark: cgFloat(from: tints, key: "park", fallback: 0.10),
            tintLand: cgFloat(from: tints, key: "land", fallback: 0.14),
            tintRoad: cgFloat(from: tints, key: "road", fallback: 0.10),
            tintBuilding: cgFloat(from: tints, key: "building", fallback: 0.14),
            tintRoadLabel: cgFloat(from: tints, key: "roadLabel", fallback: 0.04),
            tintPlaceLabel: cgFloat(from: tints, key: "placeLabel", fallback: 0.04)
        )
    }

    // MARK: - Hex Color Parsing

    /// Parses a hex color string (#RGB, #RRGGBB, #RRGGBBAA) into UIColor.
    private static func color(from dict: [String: Any], key: String) -> UIColor {
        guard let hex = dict[key] as? String else { return .gray }
        return parseHex(hex)
    }

    /// Color with an explicit UIColor fallback when the key is absent.
    private static func color(from dict: [String: Any], key: String, fallback: UIColor) -> UIColor {
        guard let hex = dict[key] as? String else { return fallback }
        return parseHex(hex)
    }

    private static func cgFloat(from dict: [String: Any], key: String, fallback: CGFloat) -> CGFloat {
        guard let num = dict[key] as? NSNumber else { return fallback }
        return CGFloat(num.doubleValue)
    }

    /// Parses hex strings: #RGB, #RRGGBB, #RRGGBBAA.
    static func parseHex(_ hex: String) -> UIColor {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }

        // Expand shorthand #RGB → #RRGGBB
        if str.count == 3 {
            str = str.map { "\($0)\($0)" }.joined()
        }

        guard str.count == 6 || str.count == 8 else { return .gray }

        var val: UInt64 = 0
        Scanner(string: str).scanHexInt64(&val)

        if str.count == 8 {
            let r = CGFloat((val >> 24) & 0xFF) / 255.0
            let g = CGFloat((val >> 16) & 0xFF) / 255.0
            let b = CGFloat((val >> 8)  & 0xFF) / 255.0
            let a = CGFloat( val        & 0xFF) / 255.0
            return UIColor(red: r, green: g, blue: b, alpha: a)
        } else {
            let r = CGFloat((val >> 16) & 0xFF) / 255.0
            let g = CGFloat((val >> 8)  & 0xFF) / 255.0
            let b = CGFloat( val        & 0xFF) / 255.0
            return UIColor(red: r, green: g, blue: b, alpha: 1.0)
        }
    }
}
