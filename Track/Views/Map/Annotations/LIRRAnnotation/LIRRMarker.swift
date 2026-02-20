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
            Image(systemName: TransportMode.lirr.icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(AppTheme.CommuterRailColors.lirrBlue)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(isHighlighted ? Color.white : Color.clear, lineWidth: 3)
                )
                .shadow(color: isHighlighted ? AppTheme.CommuterRailColors.lirrBlue.opacity(0.6) : .black.opacity(0.2), radius: isHighlighted ? 6 : 2, y: isHighlighted ? 0 : 1)
                .scaleEffect(isHighlighted ? 1.3 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHighlighted)
                .onTapGesture {
                    onTap?()
                }
        }
    }
}
