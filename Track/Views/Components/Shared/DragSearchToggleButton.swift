// Floating toggle button for enabling/disabling drag-to-search.
// Displayed at the top-left of the map. A hand-finger icon animates
// between active (hand.draw.fill) and inactive (hand.raised.slash)
// states with a satisfying circular reveal + spring animation.

import SwiftUI

/// A circular glassmorphic toggle that lets the user quickly enable
/// or disable drag-to-search without opening Settings.
struct DragSearchToggleButton: View {

    @Binding var isEnabled: Bool

    // MARK: - Animation State

    /// Drives the circular wipe / reveal on toggle.
    @State private var circleReveal: CGFloat = 1.0
    /// Subtle rotation of the hand icon on toggle.
    @State private var iconRotation: Double = 0
    /// Momentary press-ripple scale.
    @State private var rippleScale: CGFloat = 0.01
    /// Ripple opacity.
    @State private var rippleOpacity: Double = 0

    // MARK: - Constants

    private let size: CGFloat = 42
    private let iconSize: CGFloat = 16

    // MARK: - Body

    var body: some View {
        Button {
            toggle()
        } label: {
            ZStack {
                // ── Ripple ring (on tap) ──
                Circle()
                    .stroke(
                        isEnabled
                            ? AppTheme.Colors.mtaBlue.opacity(0.4)
                            : AppTheme.Colors.textSecondary.opacity(0.3),
                        lineWidth: 2
                    )
                    .frame(width: size, height: size)
                    .scaleEffect(rippleScale)
                    .opacity(rippleOpacity)

                // ── Background circle ──
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle()
                            .fill(
                                isEnabled
                                    ? AppTheme.Colors.mtaBlue.opacity(0.15)
                                    : AppTheme.Colors.cardBackground.opacity(0.35)
                            )
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(
                                isEnabled
                                    ? AppTheme.Colors.mtaBlue.opacity(0.3)
                                    : .white.opacity(0.16),
                                lineWidth: 0.5
                            )
                    }
                    .frame(width: size, height: size)

                // ── Hand icon ──
                Image(systemName: isEnabled ? "hand.draw.fill" : "hand.raised.slash")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(
                        isEnabled
                            ? AppTheme.Colors.mtaBlue
                            : AppTheme.Colors.textSecondary
                    )
                    .rotationEffect(.degrees(iconRotation))
                    .contentTransition(.symbolEffect(.replace.downUp.byLayer))
            }
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
            .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(DragToggleButtonStyle())
        .accessibilityLabel(isEnabled ? "Disable drag to search" : "Enable drag to search")
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: - Toggle Action

    private func toggle() {
        HapticManager.impact(isEnabled ? .light : .medium)

        // ── Ripple burst ──
        rippleScale = 0.6
        rippleOpacity = 0.8
        withAnimation(.easeOut(duration: 0.45)) {
            rippleScale = 2.0
            rippleOpacity = 0.0
        }

        // ── Icon rotation kick ──
        withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
            iconRotation += isEnabled ? -15 : 15
        }

        // ── Slight delay for the symbol replace to feel intentional ──
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            isEnabled.toggle()
        }

        // ── Settle icon rotation ──
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                iconRotation = 0
            }
        }
    }
}

// MARK: - Button Style

/// Press-down spring style matching the existing `IslandButtonStyle`
/// from MapControlsOverlay.
private struct DragToggleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(
                .spring(response: 0.25, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

// MARK: - Preview

#Preview("Toggle States") {
    @Previewable @State var enabled = true
    ZStack {
        Color.gray.opacity(0.2).ignoresSafeArea()
        VStack(spacing: 24) {
            DragSearchToggleButton(isEnabled: $enabled)
            Text(enabled ? "Drag Search ON" : "Drag Search OFF")
                .font(.caption)
        }
    }
}
