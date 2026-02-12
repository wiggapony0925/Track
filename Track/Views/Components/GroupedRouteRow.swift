//
//  GroupedRouteRow.swift
//  Track
//
//  A compact row for a grouped route card. Shows the route badge,
//  display name, direction count, and soonest arrival countdown.
//  Tapping opens the RouteDetailSheet.
//  Extracted from HomeView for reusability.
//

import SwiftUI

struct GroupedRouteRow: View {
    let group: GroupedNearbyTransitResponse

    var body: some View {
        HStack(spacing: 12) {
            // Mode badge
            ZStack {
                Circle()
                    .fill(badgeColor)
                    .frame(width: AppTheme.Layout.badgeSizeMedium,
                           height: AppTheme.Layout.badgeSizeMedium)
                if group.isBus {
                    Image(systemName: "bus.fill")
                        .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text(group.displayName)
                        .font(.system(size: AppTheme.Layout.badgeFontMedium,
                                      weight: .heavy, design: .monospaced))
                        .foregroundColor(AppTheme.SubwayColors.textColor(for: group.displayName))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
            .accessibilityHidden(true)

            // Route info
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 4) {
                    ForEach(group.directions, id: \.direction) { dir in
                        Text(shortDirectionLabel(dir.direction))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    if group.directions.count > 1 {
                        Text("·")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("\(group.directions.count) directions")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                }
            }

            Spacer(minLength: 4)

            // Soonest countdown
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(group.soonestMinutes)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.countdown(group.soonestMinutes))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(group.isBus ? "Bus" : "Train") \(group.displayName), next in \(group.soonestMinutes) minutes"
        )
        .accessibilityHint("Tap to see arrivals in both directions")
    }

    private var badgeColor: Color {
        if let hex = group.colorHex {
            return Color(hex: hex)
        }
        return group.isBus
            ? AppTheme.Colors.mtaBlue
            : AppTheme.SubwayColors.color(for: group.displayName)
    }
}
