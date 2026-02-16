//
//  AmtrakMarker.swift
//  Track
//
//  Native MapKit Marker for live Amtrak train positions.
//  Uses the tram icon (consistent with subway) tinted with
//  Amtrak's signature blue.
//

import SwiftUI
import MapKit

/// A native MapKit `Marker` for a single Amtrak train vehicle.
/// Uses the `tram.fill` icon (same family as subway) and tints
/// the balloon with Amtrak blue.
struct AmtrakMarker: MapContent {
    let train: HomeViewModel.TrainVehicle

    var body: some MapContent {
        Marker(
            train.nextStationName ?? train.routeId,
            systemImage: "tram.fill",
            coordinate: CLLocationCoordinate2D(
                latitude: train.lat,
                longitude: train.lon
            )
        )
        .tint(Color(hex: "#005596"))
    }
}
