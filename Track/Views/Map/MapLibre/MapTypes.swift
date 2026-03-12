//
//  MapTypes.swift
//  Track
//
//  Shared types extracted from TrackMapView for use across the
//  MapLibre GL rendering pipeline. These were originally nested
//  inside TrackMapView but are now standalone so the old MapKit
//  file can be removed without breaking MapLibre views.
//

import CoreLocation
import Foundation

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
