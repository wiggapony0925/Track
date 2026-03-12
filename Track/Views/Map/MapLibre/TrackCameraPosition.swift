//
//  TrackCameraPosition.swift
//  Track
//
//  Renderer-agnostic camera position type that replaces MapKit's
//  `MapCameraPosition` for the MapLibre GL migration.
//
//  This type flows through all view bindings (@State/@Binding) and
//  is converted to MapLibre camera parameters by MapLibreCameraState.
//  No MapKit import required — the entire camera pipeline is now
//  independent of Apple's map renderer.
//
//  Usage:
//      @State var camera: TrackCameraPosition = .nyc
//      camera = .center(on: coordinate)
//      camera = .fitPoints(from: a, to: b)
//

import CoreLocation
import Foundation

// MARK: - TrackCameraPosition

/// A renderer-agnostic camera position that replaces `MapCameraPosition`.
///
/// Supports three modes:
/// - `.camera(TrackCamera)` — explicit center/distance/heading/pitch
/// - `.userLocation` — follow the user's GPS
/// - `.automatic` — let the renderer decide
///
/// All views that previously used `@Binding var cameraPosition: MapCameraPosition`
/// now use `@Binding var cameraPosition: TrackCameraPosition`.
enum TrackCameraPosition: Equatable {
    /// Explicit camera with center, distance, heading, and pitch.
    case camera(TrackCamera)

    /// Follow the user's current location.
    case userLocation

    /// Let the renderer decide (initial state before location fix).
    case automatic

    // MARK: - Convenience Accessors

    /// Returns the explicit camera if this is a `.camera` case, nil otherwise.
    var camera: TrackCamera? {
        if case .camera(let c) = self { return c }
        return nil
    }

    /// Returns the center coordinate if available.
    var centerCoordinate: CLLocationCoordinate2D? {
        camera?.centerCoordinate
    }

    /// Returns the camera distance if available.
    var distance: Double? {
        camera?.distance
    }
}

// MARK: - TrackCamera

/// Explicit camera parameters — equivalent to MapKit's `MapCamera`.
struct TrackCamera: Equatable {
    let centerCoordinate: CLLocationCoordinate2D
    let distance: Double   // meters from focal point
    let heading: Double    // 0–360 degrees
    let pitch: Double      // 0–60 degrees

    init(
        centerCoordinate: CLLocationCoordinate2D,
        distance: Double,
        heading: Double = 0,
        pitch: Double = 0
    ) {
        self.centerCoordinate = centerCoordinate
        self.distance = distance
        self.heading = heading
        self.pitch = pitch
    }

    // MARK: - Equatable (ignore sub-pixel differences)

    static func == (lhs: TrackCamera, rhs: TrackCamera) -> Bool {
        abs(lhs.centerCoordinate.latitude - rhs.centerCoordinate.latitude) < 1e-7
            && abs(lhs.centerCoordinate.longitude - rhs.centerCoordinate.longitude) < 1e-7
            && abs(lhs.distance - rhs.distance) < 1
            && abs(lhs.heading - rhs.heading) < 0.5
            && abs(lhs.pitch - rhs.pitch) < 0.5
    }
}

// MARK: - Factory Methods

extension TrackCameraPosition {

    /// Default NYC center at comfortable neighborhood zoom.
    static let nyc = TrackCameraPosition.camera(TrackCamera(
        centerCoordinate: CLLocationCoordinate2D(
            latitude: AppSettings.shared.nycCenterLat,
            longitude: AppSettings.shared.nycCenterLon
        ),
        distance: AppSettings.shared.userZoomDistance,
        heading: 0,
        pitch: 0
    ))

    /// Center on a coordinate at the default zoom distance.
    static func center(
        on coordinate: CLLocationCoordinate2D,
        distance: Double = AppSettings.shared.userZoomDistance,
        heading: Double = 0,
        pitch: Double = 0
    ) -> TrackCameraPosition {
        .camera(TrackCamera(
            centerCoordinate: coordinate,
            distance: distance,
            heading: heading,
            pitch: pitch
        ))
    }

    /// Focus on a vehicle at a tighter zoom.
    static func focusVehicle(
        at coordinate: CLLocationCoordinate2D,
        is3D: Bool = false
    ) -> TrackCameraPosition {
        .camera(TrackCamera(
            centerCoordinate: coordinate,
            distance: AppSettings.shared.vehicleFocusDistance,
            heading: 0,
            pitch: is3D ? 60 : 0
        ))
    }
}
