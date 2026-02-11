//
//  AppTheme.swift
//  Track
//
//  Central design system for the Track NYC Transit App.
//  All styling, colors, and typography must reference this file.
//  Every view, widget, and component should pull values from here —
//  never hardcode colors, fonts, or layout constants.
//

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

    // MARK: - Subway Line Colors

    /// Official MTA subway line colors. Used by RouteBadge and widget
    /// transit badges to display the correct color per line.
    struct SubwayColors {
        static func color(for routeID: String) -> Color {
            switch routeID.uppercased() {
            case "1", "2", "3":
                return Color(red: 238/255, green: 53/255, blue: 46/255)    // IRT Red
            case "4", "5", "6":
                return Color(red: 0/255, green: 147/255, blue: 60/255)     // IRT Green
            case "7":
                return Color(red: 185/255, green: 51/255, blue: 173/255)   // IRT Purple
            case "A", "C", "E":
                return Color(red: 0/255, green: 57/255, blue: 166/255)     // IND Blue
            case "B", "D", "F", "M":
                return Color(red: 255/255, green: 99/255, blue: 25/255)    // IND Orange
            case "G":
                return Color(red: 108/255, green: 190/255, blue: 69/255)   // IND Light Green
            case "J", "Z":
                return Color(red: 153/255, green: 102/255, blue: 51/255)   // BMT Brown
            case "L":
                return Color(red: 167/255, green: 169/255, blue: 172/255)  // BMT Grey
            case "N", "Q", "R", "W":
                return Color(red: 252/255, green: 204/255, blue: 10/255)   // BMT Yellow
            case "S", "SI":
                return Color(red: 128/255, green: 129/255, blue: 131/255)  // Shuttle Grey
            default:
                return Colors.mtaBlue
            }
        }

        /// Returns white for most lines, black for yellow lines for readability.
        static func textColor(for routeID: String) -> Color {
            switch routeID.uppercased() {
            case "N", "Q", "R", "W":
                return .black
            default:
                return .white
            }
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
