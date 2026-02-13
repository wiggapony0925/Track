//
//  MapAnnotations.swift
//  Track
//
//  Reusable map annotation views used in HomeView's Map.
//  Extracted to keep HomeView focused on layout and state management.
//

import SwiftUI

// MARK: - Search Pin Annotation

/// A draggable search pin for exploring transit at other locations.
struct SearchPinAnnotation: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Colors.alertRed)
                .frame(width: 36, height: 36)
                .shadow(color: AppTheme.Colors.alertRed.opacity(0.4), radius: AppTheme.Layout.shadowRadius)
            Image(systemName: "mappin")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppTheme.Colors.textOnColor)
        }
        .accessibilityLabel("Search pin — drag to explore")
    }
}

// MARK: - Bus Vehicle Annotation

/// A map pin showing a live bus position with its route name and bearing.
/// A map pin showing a live bus position with its route name and bearing.
struct BusVehicleAnnotation: View {
    let routeName: String
    let bearing: Double?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Bus Body (Top-down view)
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.Colors.mtaBlue)
                    .frame(width: 22, height: 44)
                    .overlay(
                        VStack(spacing: 2) {
                            // Windshield
                            Rectangle()
                                .fill(Color.black.opacity(0.6))
                                .frame(height: 6)
                            Spacer()
                            // Rear window
                            Rectangle()
                                .fill(Color.black.opacity(0.4))
                                .frame(height: 4)
                        }
                        .padding(.vertical, 2)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 2)
                
                // Route Label on Roof
                Text(routeName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(-90)) // Rotate text to run along bus length
            }
            .rotationEffect(.degrees(bearing ?? 0))
        }
        .accessibilityLabel("Bus \(routeName)")
    }
}

