// Recent trip card — darker, route-first card with a subtle trip
// connector, badge row, and recency metadata.

import SwiftUI

struct RecentTripCard: View {
    let trip: SavedTrip
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                tripConnector

                VStack(alignment: .leading, spacing: 9) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trip.destinationName)
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Text("from")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.Colors.textTertiary)
                            Text(trip.originName)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 5) {
                        ForEach(Array(zip(trip.legSummary, trip.legModes).enumerated()), id: \.offset) { index, pair in
                            let (routeId, modeStr) = pair
                            if index > 0 {
                                Capsule()
                                    .fill(AppTheme.Colors.textTertiary.opacity(0.22))
                                    .frame(width: 10, height: 3)
                            }
                            legBadge(routeId: routeId, mode: modeStr)
                        }
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 10) {
                    Text(dateLabel)
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(AppTheme.Colors.cardInset.opacity(0.55))
                        )

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.32))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(cardBackground)
        }
        .buttonStyle(RecentTripButtonStyle())
    }

    private var tripConnector: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.16))
                    .frame(width: 20, height: 20)
                Circle()
                    .fill(AppTheme.Colors.accent)
                    .frame(width: 9, height: 9)
            }

            Rectangle()
                .fill(AppTheme.Colors.textTertiary.opacity(0.18))
                .frame(width: 2, height: 28)

            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.Colors.alertRed.opacity(0.16))
                    .frame(width: 20, height: 20)
                Image(systemName: "mappin")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(AppTheme.Colors.alertRed)
            }
        }
        .padding(.leading, 2)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.035), location: 0),
                                .init(color: .clear, location: 0.42),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
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
                Capsule().fill(AppTheme.Colors.cardInset.opacity(0.5))
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
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
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
