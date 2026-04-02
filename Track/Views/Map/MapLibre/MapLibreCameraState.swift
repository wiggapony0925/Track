// Bridge between `TrackCameraPosition` and MapLibre's camera system.
// Converts our renderer-agnostic camera type (distance, pitch, heading)
// to MapLibre equivalents (zoom level, pitch, bearing) and vice versa.
// No MapKit dependency — all conversions are O(1) arithmetic operations.

import CoreLocation
import Foundation

// MARK: - Camera State

/// Lightweight camera state used by the MapLibre bridge.
/// Decouples the map renderer from any specific camera type while
/// preserving the same semantic model (center, zoom, pitch, heading).
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

// MARK: - TrackCameraPosition ↔ MapLibre Conversion

extension MapLibreCameraState {

    // MARK: - Distance ↔ Zoom Conversion

    /// Converts camera `distance` (meters from focal point) to
    /// MapLibre zoom level using the Web Mercator projection formula.
    ///
    /// Formula: zoom = log2(C * cos(lat) / distance) where C ≈ 591657550.5
    /// This is the standard Mercator zoom ↔ meters-per-pixel relationship.
    ///
    /// - Parameters:
    ///   - distance: Camera distance in meters.
    ///   - latitude: Camera center latitude (affects Mercator scale factor).
    /// - Returns: MapLibre zoom level (typically 0–22).
    static func zoomFromDistance(_ distance: Double, at latitude: Double) -> Double {
        guard distance > 0 else { return MapLibreStyleConfig.maxZoom }
        let earthCircumference: Double = 40_075_016.686
        let metersPerPixelAtZoom0 = earthCircumference * cos(latitude * .pi / 180.0) / 512.0
        let zoom = log2(metersPerPixelAtZoom0 / (distance / 1200.0))
        return max(MapLibreStyleConfig.minZoom, min(zoom, MapLibreStyleConfig.maxZoom))
    }

    /// Converts MapLibre zoom level back to camera distance (meters).
    ///
    /// Inverse of `zoomFromDistance`.
    static func distanceFromZoom(_ zoom: Double, at latitude: Double) -> Double {
        let earthCircumference: Double = 40_075_016.686
        let metersPerPixelAtZoom0 = earthCircumference * cos(latitude * .pi / 180.0) / 512.0
        return (metersPerPixelAtZoom0 / pow(2, zoom)) * 1200.0
    }

    // MARK: - From TrackCameraPosition

    /// Creates a `MapLibreCameraState` from a `TrackCameraPosition`.
    ///
    /// Handles all TrackCameraPosition cases:
    /// - `.camera(TrackCamera)` → direct conversion
    /// - `.userLocation` → falls back to NYC default (user location
    ///   is managed separately by MapLibre's location module)
    /// - `.automatic` → returns NYC default
    ///
    /// - Parameter position: The camera position to convert.
    /// - Returns: Equivalent MapLibre camera state.
    init(from position: TrackCameraPosition) {
        if let camera = position.camera {
            self.center = camera.centerCoordinate
            self.zoom = Self.zoomFromDistance(camera.distance, at: camera.centerCoordinate.latitude)
            self.pitch = camera.pitch
            self.bearing = camera.heading
        } else {
            // .automatic or .userLocation — use default
            self = .nyc
        }
    }

    // MARK: - To TrackCameraPosition

    /// Converts back to a `TrackCameraPosition` for syncing with
    /// view bindings (sheets, dashboards, overlays).
    func toTrackCameraPosition() -> TrackCameraPosition {
        let distance = Self.distanceFromZoom(zoom, at: center.latitude)
        return .camera(TrackCamera(
            centerCoordinate: center,
            distance: distance,
            heading: bearing,
            pitch: pitch
        ))
    }
}
