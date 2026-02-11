//
//  TransportModeToggle.swift
//  Track
//
//  A floating capsule segment control for switching between Subway and Bus modes.
//  Sits at the bottom center of the map overlay.
//

import SwiftUI

struct TransportModeToggle: View {
    @Binding var selectedMode: TransportMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TransportMode.allCases, id: \.self) { mode in
                Button {
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
                    .foregroundColor(selectedMode == mode ? AppTheme.Colors.textOnColor : AppTheme.Colors.textPrimary)
                    .background(
                        selectedMode == mode
                            ? (mode == .subway ? AppTheme.Colors.subwayBlack : AppTheme.Colors.mtaBlue)
                            : Color.clear
                    )
                    .clipShape(Capsule())
                }
                .accessibilityLabel("\(mode.label) mode")
                .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(radius: AppTheme.Layout.shadowRadius)
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        VStack {
            Spacer()
            TransportModeToggle(selectedMode: .constant(.subway))
                .padding(.bottom, 20)
        }
    }
}
