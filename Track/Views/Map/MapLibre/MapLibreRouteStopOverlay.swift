//
//  MapLibreRouteStopOverlay.swift
//  Track
//
//  SwiftUI overlay rendering route stop markers when a specific route
//  is selected. Positions `RouteStopMarker` views using MapLibre's
//  coordinate → screen point projection.
//

import CoreLocation
import MapLibre
import SwiftUI

// MARK: - Route Stop Overlay

/// A route stop plus the coordinate it should use for on-map display.
///
/// The raw `BusStop` coordinate is preserved for tap handling and walking
/// directions, while `displayCoordinate` can be snapped onto the rendered
/// polyline so the marker sits cleanly on the route.
struct DisplayedRouteStop: Identifiable {
    let stop: BusStop
    let displayCoordinate: CLLocationCoordinate2D
    /// True when this stop is behind the nearest stop (already passed by the bus).
    let isBehind: Bool

    var id: String { stop.id }
}

/// Renders stop markers along a selected route on top of MapLibre GL.
struct MapLibreRouteStopOverlay: View {
    let mapView: MLNMapView?

    /// Direction stops filtered to the current viewport.
    let stops: [DisplayedRouteStop]

    /// Whether the selected route is a bus route.
    let isBusRoute: Bool

    /// Currently selected stop ID (for highlight).
    let selectedStopId: String?

    /// Color of the selected route.
    let routeColor: Color

    /// Callback when a stop is tapped.
    let onStopTap: (BusStop) -> Void

    /// Bumped every camera frame to force SwiftUI re-projection during gestures.
    let cameraChangeToken: UInt64

    var body: some View {
        GeometryReader { _ in
            ZStack {
                ForEach(stops) { displayedStop in
                    stopMarkerView(for: displayedStop)
                }
            }
        }
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func stopMarkerView(for displayedStop: DisplayedRouteStop) -> some View {
        let stop: BusStop = displayedStop.stop
        let coord: CLLocationCoordinate2D = displayedStop.displayCoordinate
        let isSelected: Bool = stop.id == selectedStopId
        if let point: CGPoint = projectToScreen(coord, mapView: mapView, margin: 30) {
            RouteStopMarker(
                isBusRoute: isBusRoute,
                isSelected: isSelected,
                isBehind: displayedStop.isBehind,
                routeColor: routeColor,
                stopName: stop.name
            )
            .position(point)
            .onTapGesture { onStopTap(stop) }
        }
    }
}

// MARK: - Search Pin Overlay

/// The search-area blue dot that appears when drag-to-search is active
/// and a route detail is open.
struct MapLibreSearchPinOverlay: View {
    let mapView: MLNMapView?
    let coordinate: CLLocationCoordinate2D?
    let isActive: Bool
    let hasSelectedRoute: Bool

    /// Bumped every camera frame to force SwiftUI re-projection during gestures.
    let cameraChangeToken: UInt64

    var body: some View {
        if isActive, hasSelectedRoute, let coord = coordinate {
            GeometryReader { _ in
                if let point = projectToScreen(coord, mapView: mapView, margin: 20) {
                    ZStack {
                        // Accuracy halo
                        Circle()
                            .fill(AppTheme.Colors.mtaBlue.opacity(0.12))
                            .frame(width: 36, height: 36)
                        // White border
                        Circle()
                            .fill(AppTheme.Colors.cardBackground)
                            .frame(width: 18, height: 18)
                            .shadow(color: AppTheme.Colors.shadow.opacity(0.25), radius: 2, y: 1)
                        // Blue fill
                        Circle()
                            .fill(AppTheme.Colors.mtaBlue)
                            .frame(width: 12, height: 12)
                    }
                    .position(point)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
