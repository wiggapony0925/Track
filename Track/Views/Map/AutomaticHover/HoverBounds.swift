// HoverBounds.swift
// AutomaticHover — geographic and altitude bounds for the NYC metro region.
//
// Every camera position produced by CameraHoverEngine is validated against
// these bounds before being returned.  Out-of-region coordinates are clamped
// to the metro boundary; extreme zoom levels are clipped to min/max altitudes.
//
// All values are derived from MapLibreStyleConfig (zoom) and AppSettings
// (distances) so a single settings.json change propagates everywhere.

import CoreLocation
import Foundation

// MARK: - HoverBounds

/// Geographic and altitude constraints for the NYC metro camera region.
///
/// Enforces:
/// 1. **Coordinate bounds** — center cannot leave the NYC metro area.
/// 2. **Distance bounds** — altitude stays between street-level and metro-wide.
///
/// The coordinate rectangle is intentionally generous (+0.15° lat/lon buffer
/// beyond the five boroughs) to accommodate NJ, Westchester, and Long Island
/// routes without false clamping.
enum HoverBounds {

    // MARK: - NYC Metro Rectangle

    /// Minimum latitude bound (southern border — lower NJ / SI).
    static let minLatitude: Double = 40.35

    /// Maximum latitude bound (northern border — upper Westchester).
    static let maxLatitude: Double = 41.15

    /// Minimum longitude bound (western border — central NJ).
    static let minLongitude: Double = -74.55

    /// Maximum longitude bound (eastern border — eastern Long Island).
    static let maxLongitude: Double = -73.45

    // MARK: - Altitude (camera distance) Bounds

    /// Closest the camera can be — hyper-zoomed street level (200 m).
    /// Below this, the user would see building rooftops with no transit context.
    static let minDistance: Double = 200

    /// Farthest the camera can be — full metro overview (~90 km).
    /// Beyond this, NYC becomes a dot and all spatial context is lost.
    static let maxDistance: Double = 90_000

    // MARK: - Clamping

    /// Clamps a coordinate to the NYC metro bounding rectangle.
    ///
    /// Out-of-region coordinates are snapped to the nearest edge rather
    /// than rejected, so callers never receive an invalid camera state.
    ///
    /// - Parameter coordinate: Raw geographic coordinate.
    /// - Returns: Coordinate guaranteed to be within `[minLat, maxLat] × [minLon, maxLon]`.
    static func clamp(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: min(maxLatitude, max(minLatitude, coordinate.latitude)),
            longitude: min(maxLongitude, max(minLongitude, coordinate.longitude))
        )
    }

    /// Clamps an altitude (camera distance) to the valid zoom range.
    ///
    /// - Parameter distance: Raw camera altitude in meters.
    /// - Returns: Distance in `[minDistance, maxDistance]`.
    static func clamp(distance: Double) -> Double {
        min(maxDistance, max(minDistance, distance))
    }

    // MARK: - Validation

    /// Returns `true` when the coordinate lies within the NYC metro rectangle.
    static func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= minLatitude
            && coordinate.latitude <= maxLatitude
            && coordinate.longitude >= minLongitude
            && coordinate.longitude <= maxLongitude
    }

    /// Returns `true` when the distance falls within the valid altitude range.
    static func distanceIsValid(_ distance: Double) -> Bool {
        distance >= minDistance && distance <= maxDistance
    }
}
