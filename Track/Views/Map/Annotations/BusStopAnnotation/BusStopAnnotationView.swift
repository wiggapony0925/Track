import SwiftUI

/// A minimalist, creative bus stop marker.
struct BusStopAnnotation: View {
    let stopName: String
    var isSelected: Bool = false

    var body: some View {
        ZStack {
            if isSelected {
                Circle()
                    .stroke(AppTheme.Colors.mtaBlue.opacity(0.3), lineWidth: 4)
                    .frame(width: 20, height: 20)
                    .scaleEffect(1.2)
            }

            Circle()
                .fill(Color.white)
                .frame(width: isSelected ? 12 : 8)
                .shadow(radius: 2)
                .overlay {
                    Circle()
                        .stroke(AppTheme.Colors.mtaBlue, lineWidth: isSelected ? 3 : 2)
                }
            
            if isSelected {
                Image(systemName: "bus")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
            }
        }
        .scaleEffect(isSelected ? 1.5 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        .accessibilityLabel("Bus stop: \(stopName)")
    }
}
