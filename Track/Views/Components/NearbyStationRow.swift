//
//  NearbyStationRow.swift
//  Track
//
//  Displays a nearby station with distance and available routes.
//

import SwiftUI

struct NearbyStationRow: View {
    let name: String
    let distance: Double
    let routeIDs: [String]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tram.fill")
                .font(.system(size: 18))
                .foregroundColor(AppTheme.Colors.mtaBlue)
                .frame(width: AppTheme.Layout.badgeSizeMedium, height: AppTheme.Layout.badgeSizeMedium)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 4) {
                    ForEach(routeIDs, id: \.self) { route in
                        RouteBadge(routeID: route, size: .small)
                    }
                }
            }

            Spacer(minLength: 4)

            Text(formattedDistance)
                .font(.custom("Helvetica", size: 14))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) station, routes \(routeIDs.joined(separator: ", ")), \(formattedDistance) away")
    }

    private var formattedDistance: String {
        formatDistance(distance, suffix: "")
    }
}

#Preview {
    VStack {
        NearbyStationRow(name: "1st Avenue", distance: 120, routeIDs: ["L"])
        NearbyStationRow(name: "Bedford Avenue", distance: 250, routeIDs: ["L"])
        NearbyStationRow(name: "Metropolitan Av", distance: 400, routeIDs: ["G"])
    }
    .background(AppTheme.Colors.background)
}
