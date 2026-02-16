import SwiftUI

/// A sleek, creative Subway annotation using a glassmorphism pill and the iconic MTA bullet.
struct TrainAnnotation: View {
    let routeId: String
    let direction: String
    var isHighlighted: Bool = false
    
    var body: some View {
        ZStack {
            // Shadow / Glow
            Capsule()
                .fill(AppTheme.SubwayColors.color(for: routeId).opacity(0.3))
                .frame(width: isHighlighted ? 45 : 35, height: isHighlighted ? 24 : 18)
                .blur(radius: 4)
                .offset(y: 2)

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
            .shadow(color: .black.opacity(0.2), radius: 2)
        }
        .scaleEffect(isHighlighted ? 1.3 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isHighlighted)
    }
}
