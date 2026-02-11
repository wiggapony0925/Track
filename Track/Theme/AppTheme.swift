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
        /// Large rounded header (Dynamic Type: Large Title).
        static let headerLarge: Font = .system(.largeTitle, design: .rounded).weight(.bold)

        /// Section headers (Dynamic Type: Subheadline).
        static let sectionHeader: Font = .system(.subheadline, design: .default).weight(.semibold)

        /// Monospaced route labels (Dynamic Type: Body).
        static let routeLabel: Font = .system(.body, design: .monospaced).weight(.heavy)

        /// Standard body text (Dynamic Type: Callout).
        static let body: Font = .system(.callout, design: .default).weight(.medium)
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
    /// The map is bounded so users stay within the MTA service area.
    /// Zoom limits keep context between street-level detail and
    /// the full boroughs + Long Island overview.
    ///
    /// References:
    /// - ``MapCameraBounds`` — https://developer.apple.com/documentation/mapkit/mapcamerabounds
    /// - ``MKCoordinateRegion`` — https://developer.apple.com/documentation/mapkit/mkcoordinateregion
    struct MapConfig {
        /// Center of the NYC 5 boroughs + Long Island bounding box.
        /// Lat ≈ midpoint of Bronx (40.92) and Staten Island (40.50).
        /// Lon ≈ midpoint of Staten Island (-74.26) and Suffolk (-72.50).
        static let boundsCenter = CLLocationCoordinate2D(latitude: 40.71, longitude: -73.38)

        /// Span that covers the 5 boroughs and Long Island with margin.
        /// Lat 0.60° ≈ north Bronx to south Staten Island + buffer.
        /// Lon 2.00° ≈ west Staten Island to eastern Suffolk + buffer.
        static let boundsSpan = MKCoordinateSpan(latitudeDelta: 0.60, longitudeDelta: 2.00)

        /// The region used to constrain map panning.
        static let boundsRegion = MKCoordinateRegion(center: boundsCenter, span: boundsSpan)

        /// Camera bounds that restrict panning and zoom.
        /// - minimumDistance: 300 m (street-level zoom for subway entrances)
        /// - maximumDistance: 80 km (enough to see the full service area)
        static let cameraBounds = MapCameraBounds(
            centerCoordinateBounds: boundsRegion,
            minimumDistance: 300,
            maximumDistance: 80_000
        )

        /// Default zoom distance (meters) used when centering on the user.
        static let userZoomDistance: Double = 3000

        /// Fallback center (Midtown Manhattan) shown before CoreLocation
        /// delivers the first fix.
        static let nycCenter = CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855)

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

        /// Generous bounding box for the NYC MTA service area.
        /// Covers the 5 boroughs, Long Island, and nearby NJ/Westchester.
        /// Used to detect whether a GPS fix is within the service area.
        private static let serviceAreaMinLat: Double = 40.40
        private static let serviceAreaMaxLat: Double = 41.10
        private static let serviceAreaMinLon: Double = -74.35
        private static let serviceAreaMaxLon: Double = -72.40

        /// Returns `true` if the coordinate is within the NYC metro service area.
        static func isInServiceArea(_ coordinate: CLLocationCoordinate2D) -> Bool {
            coordinate.latitude  >= serviceAreaMinLat &&
            coordinate.latitude  <= serviceAreaMaxLat &&
            coordinate.longitude >= serviceAreaMinLon &&
            coordinate.longitude <= serviceAreaMaxLon
        }
    }
}
