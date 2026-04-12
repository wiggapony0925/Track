// Central public design system for the Track NYC Transit App.
// Views should reference AppTheme tokens instead of hardcoding colors,
// gradients, spacing, or typography.

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

        // Chip Design Tokens
        /// Neutral chip surface — semi-transparent dark fill for inactive/container chips.
        static let chipSurface = AppThemeUtilities.adaptiveColor(\.chipSurface)
        /// Very subtle chip border for inactive states.
        static let chipBorder = AppThemeUtilities.adaptiveColor(\.chipBorder)
        /// Glass highlight for chip top-edge shine.
        static let chipGlassHighlight = AppThemeUtilities.adaptiveColor(\.chipGlassHighlight)
        /// Warm orange tint for Lost & Found chip.
        static let lostItemTint = AppThemeUtilities.adaptiveColor(\.lostItemTint)
        /// Red tint for favorited heart chip.
        static let favoriteTint = AppThemeUtilities.adaptiveColor(\.favoriteTint)

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
                .init(color: Colors.backgroundSecondary, location: 0.45),
                .init(color: Colors.backgroundTertiary, location: 1.00),
            ],
            startPoint: .top,
            endPoint: .bottom
        )

        static let screenSheen = LinearGradient(
            stops: [
                .init(color: Colors.glassHighlight.opacity(0.10), location: 0.00),
                .init(color: Color.clear, location: 0.30),
                .init(color: Colors.accentGlow.opacity(0.04), location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let screenGlow = LinearGradient(
            stops: [
                .init(color: Colors.accentGlow.opacity(0.12), location: 0.00),
                .init(color: Colors.accentSecondary.opacity(0.04), location: 0.50),
                .init(color: Color.clear, location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let heroGlow = LinearGradient(
            stops: [
                .init(color: Colors.accentSecondary.opacity(0.08), location: 0.00),
                .init(color: Colors.accentGlow.opacity(0.04), location: 0.50),
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
                .init(color: Colors.glassHighlight.opacity(0.12), location: 0.00),
                .init(color: Color.clear, location: 0.70),
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

        /// Vibrant accent gradient for hero elements — slightly wider color range.
        static let accentVibrant = LinearGradient(
            stops: [
                .init(color: Colors.accentSecondary, location: 0.00),
                .init(color: Colors.accent, location: 0.50),
                .init(color: Colors.accentDeep, location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static func tintWash(_ tint: Color, intensity: Double = 0.18) -> LinearGradient {
            LinearGradient(
                stops: [
                    .init(color: tint.opacity(intensity), location: 0.00),
                    .init(color: tint.opacity(intensity * 0.25), location: 0.60),
                    .init(color: tint.opacity(intensity * 0.08), location: 1.00),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Typography

    struct Typography {
        /// Large rounded header (Dynamic Type: Large Title).
        static let headerLarge: Font = .system(size: 34, weight: .bold, design: .rounded)

        /// Sheet/detail title — smaller than headerLarge, larger than headerMedium.
        /// Used for route detail sheet titles where the RouteBadge is the hero element.
        static let sheetTitle: Font = .system(size: 26, weight: .bold, design: .rounded)

        /// Medium header for sheet titles and card headers.
        static let headerMedium: Font = .system(size: 18, weight: .bold, design: .rounded)

        /// Section headers (Dynamic Type: Subheadline).
        static let sectionHeader: Font = .system(size: 13, weight: .heavy, design: .rounded)

        /// Monospaced route labels (Dynamic Type: Body).
        static let routeLabel: Font = .system(size: 17, weight: .bold, design: .rounded)

        /// Standard body text (Dynamic Type: Callout).
        static let body: Font = .system(size: 16, weight: .regular, design: .default)

        /// Card title text (bold).
        static let cardTitle: Font = .system(size: 16, weight: .semibold, design: .rounded)

        /// Card subtitle / secondary text.
        static let cardSubtitle: Font = .system(size: 14, weight: .medium, design: .default)

        /// Caption text for timestamps, metadata, and small labels.
        static let caption: Font = .system(size: 13, weight: .regular, design: .default)

        /// Small bold caption (e.g. day badges, counters).
        static let captionBold: Font = .system(size: 13, weight: .bold, design: .rounded)

        /// Search bar input text.
        static let searchInput: Font = .system(size: 15, weight: .regular, design: .default)

        /// Navigation back button text.
        static let navButton: Font = .system(size: 16, weight: .medium, design: .default)

        /// Settings row title.
        static let settingsTitle: Font = .system(size: 15, weight: .semibold, design: .rounded)

        /// Settings row description.
        static let settingsDescription: Font = .system(size: 13, weight: .regular, design: .default)

        /// Helper to get system font with rounded design at specific weight/size.
        static func helvetica(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .rounded)
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
        static let inner: CGFloat = 12
        /// Gap between related sections (16pt).
        static let section: CGFloat = 18
        /// Large gap between major content blocks (24pt).
        static let block: CGFloat = 28
    }

    // MARK: - Animation

    /// Reusable animation presets for consistent motion throughout the app.
    struct Animation {
        /// Snappy spring for taps and selections.
        static let snappy = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.75)
        /// Smooth spring for sheet transitions and navigation.
        static let smooth = SwiftUI.Animation.spring(response: 0.45, dampingFraction: 0.85)
        /// Gentle ease for fades and opacity changes.
        static let gentle = SwiftUI.Animation.easeInOut(duration: 0.25)
    }

    // MARK: - Subway Line Colors

    /// Official MTA subway line colors (2025 brand guide).
    /// Used by RouteBadge and widget transit badges.
    struct SubwayColors {
        static func color(for routeID: String) -> Color {
            switch routeID.uppercased() {
            case "1", "2", "3":
                return Color(red: 216 / 255, green: 34 / 255, blue: 51 / 255)     // Red #D82233
            case "4", "5", "6", "6X":
                // Dark Green #009952
                return Color(
                    red: 0 / 255,
                    green: 153 / 255,
                    blue: 82 / 255
                )
            case "7", "7X":
                return Color(red: 154 / 255, green: 56 / 255, blue: 161 / 255)    // Purple #9A38A1
            case "A", "C", "E":
                return Color(red: 0 / 255, green: 98 / 255, blue: 207 / 255)      // Blue #0062CF
            case "B", "D", "F", "FX", "M":
                return Color(red: 235 / 255, green: 104 / 255, blue: 0 / 255)     // Orange #EB6800
            case "G":
                // Light Green #799534
                return Color(
                    red: 121 / 255,
                    green: 149 / 255,
                    blue: 52 / 255
                )
            case "J", "Z":
                return Color(red: 142 / 255, green: 92 / 255, blue: 51 / 255)     // Brown #8E5C33
            case "L":
                return Color(red: 124 / 255, green: 133 / 255, blue: 140 / 255)   // Grey #7C858C
            case "N", "Q", "R", "W":
                return Color(red: 246 / 255, green: 188 / 255, blue: 38 / 255)    // Yellow #F6BC26
            case "S":
                return Color(red: 124 / 255, green: 133 / 255, blue: 140 / 255)   // Grey #7C858C
            case "SI", "SIR":
                return Color(red: 8 / 255, green: 23 / 255, blue: 156 / 255)      // Navy #08179C
            case "T":
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

    /// Bus route colors matching the backend canonical palette
    /// (`_BUS_SERVICE_COLORS` in nearby.py).
    struct BusColors {
        /// Local bus — #0078C6 (standard MTA bus blue).
        static let localBlue = Color(red: 0 / 255, green: 120 / 255, blue: 198 / 255)

        /// Select Bus Service (SBS) — #00B2E3 (cyan).
        static let sbsCyan = Color(red: 0 / 255, green: 178 / 255, blue: 227 / 255)

        /// Limited bus — #6E3FA3 (purple).
        static let limitedPurple = Color(red: 110 / 255, green: 63 / 255, blue: 163 / 255)

        /// Express bus — #3D9B35 (green).
        static let expressGreen = Color(red: 61 / 255, green: 155 / 255, blue: 53 / 255)

        /// School bus — #F7931E (orange).
        static let schoolOrange = Color(red: 247 / 255, green: 147 / 255, blue: 30 / 255)

        /// Default / unknown bus — #0039A6 (MTA corporate blue).
        static let defaultBlue = Color(red: 0 / 255, green: 57 / 255, blue: 166 / 255)

        /// Returns the correct color for a given bus service type string
        /// (as provided by the backend `bus_service_type` field).
        static func color(forServiceType type: String?) -> Color {
            switch type?.lowercased() {
            case "local":                       return localBlue
            case "limited":                     return limitedPurple
            case "select bus service":          return sbsCyan
            case "express":                     return expressGreen
            case "school":                      return schoolOrange
            default:                            return localBlue
            }
        }
    }

    // MARK: - Commuter Rail Colors

    /// Commuter rail colors for LIRR and Metro-North.
    struct CommuterRailColors {
        /// Long Island Rail Road brand blue.
        static let lirrBlue = Color(red: 0 / 255, green: 115 / 255, blue: 191 / 255)

        /// Metro-North Railroad brand blue (darker).
        static let mnrBlue = Color(red: 0 / 255, green: 90 / 255, blue: 140 / 255)

        static func lirrColor(for routeID: String) -> Color {
            switch routeID.uppercased() {
            case "1", "LIRR_1", "BABYLON", "BABYLON BRANCH":
                return Color(red: 0 / 255, green: 152 / 255, blue: 95 / 255)
            case "2", "LIRR_2", "HEMPSTEAD", "HEMPSTEAD BRANCH":
                return Color(red: 206 / 255, green: 142 / 255, blue: 0 / 255)
            case "3", "LIRR_3", "OYSTER BAY", "OYSTER BAY BRANCH":
                return Color(red: 0 / 255, green: 175 / 255, blue: 63 / 255)
            case "4", "LIRR_4", "RONKONKOMA", "RONKONKOMA BRANCH":
                return Color(red: 166 / 255, green: 38 / 255, blue: 170 / 255)
            case "5", "LIRR_5", "MONTAUK", "MONTAUK BRANCH":
                return Color(red: 0 / 255, green: 178 / 255, blue: 169 / 255)
            case "6", "LIRR_6", "LONG BEACH", "LONG BEACH BRANCH":
                return Color(red: 255 / 255, green: 99 / 255, blue: 25 / 255)
            case "7", "LIRR_7", "FAR ROCKAWAY", "FAR ROCKAWAY BRANCH":
                return Color(red: 110 / 255, green: 50 / 255, blue: 25 / 255)
            case "8", "LIRR_8", "WEST HEMPSTEAD", "WEST HEMPSTEAD BRANCH":
                return Color(red: 0 / 255, green: 161 / 255, blue: 222 / 255)
            case "9", "LIRR_9", "PORT WASHINGTON", "PORT WASHINGTON BRANCH":
                return Color(red: 198 / 255, green: 12 / 255, blue: 48 / 255)
            case "10", "LIRR_10", "PORT JEFFERSON", "PORT JEFFERSON BRANCH":
                return Color(red: 0 / 255, green: 110 / 255, blue: 199 / 255)
            case "11", "LIRR_11", "BELMONT PARK", "BELMONT PARK BRANCH":
                return Color(red: 96 / 255, green: 38 / 255, blue: 158 / 255)
            case "12", "LIRR_12", "CITY TERMINAL ZONE":
                return Color(red: 77 / 255, green: 83 / 255, blue: 87 / 255)
            case "13", "LIRR_13", "GREENPORT", "GREENPORT SERVICE", "GREENPORT BRANCH":
                return Color(red: 166 / 255, green: 38 / 255, blue: 170 / 255)
            default:
                return lirrBlue
            }
        }

        static func mnrColor(for routeID: String) -> Color {
            switch routeID.uppercased() {
            case "1", "MNR_1", "HUDSON", "HUDSON LINE":
                return Color(red: 0 / 255, green: 155 / 255, blue: 58 / 255)
            case "2", "MNR_2", "HARLEM", "HARLEM LINE":
                return Color(red: 0 / 255, green: 57 / 255, blue: 166 / 255)
            case "3", "MNR_3", "NEW HAVEN", "NEW HAVEN LINE":
                return Color(red: 224 / 255, green: 0 / 255, blue: 52 / 255)
            case "4", "MNR_4", "NEW CANAAN", "NEW CANAAN LINE":
                return Color(red: 224 / 255, green: 0 / 255, blue: 52 / 255)
            case "5", "MNR_5", "DANBURY", "DANBURY LINE":
                return Color(red: 224 / 255, green: 0 / 255, blue: 52 / 255)
            case "6", "MNR_6", "WATERBURY", "WATERBURY LINE":
                return Color(red: 224 / 255, green: 0 / 255, blue: 52 / 255)
            case "PASCACK VALLEY", "PASCACK VALLEY LINE":
                return Color(red: 146 / 255, green: 61 / 255, blue: 151 / 255)
            case "PORT JERVIS", "PORT JERVIS LINE":
                return Color(red: 255 / 255, green: 121 / 255, blue: 0 / 255)
            default:
                return mnrBlue
            }
        }
    }

    // MARK: - Layout

    struct Layout {
        static let margin: CGFloat = 16.0
        static let cornerRadius: CGFloat = 14.0
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
        static let boundsCenter = CLLocationCoordinate2D(
            latitude: s.boundsCenterLat,
            longitude: s.boundsCenterLon
        )

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
        static let nycCenter = CLLocationCoordinate2D(
            latitude: s.nycCenterLat,
            longitude: s.nycCenterLon
        )

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
