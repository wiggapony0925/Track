//
//  SubwayTrainMarker.swift
//  Track
//
//  MapKit Annotation for live subway train positions.
//  Uses Annotation so taps can be detected and forwarded to
//  the ViewModel for highlighting the matching arrival row.
//

import SwiftUI
import MapKit

/// A MapKit `Annotation` for a single subway train vehicle.
/// Uses `Annotation` instead of `Marker` so `onTapGesture` works,
/// allowing users to tap a train on the map to highlight its arrival row.
struct SubwayTrainMarker: MapContent {
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
                icon: TransportMode.subway.icon,
                color: AppTheme.SubwayColors.color(for: train.routeId),
                isHighlighted: isHighlighted,
                onTap: onTap
            )
        }
    }
}
