//
//  LIRRMarker.swift
//  Track
//
//  MapKit Annotation for live LIRR train positions.
//  Uses Annotation so taps can be detected and forwarded to
//  the ViewModel for highlighting the matching arrival row.
//

import SwiftUI
import MapKit

/// A MapKit `Annotation` for a single LIRR train vehicle.
/// Uses `Annotation` instead of `Marker` so `onTapGesture` works.
struct LIRRMarker: MapContent {
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
                icon: TransportMode.lirr.icon,
                color: AppTheme.CommuterRailColors.lirrBlue,
                isHighlighted: isHighlighted,
                onTap: onTap
            )
        }
    }
}
