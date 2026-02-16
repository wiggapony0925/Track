//
//  BusVehicleMarker.swift
//  Track
//
//  Native MapKit Marker for live bus vehicle positions.
//  Uses the same bus icon from the app's tab bar, tinted MTA Blue.
//

import SwiftUI
import MapKit

/// A native MapKit `Marker` for a single bus vehicle.
/// Matches the app's tab-bar icon (`bus.fill`) and tints
/// the balloon with MTA Blue.
struct BusVehicleMarker: MapContent {
    let vehicle: BusVehicleResponse

    var body: some MapContent {
        Marker(
            vehicle.nextStop ?? vehicle.displayRouteName,
            systemImage: TransportMode.bus.icon,
            coordinate: CLLocationCoordinate2D(
                latitude: vehicle.lat,
                longitude: vehicle.lon
            )
        )
        .tint(AppTheme.Colors.mtaBlue)
    }
}
