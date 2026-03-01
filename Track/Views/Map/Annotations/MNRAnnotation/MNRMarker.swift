//
//  MNRMarker.swift
//  Track
//
//  MapKit Annotation for live Metro-North Railroad train positions.
//  Uses Annotation so taps can be detected and forwarded to
//  the ViewModel for highlighting the matching arrival row.
//

import SwiftUI
import MapKit

/// A MapKit `Annotation` for a single Metro-North train vehicle.
/// Uses `Annotation` instead of `Marker` so `onTapGesture` works.
struct MNRMarker: MapContent {
    let train: TrainVehicle
    var isHighlighted: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some MapContent {
        Annotation(
            markerETALabel(minutesAway: train.minutesAway, fallback: train.nextStationName ?? train.routeId),
            coordinate: CLLocationCoordinate2D(
                latitude: train.lat,
                longitude: train.lon
            )
        ) {
            VehicleMarkerContent(
                icon: TransportMode.mnr.icon,
                color: AppTheme.CommuterRailColors.mnrBlue,
                isHighlighted: isHighlighted,
                onTap: onTap
            )
        }
    }
}
