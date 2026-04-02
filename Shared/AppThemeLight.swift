// Light mode palette for the shared transit theme.

import UIKit

enum AppThemeLight {
    static let palette = AppThemePalette(
        subwayBlack: AppThemeUtilities.rgba(14, 14, 18),
        accent: AppThemeUtilities.rgba(155, 72, 240),
        accentSecondary: AppThemeUtilities.rgba(232, 100, 198),
        accentDeep: AppThemeUtilities.rgba(100, 42, 180),
        accentTint: AppThemeUtilities.rgba(248, 242, 255),
        accentMuted: AppThemeUtilities.rgba(235, 222, 255),
        alertRed: AppThemeUtilities.rgba(232, 48, 40),
        successGreen: AppThemeUtilities.rgba(0, 140, 55),
        warningYellow: AppThemeUtilities.rgba(248, 198, 8),
        background: AppThemeUtilities.rgba(250, 248, 255),
        backgroundSecondary: AppThemeUtilities.rgba(244, 240, 252),
        backgroundTertiary: AppThemeUtilities.rgba(237, 232, 247),
        cardBackground: AppThemeUtilities.rgba(255, 255, 255),
        cardElevated: AppThemeUtilities.rgba(253, 251, 255),
        cardFloating: AppThemeUtilities.rgba(255, 255, 255, alpha: 0.96),
        cardInset: AppThemeUtilities.rgba(245, 241, 253),
        textPrimary: AppThemeUtilities.rgba(14, 16, 28),
        textSecondary: AppThemeUtilities.rgba(92, 98, 118),
        textTertiary: AppThemeUtilities.rgba(130, 136, 155),
        borderSubtle: AppThemeUtilities.rgba(92, 98, 118, alpha: 0.08),
        borderStrong: AppThemeUtilities.rgba(155, 72, 240, alpha: 0.15),
        borderAccent: AppThemeUtilities.rgba(155, 72, 240, alpha: 0.22),
        shadow: AppThemeUtilities.rgba(14, 16, 28, alpha: 0.08),
        shadowStrong: AppThemeUtilities.rgba(14, 16, 28, alpha: 0.16),
        accentGlow: AppThemeUtilities.rgba(155, 72, 240, alpha: 0.20),
        glassHighlight: AppThemeUtilities.rgba(255, 255, 255, alpha: 0.88),
        mapScrim: AppThemeUtilities.rgba(14, 16, 28, alpha: 0.06)
    )
}
