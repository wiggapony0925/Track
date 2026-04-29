// Immersive "Go" navigation view — presented as a full-screen cover
// from MainTabView when GoTripSession.activeTrip is non-nil.  Mirrors
// the polished navigation experience of best-in-class transit apps:
// a sticky map + progress header, expandable leg cards (walk steps,
// transit boarding card with next departures, destination address +
// Look Around preview), pinned action buttons, and a live arrival
// bar at the bottom.  While active the user cannot switch tabs; they
// must explicitly exit via the close button.

import CoreLocation
import EventKit
import MapKit
import SwiftUI

// MARK: - GoTripView

struct GoTripView: View {
    let trip: TripPlan
    @Environment(GoTripSession.self) private var session

    @State private var heroVisible = false
    @State private var bodyVisible = false
    @State private var showShareSheet = false
    @State private var showExitConfirmation = false
    @State private var shareItems: [Any] = []
    @State private var calendarDraft: CalendarEventDraft?
    @State private var calendarError: String?
    @State private var calendarEventStore = EKEventStore()
    @State private var expandedLegIDs: Set<UUID> = []
    @State private var sheetDetent: TrackSheetDetent = .fraction(0.5)
    @State private var sheetDragStartHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                AppTheme.Colors.background.ignoresSafeArea()

                mapBackdrop

                bottomTripSheet(in: proxy)

                // Floating top controls layered above the map
                floatingTopControls(topInset: proxy.safeAreaInsets.top)

