//
//  AppTheme.swift
//  Track
//
//  Central design system for the Track NYC Transit App.
//  All styling, colors, and typography must reference this file.
//

import SwiftUI

struct AppTheme {
    struct Colors {
        // NYC Identity
        static let subwayBlack = Color("SubwayBlack")
        static let mtaBlue = Color("MTABlue")
        static let alertRed = Color("AlertRed")
        static let successGreen = Color("SuccessGreen")
        static let warningYellow = Color("WarningYellow")

        // UI Semantics
        static let background = Color("AppBackground")
        static let cardBackground = Color("CardSurface")
        static let textPrimary = Color("TextPrimary")
        static let textSecondary = Color("TextSecondary")

        /// White text used on colored badges, buttons, and banners.
        static let textOnColor = Color.white
    }

    struct Typography {
        static func headerLarge(_ text: String) -> Text {
            Text(text).font(.system(size: 34, weight: .bold, design: .rounded))
        }

        static func routeLabel(_ text: String) -> Text {
            Text(text).font(.system(size: 18, weight: .heavy, design: .monospaced))
        }

        static func body(_ text: String) -> Text {
            Text(text).font(.system(size: 16, weight: .medium, design: .default))
        }
    }

    struct Layout {
        static let margin: CGFloat = 16.0
        static let cornerRadius: CGFloat = 12.0
        static let shadowRadius: CGFloat = 4.0

        // Reusable badge sizes
        static let badgeSizeSmall: CGFloat = 22.0
        static let badgeSizeMedium: CGFloat = 32.0
        static let badgeSizeLarge: CGFloat = 40.0

        // Font sizes for badges
        static let badgeFontSmall: CGFloat = 11.0
        static let badgeFontMedium: CGFloat = 14.0
        static let badgeFontLarge: CGFloat = 18.0
    }
}
