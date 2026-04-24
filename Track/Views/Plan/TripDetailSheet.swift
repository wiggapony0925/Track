// Premium trip detail page — immersive interactive MapLibre map hero
// with route polylines, glass stat cards, rich timeline, and polished
// action buttons.  Presented as a full-screen cover.

import SwiftUI

struct TripDetailSheet: View {
    let trip: TripPlan

    @Environment(\.dismiss) private var dismiss
    @Environment(GoTripSession.self) private var goSession
    @State private var heroVisible = false
    @State private var statsVisible = false
    @State private var bodyVisible = false
    @State private var showShareSheet = false

    var body: some View {
        ZStack(alignment: .top) {
            // Background
            AppTheme.Colors.background
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Map hero with overlaid summary card
                    mapHero
                        .opacity(heroVisible ? 1 : 0)
                        .scaleEffect(heroVisible ? 1 : 0.99)

                    // Stats row (overlapping hero)
                    statsRow
                        .padding(.top, -24)
                        .padding(.horizontal, 16)

                    // Route summary
                    routeSummary
                        .padding(.top, 20)
                        .padding(.horizontal, 16)
                        .opacity(bodyVisible ? 1 : 0)
                        .offset(y: bodyVisible ? 0 : 12)

                    if let nextAction = trip.nextAction {
                        nextActionCard(nextAction)
                            .padding(.top, 18)
                            .padding(.horizontal, 16)
                            .opacity(bodyVisible ? 1 : 0)
                            .offset(y: bodyVisible ? 0 : 12)
                    }

                    // Divider
                    RoundedRectangle(cornerRadius: 1)
                        .fill(AppTheme.Colors.borderSubtle.opacity(0.2))
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                        .opacity(bodyVisible ? 1 : 0)

                    if !trip.serviceAlerts.isEmpty {
                        alertsSection
                            .padding(.top, 18)
                            .padding(.horizontal, 16)
                            .opacity(bodyVisible ? 1 : 0)
                            .offset(y: bodyVisible ? 0 : 12)
                    }

                    // Full timeline
                    TripTimelineView(trip: trip)
                        .padding(.horizontal, 16)
                        .padding(.top, trip.serviceAlerts.isEmpty ? 16 : 20)
                        .opacity(bodyVisible ? 1 : 0)
                        .offset(y: bodyVisible ? 0 : 12)

                    // Fare estimate
                    fareEstimate
                        .padding(.top, 20)
                        .padding(.horizontal, 16)
                        .opacity(bodyVisible ? 1 : 0)

                    // Environmental impact (CO₂ + calories)
                    environmentalImpactView
                        .padding(.top, 12)
                        .padding(.horizontal, 16)
                        .opacity(bodyVisible ? 1 : 0)

                    // Action buttons
                    actionButtons
                        .padding(.top, 24)
                        .padding(.horizontal, 16)
                        .opacity(bodyVisible ? 1 : 0)
                        .offset(y: bodyVisible ? 0 : 8)

                    Spacer(minLength: 40)
                }
            }

