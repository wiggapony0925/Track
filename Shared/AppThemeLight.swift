//
//  AppThemeLight.swift
//  Shared
//
//  Light mode palette for the shared transit theme.
//

import UIKit

enum AppThemeLight {
    static let palette = AppThemePalette(
        subwayBlack: AppThemeUtilities.rgba(17, 17, 17),
        accent: AppThemeUtilities.rgba(171, 86, 246),
        accentSecondary: AppThemeUtilities.rgba(243, 112, 206),
        accentDeep: AppThemeUtilities.rgba(110, 50, 190),
        accentTint: AppThemeUtilities.rgba(245, 237, 255),
        accentMuted: AppThemeUtilities.rgba(229, 214, 255),
        alertRed: AppThemeUtilities.rgba(238, 53, 46),
        successGreen: AppThemeUtilities.rgba(0, 147, 60),
        warningYellow: AppThemeUtilities.rgba(252, 204, 10),
        background: AppThemeUtilities.rgba(247, 243, 252),
        backgroundSecondary: AppThemeUtilities.rgba(239, 234, 247),
        backgroundTertiary: AppThemeUtilities.rgba(231, 226, 241),
        cardBackground: AppThemeUtilities.rgba(255, 255, 255),
        cardElevated: AppThemeUtilities.rgba(251, 248, 255),
        cardFloating: AppThemeUtilities.rgba(255, 255, 255, alpha: 0.94),
        cardInset: AppThemeUtilities.rgba(242, 237, 250),
        textPrimary: AppThemeUtilities.rgba(18, 21, 33),
        textSecondary: AppThemeUtilities.rgba(104, 109, 127),
        textTertiary: AppThemeUtilities.rgba(137, 142, 160),
        borderSubtle: AppThemeUtilities.rgba(104, 109, 127, alpha: 0.10),
        borderStrong: AppThemeUtilities.rgba(171, 86, 246, alpha: 0.18),
        borderAccent: AppThemeUtilities.rgba(171, 86, 246, alpha: 0.26),
        shadow: AppThemeUtilities.rgba(21, 24, 38, alpha: 0.12),
        shadowStrong: AppThemeUtilities.rgba(21, 24, 38, alpha: 0.20),
        accentGlow: AppThemeUtilities.rgba(171, 86, 246, alpha: 0.24),
        glassHighlight: AppThemeUtilities.rgba(255, 255, 255, alpha: 0.84),
        mapScrim: AppThemeUtilities.rgba(18, 21, 33, alpha: 0.08)
    )
}
