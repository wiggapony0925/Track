//
//  AppThemeUtilities.swift
//  Shared
//
//  Shared palette models and adaptive color helpers used by AppTheme.
//

import SwiftUI
import UIKit

struct AppThemePalette {
    let subwayBlack: UIColor
    let accent: UIColor
    let accentSecondary: UIColor
    let accentDeep: UIColor
    let accentTint: UIColor
    let accentMuted: UIColor
    let alertRed: UIColor
    let successGreen: UIColor
    let warningYellow: UIColor
    let background: UIColor
    let backgroundSecondary: UIColor
    let backgroundTertiary: UIColor
    let cardBackground: UIColor
    let cardElevated: UIColor
    let cardFloating: UIColor
    let cardInset: UIColor
    let textPrimary: UIColor
    let textSecondary: UIColor
    let textTertiary: UIColor
    let borderSubtle: UIColor
    let borderStrong: UIColor
    let borderAccent: UIColor
    let shadow: UIColor
    let shadowStrong: UIColor
    let accentGlow: UIColor
    let glassHighlight: UIColor
    let mapScrim: UIColor
}

enum AppThemeUtilities {
    static func rgba(
        _ red: CGFloat,
        _ green: CGFloat,
        _ blue: CGFloat,
        alpha: CGFloat = 1.0
    ) -> UIColor {
        UIColor(
            red: red / 255.0,
            green: green / 255.0,
            blue: blue / 255.0,
            alpha: alpha
        )
    }

    static func adaptiveColor(_ keyPath: KeyPath<AppThemePalette, UIColor>) -> Color {
        Color(uiColor: adaptiveUIColor(keyPath))
    }

    static func adaptiveUIColor(_ keyPath: KeyPath<AppThemePalette, UIColor>) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? AppThemeDark.palette[keyPath: keyPath]
                : AppThemeLight.palette[keyPath: keyPath]
        }
    }
}
