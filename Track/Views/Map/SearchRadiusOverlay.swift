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
/// with gradient fills and dashed stroke borders.
///
/// Distance labels are intentionally NOT rendered as `Annotation` views because
/// MapKit aggressively culls annotations during zoom transitions, which caused the
/// entire radius overlay to flicker or disappear. The distance values are already
/// shown in the Settings tier indicators and the dashboard section headers.
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
    }
}
