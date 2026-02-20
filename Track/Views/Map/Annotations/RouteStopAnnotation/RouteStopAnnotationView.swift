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
                    .fill(routeColor.opacity(0.25))
                    .frame(width: 28, height: 28)
            }

            // Outer ring — always uses the route color for visibility
            Circle()
                .fill(Color.white)
                .frame(width: isSelected ? 16 : 14, height: isSelected ? 16 : 14)
                .overlay {
                    Circle()
                        .stroke(
                            isSelected ? routeColor : routeColor.opacity(0.8),
                            lineWidth: isSelected ? 3 : 2.5)
                }
                .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)

            // Inner dot for visual anchor
            Circle()
                .fill(isSelected ? routeColor : routeColor.opacity(0.6))
                .frame(width: isSelected ? 6 : 4, height: isSelected ? 6 : 4)
        }
        .frame(width: 30, height: 30)
        .drawingGroup()
        .scaleEffect(isSelected ? 1.3 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        .accessibilityLabel(stopName)
    }
}
