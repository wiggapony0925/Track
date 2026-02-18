//
//  BusVehicleMarker.swift
//  Track
//
//  MapKit Annotation for live bus vehicle positions.
//  Uses Annotation instead of Marker so SwiftUI's withAnimation()
//  can smoothly interpolate the coordinate changes.
//

import SwiftUI
import MapKit

/// A MapKit `Annotation` for a single bus vehicle.
/// Uses `Annotation` instead of `Marker` because `Marker` positions
/// snap instantly — they don't respond to SwiftUI animation. By using
/// `Annotation`, the `withAnimation(.linear)` in `updateBusSimulation()`
/// smoothly glides the bus icon along the route polyline.
struct BusVehicleMarker: MapContent {
    let vehicle: BusVehicleResponse

    var body: some MapContent {
        Annotation(
            markerETALabel(minutesAway: vehicle.minutesAway, fallback: vehicle.nextStop ?? vehicle.displayRouteName),
            coordinate: CLLocationCoordinate2D(
                latitude: vehicle.lat,
                longitude: vehicle.lon
            )
        ) {
            Image(systemName: TransportMode.bus.icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(AppTheme.Colors.mtaBlue)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
    }
}
