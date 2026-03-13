//
//  MapLibreStationOverlay.swift
//  Track
//
//  SwiftUI overlay rendering route label bubbles on top of the
//  MapLibre GL map. Uses coordinate-to-screen-point projection.
//

import CoreLocation
import MapLibre
import SwiftUI

// MARK: - Route Labels Overlay

/// Renders trunk route label bubbles (e.g., "A C E" circles) on the
/// MapLibre map at close zoom levels.
struct MapLibreRouteLabelOverlay: View {
    let mapView: MLNMapView?
    let labels: [HomeViewModel.TrunkRouteLabel]
    let currentDistance: Double?
    let hasActiveRoute: Bool

    /// Bumped every camera frame to force SwiftUI re-projection during gestures.
    let cameraChangeToken: UInt64

    @ViewBuilder
    var body: some View {
        if !hasActiveRoute,
           let distance = currentDistance,
           distance < AppSettings.shared.stationMaxZoomOutMeters * 0.16
        {
            GeometryReader { _ in
                ZStack {
                    ForEach(labels) { label in
                        if let point = projectToScreen(label.coordinate, mapView: mapView) {
                            TrunkRouteLabelView(
                                routeIds: label.routeIds,
                                color: label.color
                            )
                            .position(point)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}
