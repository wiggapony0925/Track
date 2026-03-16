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
            AppTheme.Colors.background
                .ignoresSafeArea()
        }
    }

    func trackCardBackground(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape
                .fill(AppTheme.Colors.cardBackground)
                .overlay {
                    shape.stroke(AppTheme.Colors.borderSubtle, lineWidth: 0.5)
                }
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.04), radius: 8, x: 0, y: 4)
        .shadow(color: AppTheme.Colors.shadowStrong.opacity(0.02), radius: 16, x: 0, y: 8)
    }

    func trackFloatingChrome(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            shape
                .fill(AppTheme.Colors.cardFloating)
                .overlay {
                    shape.stroke(AppTheme.Colors.borderStrong.opacity(0.5), lineWidth: 0.5)
                }
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 12, x: 0, y: 6)
        .shadow(color: AppTheme.Colors.shadowStrong.opacity(0.03), radius: 24, x: 0, y: 12)
    }

    func trackAccentBackground(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape
                .fill(AppTheme.Colors.accent)
        }
        .shadow(color: AppTheme.Colors.accent.opacity(0.2), radius: 8, x: 0, y: 4)
    }

    func trackInsetBackground(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape
                .fill(AppTheme.Colors.cardInset)
                .overlay {
                    shape.stroke(AppTheme.Colors.borderSubtle, lineWidth: 0.5)
                }
        }
    }

    func trackTintedChrome(
        tint: Color = AppTheme.Colors.mtaBlue,
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape
                .fill(AppTheme.Colors.cardFloating)
                .overlay {
                    shape.fill(tint.opacity(0.05))
                }
                .overlay {
                    shape.stroke(tint.opacity(0.15), lineWidth: 0.5)
                }
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.05), radius: 10, x: 0, y: 5)
        .shadow(color: tint.opacity(0.04), radius: 12, x: 0, y: 4)
    }
}
