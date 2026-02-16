import SwiftUI

/// A sleek, modern subway station marker.
struct SubwayStationMarker: View {
    let station: HomeViewModel.CachedSubwayStation

    var body: some View {
        ZStack {
            // Background Hub Circle
            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
            
            // Inner Core
            Circle()
                .fill(Color.black)
                .frame(width: 10, height: 10)
                .overlay {
                    // Modern minimalist 'm'
                    Text("m")
                        .font(.system(size: 7, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .offset(y: -0.5)
                }
            
            // Colorful route indicator ring (Subtle)
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [.red, .blue, .green, .orange, .purple],
                        center: .center
                    ),
                    lineWidth: 1.5
                )
                .frame(width: 16, height: 16)
        }
        .accessibilityLabel("Station: \(station.name)")
    }
}
