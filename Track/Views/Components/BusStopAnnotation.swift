//
//  BusStopAnnotation.swift
//  Track
//
//  A small white dot with a blue stroke for bus stop map annotations.
//

import SwiftUI

struct BusStopAnnotation: View {
    let stopName: String
    var isSelected: Bool = false

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: isSelected ? 14 : 8, height: isSelected ? 14 : 8)
            .shadow(radius: 2)
            .overlay(
                Circle()
                    .stroke(AppTheme.Colors.mtaBlue, lineWidth: isSelected ? 4 : 2)
            )
            .scaleEffect(isSelected ? 1.2 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
            .accessibilityLabel("Bus stop: \(stopName)")
    }
}

#Preview {
    BusStopAnnotation(stopName: "5 Av / Union St")
        .padding()
}
