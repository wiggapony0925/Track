// Floating toggle button for enabling/disabling drag-to-search.
// Displayed at the top-left of the map. A hand-finger icon animates
// between active (hand.draw.fill) and inactive (hand.raised.slash)
// states with a satisfying circular reveal + spring animation.
//
// When drag search is actively exploring an area, tapping the button
// dismisses the current session (via `onDismissSession`) and recenters
// WITHOUT disabling the feature. Only tapping while idle toggles the
// persistent preference off.

import SwiftUI

/// A circular glassmorphic toggle that lets the user quickly enable
/// or disable drag-to-search without opening Settings.
///
/// When `isDragSearchActive` is true, the button acts as a session
/// dismiss (calls `onDismissSession`) rather than toggling the feature.
struct DragSearchToggleButton: View {

    @Binding var isEnabled: Bool

    /// Whether the drag-search overlay is currently showing.
    var isDragSearchActive: Bool = false

    /// Called when the user taps while a drag-search session is active.
    /// The caller should dismiss the session and recenter the map.
    var onDismissSession: (() -> Void)?

    // MARK: - Animation State

    /// Subtle rotation of the hand icon on toggle.
    @State private var iconRotation: Double = 0
    /// Momentary press-ripple scale.
    @State private var rippleScale: CGFloat = 0.01
    /// Ripple opacity.
    @State private var rippleOpacity: Double = 0
    /// Glow pulse when drag search is active (breathing ring).
    @State private var glowPulse = false

    // MARK: - Constants

    private let size: CGFloat = 42
    private let iconSize: CGFloat = 16

    // MARK: - Body

    var body: some View {
        Button {
            handleTap()
        } label: {
            ZStack {
                // ── Active glow ring (breathing pulse while searching) ──
                if isDragSearchActive {
                    Circle()
                        .stroke(AppTheme.Colors.mtaBlue.opacity(0.35), lineWidth: 2.5)
                        .frame(width: size + 6, height: size + 6)
                        .scaleEffect(glowPulse ? 1.12 : 1.0)
                        .opacity(glowPulse ? 0.3 : 0.6)
                        .onAppear {
                            withAnimation(
                                .easeInOut(duration: 1.6)
                                .repeatForever(autoreverses: true)
                            ) {
                                glowPulse = true
                            }
                        }
                        .onDisappear { glowPulse = false }
                }

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
                                isDragSearchActive
                                    ? AppTheme.Colors.mtaBlue.opacity(0.22)
                                    : isEnabled
                                        ? AppTheme.Colors.mtaBlue.opacity(0.15)
                                        : AppTheme.Colors.cardBackground.opacity(0.35)
                            )
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(
                                isDragSearchActive
                                    ? AppTheme.Colors.mtaBlue.opacity(0.5)
                                    : isEnabled
                                        ? AppTheme.Colors.mtaBlue.opacity(0.3)
                                        : .white.opacity(0.16),
                                lineWidth: isDragSearchActive ? 1.0 : 0.5
                            )
                    }
                    .frame(width: size, height: size)

                // ── Hand icon ──
                // While searching: shows location.slash to hint "tap to go back"
                Image(systemName: effectiveIcon)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(
                        isDragSearchActive
                            ? AppTheme.Colors.mtaBlue
                            : isEnabled
                                ? AppTheme.Colors.mtaBlue
                                : AppTheme.Colors.textSecondary
                    )
                    .rotationEffect(.degrees(iconRotation))
                    .contentTransition(.symbolEffect(.replace.downUp.byLayer))
            }
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
            .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
            .animation(.easeInOut(duration: 0.25), value: isDragSearchActive)
        }
        .buttonStyle(DragToggleButtonStyle())
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: - Computed

    private var effectiveIcon: String {
        if isDragSearchActive { return "location.fill" }
        return isEnabled ? "hand.draw.fill" : "hand.raised.slash"
    }

    private var accessibilityText: String {
        if isDragSearchActive { return "Return to my location" }
        return isEnabled ? "Disable drag to search" : "Enable drag to search"
    }

    // MARK: - Actions

    private func handleTap() {
        if isDragSearchActive {
            // Session is active — dismiss and recenter, DON'T toggle feature off
            HapticManager.notification(.success)
            fireRipple()
            onDismissSession?()
        } else {
            // No active session — toggle the feature as before
            toggleFeature()
        }
    }

    private func toggleFeature() {
        HapticManager.impact(isEnabled ? .light : .medium)
        fireRipple()

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

    private func fireRipple() {
        rippleScale = 0.6
        rippleOpacity = 0.8
        withAnimation(.easeOut(duration: 0.45)) {
            rippleScale = 2.2
            rippleOpacity = 0.0
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
