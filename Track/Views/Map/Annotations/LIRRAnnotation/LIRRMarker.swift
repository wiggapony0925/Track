//
//  LIRRMarker.swift
//  Track
//
//  Native MapKit Marker for live LIRR train positions.
//  Uses the same train icon from the app's tab bar, tinted
//  with the LIRR brand blue.
//

import SwiftUI
import MapKit

/// A native MapKit `Marker` for a single LIRR train vehicle.
/// Matches the app's tab-bar icon (`train.side.front.car`)
/// and tints the balloon with LIRR blue.
struct LIRRMarker: MapContent {
    let train: HomeViewModel.TrainVehicle

    var body: some MapContent {
        Marker(
            markerETALabel(minutesAway: train.minutesAway, fallback: train.nextStationName ?? train.routeId),
            systemImage: TransportMode.lirr.icon,
            coordinate: CLLocationCoordinate2D(
                latitude: train.lat,
                longitude: train.lon
            )
        )
        .tint(AppTheme.CommuterRailColors.lirrBlue)
    }
}
