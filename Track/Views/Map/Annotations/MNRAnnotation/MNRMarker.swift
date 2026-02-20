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
            Image(systemName: TransportMode.mnr.icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(AppTheme.CommuterRailColors.mnrBlue)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(isHighlighted ? Color.white : Color.clear, lineWidth: 3)
                )
                .shadow(color: isHighlighted ? AppTheme.CommuterRailColors.mnrBlue.opacity(0.6) : .black.opacity(0.2), radius: isHighlighted ? 6 : 2, y: isHighlighted ? 0 : 1)
                .scaleEffect(isHighlighted ? 1.3 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHighlighted)
                .onTapGesture {
                    onTap?()
                }
        }
    }
}
