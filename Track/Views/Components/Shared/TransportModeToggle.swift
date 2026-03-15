//
//  TransportModeToggle.swift
//  Track
//
//  A floating capsule segment control for switching between Nearby, Subway, and Bus modes.
//  Sits at the bottom center of the map overlay.
//

import SwiftUI

struct TransportModeToggle: View {
    @Binding var selectedMode: TransportMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TransportMode.allCases, id: \.self) { mode in
                modeButton(mode)
            }
        }
        .padding(4)
        .trackFloatingChrome(cornerRadius: 999)
    }

    /// Individual mode button — extracted to reduce body type-check time.
    private func modeButton(_ mode: TransportMode) -> some View {
        let isSelected: Bool = selectedMode == mode
        let fgColor: Color = isSelected ? AppTheme.Colors.textOnColor : AppTheme.Colors.textPrimary

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedMode = mode
            }
            HapticManager.impact(.medium)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(mode.label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundColor(fgColor)
            .background {
                Capsule()
                    .fill(AppTheme.Gradients.accent)
                    .opacity(isSelected ? 1 : 0)
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
