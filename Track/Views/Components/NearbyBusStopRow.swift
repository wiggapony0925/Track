//
//  NearbyBusStopRow.swift
//  Track
//
//  Displays a nearby bus stop in a list. Tapping selects it to
//  fetch live arrivals. Extracted from HomeView for reusability.
//

import SwiftUI

struct NearbyBusStopRow: View {
    let stop: BusStop

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.mtaBlue)
                    .frame(width: AppTheme.Layout.badgeSizeMedium, height: AppTheme.Layout.badgeSizeMedium)
                Image(systemName: "bus.fill")
                    .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
            }
            .accessibilityHidden(true)

            Text(stop.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            if let direction = stop.direction {
                Text(direction == "0" ? "→" : "←")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bus stop: \(stop.name)")
    }
}
