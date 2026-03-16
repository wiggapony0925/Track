//
//  AppTheme.swift
//  Shared
//
//  Central public design system for the Track NYC Transit App.
//  Views should reference AppTheme tokens instead of hardcoding colors,
//  gradients, spacing, or typography.
//

import CoreLocation
import SwiftUI

enum AppTheme {

    // MARK: - Colors

    struct Colors {
        // NYC Identity
        static let subwayBlack = AppThemeUtilities.adaptiveColor(\.subwayBlack)
        static let accent = AppThemeUtilities.adaptiveColor(\.accent)

        /// Legacy name kept so existing views inherit the transit-purple
        /// accent without touching every call site in the app.
        static var mtaBlue: Color { accent }

        static let accentSecondary = AppThemeUtilities.adaptiveColor(\.accentSecondary)
        static let accentDeep = AppThemeUtilities.adaptiveColor(\.accentDeep)
        static let accentTint = AppThemeUtilities.adaptiveColor(\.accentTint)
        static let accentMuted = AppThemeUtilities.adaptiveColor(\.accentMuted)
        static let alertRed = AppThemeUtilities.adaptiveColor(\.alertRed)
        static let successGreen = AppThemeUtilities.adaptiveColor(\.successGreen)
        static let warningYellow = AppThemeUtilities.adaptiveColor(\.warningYellow)

        // UI Semantics
        static let background = AppThemeUtilities.adaptiveColor(\.background)
        static let backgroundSecondary = AppThemeUtilities.adaptiveColor(\.backgroundSecondary)
        static let backgroundTertiary = AppThemeUtilities.adaptiveColor(\.backgroundTertiary)
        static let cardBackground = AppThemeUtilities.adaptiveColor(\.cardBackground)
        static let cardElevated = AppThemeUtilities.adaptiveColor(\.cardElevated)
        static let cardFloating = AppThemeUtilities.adaptiveColor(\.cardFloating)
        static let cardInset = AppThemeUtilities.adaptiveColor(\.cardInset)
        static let textPrimary = AppThemeUtilities.adaptiveColor(\.textPrimary)
        static let textSecondary = AppThemeUtilities.adaptiveColor(\.textSecondary)
        static let textTertiary = AppThemeUtilities.adaptiveColor(\.textTertiary)
        static let borderSubtle = AppThemeUtilities.adaptiveColor(\.borderSubtle)
        static let borderStrong = AppThemeUtilities.adaptiveColor(\.borderStrong)
        static let borderAccent = AppThemeUtilities.adaptiveColor(\.borderAccent)
        static let shadow = AppThemeUtilities.adaptiveColor(\.shadow)
        static let shadowStrong = AppThemeUtilities.adaptiveColor(\.shadowStrong)
        static let accentGlow = AppThemeUtilities.adaptiveColor(\.accentGlow)
        static let glassHighlight = AppThemeUtilities.adaptiveColor(\.glassHighlight)
        static let mapScrim = AppThemeUtilities.adaptiveColor(\.mapScrim)

        /// White text used on colored badges, buttons, and banners.
        static let textOnColor = Color.white

        /// Pulsing "GO" mode accent — a vivid green for the live tracking state.
        static let goGreen = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)

