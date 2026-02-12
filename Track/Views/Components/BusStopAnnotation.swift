//
//  BusStopAnnotation.swift
//  Track
//
//  A small white dot with a blue stroke for bus stop map annotations.
//

import SwiftUI

struct BusStopAnnotation: View {
    let stopName: String

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 8, height: 8)
            .shadow(radius: 2)
            .overlay(
                Circle()
                    .stroke(AppTheme.Colors.mtaBlue, lineWidth: 2)
            )
            .accessibilityLabel("Bus stop: \(stopName)")
    }
}

#Preview {
    BusStopAnnotation(stopName: "5 Av / Union St")
        .padding()
}
