//
//  SubwayTrainMarker.swift
//  Track
//
//  Native MapKit Marker for live subway train positions.
//  Uses the same tram icon from the app's tab bar, tinted
//  with the official MTA line color.
//

import SwiftUI
import MapKit

/// A native MapKit `Marker` for a single subway train vehicle.
/// Matches the app's tab-bar icon (`tram.fill`) and tints the
/// balloon with the subway line's brand color.
struct SubwayTrainMarker: MapContent {
    let train: HomeViewModel.TrainVehicle

    var body: some MapContent {
        Marker(
            train.nextStationName ?? train.routeId,
            systemImage: TransportMode.subway.icon,
            coordinate: CLLocationCoordinate2D(
                latitude: train.lat,
                longitude: train.lon
            )
        )
        .tint(AppTheme.SubwayColors.color(for: train.routeId))
    }
}
