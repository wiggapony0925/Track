//
//  AmtrakMarker.swift
//  Track
//
//  MapKit Annotation for live Amtrak train positions.
//  Uses Annotation so taps can be detected and forwarded to
//  the ViewModel for highlighting the matching arrival row.
//

import SwiftUI
import MapKit

/// A MapKit `Annotation` for a single Amtrak train vehicle.
/// Uses `Annotation` instead of `Marker` so `onTapGesture` works.
struct AmtrakMarker: MapContent {
    let train: HomeViewModel.TrainVehicle
    var isHighlighted: Bool = false
    var onTap: (() -> Void)? = nil

    private let amtrakBlue = Color(hex: "#005596")

    var body: some MapContent {
        Annotation(
            markerETALabel(minutesAway: train.minutesAway, fallback: train.nextStationName ?? train.routeId),
            coordinate: CLLocationCoordinate2D(
                latitude: train.lat,
                longitude: train.lon
            )
        ) {
            Image(systemName: "tram.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(amtrakBlue)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(isHighlighted ? Color.white : Color.clear, lineWidth: 3)
                )
                .shadow(color: isHighlighted ? amtrakBlue.opacity(0.6) : .black.opacity(0.2), radius: isHighlighted ? 6 : 2, y: isHighlighted ? 0 : 1)
                .scaleEffect(isHighlighted ? 1.3 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHighlighted)
                .onTapGesture {
                    onTap?()
                }
        }
    }
}
