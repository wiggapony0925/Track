// Reusable surface and background helpers powered by AppTheme.
// Clean, minimal surfaces — single fill, single shadow where needed.

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
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 8, x: 0, y: 3)
    }

    func trackFloatingChrome(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Colors.cardFloating)
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.08), radius: 10, x: 0, y: 4)
    }

    func trackAccentBackground(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Gradients.accent)
        }
        .shadow(color: AppTheme.Colors.accent.opacity(0.20), radius: 8, x: 0, y: 4)
    }

    func trackInsetBackground(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Colors.cardInset)
        }
    }

    func trackTintedChrome(
        tint: Color = AppTheme.Colors.mtaBlue,
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Colors.cardFloating)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(0.04))
                }
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 8, x: 0, y: 3)
    }

    // MARK: - Stale / Refreshing State

    /// Greyed-out treatment for rows refreshing stale data.
    /// Applies reduced opacity, desaturation, disables hit-testing, and
    /// animates the transition.  Use this instead of duplicating the 4
    /// modifiers inline.
    ///
    /// - Parameters:
    ///   - isStale: Whether the row/card is currently stale.
    ///   - normalOpacity: Opacity when *not* stale (default 1.0).
    ///     FavoriteCard passes a lower value for unmatched cards.
    func staleOverlay(
        _ isStale: Bool,
        normalOpacity: Double = 1.0
    ) -> some View {
        self
            .opacity(isStale ? 0.45 : normalOpacity)
            .saturation(isStale ? 0.3 : 1.0)
            .allowsHitTesting(!isStale)
            .animation(.easeInOut(duration: 0.35), value: isStale)
    }

    /// Elevated hero card — used for primary action cards and key content.
    func trackHeroCard(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Colors.cardElevated)
        }
        .shadow(color: AppTheme.Colors.shadow.opacity(0.10), radius: 12, x: 0, y: 6)
    }
}
