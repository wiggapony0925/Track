// Horizontal scrolling strip of scheduled-only chips.
//
// Used as the empty-state fallback when no live vehicles are near
// the stop but the GTFS timetable still has departures to surface
// (e.g. very early morning at a bus stop with one trip per hour).

import SwiftUI

struct ScheduledChipStrip: View {
    let departures: [ScheduledItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                SectionHeader(title: "Scheduled Departures", size: 10, tracking: 1.0, color: AppTheme.Colors.textSecondary.opacity(0.5))

                LinearGradient(
                    colors: [
                        AppTheme.Colors.textSecondary.opacity(0.1),
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 0.5)
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(departures) { departure in
                        ScheduledChipView(departure: departure)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.vertical, 6)
            }
        }
    }
}
