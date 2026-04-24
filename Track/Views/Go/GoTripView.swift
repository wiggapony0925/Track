// Immersive "Go" navigation view — presented as a full-screen cover
// from MainTabView when GoTripSession.activeTrip is non-nil.  Mirrors
// the polished navigation experience of best-in-class transit apps:
// a sticky map + progress header, expandable leg cards (walk steps,
// transit boarding card with next departures, destination address +
// Look Around preview), pinned action buttons, and a live arrival
// bar at the bottom.  While active the user cannot switch tabs; they
// must explicitly exit via the close button.

import CoreLocation
import MapKit
import SwiftUI

// MARK: - GoTripView

struct GoTripView: View {
    let trip: TripPlan
    @Environment(GoTripSession.self) private var session

    @State private var heroVisible = false
    @State private var bodyVisible = false
    @State private var showShareSheet = false
    @State private var expandedLegIDs: Set<UUID> = []

    var body: some View {
        ZStack(alignment: .top) {
            AppTheme.Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                stickyHeader

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

                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                bottomArrivalBar
            }

            // Floating top controls layered above the map
            floatingTopControls
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [shareText])
                .presentationDetents([.medium])
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
        }
    }

    // MARK: - Sticky Header (map + Go-in title + progress bar)

    private var stickyHeader: some View {
        VStack(spacing: 0) {
            // Compact map preview at the very top
            ZStack(alignment: .bottom) {
                TripRouteMapView(trip: trip, isInteractive: false)
                    .frame(height: 180)
                    .clipped()

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: AppTheme.Colors.background.opacity(0.5), location: 0.6),
                        .init(color: AppTheme.Colors.background, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 70)
                .allowsHitTesting(false)
            }
            .opacity(heroVisible ? 1 : 0)

            // "Go in X min" + multi-segment progress
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text(goInTitle)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Spacer()
                }

                GoLegProgressBar(
                    legs: trip.legs,
                    currentLegIndex: session.currentLegIndex
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .background(AppTheme.Colors.background)
        }
    }

    private var floatingTopControls: some View {
        HStack {
            FloatingCircleButton(
                icon: "chevron.left",
                fillColor: AppTheme.Colors.cardElevated,
                iconColor: AppTheme.Colors.textPrimary,
                iconSize: 14
            ) {
                // Back == exit Go mode (no underlying nav stack to pop in fullScreenCover)
                session.stop()
            }

            Spacer()

            FloatingCircleButton(icon: "xmark") {
                session.stop()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 54)
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
        // We don't currently persist coordinates on TripLeg, so derive from
        // the trip route map data if available.  Returning nil hides the
        // Look Around preview gracefully.
        nil
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            actionRow(icon: "mappin.circle.fill", title: "Change destination stop") {
                // Reserved for future: present a stop picker
            }
            actionRow(icon: "square.and.arrow.up", title: "Share ETA") {
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

    // MARK: - Bottom Arrival Bar

    private var bottomArrivalBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Arrival time")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(timeString(trip.arrivalTime))
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                    Circle()
                        .fill(AppTheme.Colors.textTertiary.opacity(0.5))
                        .frame(width: 4, height: 4)
                    Text(trip.durationString)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(
            AppTheme.Colors.cardElevated
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: AppTheme.Colors.shadow, radius: 8, y: -2)
        )
    }

    // MARK: - Helpers

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

    private func addToCalendar() {
        // Lightweight stub — opens default Calendar app via URL scheme.
        // Full EKEventEditViewController integration can replace this later.
        let title = "Trip to \(trip.legs.last?.alightStopName ?? "Destination")"
        let start = Int(trip.departureTime.timeIntervalSinceReferenceDate)
        let end = Int(trip.arrivalTime.timeIntervalSinceReferenceDate)
        if let url = URL(string: "calshow:\(start)") {
            _ = (start, end, title)
            UIApplication.shared.open(url)
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
            HStack(spacing: 4) {
                ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                    let fraction = CGFloat(leg.durationMinutes) / CGFloat(totalDuration)
                    let width = max(36, fraction * geo.size.width - 4)
                    segment(for: leg, index: index, width: width)
                }
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

            // Real next-departure data isn't currently surfaced per-leg,
            // so we display the leg's primary departure as a live count
            // down.  When liveStatus is added with multiple ETAs this
            // section can iterate and render each row.
            departureRow(
                routeId: leg.routeId ?? "",
                headsign: leg.headsign ?? leg.alightStopName,
                date: leg.departureTime,
                isLive: leg.liveStatus != nil
            )
        }
    }

    private func departureRow(routeId: String, headsign: String, date: Date, isLive: Bool)
        -> some View
    {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let mins = max(0, Int((date.timeIntervalSince(context.date) / 60).rounded()))
            HStack(spacing: 10) {
                if !routeId.isEmpty {
                    RouteBadge(routeID: routeId, size: .small, mode: modeString)
                }
                Text(headsign)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                Spacer()
                if isLive {
                    Image(systemName: "wifi")
                        .rotationEffect(.degrees(90))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.successGreen)
                }
                Text(mins <= 0 ? "now" : "\(mins) min")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(
                        isLive ? AppTheme.Colors.successGreen : AppTheme.Colors.textPrimary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.Colors.cardInset.opacity(0.4))
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
            ForEach(0..<max(0, leg.numStops - 1), id: \.self) { i in
                HStack(spacing: 10) {
                    Circle()
                        .fill(routeColor.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text("Stop \(i + 1)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
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
