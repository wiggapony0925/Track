import SwiftUI

/// Visual marker for route stops — Transit app style:
/// large white filled circle with a bold route-colored ring,
/// pulsing glow when selected.
struct RouteStopMarker: View, Equatable {
    let isBusRoute: Bool
    let isSelected: Bool
    /// When true the bus has already passed this stop — render dimmed.
    var isBehind: Bool = false
    let routeColor: Color
    let stopName: String

    static func == (lhs: RouteStopMarker, rhs: RouteStopMarker) -> Bool {
        lhs.isBusRoute == rhs.isBusRoute && lhs.isSelected == rhs.isSelected && lhs.isBehind == rhs.isBehind && lhs.stopName == rhs.stopName
    }

    var body: some View {
        ZStack {
            if isSelected {
                // Subtle selection halo — Apple Maps style
                Circle()
                    .fill(routeColor.opacity(0.12))
                    .frame(width: 26, height: 26)
            }

            // Clean white circle with route-colored ring
            Circle()
                .fill(AppTheme.Colors.cardFloating)
                .frame(
                    width: isSelected ? 14 : 10,
                    height: isSelected ? 14 : 10
                )
                .overlay {
                    Circle()
                        .stroke(
                            routeColor,
                            lineWidth: isSelected ? 2.5 : 2)
                }
                .shadow(color: AppTheme.Colors.shadow.opacity(0.18), radius: 2, x: 0, y: 1)

            // Center fill dot — only on selected stop
            if isSelected {
                Circle()
                    .fill(routeColor)
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 30, height: 30)
        .drawingGroup()
        .opacity(isBehind && !isSelected ? 0.30 : 1.0)
        .scaleEffect(isSelected ? 1.1 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .accessibilityLabel(stopName)
    }
}
