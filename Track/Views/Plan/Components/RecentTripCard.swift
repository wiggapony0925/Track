// Recent trip card — clean, bold card with large destination text,
// inline route badges, and compact date label.

import SwiftUI

struct RecentTripCard: View {
    let trip: SavedTrip
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Mode icon badge
                Image(systemName: primaryModeIcon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.Colors.accent.gradient)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    // Route: Origin → Destination
                    HStack(spacing: 6) {
                        Text(trip.originName)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)

                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.45))

                        Text(trip.destinationName)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                    }

                    // Leg badges
                    HStack(spacing: 5) {
                        ForEach(Array(zip(trip.legSummary, trip.legModes).enumerated()), id: \.offset) { index, pair in
                            let (routeId, modeStr) = pair
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.3))
                            }
                            legBadge(routeId: routeId, mode: modeStr)
                        }
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(dateLabel)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.25))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(RecentTripButtonStyle())
    }

    // MARK: - Leg Badge

    @ViewBuilder
    private func legBadge(routeId: String, mode: String) -> some View {
        if mode == "walk" {
            HStack(spacing: 2) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 10, weight: .bold))
                Text(routeId)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(AppTheme.Colors.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(AppTheme.Colors.cardInset.opacity(0.45))
            )
        } else {
            RouteBadge(
                routeID: routeId,
                size: .small,
                mode: mode == "bus" ? "bus" : (mode == "lirr" ? "lirr" : (mode == "mnr" ? "mnr" : nil))
            )
        }
    }

    // MARK: - Helpers

    private var primaryModeIcon: String {
        if trip.legModes.contains("subway") { return "tram.fill" }
        if trip.legModes.contains("bus") { return "bus.fill" }
        if trip.legModes.contains("lirr") || trip.legModes.contains("mnr") { return "train.side.front.car" }
        return "map.fill"
    }

    private var dateLabel: String {
        guard let date = trip.lastUsedAt ?? Optional(trip.savedAt) else {
            return "Saved"
        }
        if Calendar.current.isDateInToday(date) {
            return "Today"
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return f.string(from: date)
        }
    }
}

// MARK: - Button Style

private struct RecentTripButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    VStack(spacing: 8) {
        RecentTripCard(
            trip: SavedTrip(
                originName: "Home",
                originAddress: "117-13 125th St",
                originLat: 40.6745,
                originLon: -73.7955,
                destinationName: "Times Square",
                destinationAddress: "42 St",
                destinationLat: 40.7580,
                destinationLon: -73.9855,
                legSummary: ["Q9", "E"],
                legModes: ["bus", "subway"],
                savedAt: Date()
            ),
            onTap: {}
        )
    }
    .padding()
    .background(Color.black)
}
