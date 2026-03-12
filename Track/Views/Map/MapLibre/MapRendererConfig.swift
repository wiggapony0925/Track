//
//  MapRendererConfig.swift
//  Track
//
//  Feature flag to toggle between Apple MapKit and MapLibre GL
//  map renderers. Allows A/B testing and gradual migration.
//
//  Usage:
//      if MapRendererConfig.useMapLibre {
//          MapLibreTrackMapView(...)
//      } else {
//          TrackMapView(...)
//      }
//

import Foundation

/// Configuration for choosing the map rendering backend.
enum MapRendererConfig {

    /// Which map renderer to use.
    enum Renderer {
        /// Apple MapKit (SwiftUI Map) — the original renderer.
        case mapKit
        /// MapLibre GL Native with OpenStreetMap/MapTiler tiles.
        case mapLibre
    }

    /// The active map renderer.
    ///
    /// On the `feature/maplibre-migration` branch, this defaults to `.mapLibre`.
    /// On `main`, it should default to `.mapKit` until migration is validated.
    ///
    /// Can also be overridden via UserDefaults for runtime A/B testing:
    /// ```
    /// defaults write com.track.app MapRenderer maplibre
    /// ```
    static var activeRenderer: Renderer {
        if let override = UserDefaults.standard.string(forKey: "MapRenderer") {
            switch override.lowercased() {
            case "maplibre", "osm": return .mapLibre
            case "mapkit", "apple": return .mapKit
            default: break
            }
        }
        // Default for this branch: MapLibre
        return .mapLibre
    }

    /// Convenience: `true` when MapLibre is the active renderer.
    static var useMapLibre: Bool {
        activeRenderer == .mapLibre
    }

    /// Convenience: `true` when Apple MapKit is the active renderer.
    static var useMapKit: Bool {
        activeRenderer == .mapKit
    }
}