                if showExitConfirmation {
                    GoExitConfirmationOverlay(
                        keepTracking: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                showExitConfirmation = false
                            }
                        },
                        exitTrip: {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                                showExitConfirmation = false
                            }
                            session.stop()
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(20)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: showExitConfirmation)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems.isEmpty ? [shareText] : shareItems)
                .presentationDetents([.medium])
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
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                heroVisible = true
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(0.15)) {
                bodyVisible = true
            }
            // Auto-expand the current transit leg so user immediately sees details
            if let firstTransit = trip.legs.first(where: { $0.isTransit }) {
                expandedLegIDs.insert(firstTransit.id)
            }
            session.refreshGuidance()
        }
        .task(id: trip.id) {
            while !Task.isCancelled {
                await session.refreshLiveGuidance()
                try? await Task.sleep(nanoseconds: LiveTrackingClock.vehiclePollSleepNanoseconds)
            }
        }
    }

    // MARK: - Map + Go Status

    private var mapBackdrop: some View {
        ZStack(alignment: .bottom) {
            TripRouteMapView(trip: trip, isInteractive: true)
                .ignoresSafeArea()
                .opacity(heroVisible ? 1 : 0)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: AppTheme.Colors.background.opacity(0.08), location: 0.42),
                    .init(color: AppTheme.Colors.background.opacity(0.55), location: 0.76),
                    .init(color: AppTheme.Colors.background.opacity(0.92), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var goStatusHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrowshape.turn.up.right.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(session.guidanceStatusText)
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Spacer(minLength: 0)
            }

            GoLegProgressBar(
                legs: trip.legs,
                currentLegIndex: session.currentLegIndex
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: AppTheme.Colors.shadow.opacity(0.45), radius: 18, y: 8)
    }

    private func floatingTopControls(topInset: CGFloat) -> some View {
        HStack {
            Spacer()

            FloatingCircleButton(icon: "xmark") {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    showExitConfirmation = true
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, max(2, topInset + 2))
    }

    // MARK: - Bottom Sheet

    private static let goStatusHeaderHeight: CGFloat = 96

    private func bottomTripSheet(in proxy: GeometryProxy) -> some View {
        return TrackBottomSheet(
            selection: $sheetDetent,
            detents: goSheetDetents,
            cornerRadius: 28,
            topInset: proxy.safeAreaInsets.top + 108,
            background: AnyView(AppTheme.Colors.background.opacity(0.96))
        ) {
            VStack(spacing: 0) {
                sheetHandle
                    .gesture(sheetDragGesture(in: proxy))

                goStatusHeader
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .contentShape(Rectangle())
                    .gesture(sheetDragGesture(in: proxy))

                goKeyFacts
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .opacity(bodyVisible ? 1 : 0)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(Array(trip.legs.enumerated()), id: \.element.id) { index, leg in
                            legCard(leg, index: index)
                                .opacity(bodyVisible ? 1 : 0)
                                .offset(y: bodyVisible ? 0 : 8)
                                .animation(
                                    .spring(response: 0.45, dampingFraction: 0.85)
                                        .delay(Double(index) * 0.04),
                                    value: bodyVisible)
                        }

                        destinationCard
                            .opacity(bodyVisible ? 1 : 0)
                            .offset(y: bodyVisible ? 0 : 8)

                        actionButtons
                            .padding(.top, 6)
                            .opacity(bodyVisible ? 1 : 0)

                        Spacer(minLength: proxy.safeAreaInsets.bottom + 28)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var goSheetDetents: [TrackSheetDetent] {
        [.height(260), .fraction(0.5), .fraction(0.62), .large]
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

    // MARK: - Leg Cards

    @ViewBuilder
    private func legCard(_ leg: TripLeg, index: Int) -> some View {
        switch leg.mode {
        case .walk, .transfer:
            GoWalkLegCard(leg: leg, isFirst: index == 0)
        default:
            GoTransitLegCard(
                leg: leg,
                expanded: expandedLegIDs.contains(leg.id),
                toggleExpanded: { toggle(leg.id) }
            )
        }
    }

    private func toggle(_ id: UUID) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            if expandedLegIDs.contains(id) {
                expandedLegIDs.remove(id)
            } else {
                expandedLegIDs.insert(id)
            }
        }
    }

    // MARK: - Destination Card

    private var destinationCard: some View {
        let destName = trip.legs.last?.alightStopName ?? "Destination"
        let destCoord = destinationCoordinate

        return VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(AppTheme.Colors.alertRed)
                    .frame(width: 14, height: 14)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Destination")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                    Text(destName)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                Spacer()
            }

            if let coord = destCoord {
                LookAroundCardView(coordinate: coord)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(14)
        .trackGlassCard(cornerRadius: 18, borderOpacity: 0.15, shadowRadius: 10, shadowY: 4)
    }

    private var destinationCoordinate: CLLocationCoordinate2D? {
        trip.mapDestinationCoordinate
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            actionRow(icon: "mappin.circle.fill", title: "Change destination stop") {
                // Reserved for future: present a stop picker
            }
            actionRow(icon: "square.and.arrow.up", title: "Share ETA") {
                shareItems = [shareText]
                showShareSheet = true
            }
            actionRow(icon: "mappin.and.ellipse", title: "Share destination") {
                shareItems = [destinationShareText]
                showShareSheet = true
            }
            actionRow(icon: "calendar.badge.plus", title: "Add to calendar") {
                addToCalendar()
            }
            actionRow(icon: "exclamationmark.bubble.fill", title: "Report issue") {
                // Reserved for future
            }
        }
    }

    private func actionRow(
        icon: String, title: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.accent)
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.accent)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                Capsule()
                    .fill(AppTheme.Colors.accent.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }


    private var goKeyFacts: some View {
        HStack(spacing: 10) {
            goFactCard(
                icon: "flag.checkered",
                label: "ARRIVE",
                value: timeString(session.liveArrivalTime ?? trip.arrivalTime),
                color: AppTheme.Colors.successGreen
            )
            goFactCard(
                icon: "creditcard.fill",
                label: "FARE",
                value: fareTotalText,
                color: AppTheme.Colors.accent
            )
            goFactCard(
                icon: "timer",
                label: "TRIP",
                value: trip.durationString,
                color: AppTheme.Colors.warningYellow
            )
        }
    }

    private func goFactCard(
        icon: String,
        label: String,
        value: String,
        color: Color
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.Colors.cardElevated.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private var fareTotalText: String {
        (trip.fare ?? TripFareEstimate.localEstimate(for: trip))?.formattedTotal ?? "--"
    }

    private var goInTitle: String {
        let now = Date()
        let secs = trip.departureTime.timeIntervalSince(now)
        if secs <= 60 { return "Go now" }
        let mins = Int(round(secs / 60))
        return "Go in \(mins) min"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
    private func timeString(_ d: Date) -> String { Self.timeFormatter.string(from: d) }

    private var shareText: String {
        let dest = trip.legs.last?.alightStopName ?? "Destination"
        return "I'm on my way! ETA \(timeString(trip.arrivalTime)) (\(trip.durationString)) → \(dest). Tracked with Track."
    }

    private var destinationShareText: String {
        let dest = trip.legs.last?.alightStopName ?? "Destination"
        if let coordinate = trip.mapDestinationCoordinate {
            return "\(dest)\nhttps://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)&q=\(dest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dest)"
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
            let destination = trip.legs.last?.alightStopName ?? "Destination"
            calendarDraft = CalendarEventDraft(
                title: "Trip to \(destination)",
                location: destination,
                notes: shareText,
                startDate: trip.departureTime,
                endDate: trip.arrivalTime
            )
        }
    }
}

private struct GoExitConfirmationOverlay: View {
    let keepTracking: () -> Void
    let exitTrip: () -> Void

    var body: some View {
        ZStack {
            AppTheme.Colors.background.opacity(0.48)
                .ignoresSafeArea()
                .onTapGesture(perform: keepTracking)

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.warningYellow.opacity(0.14))
                        .frame(width: 48, height: 48)

                    Image(systemName: "location.slash.fill")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(AppTheme.Colors.warningYellow)
                }

                VStack(spacing: 8) {
                    Text("Exit this trip?")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Live guidance, widgets, and arrival alerts will stop.")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    Button(action: keepTracking) {
                        Text("Keep Tracking")
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(AppTheme.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: exitTrip) {
                        Text("Exit Trip")
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(AppTheme.Colors.alertRed)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
            .frame(maxWidth: 336)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(AppTheme.Colors.cardElevated.opacity(0.98))
                    .shadow(color: AppTheme.Colors.shadow.opacity(0.34), radius: 28, y: 16)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(AppTheme.Colors.borderSubtle.opacity(0.9), lineWidth: 1)
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Multi-segment Progress Bar

private struct GoLegProgressBar: View {
    let legs: [TripLeg]
    let currentLegIndex: Int

    var body: some View {
        GeometryReader { geo in
            let totalDuration = max(1, legs.map(\.durationMinutes).reduce(0, +))
            let minimumLegWidth: CGFloat = 58
            let contentWidth = max(
                geo.size.width,
                CGFloat(legs.count) * minimumLegWidth + CGFloat(max(0, legs.count - 1)) * 4
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                        let fraction = CGFloat(leg.durationMinutes) / CGFloat(totalDuration)
                        let width = max(minimumLegWidth, fraction * contentWidth - 4)
                        segment(for: leg, index: index, width: width)
                    }
                }
                .frame(minWidth: geo.size.width, alignment: .leading)
            }
        }
        .frame(height: 36)
    }

    @ViewBuilder
    private func segment(for leg: TripLeg, index: Int, width: CGFloat) -> some View {
        let isCurrent = index == currentLegIndex
        let isPassed = index < currentLegIndex
        let color = legColor(leg)
        let icon = legIcon(leg)
        let label = legLabel(leg)

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isPassed ? AppTheme.Colors.cardInset : color.opacity(isCurrent ? 1 : 0.85))
                .frame(width: width, height: 30)
                .overlay(alignment: .center) {
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(textColor(leg, passed: isPassed))
                        if let label, width > 80 {
                            Text(label)
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .foregroundStyle(textColor(leg, passed: isPassed))
                                .lineLimit(1)
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isCurrent ? color : .clear, lineWidth: 2)
                )

            if isCurrent {
                Circle()
                    .fill(AppTheme.Colors.accent)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .offset(x: -6, y: 18)
            }
        }
    }

    private func legColor(_ leg: TripLeg) -> Color {
        if leg.mode == .walk || leg.mode == .transfer {
            return AppTheme.Colors.cardInset
        }
        if let hex = leg.routeColor, !hex.isEmpty {
            return Color(hex: hex)
        }
        return AppTheme.Colors.accent
    }

    private func legIcon(_ leg: TripLeg) -> String {
        switch leg.mode {
        case .walk, .transfer: return "figure.walk"
        case .bus: return "bus.fill"
        case .subway: return "tram.fill"
        case .lirr, .mnr: return "train.side.front.car"
        }
    }

    private func legLabel(_ leg: TripLeg) -> String? {
        if leg.mode == .walk || leg.mode == .transfer { return nil }
        return leg.routeId ?? leg.routeName
    }

    private func textColor(_ leg: TripLeg, passed: Bool) -> Color {
        if passed { return AppTheme.Colors.textTertiary }
        if leg.mode == .walk || leg.mode == .transfer {
            return AppTheme.Colors.textPrimary
        }
        if let hex = leg.textColorHex, !hex.isEmpty { return Color(hex: hex) }
        return .white
    }
}

// MARK: - Walk Leg Card

private struct GoWalkLegCard: View {
    let leg: TripLeg
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(AppTheme.Colors.textPrimary)
                    .frame(width: 10, height: 10)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Walk to")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        Text("🚌")
                            .font(.system(size: 17))
                        Text(leg.alightStopName)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(2)
                    }
                    Text("\(leg.durationMinutes) min")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Spacer()

                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.Colors.cardInset)
                    )
            }

            // Generic walk hints (real turn-by-turn requires MKRoute fetch).
            VStack(spacing: 0) {
                walkStep(icon: "arrow.up", text: "Start walking")
                Divider().background(AppTheme.Colors.borderSubtle.opacity(0.4))
                walkStep(
                    icon: "arrow.up",
                    text: "Continue toward \(leg.alightStopName)")
                Divider().background(AppTheme.Colors.borderSubtle.opacity(0.4))
                walkStep(icon: "arrow.up.right", text: "Arrive at boarding stop")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.Colors.cardInset.opacity(0.6))
        )
    }

    private func walkStep(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppTheme.Colors.cardElevated)
                )
            Text(text)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Spacer()
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Transit Leg Card

