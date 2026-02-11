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

    // MARK: - NYC Metro Map Configuration

    /// Geographic bounds and camera constraints for the NYC 5 boroughs + Long Island.
    ///
    /// The map is bounded to the NYC metro core so users stay within
    /// the service area. Zoom limits keep context between street-level
    /// detail and the full boroughs + Long Island overview.
    ///
    /// References:
    /// - ``MapCameraBounds`` — https://developer.apple.com/documentation/mapkit/mapcamerabounds
    /// - ``MKCoordinateRegion`` — https://developer.apple.com/documentation/mapkit/mkcoordinateregion
    struct MapConfig {
        /// Geographic center of the NYC 5 boroughs + Long Island area.
        /// Positioned to balance the boroughs (west) with Long Island (east).
        static let metroCenter = CLLocationCoordinate2D(latitude: 40.72, longitude: -73.55)

        /// Coordinate span covering the 5 boroughs and Long Island.
        /// North ~40.92 (Bronx) → South ~40.50 (Staten Island) ≈ 0.50
        /// West ~-74.26 (Staten Island) → East ~-72.50 (Suffolk) ≈ 1.80
        static let metroSpan = MKCoordinateSpan(latitudeDelta: 0.55, longitudeDelta: 1.80)

        /// The region used to constrain map panning to the 5 boroughs + Long Island.
        static let metroRegion = MKCoordinateRegion(center: metroCenter, span: metroSpan)

        /// Camera bounds that restrict user panning to the NYC boroughs + Long Island.
        /// - minimumDistance: 500 m (street-level zoom)
        /// - maximumDistance: 150 km (see the whole region)
        static let cameraBounds = MapCameraBounds(
            centerCoordinateBounds: metroRegion,
            minimumDistance: 500,
            maximumDistance: 150_000
        )

        /// Default NYC center (Manhattan) for fallback when user location is unavailable.
        static let nycCenter = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)

        /// Default zoom distance (meters) for centering on the user's location.
        static let userZoomDistance: Double = 3000

        /// Initial camera position — starts on NYC center; replaced by user
        /// location once CoreLocation delivers the first fix.
        static let initialPosition: MapCameraPosition = .camera(
            MapCamera(centerCoordinate: nycCenter, distance: userZoomDistance)
        )
    }
}
