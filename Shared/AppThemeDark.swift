// Dark mode palette for the shared transit theme.

import UIKit

enum AppThemeDark {
    static let palette = AppThemePalette(
        subwayBlack: AppThemeUtilities.rgba(18, 20, 28),
        accent: AppThemeUtilities.rgba(200, 120, 255),
        accentSecondary: AppThemeUtilities.rgba(255, 134, 216),
        accentDeep: AppThemeUtilities.rgba(130, 68, 220),
        accentTint: AppThemeUtilities.rgba(50, 28, 72),
        accentMuted: AppThemeUtilities.rgba(72, 46, 98),
        alertRed: AppThemeUtilities.rgba(255, 82, 82),
        successGreen: AppThemeUtilities.rgba(52, 211, 110),
        warningYellow: AppThemeUtilities.rgba(255, 208, 64),
        background: AppThemeUtilities.rgba(2, 4, 12),
        backgroundSecondary: AppThemeUtilities.rgba(6, 10, 22),
        backgroundTertiary: AppThemeUtilities.rgba(12, 18, 32),
        cardBackground: AppThemeUtilities.rgba(14, 20, 34),
        cardElevated: AppThemeUtilities.rgba(20, 27, 44),
        cardFloating: AppThemeUtilities.rgba(16, 24, 40, alpha: 0.97),
        cardInset: AppThemeUtilities.rgba(8, 13, 24),
        textPrimary: AppThemeUtilities.rgba(248, 248, 255),
        textSecondary: AppThemeUtilities.rgba(155, 164, 194),
        textTertiary: AppThemeUtilities.rgba(100, 112, 142),
        borderSubtle: AppThemeUtilities.rgba(200, 120, 255, alpha: 0.10),
        borderStrong: AppThemeUtilities.rgba(200, 120, 255, alpha: 0.22),
        borderAccent: AppThemeUtilities.rgba(255, 150, 225, alpha: 0.20),
        shadow: AppThemeUtilities.rgba(0, 0, 0, alpha: 0.55),
        shadowStrong: AppThemeUtilities.rgba(0, 0, 0, alpha: 0.75),
        accentGlow: AppThemeUtilities.rgba(200, 120, 255, alpha: 0.35),
        glassHighlight: AppThemeUtilities.rgba(255, 255, 255, alpha: 0.06),
        mapScrim: AppThemeUtilities.rgba(0, 0, 0, alpha: 0.28)
    )
}
