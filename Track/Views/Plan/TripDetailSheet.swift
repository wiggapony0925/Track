// Premium trip detail sheet — immersive hero banner,
// glass stat cards, rich timeline, and polished action buttons.

import SwiftUI

struct TripDetailSheet: View {
    let trip: TripPlan

    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Hero banner
                    heroBanner

                    // Stats row (overlapping hero)
                    statsRow
                        .padding(.top, -30)
                        .padding(.horizontal, 16)

                    // Route summary
                    routeSummary
                        .padding(.top, 20)
                        .padding(.horizontal, 16)

                    if let nextAction = trip.nextAction {
                        nextActionCard(nextAction)
                            .padding(.top, 18)
                            .padding(.horizontal, 16)
                    }

                    // Divider
                    RoundedRectangle(cornerRadius: 1)
                        .fill(AppTheme.Colors.borderSubtle.opacity(0.2))
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                        .padding(.top, 18)

                    if !trip.serviceAlerts.isEmpty {
                        alertsSection
                            .padding(.top, 18)
                            .padding(.horizontal, 16)
                    }

                    // Full timeline
                    TripTimelineView(trip: trip)
                        .padding(.horizontal, 16)
                        .padding(.top, trip.serviceAlerts.isEmpty ? 16 : 20)

                    // Fare estimate
                    fareEstimate
                        .padding(.top, 20)
                        .padding(.horizontal, 16)

                    // Environmental impact (CO₂ + calories)
                    environmentalImpactView
                        .padding(.top, 12)
                        .padding(.horizontal, 16)

                    // Action buttons
                    actionButtons
                        .padding(.top, 24)
                        .padding(.horizontal, 16)

