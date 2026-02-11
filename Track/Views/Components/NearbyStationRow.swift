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
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                HStack(spacing: 4) {
                    ForEach(routeIDs, id: \.self) { route in
                        Text(route)
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(AppTheme.Colors.mtaBlue)
                            .clipShape(Circle())
                    }
                }
            }

            Spacer()

            Text(formattedDistance)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    private var formattedDistance: String {
        if distance < 1000 {
            return "\(Int(distance))m"
        } else {
            return String(format: "%.1fkm", distance / 1000)
        }
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
