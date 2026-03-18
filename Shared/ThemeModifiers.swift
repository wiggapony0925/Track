//
//  ThemeModifiers.swift
//  Shared
//
//  Reusable surface and background helpers powered by AppTheme.
//  Transit 6.0–inspired: layered glass, refined borders, deeper shadows.
//

import SwiftUI

extension View {
    func trackScreenBackground() -> some View {
        background {
            ZStack {
                AppTheme.Colors.background
                AppTheme.Gradients.screenSheen
            }
            .ignoresSafeArea()
        }
    }

    func trackCardBackground(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            shape
                .fill(AppTheme.Colors.cardBackground)
                .overlay {
                    // Subtle top-highlight for depth
                    shape.fill(AppTheme.Gradients.chromeHighlight)
                }
                .overlay {
                    shape.stroke(AppTheme.Colors.borderSubtle, lineWidth: 0.5)
                }
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.05), radius: 8, x: 0, y: 3)
        .shadow(color: AppTheme.Colors.shadowStrong.opacity(0.03), radius: 20, x: 0, y: 10)
    }

    func trackFloatingChrome(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            shape
                .fill(AppTheme.Colors.cardFloating)
                .overlay {
                    shape.fill(AppTheme.Gradients.chromeHighlight)
                }
                .overlay {
                    shape.stroke(AppTheme.Colors.borderStrong.opacity(0.4), lineWidth: 0.5)
                }
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.08), radius: 12, x: 0, y: 5)
        .shadow(color: AppTheme.Colors.shadowStrong.opacity(0.04), radius: 28, x: 0, y: 14)
    }

    func trackAccentBackground(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            shape
                .fill(AppTheme.Gradients.accent)
                .overlay {
                    shape.fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
        }
        .shadow(color: AppTheme.Colors.accent.opacity(0.25), radius: 10, x: 0, y: 5)
        .shadow(color: AppTheme.Colors.accentDeep.opacity(0.15), radius: 20, x: 0, y: 10)
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
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            shape
                .fill(AppTheme.Colors.cardFloating)
                .overlay {
                    shape.fill(tint.opacity(0.04))
                }
                .overlay {
                    shape.fill(AppTheme.Gradients.chromeHighlight)
                }
                .overlay {
                    shape.stroke(tint.opacity(0.12), lineWidth: 0.5)
                }
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 10, x: 0, y: 5)
        .shadow(color: tint.opacity(0.05), radius: 16, x: 0, y: 6)
    }

    /// Elevated hero card — used for primary action cards and key content.
    func trackHeroCard(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            shape
                .fill(AppTheme.Colors.cardElevated)
                .overlay {
                    shape.fill(AppTheme.Gradients.chromeHighlight)
                }
                .overlay {
                    shape.stroke(AppTheme.Colors.borderStrong.opacity(0.3), lineWidth: 0.5)
                }
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.10), radius: 16, x: 0, y: 8)
        .shadow(color: AppTheme.Colors.accentGlow.opacity(0.06), radius: 30, x: 0, y: 15)
    }
}
