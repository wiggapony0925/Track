import SwiftUI

/// A sleek, creative Subway annotation using a glassmorphism pill and the iconic MTA bullet.
struct TrainAnnotation: View, Equatable {
    let routeId: String
    let direction: String
    var isHighlighted: Bool = false

    static func == (lhs: TrainAnnotation, rhs: TrainAnnotation) -> Bool {
        lhs.routeId == rhs.routeId && lhs.direction == rhs.direction && lhs.isHighlighted == rhs.isHighlighted
    }
    
    var body: some View {
        ZStack {
            // Main Glass Pill
            HStack(spacing: 4) {
                // The iconic MTA Bullet
                ZStack {
                    Circle()
                        .fill(AppTheme.SubwayColors.color(for: routeId))
                        .frame(width: isHighlighted ? 18 : 14)
                    
                    Text(routeId)
                        .font(.system(size: isHighlighted ? 10 : 8, weight: .black))
                        .foregroundColor(.white)
                }
                
                // Direction Indicator (Minimalist)
                Image(systemName: direction == "N" ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.trailing, 2)
            }
            .padding(4)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            }
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
            }
            .shadow(color: AppTheme.SubwayColors.color(for: routeId).opacity(0.35), radius: 4, y: 2)
            .shadow(color: .black.opacity(0.15), radius: 2)
        }
        .scaleEffect(isHighlighted ? 1.3 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isHighlighted)
        .drawingGroup()
    }
}
