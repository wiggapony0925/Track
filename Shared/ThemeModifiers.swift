//
//  ThemeModifiers.swift
//  Shared
//
//  Reusable surface and background helpers powered by AppTheme.
//

import SwiftUI

extension View {
    func trackScreenBackground() -> some View {
        background {
            ZStack {
                AppTheme.Gradients.screen
                AppTheme.Gradients.screenGlow
            }
            .ignoresSafeArea()
        }
    }

    func trackCardBackground(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Gradients.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(AppTheme.Colors.borderSubtle, lineWidth: 1)
                )
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.18), radius: 14, x: 0, y: 8)
    }

    func trackFloatingChrome(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Gradients.floating)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(AppTheme.Colors.borderStrong, lineWidth: 1)
                )
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.22), radius: 18, x: 0, y: 10)
        .shadow(color: AppTheme.Colors.accentGlow.opacity(0.18), radius: 22, x: 0, y: 4)
    }

    func trackAccentBackground(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Gradients.accent)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(AppTheme.Colors.textOnColor.opacity(0.12), lineWidth: 1)
                )
        }
        .shadow(color: AppTheme.Colors.accentGlow.opacity(0.52), radius: 18, x: 0, y: 8)
    }
}