private struct GoTransitLegCard: View {
    let leg: TripLeg
    let expanded: Bool
    let toggleExpanded: () -> Void

    @State private var routeStops: [BusStop] = []
    @State private var liveDepartures: [GoLiveDeparture] = []
    @State private var didLoadRouteDetails = false

    private var routeColor: Color {
        if let hex = leg.routeColor, !hex.isEmpty { return Color(hex: hex) }
        return AppTheme.Colors.accent
    }

    private var modeIcon: String {
        switch leg.mode {
        case .bus: return "bus.fill"
        case .subway: return "tram.fill"
        case .lirr, .mnr: return "train.side.front.car"
        default: return "arrow.right.circle.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title row
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: modeIcon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(.top, 2)

                if let routeId = leg.routeId {
                    RouteBadge(
                        routeID: routeId,
                        size: .medium,
                        mode: modeString
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    boardingTitle
                }
                Spacer()
            }
            .padding(16)

            // Stops timeline (board + departures + alight)
            HStack(alignment: .top, spacing: 12) {
                // Vertical colored line with end caps
                VStack(spacing: 0) {
                    Circle()
                        .strokeBorder(.white, lineWidth: 3)
                        .background(Circle().fill(routeColor))
                        .frame(width: 14, height: 14)
                    Rectangle()
                        .fill(routeColor)
                        .frame(width: 6)
                        .frame(maxHeight: .infinity)
                    Circle()
                        .strokeBorder(.white, lineWidth: 3)
                        .background(Circle().fill(routeColor))
                        .frame(width: 14, height: 14)
                }
                .frame(width: 14)
                .padding(.leading, 6)

                VStack(alignment: .leading, spacing: 0) {
                    // Boarding row
                    boardingRow

                    // Next departures
                    nextDeparturesSection
                        .padding(.top, 10)

                    // Stay on for N stops (collapsible)
                    stayOnRow
                        .padding(.top, 14)

                    if expanded {
                        intermediateStopsList
                            .padding(.top, 4)
                    }

                    // Alight row
                    alightRow
                        .padding(.top, 14)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.Colors.cardElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: AppTheme.Colors.shadow.opacity(0.6), radius: 12, y: 4)
        .task(id: leg.id) {
            await loadRouteDetails()
        }
    }

    private var modeString: String? {
        switch leg.mode {
        case .bus: return "bus"
        case .lirr: return "lirr"
        case .mnr: return "mnr"
        default: return nil
        }
    }

    private var boardingTitle: some View {
        let modeLabel: String = {
            switch leg.mode {
            case .bus: return "bus"
            case .subway: return "train"
            case .lirr, .mnr: return "train"
            default: return "vehicle"
            }
        }()
        let routeText = leg.routeId ?? leg.routeName ?? ""
        let dest = leg.headsign ?? leg.alightStopName
        var attributed = AttributedString("Board the \(routeText) \(modeLabel) for \(dest)")
        attributed.foregroundColor = AppTheme.Colors.textPrimary
        if let range = attributed.range(of: routeText), !routeText.isEmpty {
            attributed[range].font = .system(size: 15, weight: .heavy, design: .rounded)
        }
        if let range = attributed.range(of: dest) {
            attributed[range].font = .system(size: 15, weight: .heavy, design: .rounded)
        }
        return Text(attributed)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .lineLimit(3)
    }

    private var boardingRow: some View {
        HStack {
            Text(leg.boardStopName)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .lineLimit(2)
            Spacer()
            Text(timeString(leg.departureTime))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    private var nextDeparturesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next departures")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textTertiary)

            ForEach(displayDepartures) { departure in
                departureRow(departure)
            }
        }
    }

    private var displayDepartures: [GoLiveDeparture] {
        if !liveDepartures.isEmpty { return liveDepartures }
        return [GoLiveDeparture(
            routeId: leg.routeId ?? "",
            headsign: leg.headsign ?? leg.alightStopName,
            date: resolvedDepartureTime,
            isLive: leg.liveStatus?.isRealtime == true,
            isSelected: true
        )]
    }

    private var resolvedDepartureTime: Date {
        leg.liveStatus?.predictedDepartureTime ?? leg.departureTime
    }

    private func departureRow(_ departure: GoLiveDeparture) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let mins = TrackingTimeSync.remainingMinutes(until: departure.date, now: context.date)
            HStack(spacing: 10) {
                if !departure.routeId.isEmpty {
                    RouteBadge(routeID: departure.routeId, size: .small, mode: modeString)
                }
                Text(departure.headsign)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                Spacer()
                if departure.isLive {
                    Image(systemName: "wifi")
                        .rotationEffect(.degrees(90))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                }
                Text(mins <= 0 ? "<1 min" : "\(mins) min")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(
                        departure.isLive ? AppTheme.Colors.successGreen : AppTheme.Colors.textPrimary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(departure.isSelected
                        ? routeColor.opacity(0.16)
                        : AppTheme.Colors.cardInset.opacity(0.4))
            )
        }
    }

    private var stayOnRow: some View {
        Button(action: toggleExpanded) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(routeColor)
                Text(stayOnText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(routeColor)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private var stayOnText: String {
        let stops = max(1, leg.numStops)
        let mins = max(1, leg.durationMinutes)
        let stopsStr = "\(stops) stop\(stops == 1 ? "" : "s")"
        return "Stay on for \(stopsStr) (\(mins) min)"
    }

    private var intermediateStopsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !intermediateStops.isEmpty {
                ForEach(intermediateStops, id: \.id) { stop in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(routeColor.opacity(0.45))
                            .frame(width: 6, height: 6)
                        Text(stop.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            } else if intermediateStopCount > 0 {
                HStack(spacing: 10) {
                    Circle()
                        .fill(routeColor.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text("\(intermediateStopCount) intermediate stop\(intermediateStopCount == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var intermediateStopCount: Int {
        max(0, leg.numStops - 1)
    }

    private var intermediateStops: [BusStop] {
        guard routeStops.count > 2 else { return [] }
        return Array(routeStops.dropFirst().dropLast())
    }

    private var alightRow: some View {
        HStack {
            Text(leg.alightStopName)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .lineLimit(2)
            Spacer()
            Text(timeString(leg.arrivalTime))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
    private func timeString(_ d: Date) -> String { Self.timeFormatter.string(from: d) }

    private func loadRouteDetails() async {
        guard !didLoadRouteDetails else { return }
        didLoadRouteDetails = true
        do {
            let shape = try await fetchShapeForLeg()
            let stops = Self.stopSequence(for: leg, shape: shape)
            routeStops = stops
            await loadLiveDepartures(boardStop: stops.first)
        } catch {
            await loadLiveDepartures(boardStop: nil)
        }
    }

    private func fetchShapeForLeg() async throws -> RouteShapeResponse {
        guard let routeId = leg.routeId else { throw URLError(.badURL) }
        switch leg.mode {
        case .subway:
            return try await TrackAPI.fetchSubwayShape(routeID: routeId)
        case .bus:
            return try await TrackAPI.fetchRouteShape(routeID: routeId)
        case .lirr:
            return try await TrackAPI.fetchLIRRShape(routeID: routeId)
        case .mnr:
            return try await TrackAPI.fetchMNRShape(routeID: routeId)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func loadLiveDepartures(boardStop: BusStop?) async {
        guard let boardStop else { return }
        do {
            let arrivals = try await TrackAPI.fetchNearbyTransit(
                lat: boardStop.lat,
                lon: boardStop.lon,
                radius: 650
            )
            let routeToken = Self.normalizedMatchToken(leg.routeId ?? leg.routeName ?? "")
            let stopId = leg.boardStopId?.uppercased()
            let stopName = Self.normalizedMatchToken(leg.boardStopName)
            let matching = arrivals
                .filter { arrival in
                    guard !arrival.isPlaceholder,
                          Self.widgetMode(for: arrival.mode) == Self.widgetMode(for: leg),
                          Self.normalizedMatchToken(arrival.routeId) == routeToken
                    else { return false }

                    if let stopId,
                       let arrivalStopId = arrival.stopId?.uppercased(),
                       arrivalStopId == stopId {
                        return true
                    }
                    let arrivalStopName = Self.normalizedMatchToken(arrival.stopName)
                    return arrivalStopName == stopName
                        || arrivalStopName.contains(stopName)
                        || stopName.contains(arrivalStopName)
                }
                .map { arrival in
                    GoLiveDeparture(
                        routeId: leg.routeId ?? arrival.routeId,
                        headsign: arrival.destination ?? leg.headsign ?? leg.alightStopName,
                        date: Self.arrivalDate(for: arrival),
                        isLive: arrival.isRealTime,
                        isSelected: Self.isSameArrival(arrival, as: resolvedDepartureTime)
                    )
                }
                .sorted { $0.date < $1.date }

            liveDepartures = Array(matching.prefix(3))
        } catch {
            liveDepartures = []
        }
    }

    nonisolated private static func stopSequence(for leg: TripLeg, shape: RouteShapeResponse) -> [BusStop] {
        guard let direction = bestDirection(for: leg, shape: shape) else { return [] }
        guard let boardStop = TripRouteClipping.findStop(
            in: direction.stops,
            id: leg.boardStopId,
            name: leg.boardStopName
        ),
              let alightStop = TripRouteClipping.findStop(
                in: direction.stops,
                id: leg.alightStopId,
                name: leg.alightStopName
              ),
              let boardIndex = direction.stops.firstIndex(where: { $0.id == boardStop.id }),
              let alightIndex = direction.stops.firstIndex(where: { $0.id == alightStop.id }),
              boardIndex != alightIndex
        else { return [] }

        if boardIndex < alightIndex {
            return Array(direction.stops[boardIndex...alightIndex])
        }
        return Array(direction.stops[alightIndex...boardIndex].reversed())
    }

    nonisolated private static func bestDirection(
        for leg: TripLeg,
        shape: RouteShapeResponse
    ) -> DirectionShapeResponse? {
        guard !shape.directions.isEmpty else { return nil }
        let headsign = leg.headsign.map(normalizedMatchToken)

        struct Candidate {
            let direction: DirectionShapeResponse
            let forward: Bool
            let nameMatches: Bool
            let span: Int
        }

        let candidates: [Candidate] = shape.directions.compactMap { direction in
            guard let boardStop = TripRouteClipping.findStop(
                in: direction.stops,
                id: leg.boardStopId,
                name: leg.boardStopName
            ),
                  let alightStop = TripRouteClipping.findStop(
                    in: direction.stops,
                    id: leg.alightStopId,
                    name: leg.alightStopName
                  ),
                  let boardIndex = direction.stops.firstIndex(where: { $0.id == boardStop.id }),
                  let alightIndex = direction.stops.firstIndex(where: { $0.id == alightStop.id }),
                  boardIndex != alightIndex
            else { return nil }

            let directionHeadsign = normalizedMatchToken(direction.headsign)
            let nameMatches = headsign.map {
                $0 == directionHeadsign || $0.contains(directionHeadsign) || directionHeadsign.contains($0)
            } ?? false
            return Candidate(
                direction: direction,
                forward: boardIndex < alightIndex,
                nameMatches: nameMatches,
                span: abs(alightIndex - boardIndex)
            )
        }

        return candidates.min { lhs, rhs in
            if lhs.forward != rhs.forward { return lhs.forward && !rhs.forward }
            if lhs.nameMatches != rhs.nameMatches { return lhs.nameMatches && !rhs.nameMatches }
            return lhs.span < rhs.span
        }?.direction
    }

    nonisolated private static func arrivalDate(for arrival: NearbyTransitResponse) -> Date {
        if let ts = arrival.arrivalTs, ts > 0 {
            return Date(timeIntervalSince1970: TimeInterval(ts))
        }
        return Date().addingTimeInterval(TimeInterval(max(0, arrival.minutesAway)) * 60)
    }

    nonisolated private static func isSameArrival(_ arrival: NearbyTransitResponse, as date: Date) -> Bool {
        abs(arrivalDate(for: arrival).timeIntervalSince(date)) <= 90
    }

    nonisolated private static func widgetMode(for leg: TripLeg) -> String {
        switch leg.mode {
        case .bus: return "bus"
        case .lirr: return "lirr"
        case .mnr: return "mnr"
        default: return "subway"
        }
    }

    nonisolated private static func widgetMode(for mode: String) -> String {
        switch mode.lowercased() {
        case "bus": return "bus"
        case "lirr": return "lirr"
        case "mnr", "metro_north": return "mnr"
        default: return "subway"
        }
    }

    nonisolated private static func normalizedMatchToken(_ value: String) -> String {
        value.uppercased()
            .replacingOccurrences(of: "MTA NYCT_", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct GoLiveDeparture: Identifiable, Equatable {
    let id = UUID()
    let routeId: String
    let headsign: String
    let date: Date
    let isLive: Bool
    let isSelected: Bool
}

// MARK: - Look Around preview wrapper

private struct LookAroundCardView: View {
    let coordinate: CLLocationCoordinate2D
    @State private var scene: MKLookAroundScene?

    var body: some View {
        Group {
            if let scene {
                LookAroundPreview(initialScene: scene)
                    .overlay(alignment: .topLeading) {
                        Label("Look Around", systemImage: "binoculars.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(.black.opacity(0.6))
                            )
                            .padding(8)
                    }
            } else {
                ZStack {
                    AppTheme.Colors.cardInset
                    Image(systemName: "binoculars.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
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
            let s = try await request.scene
            await MainActor.run { scene = s }
        } catch {
            await MainActor.run { scene = nil }
        }
    }
}
