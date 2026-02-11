//
//  AppTheme.swift
//  Track
//
//  Central design system for the Track NYC Transit App.
//  All styling, colors, and typography must reference this file.
//  Every view, widget, and component should pull values from here —
//  never hardcode colors, fonts, or layout constants.
//
//  NOTE: This is a shared copy that must stay in sync with Track/Theme/AppTheme.swift

import SwiftUI

struct AppTheme {

    // MARK: - Colors

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

        /// Returns the appropriate countdown color for a given minutes value.
        /// Red ≤ 2 min, green ≤ 5 min, primary otherwise.
        static func countdown(_ minutes: Int) -> Color {
            if minutes <= 2 { return alertRed }
            if minutes <= 5 { return successGreen }
            return textPrimary
        }
    }

    // MARK: - Typography

    struct Typography {
        static func headerLarge(_ text: String) -> Text {
            Text(text).font(.system(size: 34, weight: .bold, design: .rounded))
        }

        static func sectionHeader(_ text: String) -> Text {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
        }

        static func routeLabel(_ text: String) -> Text {
            Text(text).font(.system(size: 18, weight: .heavy, design: .monospaced))
        }

        static func body(_ text: String) -> Text {
            Text(text).font(.system(size: 16, weight: .medium, design: .default))
        }
    }

    // MARK: - Layout

    struct Layout {
        static let margin: CGFloat = 16.0
        static let cornerRadius: CGFloat = 12.0
        static let shadowRadius: CGFloat = 4.0

        /// Inner padding for card-style containers.
        static let cardPadding: CGFloat = 12.0

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
