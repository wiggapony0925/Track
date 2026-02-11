//
//  BusStopAnnotation.swift
//  Track
//
//  A small circular blue pin with a white bus icon for bus stop map annotations.
//

import SwiftUI

struct BusStopAnnotation: View {
    let stopName: String

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Colors.mtaBlue)
                .frame(width: 30, height: 30)
                .shadow(radius: 2)

            Image(systemName: "bus.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
        .accessibilityLabel("Bus stop: \(stopName)")
    }
}

#Preview {
    BusStopAnnotation(stopName: "5 Av / Union St")
        .padding()
}