                    Spacer(minLength: 40)
                }
            }
            .background(AppTheme.Colors.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(AppTheme.Colors.cardInset)
                                    .overlay(
                                        Circle().strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.3), lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .principal) {
                    Text("Trip Details")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        // TODO: Share
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.5).delay(0.1)) {
                    appeared = true
                }
            }
        }
    }

    // MARK: - Hero Banner

    private var heroBanner: some View {
        ZStack(alignment: .bottomLeading) {
            // Gradient background
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: AppTheme.Colors.accent, location: 0),
                        .init(color: AppTheme.Colors.accentDeep, location: 0.65),
                        .init(color: AppTheme.Colors.accentDeep.opacity(0.9), location: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Decorative orbs
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.08), .clear],
                            center: .center, startRadius: 0, endRadius: 90
                        )
                    )
                    .frame(width: 180, height: 180)
                    .offset(x: 200, y: -50)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [AppTheme.Colors.accentSecondary.opacity(0.1), .clear],
                            center: .center, startRadius: 0, endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)
                    .offset(x: -20, y: 30)
            }

            // Content
            VStack(alignment: .leading, spacing: 10) {
                Spacer()

                // Departure time
                Text("Go at \(timeString(trip.departureTime))")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                // Trip summary chips
                HStack(spacing: 12) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(trip.durationString)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }

                    Text("·")
                        .font(.system(size: 14, weight: .bold))

                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: 11, weight: .bold))
                        Text(
                            trip.numTransfers == 0
                                ? "Direct"
                                : "\(trip.numTransfers) transfer\(trip.numTransfers > 1 ? "s" : "")"
                        )
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }

                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 48)
        }
        .frame(height: 190)
        .clipShape(Rectangle())
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard(
                icon: "arrow.right.circle.fill",
                label: "DEPART",
                value: timeString(trip.departureTime),
                color: AppTheme.Colors.accent
            )
            statCard(
                icon: "flag.checkered",
                label: "ARRIVE",
                value: timeString(trip.arrivalTime),
                color: AppTheme.Colors.successGreen
            )
            statCard(
                icon: "figure.walk",
                label: "WALK",
                value: walkDistanceString,
                color: AppTheme.Colors.warningYellow
            )
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 15)
    }

    private func statCard(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
                // Top-edge glass highlight
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.04), location: 0),
                                .init(color: .clear, location: 0.4),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.25), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
        )
    }

    // MARK: - Route Summary

    private var routeSummary: some View {
        HStack(spacing: 8) {
            ForEach(Array(trip.legs.filter(\.isTransit).enumerated()), id: \.element.id) { index, leg in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.5))
                }
                if let routeId = leg.routeId {
                    HStack(spacing: 7) {
                        RouteBadge(
                            routeID: routeId,
                            size: .medium,
                            mode: modeString(leg.mode)
                        )
                        if let headsign = leg.headsign {
                            Text(headsign)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private func nextActionCard(_ nextAction: TripNextAction) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: actionIcon(for: nextAction.status))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(nextAction.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(nextAction.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Text(relativeDueString(nextAction.dueInSeconds))
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(AppTheme.Colors.accent.opacity(0.1))
                )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(AppTheme.Colors.accent.opacity(0.15), lineWidth: 0.8)
                )
        )
    }

    @ViewBuilder
    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live Alerts")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .textCase(.uppercase)
                .tracking(1.0)

            ForEach(trip.serviceAlerts.prefix(3)) { alert in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.warningYellow)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(alert.title)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        Text(alert.description)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .lineLimit(3)
                    }

                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(AppTheme.Colors.warningYellow.opacity(0.14), lineWidth: 0.8)
                        )
                )
            }
        }
    }

    // MARK: - Fare Estimate

    private var fareEstimate: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.1))
                    .frame(width: 42, height: 42)
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Estimated Fare")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                if let fare = trip.fare {
                    Text(fare.description.isEmpty ? fare.formattedTotal : fare.description)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                } else {
                    Text("$2.90 with OMNY")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.2), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Environmental Impact

    @ViewBuilder
    private var environmentalImpactView: some View {
        if let impact = trip.environmentalImpact, (impact.co2SavedGrams > 0 || impact.caloriesBurned > 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.1))
                        .frame(width: 42, height: 42)
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.green)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Environmental Impact")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    HStack(spacing: 12) {
                        if impact.co2SavedGrams > 0 {
                            Label(impact.formattedCO2, systemImage: "cloud.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.Colors.textTertiary)
                        }
                        if impact.caloriesBurned > 0 {
                            Label(impact.formattedCalories, systemImage: "flame.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.2), lineWidth: 0.5)
                    )
            )
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            // Save trip — primary
            Button {
                // TODO: Save this trip
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Save Trip")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .shadow(color: AppTheme.Colors.accent.opacity(0.3), radius: 10, y: 4)
                )
            }
            .buttonStyle(.plain)

            // Secondary actions
            HStack(spacing: 10) {
                Button {
                    // TODO: Set departure alarm
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Set Alarm")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(AppTheme.Colors.accent.opacity(0.08))
                            .overlay(
                                Capsule()
                                    .strokeBorder(AppTheme.Colors.accent.opacity(0.2), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)

                Button {
                    // TODO: Share trip
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .bold))
                        Text("Share")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(AppTheme.Colors.cardInset)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    private var walkDistanceString: String {
        if trip.totalWalkMeters > 1609 {
            return String(format: "%.1f mi", trip.totalWalkMeters / 1609.34)
        }
        return "\(Int(trip.totalWalkMeters))m"
    }

    private func modeString(_ mode: TripLegMode) -> String? {
        switch mode {
        case .bus:  return "bus"
        case .lirr: return "lirr"
        case .mnr:  return "mnr"
        default:    return nil
        }
    }

    private func actionIcon(for status: String) -> String {
        switch status {
        case "walking":
            return "figure.walk"
        case "waiting":
            return "clock.fill"
        case "riding":
            return "tram.fill"
        case "arrived":
            return "flag.checkered"
        default:
            return "arrow.right.circle.fill"
        }
    }

    private func relativeDueString(_ dueInSeconds: Int) -> String {
        if dueInSeconds <= 0 {
            return "Now"
        }
        let minutes = max(1, Int(round(Double(dueInSeconds) / 60.0)))
        return "in \(minutes)m"
    }
}

#Preview {
    TripDetailSheet(
        trip: TripPlan(
            departureTime: Date(),
            arrivalTime: Date().addingTimeInterval(3660),
            totalDurationMinutes: 61,
            legs: [
                TripLeg(
                    mode: .bus, routeId: "Q9", routeName: "Q9",
                    routeColor: "#D42781", headsign: "Springfield Blvd",
                    boardStopName: "125th St / Jamaica Ave",
                    alightStopName: "Hillside Ave",
                    departureTime: Date(),
                    arrivalTime: Date().addingTimeInterval(1200),
                    numStops: 8, durationMinutes: 20
                ),
                TripLeg(
                    mode: .walk, routeId: nil, routeName: nil,
                    routeColor: nil, headsign: nil,
                    boardStopName: "Hillside Ave",
                    alightStopName: "Parsons Blvd Station",
                    departureTime: Date().addingTimeInterval(1200),
                    arrivalTime: Date().addingTimeInterval(1380),
                    numStops: 0, durationMinutes: 3
                ),
                TripLeg(
                    mode: .subway, routeId: "E", routeName: "E Train",
                    routeColor: "#EB6800", headsign: "World Trade Center",
                    boardStopName: "Parsons Blvd",
                    alightStopName: "34 St-Penn Station",
                    departureTime: Date().addingTimeInterval(1500),
                    arrivalTime: Date().addingTimeInterval(3360),
                    numStops: 12, durationMinutes: 31
                ),
            ],
            totalWalkMeters: 400,
            numTransfers: 1
        )
    )
    .preferredColorScheme(.dark)
}
