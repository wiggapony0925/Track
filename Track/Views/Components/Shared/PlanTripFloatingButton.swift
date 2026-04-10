// Floating circular button that hovers above the bottom sheet,
// inviting users to plan a trip. Glassmorphic style with a breathing
// accent glow ring and a tap-ripple effect — matches the visual
// language of DragSearchToggleButton.

import SwiftUI

struct PlanTripFloatingButton: View {

    var action: () -> Void

    // MARK: - Animation State

    /// Breathing glow ring.
    @State private var glowPulse = false
    /// Tap-ripple scale.
    @State private var rippleScale: CGFloat = 0.01
    /// Tap-ripple opacity.
    @State private var rippleOpacity: Double = 0
    /// Subtle icon rotation kick on tap.
    @State private var iconRotation: Double = 0
    /// Entrance scale for appear animation.
    @State private var appeared = false

    // MARK: - Constants

    private let size: CGFloat = 48
    private let iconSize: CGFloat = 18

    // MARK: - Body

    var body: some View {
        Button {
            handleTap()
        } label: {
            ZStack {
                // ── Breathing glow ring ──
                Circle()
                    .stroke(
                        AppTheme.Colors.accent.opacity(0.3),
                        lineWidth: 2.5
                    )
                    .frame(width: size + 8, height: size + 8)
                    .scaleEffect(glowPulse ? 1.15 : 1.0)
                    .opacity(glowPulse ? 0.25 : 0.55)

                // ── Tap ripple ──
                Circle()
                    .stroke(
                        AppTheme.Colors.accent.opacity(0.4),
                        lineWidth: 2
                    )
                    .frame(width: size, height: size)
                    .scaleEffect(rippleScale)
                    .opacity(rippleOpacity)

                // ── Glass circle ──
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle()
                            .fill(AppTheme.Colors.accent.opacity(0.12))
                    }
                    .overlay {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.15),
                                        .clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(
                                AppTheme.Colors.accent.opacity(0.35),
                                lineWidth: 0.5
                            )
                    }
                    .frame(width: size, height: size)

                // ── Icon ──
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .rotationEffect(.degrees(iconRotation))
            }
            .shadow(color: AppTheme.Colors.accent.opacity(0.15), radius: 12, x: 0, y: 4)
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
            .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(PlanTripButtonStyle())
        .scaleEffect(appeared ? 1.0 : 0.5)
        .opacity(appeared ? 1.0 : 0)
        .onAppear {
            // Entrance animation
            withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) {
                appeared = true
            }
            // Start breathing glow
            withAnimation(
                .easeInOut(duration: 2.0)
                .repeatForever(autoreverses: true)
            ) {
                glowPulse = true
            }
        }
        .accessibilityLabel("Plan a trip")
    }

    // MARK: - Tap Handler

    private func handleTap() {
        HapticManager.impact(.medium)
        fireRipple()

        // Icon rotation kick
        withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
            iconRotation += 180
        }

        // Settle rotation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                iconRotation = 0
            }
        }

        // Fire action slightly delayed so user sees the animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            action()
        }
    }

    private func fireRipple() {
        rippleScale = 0.6
        rippleOpacity = 0.8
        withAnimation(.easeOut(duration: 0.45)) {
            rippleScale = 2.4
            rippleOpacity = 0.0
        }
    }
}

// MARK: - Button Style

private struct PlanTripButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(
                .spring(response: 0.25, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.gray.opacity(0.2).ignoresSafeArea()
        VStack {
            Spacer()
            HStack {
                Spacer()
                PlanTripFloatingButton { }
                    .padding(.trailing, 16)
                    .padding(.bottom, 40)
            }
        }
    }
}