            // Floating close + share buttons over map
            floatingButtons
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [buildShareText()])
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                heroVisible = true
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82).delay(0.12)) {
                statsVisible = true
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.22)) {
                bodyVisible = true
            }
        }
    }

    // MARK: - Floating Buttons

    private var floatingButtons: some View {
        HStack {
            Spacer()
            VStack(spacing: 12) {
                FloatingCircleButton(icon: "xmark") { dismiss() }

                FloatingCircleButton(
                    icon: "location.fill",
                    fillColor: AppTheme.Colors.accent,
                    iconSize: 14
                ) { showShareSheet = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 54) // below status bar
    }

    // MARK: - Map Hero

    private var mapHero: some View {
        ZStack(alignment: .bottom) {
            // Live interactive route map (MapLibre GL)
            TripRouteMapView(trip: trip, isInteractive: true)
                .frame(height: 420)

            // Gradient fade into background
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: AppTheme.Colors.background.opacity(0.3), location: 0.4),
                    .init(color: AppTheme.Colors.background.opacity(0.85), location: 0.75),
                    .init(color: AppTheme.Colors.background, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 180)

            // Overlaid trip summary card
            tripSummaryCard
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Trip Summary Card

    private var tripSummaryCard: some View {
        VStack(spacing: 12) {
            // Times + duration row
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Leave at \(timeString(trip.departureTime))")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Arrive at \(timeString(trip.arrivalTime))")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Spacer()

                Text(trip.durationString)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(.top, 4)
            }

            // Mini timeline bar
            MiniTimelineBar(legs: trip.legs)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .trackGlassCard(
            cornerRadius: 20,
            borderOpacity: 0.15,
            shadowRadius: 16,
            shadowY: 8
        )
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
        .opacity(statsVisible ? 1 : 0)
        .offset(y: statsVisible ? 0 : 15)
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
        .trackGlassCard(
            cornerRadius: 16,
            borderOpacity: 0.25,
            shadowRadius: 10,
            shadowY: 5
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
        IconInfoRow(
            icon: actionIcon(for: nextAction.status),
            circleOpacity: 0.14,
            title: nextAction.title,
            titleSize: 15,
            subtitle: nextAction.subtitle,
            subtitleColor: AppTheme.Colors.textSecondary
        ) {
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
        .trackTintedCard(cornerRadius: 18)
    }

    @ViewBuilder
    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Live Alerts", tracking: 1.0)

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
                .trackTintedCard(
                    cornerRadius: 16,
                    tint: AppTheme.Colors.warningYellow,
                    borderOpacity: 0.14
                )
            }
        }
    }

    // MARK: - Fare Estimate

    private var fareEstimate: some View {
        IconInfoRow(
            icon: "creditcard.fill",
            title: "Estimated Fare",
            subtitle: fareSubtitle
        )
        .padding(14)
        .trackGlassCard(cornerRadius: 14, hasHighlight: false)
    }

    private var fareSubtitle: String {
        if let fare = trip.fare {
            return fare.description.isEmpty ? fare.formattedTotal : fare.description
        }
        return "$2.90 with OMNY"
    }

    // MARK: - Environmental Impact

    @ViewBuilder
    private var environmentalImpactView: some View {
        if let impact = trip.environmentalImpact, (impact.co2SavedGrams > 0 || impact.caloriesBurned > 0) {
            IconInfoRow(
                icon: "leaf.fill",
                iconColor: .green,
                title: "Environmental Impact",
                subtitleView: AnyView(
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
                )
            )
            .padding(14)
            .trackGlassCard(cornerRadius: 14, hasHighlight: false)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            // GO — primary, immersive navigation takeover
            Button {
                // Activate the Go session first so the parent's
                // fullScreenCover (driven by `goSession.activeTrip`)
                // schedules a presentation, then dismiss this sheet.
                // SwiftUI handles the swap cleanly without a manual
                // delay — the previous asyncAfter approach would
                // sometimes drop the GO tap if the sheet's dismissal
                // animation interrupted the start call.
                goSession.start(trip)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 16, weight: .heavy))
                    Text("GO")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .tracking(1.0)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppTheme.Colors.goGreen,
                                    AppTheme.Colors.goGreen.opacity(0.85),
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .shadow(
                            color: AppTheme.Colors.goGreen.opacity(0.45), radius: 14, y: 6)
                )
            }
            .buttonStyle(.plain)

            // Secondary actions
            HStack(spacing: 10) {
                Button {
                    // TODO: Save this trip
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Save")
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
                                    .strokeBorder(
                                        AppTheme.Colors.accent.opacity(0.2), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showShareSheet = true
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private func timeString(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
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

    // MARK: - Share Builder

    private static let shareDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    private func buildShareText() -> String {
        let dateLine = Self.shareDateFormatter.string(from: trip.departureTime)
        let originName = trip.legs.first?.boardStopName ?? "Origin"
        let destName = trip.legs.last?.alightStopName ?? "Destination"

        var lines: [String] = []

        // Header
        lines.append("🚇 Trip Plan — \(dateLine)")
        lines.append("\(originName) → \(destName)")
        lines.append("")

        // Quick stats
        let transferLabel = trip.numTransfers == 0
            ? "Direct"
            : "\(trip.numTransfers) transfer\(trip.numTransfers > 1 ? "s" : "")"
        lines.append("🕐 Depart \(timeString(trip.departureTime)) · Arrive \(timeString(trip.arrivalTime))")
        lines.append("⏱ \(trip.durationString) · \(transferLabel) · Walk \(walkDistanceString)")
        lines.append("")

        // Step-by-step legs
        lines.append("Route:")
        for (i, leg) in trip.legs.enumerated() {
            let stepNum = i + 1
            switch leg.mode {
            case .walk:
                let mins = leg.durationMinutes
                lines.append("  \(stepNum). 🚶 Walk \(mins) min — \(leg.boardStopName) → \(leg.alightStopName)")
            case .transfer:
                lines.append("  \(stepNum). 🔄 Transfer at \(leg.boardStopName)")
            default:
                let emoji = leg.mode == .bus ? "🚌" : leg.mode == .lirr || leg.mode == .mnr ? "🚆" : "🚇"
                let route = leg.routeId ?? leg.routeName ?? "Transit"
                let headsignPart = leg.headsign.map { " → \($0)" } ?? ""
                lines.append("  \(stepNum). \(emoji) \(route)\(headsignPart)")
                lines.append("       Board \(leg.boardStopName) at \(timeString(leg.departureTime))")
                lines.append("       Exit  \(leg.alightStopName) at \(timeString(leg.arrivalTime))")
                if leg.numStops > 0 {
                    lines.append("       \(leg.numStops) stop\(leg.numStops > 1 ? "s" : ""), \(leg.durationMinutes) min")
                }
            }
        }

        // Fare
        if let fare = trip.fare {
            lines.append("")
            if !fare.description.isEmpty {
                lines.append("💳 \(fare.description)")
            } else {
                lines.append("💳 Est. fare: \(fare.formattedTotal)")
            }
        }

        // Environmental impact
        if let impact = trip.environmentalImpact {
            var parts: [String] = []
            if impact.co2SavedGrams > 0 { parts.append(impact.formattedCO2 + " saved") }
            if impact.caloriesBurned > 0 { parts.append(impact.formattedCalories) }
            if !parts.isEmpty {
                lines.append("🌿 \(parts.joined(separator: " · "))")
            }
        }

        // Service alerts
        if !trip.serviceAlerts.isEmpty {
            lines.append("")
            lines.append("⚠️ Alerts:")
            for alert in trip.serviceAlerts.prefix(3) {
                lines.append("  • \(alert.title)")
            }
        }

        lines.append("")
        lines.append("Shared from Track")

        return lines.joined(separator: "\n")
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
    .environment(GoTripSession())
    .preferredColorScheme(.dark)
}
