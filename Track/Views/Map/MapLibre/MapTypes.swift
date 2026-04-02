// Shared types and helpers for the MapLibre GL rendering pipeline.

import CoreLocation
import Foundation
import MapLibre

// MARK: - ZoomTier

/// Discrete zoom tiers to avoid continuous re-renders of station markers.
/// Station annotation bodies only re-evaluate when crossing a tier boundary,
/// not on every pixel of zoom change.
enum ZoomTier: CGFloat {
    case veryClose = 1.8
    case close     = 1.3
    case medium    = 1.0
    case far       = 0.7
    case distant   = 0.4

    /// Determines the appropriate zoom tier for a given camera distance.
    static func tier(for distance: Double?) -> ZoomTier {
        guard let d = distance else { return .medium }
        if d < 1_500  { return .veryClose }
        if d < 3_500  { return .close }
        if d < 8_000  { return .medium }
        if d < 25_000 { return .far }
        return .distant
    }
}

// MARK: - TransferConnector

/// A thin grey line connecting two platforms in the same station complex
/// that are on different physical levels (e.g., elevated 7 ↔ underground E/F/M/R).
struct TransferConnector: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    /// Straight-line distance in meters from the platform to the
    /// complex centroid. Short distances (vertical transfers like
    /// 74 St) get a thicker, more opaque line; long walking
    /// transfers get thinner, fainter lines.
    let distanceMeters: Double
}

// MARK: - Coordinate Projection Helper

/// Projects a geographic coordinate to a screen point via MapLibre's
/// camera matrix. Returns `nil` if the coordinate is outside the
/// visible bounds (plus `margin` overflow for partially-visible markers).
///
/// Complexity: O(1) — single matrix multiply.
///
/// - Parameters:
///   - coordinate: The geographic coordinate to project.
///   - mapView: The MLNMapView performing the projection.
///   - margin: Extra pixels beyond the viewport to keep partially-visible markers.
/// - Returns: The screen point, or `nil` if offscreen.
@inlinable
func projectToScreen(
    _ coordinate: CLLocationCoordinate2D,
    mapView: MLNMapView?,
    margin: CGFloat = 40
) -> CGPoint? {
    guard let mapView else { return nil }
    let point = mapView.convert(coordinate, toPointTo: mapView)
    guard point.x > -margin, point.x < mapView.bounds.width + margin,
          point.y > -margin, point.y < mapView.bounds.height + margin
    else { return nil }
    return point
}
