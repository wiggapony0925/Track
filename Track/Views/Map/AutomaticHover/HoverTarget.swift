// HoverTarget.swift
// AutomaticHover — semantic description of where the camera should go.
//
// Callers express *intent* ("focus this vehicle", "fit this walk") rather
// than constructing raw TrackCamera values.  CameraHoverEngine resolves
// each case into a validated, bounds-clamped TrackCameraPosition.
//
// Usage:
//     let target = HoverTarget.coordinate(userCoord)
//     let position = CameraHoverEngine.resolve(target, is3D: false)
//     withAnimation(HoverAnimations.fly) { cameraPosition = position }

import CoreLocation
import Foundation

// MARK: - HoverTarget

/// Semantic description of a map camera hover intent.
///
/// Each case maps to a specific geometry strategy in `CameraHoverEngine`:
/// - `.coordinate` — single-point center at default or explicit distance
/// - `.vehicle` — tight zoom on a live vehicle marker
/// - `.walkingPath` — bounding-box fit for user → stop walking segment
/// - `.walkingRoute` — bounding-box fit for a decoded walking polyline
/// - `.fitTwo` — midpoint fit for two arbitrary coordinates
/// - `.userLocation` — follow GPS (renderer manages actual tracking)
/// - `.nyc` — NYC metro overview
enum HoverTarget: Equatable, Sendable {

    // MARK: - Cases

    /// Center the camera on a single coordinate.
    ///
    /// - Parameters:
    ///   - coordinate: Target center.
    ///   - distance: Camera altitude in meters. Pass `nil` to use the
    ///     app's configured default (`AppSettings.userZoomDistance`).
    case coordinate(CLLocationCoordinate2D, distance: Double? = nil)

    /// Tight zoom on a live vehicle (bus or train) marker.
    ///
    /// Uses `AppSettings.vehicleFocusDistance` to stay consistent with
    /// the rest of the app.
    case vehicle(at: CLLocationCoordinate2D)

    /// Bounding-box fit showing both the user and a transit stop.
    ///
    /// Centers with a configurable bias toward the stop so the destination
    /// is slightly more prominent than the departure point.
    case walkingPath(user: CLLocationCoordinate2D, stop: CLLocationCoordinate2D)

    /// Bounding-box fit for a fully decoded walking route polyline.
    ///
    /// - Parameters:
    ///   - latSpanMeters: North-south extent of the route.
    ///   - lonSpanMeters: East-west extent of the route.
    ///   - center: Geographic centroid of the bounding box.
    case walkingRoute(latSpanMeters: Double, lonSpanMeters: Double, center: CLLocationCoordinate2D)

    /// Fit two arbitrary points with smart zoom clamping.
    ///
    /// Camera centers on the midpoint; altitude is proportional to the
    /// straight-line distance between the two points (with padding).
    case fitTwo(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D)

    /// Follow the user's GPS location (renderer-managed tracking mode).
    ///
    /// Resolves to `.userLocation` on `TrackCameraPosition`; the MapLibre
    /// renderer handles actual position updates.
    case userLocation

    /// NYC metro overview — wide angle centered on Manhattan.
    case nyc

    // MARK: - Equatable

    public static func == (lhs: HoverTarget, rhs: HoverTarget) -> Bool {
        switch (lhs, rhs) {
        case let (.coordinate(c1, d1), .coordinate(c2, d2)):
            return c1 ~~ c2 && d1 == d2
        case let (.vehicle(c1), .vehicle(c2)):
            return c1 ~~ c2
        case let (.walkingPath(u1, s1), .walkingPath(u2, s2)):
            return u1 ~~ u2 && s1 ~~ s2
        case let (.walkingRoute(lS1, loS1, c1), .walkingRoute(lS2, loS2, c2)):
            return abs(lS1 - lS2) < 1 && abs(loS1 - loS2) < 1 && c1 ~~ c2
        case let (.fitTwo(f1, t1), .fitTwo(f2, t2)):
            return f1 ~~ f2 && t1 ~~ t2
        case (.userLocation, .userLocation), (.nyc, .nyc):
            return true
        default:
            return false
        }
    }
}

// MARK: - CLLocationCoordinate2D approximate equality helper

/// ~~ operator: coordinate equality within 1e-7 degrees (~1 cm precision).
infix operator ~~: ComparisonPrecedence
private func ~~ (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
    abs(lhs.latitude - rhs.latitude) < 1e-7
        && abs(lhs.longitude - rhs.longitude) < 1e-7
}
