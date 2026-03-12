//
//  MapLibreCameraState.swift
//  Track
//
//  Bridge between MapKit's `MapCameraPosition` and MapLibre's camera system.
//  Allows the rest of the app to keep using `MapCameraPosition` bindings
//  while the actual rendering happens through MapLibre GL.
//
//  This adapter converts MapKit camera concepts (distance, pitch, heading)
//  to MapLibre equivalents (zoom level, pitch, bearing) and vice versa.
//
//  Complexity: All conversions are O(1) arithmetic operations.
//

import CoreLocation
import Foundation
import MapKit
import SwiftUI

// MARK: - Camera State

/// Lightweight camera state used by the MapLibre bridge.
/// Decouples the map renderer from MapKit's `MapCameraPosition` type
/// while preserving the same semantic model (center, zoom, pitch, heading).
struct MapLibreCameraState: Equatable {
    var center: CLLocationCoordinate2D
    var zoom: Double
    var pitch: Double  // 0–60 degrees
    var bearing: Double  // 0–360 degrees

    /// Default camera centered on NYC at a comfortable neighborhood zoom.
    static let nyc = MapLibreCameraState(
        center: CLLocationCoordinate2D(
            latitude: AppSettings.shared.nycCenterLat,
            longitude: AppSettings.shared.nycCenterLon
        ),
        zoom: MapLibreStyleConfig.defaultZoom,
        pitch: 0,
        bearing: 0
    )

    // MARK: - Equatable (ignore sub-pixel differences)

    static func == (lhs: MapLibreCameraState, rhs: MapLibreCameraState) -> Bool {
        abs(lhs.center.latitude - rhs.center.latitude) < 1e-7
            && abs(lhs.center.longitude - rhs.center.longitude) < 1e-7
            && abs(lhs.zoom - rhs.zoom) < 0.01
            && abs(lhs.pitch - rhs.pitch) < 0.5
            && abs(lhs.bearing - rhs.bearing) < 0.5
    }
}

// MARK: - MapKit ↔ MapLibre Conversion

extension MapLibreCameraState {

    // MARK: - Distance ↔ Zoom Conversion

    /// Converts MapKit camera `distance` (meters from focal point) to
    /// MapLibre zoom level using the Web Mercator projection formula.
    ///
    /// Formula: zoom = log2(C * cos(lat) / distance) where C ≈ 591657550.5
    /// This is the standard Mercator zoom ↔ meters-per-pixel relationship.
    ///
    /// - Parameters:
    ///   - distance: MapKit camera distance in meters.
    ///   - latitude: Camera center latitude (affects Mercator scale factor).
    /// - Returns: MapLibre zoom level (typically 0–22).
    static func zoomFromDistance(_ distance: Double, at latitude: Double) -> Double {
        guard distance > 0 else { return MapLibreStyleConfig.maxZoom }
        // Earth circumference at equator in meters × cos(lat) / distance
        // Adjusted for MapKit's camera model (distance = altitude above ground
        // for pitch=0; perspective distance for pitched cameras).
        let earthCircumference: Double = 40_075_016.686
        let metersPerPixelAtZoom0 = earthCircumference * cos(latitude * .pi / 180.0) / 512.0
        let zoom = log2(metersPerPixelAtZoom0 / (distance / 1200.0))
        return max(MapLibreStyleConfig.minZoom, min(zoom, MapLibreStyleConfig.maxZoom))
    }

    /// Converts MapLibre zoom level back to MapKit camera distance (meters).
    ///
    /// Inverse of `zoomFromDistance`.
    static func distanceFromZoom(_ zoom: Double, at latitude: Double) -> Double {
        let earthCircumference: Double = 40_075_016.686
        let metersPerPixelAtZoom0 = earthCircumference * cos(latitude * .pi / 180.0) / 512.0
        return (metersPerPixelAtZoom0 / pow(2, zoom)) * 1200.0
    }

    // MARK: - From MapCameraPosition

    /// Creates a `MapLibreCameraState` from a MapKit `MapCameraPosition`.
    ///
    /// Handles all MapCameraPosition cases:
    /// - `.camera(MapCamera)` → direct conversion
    /// - `.region(MKCoordinateRegion)` → center + span-derived zoom
    /// - `.userLocation` → falls back to NYC default (user location
    ///   is managed separately by MapLibre's location module)
    /// - `.automatic` → returns NYC default
    ///
    /// - Parameter position: The MapKit camera position to convert.
    /// - Returns: Equivalent MapLibre camera state.
    init(from position: MapCameraPosition) {
        if let camera = position.camera {
            self.center = camera.centerCoordinate
            self.zoom = Self.zoomFromDistance(camera.distance, at: camera.centerCoordinate.latitude)
            self.pitch = camera.pitch
            self.bearing = camera.heading
        } else if let region = position.region {
            self.center = region.center
            // Approximate zoom from region span
            let latSpanMeters = region.span.latitudeDelta * 111_000
            self.zoom = Self.zoomFromDistance(latSpanMeters, at: region.center.latitude)
            self.pitch = 0
            self.bearing = 0
        } else {
            // .automatic or .userLocation — use default
            self = .nyc
        }
    }

    // MARK: - To MapCameraPosition

    /// Converts back to a MapKit `MapCameraPosition` for compatibility
    /// with views that still use MapKit camera bindings (sheets, dashboards).
    func toMapCameraPosition() -> MapCameraPosition {
        let distance = Self.distanceFromZoom(zoom, at: center.latitude)
        return .camera(MapCamera(
            centerCoordinate: center,
            distance: distance,
            heading: bearing,
            pitch: pitch
        ))
    }
}
