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
struct BusVehicleAnnotation: View {
    let routeName: String
    let bearing: Double?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.mtaBlue)
                    .frame(width: AppTheme.Layout.badgeSizeMedium, height: AppTheme.Layout.badgeSizeMedium)
                    .shadow(color: AppTheme.Colors.mtaBlue.opacity(0.4), radius: AppTheme.Layout.shadowRadius)
                Image(systemName: "bus.fill")
                    .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
                    .rotationEffect(.degrees(bearing ?? 0))
            }
            Text(routeName)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(AppTheme.Colors.textOnColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(AppTheme.Colors.mtaBlue)
                .clipShape(Capsule())
        }
        .accessibilityLabel("Bus \(routeName)")
    }
}
