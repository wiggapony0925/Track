// A floating capsule segment control for switching between Nearby, Subway, and Bus modes.
// Sits at the bottom center of the map overlay.

import SwiftUI

struct TransportModeToggle: View {
    @Binding var selectedMode: TransportMode

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TransportMode.allCases, id: \.self) { mode in
                modeButton(mode)
            }
        }
        .padding(6)
        .trackFloatingChrome(cornerRadius: 999)
    }

    /// Individual mode button — extracted to reduce body type-check time.
    private func modeButton(_ mode: TransportMode) -> some View {
        let isSelected: Bool = selectedMode == mode

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedMode = mode
            }
            HapticManager.impact(.medium)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            isSelected
                                ? AnyShapeStyle(AppTheme.Gradients.accent)
                                : AnyShapeStyle(AppTheme.Gradients.controlSurface)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    isSelected
                                        ? AppTheme.Colors.textOnColor.opacity(0.18)
                                        : AppTheme.Colors.borderSubtle,
                                    lineWidth: 1
                                )
                        }

                    Image(systemName: mode.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isSelected ? .white : AppTheme.Colors.textSecondary)
                }
                .frame(width: 30, height: 30)

                Text(mode.label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(
                        isSelected
                            ? AppTheme.Colors.textPrimary
                            : AppTheme.Colors.textSecondary
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(AppTheme.Colors.glassHighlight.opacity(0.07))
                            : AnyShapeStyle(Color.clear)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected
                            ? AppTheme.Colors.borderSubtle
                            : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .accessibilityLabel("\(mode.label) mode")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    ZStack {
        AppTheme.Colors.background.opacity(0.3).ignoresSafeArea()
        VStack {
            Spacer()
            TransportModeToggle(selectedMode: .constant(.nearby))
                .padding(.bottom, 20)
        }
    }
}
