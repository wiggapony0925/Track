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

/// Renders stop markers along a selected route on top of MapLibre GL.
struct MapLibreRouteStopOverlay: View {
    let mapView: MLNMapView?

    /// Direction stops filtered to the current viewport.
    let stops: [BusStop]

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
                ForEach(stops) { stop in
                    let coord = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
                    if let point = projectToScreen(coord, mapView: mapView, margin: 30) {
                        RouteStopMarker(
                            isBusRoute: isBusRoute,
                            isSelected: stop.id == selectedStopId,
                            routeColor: routeColor,
                            stopName: stop.name
                        )
                        .position(point)
                        .onTapGesture { onStopTap(stop) }
                    }
                }
            }
        }
        .allowsHitTesting(true)
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
                            .fill(Color(red: 0.0, green: 0.48, blue: 1.0).opacity(0.12))
                            .frame(width: 36, height: 36)
                        // White border
                        Circle()
                            .fill(.white)
                            .frame(width: 18, height: 18)
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        // Blue fill
                        Circle()
                            .fill(Color(red: 0.0, green: 0.48, blue: 1.0))
                            .frame(width: 12, height: 12)
                    }
                    .position(point)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
