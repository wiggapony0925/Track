//
//  SearchRadiusOverlay.swift
//  Track
//
//  Color-coded radius circles rendered on the map to visualize
//  the three transit search tiers from Settings:
//    🟢 Near You       — green
//    🔵 A Bit Farther  — blue
//    🟡 Much Farther   — yellow
//
//  Toggle on/off via Settings → Map & Display → Search Radius.
//

import SwiftUI
import MapKit

/// Map content that draws three concentric radius circles around the user's location
/// with gradient fills, dashed stroke borders, and labeled distance markers.
struct SearchRadiusOverlay: MapContent {
    let center: CLLocationCoordinate2D
    let nearRadius: Double
    let fartherRadius: Double
    let muchFartherRadius: Double
    
    var body: some MapContent {
        // Draw outermost first so inner circles layer correctly
        
        // ── Much Farther — yellow ──
        MapCircle(center: center, radius: muchFartherRadius)
            .foregroundStyle(
                .radialGradient(
                    colors: [
                        AppTheme.Colors.warningYellow.opacity(0.03),
                        AppTheme.Colors.warningYellow.opacity(0.08)
                    ],
                    center: .center,
                    startRadius: muchFartherRadius * 0.4,
                    endRadius: muchFartherRadius
                )
            )
            .stroke(
                AppTheme.Colors.warningYellow.opacity(0.4),
                style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])
            )
        
        // Much Farther label
        Annotation("", coordinate: offsetCoordinate(bearing: 45, distance: muchFartherRadius)) {
            RadiusLabel(
                text: formatDistance(muchFartherRadius),
                color: AppTheme.Colors.warningYellow
            )
        }
        
        // ── A Bit Farther — blue ──
        MapCircle(center: center, radius: fartherRadius)
            .foregroundStyle(
                .radialGradient(
                    colors: [
                        AppTheme.Colors.mtaBlue.opacity(0.03),
                        AppTheme.Colors.mtaBlue.opacity(0.10)
                    ],
                    center: .center,
                    startRadius: fartherRadius * 0.4,
                    endRadius: fartherRadius
                )
            )
            .stroke(
                AppTheme.Colors.mtaBlue.opacity(0.45),
                style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])
            )
        
        // Farther label
        Annotation("", coordinate: offsetCoordinate(bearing: 45, distance: fartherRadius)) {
            RadiusLabel(
                text: formatDistance(fartherRadius),
                color: AppTheme.Colors.mtaBlue
            )
        }
        
        // ── Near You — green ──
        MapCircle(center: center, radius: nearRadius)
            .foregroundStyle(
                .radialGradient(
                    colors: [
                        AppTheme.Colors.successGreen.opacity(0.04),
                        AppTheme.Colors.successGreen.opacity(0.12)
                    ],
                    center: .center,
                    startRadius: nearRadius * 0.3,
                    endRadius: nearRadius
                )
            )
            .stroke(
                AppTheme.Colors.successGreen.opacity(0.55),
                style: StrokeStyle(lineWidth: 2, dash: [6, 4])
            )
        
        // Near label
        Annotation("", coordinate: offsetCoordinate(bearing: 45, distance: nearRadius)) {
            RadiusLabel(
                text: formatDistance(nearRadius),
                color: AppTheme.Colors.successGreen
            )
        }
    }
    
    // MARK: - Helpers
    
    /// Offsets a coordinate from center by a bearing (degrees) and distance (meters).
    private func offsetCoordinate(bearing: Double, distance: Double) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0 // meters
        let bearingRad = bearing * .pi / 180
        let lat1 = center.latitude * .pi / 180
        let lon1 = center.longitude * .pi / 180
        let angularDistance = distance / earthRadius
        
        let lat2 = asin(
            sin(lat1) * cos(angularDistance) +
            cos(lat1) * sin(angularDistance) * cos(bearingRad)
        )
        let lon2 = lon1 + atan2(
            sin(bearingRad) * sin(angularDistance) * cos(lat1),
            cos(angularDistance) - sin(lat1) * sin(lat2)
        )
        
        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: lon2 * 180 / .pi
        )
    }
    
    /// Formats meters into a human-readable distance string (miles).
    private func formatDistance(_ meters: Double) -> String {
        formatDistanceMiles(meters)
    }
}

// MARK: - Radius Label

/// A small frosted-glass pill that displays the distance at the edge of a radius circle.
private struct RadiusLabel: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(color.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}
