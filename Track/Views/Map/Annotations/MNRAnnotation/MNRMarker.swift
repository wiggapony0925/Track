//
//  MNRMarker.swift
//  Track
//
//  Native MapKit Marker for live Metro-North Railroad train positions.
//  Uses the same train icon from the app's tab bar, tinted
//  with the MNR brand blue.
//

import SwiftUI
import MapKit

/// A native MapKit `Marker` for a single Metro-North train vehicle.
/// Matches the app's tab-bar icon (`train.side.rear.car`)
/// and tints the balloon with MNR blue.
struct MNRMarker: MapContent {
    let train: HomeViewModel.TrainVehicle

    var body: some MapContent {
        Marker(
            train.nextStationName ?? train.routeId,
            systemImage: TransportMode.mnr.icon,
            coordinate: CLLocationCoordinate2D(
                latitude: train.lat,
                longitude: train.lon
            )
        )
        .tint(AppTheme.CommuterRailColors.mnrBlue)
    }
}
