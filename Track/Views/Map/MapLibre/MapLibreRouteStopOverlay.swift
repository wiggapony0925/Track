//
//  MapLibreRouteStopOverlay.swift
//  Track
//
//  SwiftUI overlay rendering route stop markers when a specific route
//  is selected. Positions `RouteStopMarker` views using MapLibre's
//  coordinate → screen point projection.
//
//  Mirrors the `routeStopAnnotations` section of the original TrackMapView.
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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(stops) { stop in
                    let coord = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
                    if let point = projectToScreen(coord, in: geo) {
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

    // MARK: - Coordinate Projection

    private func projectToScreen(
        _ coordinate: CLLocationCoordinate2D,
        in geometry: GeometryProxy
    ) -> CGPoint? {
        guard let mapView else { return nil }
        let point = mapView.convert(coordinate, toPointTo: mapView)
        let margin: CGFloat = 30
        guard point.x > -margin, point.x < mapView.bounds.width + margin,
              point.y > -margin, point.y < mapView.bounds.height + margin
        else { return nil }
        return point
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

    var body: some View {
        if isActive, hasSelectedRoute, let coord = coordinate {
            GeometryReader { geo in
                if let point = projectToScreen(coord, in: geo) {
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

    private func projectToScreen(
        _ coordinate: CLLocationCoordinate2D,
        in geometry: GeometryProxy
    ) -> CGPoint? {
        guard let mapView else { return nil }
        let point = mapView.convert(coordinate, toPointTo: mapView)
        guard point.x > -20, point.x < mapView.bounds.width + 20,
              point.y > -20, point.y < mapView.bounds.height + 20
        else { return nil }
        return point
    }
}
