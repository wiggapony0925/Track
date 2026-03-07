//
//  VehicleMarkerContent.swift
//  Track
//
//  Shared annotation content view for all live vehicle markers
//  (bus, subway, LIRR, MNR). Eliminates duplicate rendering code
//  across BusVehicleMarker, SubwayTrainMarker, LIRRMarker, MNRMarker.
//

import SwiftUI

/// Reusable vehicle marker icon rendered inside a MapKit `Annotation`.
/// All four vehicle types share the same circle-icon layout and
/// highlight/tap behavior — only the icon and color differ.
struct VehicleMarkerContent: View {
    let icon: String
    let color: Color
    let isHighlighted: Bool
    var onTap: (() -> Void)? = nil

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(isHighlighted ? Color.white : Color.clear, lineWidth: 3)
            )
            .shadow(
                color: isHighlighted ? color.opacity(0.6) : .black.opacity(0.2),
                radius: isHighlighted ? 6 : 2,
                y: isHighlighted ? 0 : 1
            )
            .scaleEffect(isHighlighted ? 1.3 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHighlighted)
            .drawingGroup()
            .onTapGesture { onTap?() }
    }
}
