import SwiftUI

/// A premium minimalist search pin using glassmorphism.
struct SearchPinAnnotation: View {
    var body: some View {
        ZStack {
            // Radial Glow
            Circle()
                .fill(RadialGradient(colors: [AppTheme.Colors.alertRed.opacity(0.3), .clear], center: .center, startRadius: 0, endRadius: 25))
                .frame(width: 50, height: 50)

            // Blur Ring
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 32, height: 32)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.5), lineWidth: 1)
                }
            
            // Central Dot
            Circle()
                .fill(AppTheme.Colors.alertRed)
                .frame(width: 12, height: 12)
                .shadow(color: AppTheme.Colors.alertRed.opacity(0.8), radius: 4)
            
            // Crosshair lines
            Rectangle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 1, height: 40)
            Rectangle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 40, height: 1)
        }
        .accessibilityLabel("Search pin — drag to explore")
    }
}