        /// Returns the appropriate countdown color for a given minutes value.
        /// Red ≤ 2 min, green ≤ 5 min, primary otherwise.
        static func countdown(_ minutes: Int) -> Color {
            if minutes <= 2 { return alertRed }
            if minutes <= 5 { return successGreen }
            return textPrimary
        }
    }

    // MARK: - Gradients

    struct Gradients {
        static let screen = LinearGradient(
            stops: [
                .init(color: Colors.background, location: 0.00),
                .init(color: Colors.backgroundSecondary, location: 0.52),
                .init(color: Colors.backgroundTertiary, location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let screenSheen = LinearGradient(
            stops: [
                .init(color: Colors.glassHighlight.opacity(0.14), location: 0.00),
                .init(color: Color.clear, location: 0.36),
                .init(color: Colors.accentGlow.opacity(0.06), location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let screenGlow = LinearGradient(
            stops: [
                .init(color: Colors.accentGlow.opacity(0.15), location: 0.00),
                .init(color: Color.clear, location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let heroGlow = LinearGradient(
            stops: [
                .init(color: Colors.accentSecondary.opacity(0.10), location: 0.00),
                .init(color: Color.clear, location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let surface = LinearGradient(
            stops: [
                .init(color: Colors.cardElevated, location: 0.00),
                .init(color: Colors.cardBackground, location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let floating = LinearGradient(
            stops: [
                .init(color: Colors.cardFloating, location: 0.00),
                .init(color: Colors.cardElevated, location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let controlSurface = LinearGradient(
            stops: [
                .init(color: Colors.cardInset, location: 0.00),
                .init(color: Colors.cardBackground, location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let accentSurface = LinearGradient(
            stops: [
                .init(color: Colors.accentTint.opacity(0.8), location: 0.00),
                .init(color: Colors.accentTint.opacity(0.5), location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let inset = LinearGradient(
            stops: [
                .init(color: Colors.cardInset, location: 0.00),
                .init(color: Colors.cardBackground, location: 1.00),
            ],
            startPoint: .topTrailing,
            endPoint: .bottomLeading
        )

        static let chromeHighlight = LinearGradient(
            stops: [
                .init(color: Colors.glassHighlight.opacity(0.15), location: 0.00),
                .init(color: Color.clear, location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let accent = LinearGradient(
            stops: [
                .init(color: Colors.accent, location: 0.00),
                .init(color: Colors.accentDeep, location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static func tintWash(_ tint: Color, intensity: Double = 0.18) -> LinearGradient {
            LinearGradient(
                stops: [
                    .init(color: tint.opacity(intensity), location: 0.00),
                    .init(color: tint.opacity(intensity * 0.3), location: 1.00),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Typography

    struct Typography {
        /// Large rounded header (Dynamic Type: Large Title).
        static let headerLarge: Font = .custom("Helvetica-Bold", size: 34)

        /// Sheet/detail title — smaller than headerLarge, larger than headerMedium.
        /// Used for route detail sheet titles where the RouteBadge is the hero element.
        static let sheetTitle: Font = .custom("Helvetica-Bold", size: 26)

        /// Medium header for sheet titles and card headers.
        static let headerMedium: Font = .custom("Helvetica-Bold", size: 18)

        /// Section headers (Dynamic Type: Subheadline).
        static let sectionHeader: Font = .custom("Helvetica-Bold", size: 15)

        /// Monospaced route labels (Dynamic Type: Body).
        /// Using Helvetica-Bold instead of generic heavy monospaced for better brand alignment.
        static let routeLabel: Font = .custom("Helvetica-Bold", size: 17)

        /// Standard body text (Dynamic Type: Callout).
        static let body: Font = .custom("Helvetica", size: 16)

        /// Card title text (bold).
        static let cardTitle: Font = .custom("Helvetica-Bold", size: 16)

        /// Card subtitle / secondary text.
        static let cardSubtitle: Font = .custom("Helvetica", size: 14)

        /// Caption text for timestamps, metadata, and small labels.
        static let caption: Font = .custom("Helvetica", size: 13)

        /// Small bold caption (e.g. day badges, counters).
        static let captionBold: Font = .custom("Helvetica-Bold", size: 13)

        /// Search bar input text.
        static let searchInput: Font = .system(size: 15, weight: .regular)

        /// Navigation back button text.
        static let navButton: Font = .custom("Helvetica", size: 16)

        /// Settings row title.
        static let settingsTitle: Font = .custom("Helvetica-Bold", size: 15)

        /// Settings row description.
        static let settingsDescription: Font = .custom("Helvetica", size: 13)

        /// Helper to get Helvetica with specific weight/size.
        static func helvetica(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .custom("Helvetica", size: size).weight(weight)
        }
    }

    // MARK: - Shadows

    /// Reusable shadow presets for consistent depth across the app.
    struct Shadows {
        /// Subtle card shadow — used for card containers and floating sections.
        static func card(_ content: some View) -> some View {
            content
                .shadow(color: Colors.shadow.opacity(0.06), radius: 8, x: 0, y: 4)
                .shadow(color: Colors.shadowStrong.opacity(0.03), radius: 16, x: 0, y: 8)
        }

        /// Elevated shadow — used for active/selected elements.
        static func elevated(_ content: some View) -> some View {
            content
                .shadow(color: Colors.shadow.opacity(0.12), radius: 10, x: 0, y: 5)
                .shadow(color: Colors.shadowStrong.opacity(0.06), radius: 20, x: 0, y: 10)
        }
    }

    // MARK: - Spacing

    /// Standardized spacing values for consistent vertical rhythm.
    struct Spacing {
        /// Small gap within tightly grouped items (4–6pt).
        static let tight: CGFloat = 6
        /// Standard inner section spacing (10–12pt).
        static let inner: CGFloat = 10
        /// Gap between related sections (16pt).
        static let section: CGFloat = 16
        /// Large gap between major content blocks (24pt).
        static let block: CGFloat = 24
    }

    // MARK: - Subway Line Colors

    /// Official MTA subway line colors (2025 brand guide).
    /// Used by RouteBadge and widget transit badges.
    struct SubwayColors {
        static func color(for routeID: String) -> Color {
            switch routeID.uppercased() {
            case "1", "2", "3":
                return Color(red: 216 / 255, green: 34 / 255, blue: 51 / 255)     // Red #D82233
            case "4", "5", "6":
                return Color(red: 0 / 255, green: 153 / 255, blue: 82 / 255)      // Dark Green #009952
            case "7":
                return Color(red: 154 / 255, green: 56 / 255, blue: 161 / 255)    // Purple #9A38A1
            case "A", "C", "E":
                return Color(red: 0 / 255, green: 98 / 255, blue: 207 / 255)      // Blue #0062CF
            case "B", "D", "F", "M":
                return Color(red: 235 / 255, green: 104 / 255, blue: 0 / 255)     // Orange #EB6800
            case "G":
                return Color(red: 121 / 255, green: 149 / 255, blue: 52 / 255)    // Light Green #799534
            case "J", "Z":
                return Color(red: 142 / 255, green: 92 / 255, blue: 51 / 255)     // Brown #8E5C33
            case "L":
                return Color(red: 124 / 255, green: 133 / 255, blue: 140 / 255)   // Grey #7C858C
            case "N", "Q", "R", "W":
                return Color(red: 246 / 255, green: 188 / 255, blue: 38 / 255)    // Yellow #F6BC26
            case "S":
                return Color(red: 124 / 255, green: 133 / 255, blue: 140 / 255)   // Grey #7C858C
            case "SI":
                return Color(red: 0 / 255, green: 142 / 255, blue: 183 / 255)     // Teal #008EB7
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

    // MARK: - Bus Colors

    /// Bus route colors for visual distinction from subway routes.
    struct BusColors {
        /// Standard local bus color (MTA Blue).
        static let localBlue = Color(red: 0 / 255, green: 57 / 255, blue: 166 / 255)

        /// Select Bus Service (SBS) purple color.
        static let sbsPurple = Color(red: 128 / 255, green: 0 / 255, blue: 128 / 255)
    }

    // MARK: - Commuter Rail Colors

    /// Commuter rail colors for LIRR and Metro-North.
    struct CommuterRailColors {
        /// Long Island Rail Road brand blue.
        static let lirrBlue = Color(red: 0 / 255, green: 115 / 255, blue: 191 / 255)

        /// Metro-North Railroad brand blue (darker).
        static let mnrBlue = Color(red: 0 / 255, green: 90 / 255, blue: 140 / 255)
    }

    // MARK: - Layout

    struct Layout {
        static let margin: CGFloat = 16.0
        static let cornerRadius: CGFloat = 20.0
        static let shadowRadius: CGFloat = 4.0

        /// Inner padding for card-style containers.
        static let cardPadding: CGFloat = 16.0

        // Reusable badge sizes
        static let badgeSizeSmall: CGFloat = 26.0
        static let badgeSizeMedium: CGFloat = 36.0
        static let badgeSizeLarge: CGFloat = 44.0

        // Font sizes for badges
        static let badgeFontSmall: CGFloat = 13.0
        static let badgeFontMedium: CGFloat = 18.0
        static let badgeFontLarge: CGFloat = 22.0

        /// Corner radius for search bars and small interactive elements.
        static let searchBarCornerRadius: CGFloat = 12.0

        /// Standard icon circle size (used in info cards, schedule rows, etc.).
        static let iconCircleSize: CGFloat = 44.0
    }

    // MARK: - NYC Metro Map Configuration

    /// Geographic bounds and camera constraints for the NYC 5 boroughs + Long Island.
    ///
    /// The map is bounded so users stay within the MTA service area.
    /// Zoom limits keep context between street-level detail and
    /// the full boroughs + Long Island overview.
    struct MapConfig {
        private static let s = AppSettings.shared

        /// Center of the NYC 5 boroughs + Long Island bounding box.
        static let boundsCenter = CLLocationCoordinate2D(latitude: s.boundsCenterLat, longitude: s.boundsCenterLon)

        /// Bounds lat/lon deltas (used by MapLibre for clamping).
        static let boundsLatDelta: Double = s.boundsLatDelta
        static let boundsLonDelta: Double = s.boundsLonDelta

        /// Minimum / maximum camera distance in meters (used by MapLibre).
        static let minCameraDistance: Double = s.minCameraDistance
        static let maxCameraDistance: Double = s.maxCameraDistance

        /// Default zoom distance (meters) used when centering on the user.
        static let userZoomDistance: Double = s.userZoomDistance

        /// Fallback center (Midtown Manhattan) shown before CoreLocation
        /// delivers the first fix.
        static let nycCenter = CLLocationCoordinate2D(latitude: s.nycCenterLat, longitude: s.nycCenterLon)

        // MARK: - Service Area Validation

        /// Returns `true` if the coordinate is within the NYC metro service area.
        static func isInServiceArea(_ coordinate: CLLocationCoordinate2D) -> Bool {
            coordinate.latitude >= s.serviceAreaMinLat &&
            coordinate.latitude <= s.serviceAreaMaxLat &&
            coordinate.longitude >= s.serviceAreaMinLon &&
            coordinate.longitude <= s.serviceAreaMaxLon
        }
    }
}
