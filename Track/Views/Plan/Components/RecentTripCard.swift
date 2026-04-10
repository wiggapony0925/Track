// Premium recent trip card — layered glass card with gradient
// accent strip, rich mode icon container, route badges, and
// polished recency label.

import SwiftUI

struct RecentTripCard: View {
    let trip: SavedTrip
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // Gradient accent strip
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 3.5)
                    .padding(.vertical, 10)

                HStack(spacing: 14) {
                    // Mode icon container
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [AppTheme.Colors.accent.opacity(0.15), AppTheme.Colors.accent.opacity(0.05)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 46, height: 46)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(AppTheme.Colors.accent.opacity(0.12), lineWidth: 0.5)
                            )
                        Image(systemName: primaryModeIcon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.accent)
                    }

                    // Trip info
                    VStack(alignment: .leading, spacing: 7) {
                        // Origin → destination
                        HStack(spacing: 6) {
                            Text(trip.originName)
                                .lineLimit(1)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.5))
                            Text(trip.destinationName)
                                .lineLimit(1)
                        }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                        // Leg badges + date
                        HStack(spacing: 5) {
                            ForEach(Array(zip(trip.legSummary, trip.legModes).enumerated()), id: \.offset) { index, pair in
                                let (routeId, modeStr) = pair
                                if index > 0 {
                                    Circle()
                                        .fill(AppTheme.Colors.textTertiary.opacity(0.25))
                                        .frame(width: 3, height: 3)
                                }
                                legBadge(routeId: routeId, mode: modeStr)
                            }

                            Spacer(minLength: 0)

                            Text(dateLabel)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.Colors.textTertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(AppTheme.Colors.cardInset.opacity(0.5))
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.08), lineWidth: 0.5)
                                        )
                                )
                        }
                    }

                    // Chevron
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.3))
                }
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .padding(.vertical, 13)
            }
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground)

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.04), location: 0),
                                    .init(color: .clear, location: 0.35),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [AppTheme.Colors.borderSubtle.opacity(0.2), AppTheme.Colors.borderSubtle.opacity(0.08)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                }
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            )
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
