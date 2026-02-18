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
    var isHighlighted: Bool = false
    var onTap: (() -> Void)? = nil

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
                .overlay(
                    Circle()
                        .stroke(isHighlighted ? Color.white : Color.clear, lineWidth: 3)
                )
                .shadow(color: isHighlighted ? AppTheme.Colors.mtaBlue.opacity(0.6) : .black.opacity(0.2), radius: isHighlighted ? 6 : 2, y: isHighlighted ? 0 : 1)
                .scaleEffect(isHighlighted ? 1.3 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHighlighted)
                .onTapGesture {
                    onTap?()
                }
        }
    }
}
