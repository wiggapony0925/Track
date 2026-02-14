//
//  AppTheme.swift
//  Shared
//
//  Central design system for the Track NYC Transit App.
//  All styling, colors, and typography must reference this file.
//  Every view, widget, and component should pull values from here —
//  never hardcode colors, fonts, or layout constants.
//

import SwiftUI
import MapKit

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

        /// Pulsing "GO" mode accent — a vivid green for the live tracking state.
        static let goGreen = Color(red: 52/255, green: 199/255, blue: 89/255)

        /// Returns the appropriate countdown color for a given minutes value.
        /// Red ≤ 2 min, green ≤ 5 min, primary otherwise.
        static func countdown(_ minutes: Int) -> Color {
            if minutes <= 2 { return alertRed }
            if minutes <= 5 { return successGreen }
            return textPrimary
        }
    }

    // MARK: - Typography

    // MARK: - Typography

    struct Typography {
        /// Large rounded header (Dynamic Type: Large Title).
        static let headerLarge: Font = .custom("Helvetica-Bold", size: 34)

        /// Section headers (Dynamic Type: Subheadline).
        static let sectionHeader: Font = .custom("Helvetica-Bold", size: 15)

        /// Monospaced route labels (Dynamic Type: Body).
        /// Using Helvetica-Bold instead of generic heavy monospaced for better brand alignment.
        static let routeLabel: Font = .custom("Helvetica-Bold", size: 17)

        /// Standard body text (Dynamic Type: Callout).
        static let body: Font = .custom("Helvetica", size: 16)
        
        /// Helper to get Helvetica with specific weight/size
        static func helvetica(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            // Helvetica handles weights via font names mostly, but SwiftUI can apply weights too.
            // Standard Helvetica doesn't always support all weights via .weight() modifier on ".custom",
            // so we stick to the main ones or let system simulate.
            // For safety and consistency:
            return .custom("Helvetica", size: size).weight(weight)
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
                // Determine if it's likely a bus (e.g. Bx12, M15, Q32) or just unknown.
                // MTA buses are generally blue. LIRR is also often blue/yellow but we treat default as MTA blue.
                return Colors.mtaBlue
            }
        }

        /// Returns white for most lines, black for yellow lines for readability.
        static func textColor(for routeID: String) -> Color {
            switch routeID.uppercased() {
            case "N", "Q", "R", "W":
                // Standard yellow lines use black text.
                return .black
            default:
                // All others (Red, Green, Blue, Orange, Grey, Purple, Buses) use white.
                return .white
            }
        }
    }

    // MARK: - Layout

    struct Layout {
        static let margin: CGFloat = 16.0
        static let cornerRadius: CGFloat = 20.0 // Larger, softer corners like Apple Maps
        static let shadowRadius: CGFloat = 4.0

        /// Inner padding for card-style containers.
        static let cardPadding: CGFloat = 16.0 // More breathing room

        // Reusable badge sizes
        static let badgeSizeSmall: CGFloat = 26.0
        static let badgeSizeMedium: CGFloat = 36.0 // Bigger icons
        static let badgeSizeLarge: CGFloat = 44.0

        // Font sizes for badges
        static let badgeFontSmall: CGFloat = 13.0
        static let badgeFontMedium: CGFloat = 18.0
        static let badgeFontLarge: CGFloat = 22.0
    }

    // MARK: - NYC Metro Map Configuration

    /// Geographic bounds and camera constraints for the NYC 5 boroughs + Long Island.
    ///
    /// The map is bounded so users stay within the MTA service area.
    /// Zoom limits keep context between street-level detail and
    /// the full boroughs + Long Island overview.
    ///
    /// References:
    /// - ``MapCameraBounds`` — https://developer.apple.com/documentation/mapkit/mapcamerabounds
    /// - ``MKCoordinateRegion`` — https://developer.apple.com/documentation/mapkit/mkcoordinateregion
    struct MapConfig {
        private static let s = AppSettings.shared

        /// Center of the NYC 5 boroughs + Long Island bounding box.
        static let boundsCenter = CLLocationCoordinate2D(latitude: s.boundsCenterLat, longitude: s.boundsCenterLon)

        /// Span that covers the 5 boroughs and Long Island with margin.
        static let boundsSpan = MKCoordinateSpan(latitudeDelta: s.boundsLatDelta, longitudeDelta: s.boundsLonDelta)

        /// The region used to constrain map panning.
        static let boundsRegion = MKCoordinateRegion(center: boundsCenter, span: boundsSpan)

        /// Camera bounds that restrict panning and zoom.
        static let cameraBounds = MapCameraBounds(
            centerCoordinateBounds: boundsRegion,
            minimumDistance: s.minCameraDistance,
            maximumDistance: s.maxCameraDistance
        )

        /// Default zoom distance (meters) used when centering on the user.
        static let userZoomDistance: Double = s.userZoomDistance

        /// Fallback center (Midtown Manhattan) shown before CoreLocation
        /// delivers the first fix.
        static let nycCenter = CLLocationCoordinate2D(latitude: s.nycCenterLat, longitude: s.nycCenterLon)

        /// Fallback region centered on Midtown at a comfortable zoom level.
        static let fallbackRegion = MKCoordinateRegion(
            center: nycCenter,
            latitudinalMeters: userZoomDistance,
            longitudinalMeters: userZoomDistance
        )

        /// Initial camera position — follows the user's location.
        /// Falls back to Midtown Manhattan if location is unavailable.
        static let initialPosition: MapCameraPosition = .userLocation(
            fallback: .region(fallbackRegion)
        )

        // MARK: - Service Area Validation

        /// Returns `true` if the coordinate is within the NYC metro service area.
        static func isInServiceArea(_ coordinate: CLLocationCoordinate2D) -> Bool {
            coordinate.latitude  >= s.serviceAreaMinLat &&
            coordinate.latitude  <= s.serviceAreaMaxLat &&
            coordinate.longitude >= s.serviceAreaMinLon &&
            coordinate.longitude <= s.serviceAreaMaxLon
        }
    }
}
