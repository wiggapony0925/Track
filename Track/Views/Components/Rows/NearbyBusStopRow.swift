// Displays a nearby bus stop in a list. Tapping selects it to
// fetch live arrivals. Extracted from HomeView for reusability.

import SwiftUI

struct NearbyBusStopRow: View {
    let stop: BusStop

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.Colors.mtaBlue)
                    .frame(
                        width: AppTheme.Layout.badgeSizeMedium,
                        height: AppTheme.Layout.badgeSizeMedium
                    )
                    .shadow(color: AppTheme.Colors.mtaBlue.opacity(0.3), radius: 2, x: 0, y: 1)
                
                Image(systemName: "bus.fill")
                    .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
            }
            .accessibilityHidden(true)

            Text(stop.name)
                .font(.custom("Helvetica-Bold", size: 15))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            if let direction = stop.direction {
                Text(direction == "0" ? "→" : "←")
                    .font(.custom("Helvetica", size: 16))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bus stop: \(stop.name)")
    }
}
