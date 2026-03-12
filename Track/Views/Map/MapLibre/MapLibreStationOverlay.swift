//
//  MapLibreStationOverlay.swift
//  Track
//
//  SwiftUI overlay rendering station capsule markers on top of the
//  MapLibre GL map. Uses coordinate-to-screen-point projection to
//  position the existing `StationCapsuleView` components.
//
//  Performance: O(n) per frame where n = cached visible stations.
//  Viewport culling is done upstream.
//

import CoreLocation
import MapLibre
import SwiftUI

// MARK: - Station Overlay

/// Renders station capsule markers as a SwiftUI overlay above MapLibre GL.
struct MapLibreStationOverlay: View {
    /// Reference to the underlying MapLibre map view.
    let mapView: MLNMapView?

    /// Visible stations (pre-filtered to viewport by TrackMapView logic).
    let stations: [MapSystemViewModel.ConsolidatedStation]

    /// Transfer connectors — thin lines between multi-platform complexes.
    /// Rendered as map layers, not in this overlay.
    let transferConnectors: [TransferConnector]

    /// Current zoom tier for size adaptation.
    let zoomTier: ZoomTier

    /// Whether station labels should be visible.
    let showLabels: Bool

    /// Imminent arrivals map (stopId → routeId) for pulse animation.
    let imminentArrivals: [String: String]

    /// Whether a route is selected (hides system stations).
    let hasActiveRoute: Bool

    /// Bumped every camera frame to force SwiftUI re-projection during gestures.
    let cameraChangeToken: UInt64

    @ViewBuilder
    var body: some View {
        if !hasActiveRoute {
            GeometryReader { _ in
                ZStack {
                    ForEach(stations) { station in
                        if let point = projectToScreen(station.coordinate, mapView: mapView, margin: 60) {
                            let pulseRouteId: String? = imminentArrivals.isEmpty ? nil :
                                station.sourceStopIDs.lazy.compactMap { imminentArrivals[$0] }.first

                            StationCapsuleView(
                                station: station,
                                zoomTier: zoomTier,
                                imminentRouteId: pulseRouteId
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
