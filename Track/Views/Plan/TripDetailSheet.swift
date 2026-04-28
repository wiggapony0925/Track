// Premium trip detail page — immersive interactive MapLibre map hero
// with route polylines, glass stat cards, rich timeline, and polished
// action buttons.  Presented as a full-screen cover.

import CoreLocation
import EventKit
import MapKit
import SwiftUI

struct TripDetailSheet: View {
    let trip: TripPlan
    var originCoordinate: CLLocationCoordinate2D?
    var destinationCoordinate: CLLocationCoordinate2D?

    @Environment(\.dismiss) private var dismiss
    @Environment(GoTripSession.self) private var goSession
    @State private var heroVisible = false
    @State private var statsVisible = false
    @State private var bodyVisible = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var calendarDraft: CalendarEventDraft?
    @State private var calendarError: String?
    @State private var calendarEventStore = EKEventStore()
    @State private var sheetDetent: TrackSheetDetent = .height(300)
    @State private var sheetDragStartHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                AppTheme.Colors.background
                    .ignoresSafeArea()

                mapBackdrop

                tripDetailBottomSheet(in: proxy)

                // Floating close + share buttons over map
                floatingButtons(topInset: proxy.safeAreaInsets.top)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems.isEmpty ? [buildShareText()] : shareItems)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $calendarDraft) { draft in
            CalendarEventEditor(eventStore: calendarEventStore, draft: draft)
                .ignoresSafeArea()
        }
        .alert("Calendar unavailable", isPresented: calendarErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(calendarError ?? "Track could not open Calendar.")
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

    private func floatingButtons(topInset: CGFloat) -> some View {
        HStack {
            Spacer()

            FloatingCircleButton(icon: "xmark") { dismiss() }
        }
        .padding(.horizontal, 18)
        .padding(.top, max(2, topInset + 2))
    }

    // MARK: - Map + Bottom Sheet

    private var mapBackdrop: some View {
        ZStack(alignment: .bottom) {
            TripRouteMapView(
                trip: mapTrip,
                isInteractive: true,
                originOverride: originCoordinate,
                destinationOverride: destinationCoordinate
            )
                .ignoresSafeArea()
                .opacity(heroVisible ? 1 : 0)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: AppTheme.Colors.background.opacity(0.08), location: 0.42),
                    .init(color: AppTheme.Colors.background.opacity(0.55), location: 0.78),
                    .init(color: AppTheme.Colors.background.opacity(0.94), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var mapTrip: TripPlan {
        trip.withMapEndpoints(origin: originCoordinate, destination: destinationCoordinate)
    }

    private func tripDetailBottomSheet(in proxy: GeometryProxy) -> some View {
        TrackBottomSheet(
            selection: $sheetDetent,
            detents: tripSheetDetents,
            cornerRadius: 28,
            topInset: proxy.safeAreaInsets.top + 108,
            background: AnyView(AppTheme.Colors.background.opacity(0.96))
        ) {
            VStack(spacing: 0) {
                sheetHandle
                    .gesture(sheetDragGesture(in: proxy))

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        tripSummaryCard
                            .opacity(bodyVisible ? 1 : 0)
                            .offset(y: bodyVisible ? 0 : 10)
                            .contentShape(Rectangle())
                            .gesture(sheetDragGesture(in: proxy))

                        actionButtons
                            .opacity(bodyVisible ? 1 : 0)
                            .offset(y: bodyVisible ? 0 : 8)

                        statsRow
                            .opacity(statsVisible ? 1 : 0)

                        routeSummary
                            .padding(.top, 4)
                            .opacity(bodyVisible ? 1 : 0)

                        if let nextAction = trip.nextAction {
                            nextActionCard(nextAction)
                                .opacity(bodyVisible ? 1 : 0)
                                .offset(y: bodyVisible ? 0 : 12)
                        }

                        if !trip.serviceAlerts.isEmpty {
                            alertsSection
                                .padding(.top, 4)
                                .opacity(bodyVisible ? 1 : 0)
                                .offset(y: bodyVisible ? 0 : 12)
                        }

                        TripTimelineView(trip: trip)
                            .padding(.top, trip.serviceAlerts.isEmpty ? 8 : 12)
                            .opacity(bodyVisible ? 1 : 0)
                            .offset(y: bodyVisible ? 0 : 12)

                        arrivalDestinationSection
                            .padding(.top, 8)
                            .opacity(bodyVisible ? 1 : 0)
                            .offset(y: bodyVisible ? 0 : 12)

                        fareEstimate
                            .padding(.top, 8)
                            .opacity(bodyVisible ? 1 : 0)

                        environmentalImpactView
                            .opacity(bodyVisible ? 1 : 0)

                        Spacer(minLength: proxy.safeAreaInsets.bottom + 36)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var tripSheetDetents: [TrackSheetDetent] {
        [.height(260), .height(360), .fraction(0.62), .large]
    }

    private var sheetHandle: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(AppTheme.Colors.textTertiary.opacity(0.35))
                .frame(width: 42, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func sheetDragGesture(in proxy: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let topInset = proxy.safeAreaInsets.top + 108
                let available = proxy.size.height
                if sheetDragStartHeight == 0 {
                    sheetDragStartHeight = sheetDetent.resolve(in: available, topInset: topInset)
                }
                let maxHeight = TrackSheetDetent.large.resolve(in: available, topInset: topInset)
                let minHeight = TrackSheetDetent.height(240).resolve(in: available, topInset: topInset)
                let proposed = sheetDragStartHeight - value.translation.height
                sheetDetent = .height(min(max(proposed, minHeight), maxHeight))
            }
            .onEnded { value in
                let topInset = proxy.safeAreaInsets.top + 108
                let available = proxy.size.height
                let maxHeight = TrackSheetDetent.large.resolve(in: available, topInset: topInset)
                let minHeight = TrackSheetDetent.height(260).resolve(in: available, topInset: topInset)
                let proposed = sheetDragStartHeight - value.predictedEndTranslation.height
                sheetDragStartHeight = 0

                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    if proposed > maxHeight * 0.84 {
                        sheetDetent = .large
                    } else if proposed < minHeight + 55 {
                        sheetDetent = .height(260)
                    } else {
                        sheetDetent = .height(min(max(proposed, minHeight), maxHeight))
                    }
                }
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

    // MARK: - Arrival Destination

    private var arrivalDestinationSection: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(AppTheme.Colors.borderSubtle.opacity(0.55))
                    .frame(width: 2, height: 22)
                Circle()
                    .fill(Color.red)
                    .frame(width: 22, height: 22)
                    .shadow(color: Color.red.opacity(0.28), radius: 8, y: 3)
                Rectangle()
                    .fill(AppTheme.Colors.borderSubtle.opacity(0.55))
                    .frame(width: 2, height: destinationCoordinate == nil ? 18 : 154)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Destination")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textTertiary)

                    Text(destinationName)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }

                if let destinationCoordinate {
                    TripLookAroundCardView(coordinate: destinationCoordinate)
                        .frame(height: 172)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                        )
                        .shadow(color: AppTheme.Colors.shadow.opacity(0.18), radius: 12, y: 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(AppTheme.Colors.cardElevated.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.16), lineWidth: 1)
        )
    }

    private var destinationName: String {
        trip.legs.last?.alightStopName ?? "Destination"
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
        if let fare = trip.fare ?? TripFareEstimate.localEstimate(for: trip) {
            return fare.description.isEmpty ? fare.formattedTotal : fare.description
        }
        return "Fare unavailable"
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
                goSession.start(mapTrip)
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
                    shareItems = [destinationShareText]
                    showShareSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 13, weight: .bold))
                        Text("Destination")
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

                Button {
                    shareItems = [buildShareText()]
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

            Button {
                addToCalendar()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 14, weight: .bold))
                    Text("Add to Calendar")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(AppTheme.Colors.accent.opacity(0.1))
                        .overlay(
                            Capsule()
                                .strokeBorder(AppTheme.Colors.accent.opacity(0.18), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
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

    private var destinationShareText: String {
        let dest = destinationName
        if let destinationCoordinate {
            return "\(dest)\nhttps://maps.apple.com/?ll=\(destinationCoordinate.latitude),\(destinationCoordinate.longitude)&q=\(dest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dest)"
        }
        return dest
    }

    private var calendarErrorBinding: Binding<Bool> {
        Binding(
            get: { calendarError != nil },
            set: { if !$0 { calendarError = nil } }
        )
    }

    private func addToCalendar() {
        Task { @MainActor in
            guard await CalendarEventAccess.request(for: calendarEventStore) else {
                calendarError = "Allow calendar access in Settings to add this trip."
                return
            }
            calendarDraft = CalendarEventDraft(
                title: "Trip to \(destinationName)",
                location: destinationName,
                notes: buildShareText(),
                startDate: trip.departureTime,
                endDate: trip.arrivalTime
            )
        }
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
        if let fare = trip.fare ?? TripFareEstimate.localEstimate(for: trip) {
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

private struct TripLookAroundCardView: View {
    let coordinate: CLLocationCoordinate2D
    @State private var scene: MKLookAroundScene?

    var body: some View {
        Group {
            if let scene {
                LookAroundPreview(initialScene: scene)
                    .overlay(alignment: .topLeading) {
                        Label("Look Around", systemImage: "binoculars.fill")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.black.opacity(0.58))
                            )
                            .padding(12)
                    }
            } else {
                TripDestinationMiniMap(coordinate: coordinate)
                    .overlay(alignment: .topLeading) {
                        Label("Map Preview", systemImage: "map.fill")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.black.opacity(0.52))
                            )
                            .padding(12)
                    }
            }
        }
        .task(id: "\(coordinate.latitude),\(coordinate.longitude)") {
            await loadScene()
        }
    }

    private func loadScene() async {
        let request = MKLookAroundSceneRequest(coordinate: coordinate)
        do {
            let nextScene = try await request.scene
            await MainActor.run { scene = nextScene }
        } catch {
            await MainActor.run { scene = nil }
        }
    }
}

private struct TripDestinationMiniMap: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.isUserInteractionEnabled = false
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.pointOfInterestFilter = .excludingAll
        if #available(iOS 16.0, *) {
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
            configuration.pointOfInterestFilter = .excludingAll
            mapView.preferredConfiguration = configuration
        } else {
            mapView.mapType = .mutedStandard
        }
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.removeAnnotations(mapView.annotations)
        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        mapView.addAnnotation(annotation)
        mapView.setRegion(
            MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 520,
                longitudinalMeters: 520
            ),
            animated: false
        )
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
