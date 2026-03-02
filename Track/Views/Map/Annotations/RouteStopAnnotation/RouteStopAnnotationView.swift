import SwiftUI

/// Visual marker for route stops — Transit app style:
/// large white filled circle with a bold route-colored ring,
/// pulsing glow when selected.
struct RouteStopMarker: View {
    let isBusRoute: Bool
    let isSelected: Bool
    let routeColor: Color
    let stopName: String

    var body: some View {
        ZStack {
            if isSelected {
                // Outer pulsing glow ring — mimics Transit's selection highlight
                Circle()
                    .fill(routeColor.opacity(0.2))
                    .frame(width: 36, height: 36)

                Circle()
                    .fill(routeColor.opacity(0.1))
                    .frame(width: 46, height: 46)
            }

            // Drop shadow base for depth
            Circle()
                .fill(Color.black.opacity(0.18))
                .frame(
                    width: isSelected ? 24 : 20,
                    height: isSelected ? 24 : 20
                )
                .blur(radius: 3)
                .offset(y: 2)

            // Bold route-colored ring — the signature Transit look
            Circle()
                .fill(Color.white)
                .frame(
                    width: isSelected ? 22 : 18,
                    height: isSelected ? 22 : 18
                )
                .overlay {
                    Circle()
                        .stroke(
                            isSelected ? routeColor : routeColor,
                            lineWidth: isSelected ? 4.5 : 3.5)
                }
                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1.5)

            // Center fill dot — only on selected stop to draw the eye
            if isSelected {
                Circle()
                    .fill(routeColor)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 50, height: 50)
        .drawingGroup()
        .scaleEffect(isSelected ? 1.15 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        .accessibilityLabel(stopName)
    }
}
