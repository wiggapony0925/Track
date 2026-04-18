// Reusable floating circle button — close (X), location, share, etc.
// Replaces 5+ hand-rolled circle buttons across sheets and overlays.

import SwiftUI

struct FloatingCircleButton: View {
    let icon: String
    var fillColor: Color = AppTheme.Colors.alertRed
    var iconColor: Color = .white
    var size: CGFloat = 38
    var iconSize: CGFloat = 15
    var shadowRadius: CGFloat = 8
    var shadowY: CGFloat = 3
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(fillColor)
                        .shadow(
                            color: fillColor.opacity(0.4),
                            radius: shadowRadius,
                            y: shadowY
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HStack(spacing: 16) {
        FloatingCircleButton(icon: "xmark") {}
        FloatingCircleButton(
            icon: "location.fill",
            fillColor: AppTheme.Colors.accent,
            iconSize: 14
        ) {}
        FloatingCircleButton(
            icon: "square.and.arrow.up",
            fillColor: AppTheme.Colors.accent,
            iconSize: 14
        ) {}
    }
    .padding()
    .preferredColorScheme(.dark)
}
