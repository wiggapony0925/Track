//
//  AppThemeDark.swift
//  Shared
//
//  Dark mode palette for the shared transit theme.
//

import UIKit

enum AppThemeDark {
    static let palette = AppThemePalette(
        subwayBlack: AppThemeUtilities.rgba(30, 34, 43),
        accent: AppThemeUtilities.rgba(214, 116, 255),
        accentSecondary: AppThemeUtilities.rgba(255, 144, 220),
        accentDeep: AppThemeUtilities.rgba(143, 79, 229),
        accentTint: AppThemeUtilities.rgba(60, 35, 81),
        accentMuted: AppThemeUtilities.rgba(83, 53, 108),
        alertRed: AppThemeUtilities.rgba(255, 95, 95),
        successGreen: AppThemeUtilities.rgba(61, 214, 116),
        warningYellow: AppThemeUtilities.rgba(255, 212, 74),
        background: AppThemeUtilities.rgba(5, 8, 17),
        backgroundSecondary: AppThemeUtilities.rgba(10, 15, 27),
        backgroundTertiary: AppThemeUtilities.rgba(16, 23, 37),
        cardBackground: AppThemeUtilities.rgba(16, 23, 37),
        cardElevated: AppThemeUtilities.rgba(22, 30, 47),
        cardFloating: AppThemeUtilities.rgba(18, 27, 43, alpha: 0.96),
        cardInset: AppThemeUtilities.rgba(12, 18, 30),
        textPrimary: AppThemeUtilities.rgba(246, 245, 255),
        textSecondary: AppThemeUtilities.rgba(162, 170, 198),
        textTertiary: AppThemeUtilities.rgba(110, 120, 148),
        borderSubtle: AppThemeUtilities.rgba(214, 116, 255, alpha: 0.12),
        borderStrong: AppThemeUtilities.rgba(214, 116, 255, alpha: 0.26),
        borderAccent: AppThemeUtilities.rgba(255, 160, 229, alpha: 0.22),
        shadow: AppThemeUtilities.rgba(0, 0, 0, alpha: 0.48),
        shadowStrong: AppThemeUtilities.rgba(0, 0, 0, alpha: 0.68),
        accentGlow: AppThemeUtilities.rgba(214, 116, 255, alpha: 0.40),
        glassHighlight: AppThemeUtilities.rgba(255, 255, 255, alpha: 0.08),
        mapScrim: AppThemeUtilities.rgba(0, 0, 0, alpha: 0.22)
    )
}
