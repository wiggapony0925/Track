import SwiftUI

/// A minimalist, creative bus stop marker.
struct BusStopAnnotation: View, Equatable {
    let stopName: String
    var isSelected: Bool = false

    var body: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(AppTheme.Colors.mtaBlue.opacity(0.1))
                    .frame(width: 18, height: 18)
            }

            Circle()
                .fill(Color.white)
                .frame(width: isSelected ? 10 : 6)
                .overlay {
                    Circle()
                        .stroke(AppTheme.Colors.mtaBlue, lineWidth: isSelected ? 2 : 1.5)
                }
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 0.5)
        }
        .scaleEffect(isSelected ? 1.2 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .drawingGroup()
        .accessibilityLabel("Bus stop: \(stopName)")
    }
}
