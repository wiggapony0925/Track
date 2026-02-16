import SwiftUI

/// Visual marker for route stops, redesigned to be sleek and creative.
struct RouteStopMarker: View {
    let isBusRoute: Bool
    let isSelected: Bool
    let routeColor: Color
    let stopName: String
    
    var body: some View {
        ZStack {
            if isSelected {
                // Outer Pulse/Glow
                Circle()
                    .fill(routeColor.opacity(0.2))
                    .frame(width: 24, height: 24)
                    .scaleEffect(1.2)
            }

            // Central Point
            Circle()
                .fill(Color.white)
                .frame(width: isSelected ? 12 : 8)
                .shadow(color: .black.opacity(0.1), radius: 1)
                .overlay {
                    Circle()
                        .stroke(isSelected ? routeColor : Color.gray.opacity(0.5), lineWidth: isSelected ? 4 : 2)
                }
            
            if isSelected {
                // Tiny dot in middle for "selected" feel
                Circle()
                    .fill(routeColor)
                    .frame(width: 4, height: 4)
            }
        }
        .scaleEffect(isSelected ? 1.4 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        .accessibilityLabel(stopName)
    }
}
