import SwiftUI
import CoreLocation

// MARK: - Stop Row Data

/// Value bag fed to `StopRowView` — decouples the component from
/// sheet-internal types like `BusStop`, `NearbyTransitResponse`, etc.
struct StopRowData: Identifiable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let isCurrent: Bool
    let isPassed: Bool
    let isSelected: Bool
    let transfers: [String]            // route display names for transfer badges
    let accessibilityOutages: [String] // descriptions
    let hasElevatorOutage: Bool
    let nextArrivalMinutes: Int?       // nil = no arrival
    let nextArrivalIsScheduled: Bool
    let nextArrivalIsAtStop: Bool      // minutesAway <= 0
    let nextArrivalTimestamp: Int?
    let isFirst: Bool
    let isLast: Bool
}

// MARK: - Stops List View

/// Reusable stops list with a continuous route-colored line, transfer badges,
/// accessibility outage warnings, and next-arrival ETAs.
/// Inspired by Transit app's clean vertical timeline layout.
struct StopsListView: View {
    let stops: [StopRowData]
    let routeColor: Color
    let isLoading: Bool               // shape == nil → show skeleton
    let selectedStopId: String?
    var userLocation: CLLocationCoordinate2D? = nil
    var onStopTapped: ((StopRowData) -> Void)?

    @State private var showPreviousStops = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                // Left accent bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(routeColor)
                    .frame(width: 3, height: 18)

                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(routeColor)

                Text("Stops")
                    .font(.custom("Helvetica-Bold", size: 14))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .textCase(.uppercase)
                    .tracking(0.8)

                Spacer()

                if !stops.isEmpty {
                    HStack(spacing: 3) {
                        Text("\(stops.count)")
                            .font(.custom("Helvetica-Bold", size: 12))
                            .foregroundColor(routeColor)
                        Text("stop\(stops.count == 1 ? "" : "s")")
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(routeColor.opacity(0.06))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            if stops.isEmpty {
                if isLoading {
                    StopsListSkeleton()
                } else {
                    stopsEmptyState
                }
            } else {
                stopsContent
            }
        }
    }

    // MARK: - Nearest Stop

    /// Index of the stop closest to the user — shown with walking time.
    private var nearestStopIndex: Int? {
        guard let loc = userLocation else { return nil }
        let userLoc = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
        var bestIdx: Int?
        var bestDist = Double.greatestFiniteMagnitude
        for (i, stop) in stops.enumerated() {
            guard !stop.isPassed else { continue }
            let d = userLoc.distance(from: CLLocation(latitude: stop.lat, longitude: stop.lon))
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return bestIdx
    }

    // MARK: - Sub-Views

    private var stopsEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
            Text("No stops for this direction")
                .font(.custom("Helvetica", size: 15))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    private var stopsContent: some View {
        let nearest = nearestStopIndex
        let firstUpcomingIndex = stops.firstIndex(where: { !$0.isPassed })
            ?? stops.count
        let passedCount = firstUpcomingIndex

        return VStack(spacing: 0) {
            // ── Collapsible previous stops ──
            if passedCount > 0 {
                previousStopsToggle(count: passedCount)

                if showPreviousStops {
                    ForEach(
                        Array(stops.prefix(passedCount).enumerated()),
                        id: \.element.id
                    ) { index, stop in
                        if index == nearest, let loc = userLocation {
                            let d = CLLocation(
                                latitude: loc.latitude,
                                longitude: loc.longitude
                            ).distance(from: CLLocation(
                                latitude: stop.lat,
                                longitude: stop.lon
                            ))
                            let walkMin = max(1, Int((d / 80.0).rounded()))
                            walkingTimeBadge(minutes: walkMin)
                        }

                        StopRowView(
                            stop: stop,
                            routeColor: routeColor,
                            showTopLine: !stop.isFirst,
                            showBottomLine: !stop.isLast,
                            lineFaded: true
                        )
                        .opacity(0.5)
                        .contentShape(Rectangle())
                        .onTapGesture { onStopTapped?(stop) }
                    }
                }
            }

            // ── Current + upcoming stops (always visible) ──
            ForEach(
                Array(stops.suffix(from: passedCount).enumerated()),
                id: \.element.id
            ) { offset, stop in
                let globalIndex = passedCount + offset

                if globalIndex == nearest, let loc = userLocation {
                    let d = CLLocation(
                        latitude: loc.latitude,
                        longitude: loc.longitude
                    ).distance(from: CLLocation(
                        latitude: stop.lat,
                        longitude: stop.lon
                    ))
                    let walkMin = max(1, Int((d / 80.0).rounded()))
                    walkingTimeBadge(minutes: walkMin)
                }

                StopRowView(
                    stop: stop,
                    routeColor: routeColor,
                    showTopLine: (passedCount > 0 && !showPreviousStops && offset == 0)
                        ? false : !stop.isFirst,
                    showBottomLine: !stop.isLast,
                    lineFaded: stop.isPassed
                )
                .opacity(stop.isPassed ? 0.5 : 1.0)
                .contentShape(Rectangle())
                .onTapGesture { onStopTapped?(stop) }
            }
        }
        .padding(.vertical, 8)
        .trackCardBackground(cornerRadius: AppTheme.Layout.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius)
                .strokeBorder(routeColor.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    /// MTA-style collapsible toggle for previous (passed) stops.
    private func previousStopsToggle(count: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                showPreviousStops.toggle()
            }
        } label: {
            HStack(spacing: 0) {
                // Dot-dot-dot indicator aligned with the route timeline
                ZStack {
                    VStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle()
                                .fill(routeColor.opacity(0.25))
                                .frame(width: 4, height: 4)
                        }
                    }
                }
                .frame(width: 30)

                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(
                            .degrees(showPreviousStops ? 180 : 0)
                        )

                    Text(
                        showPreviousStops
                            ? "Hide previous stops"
                            : "Show previous stops (\(count))"
                    )
                    .font(.system(
                        size: 12, weight: .semibold, design: .rounded
                    ))
                }
                .foregroundColor(routeColor)
                .padding(.leading, 10)

                Spacer()
            }
            .padding(.leading, AppTheme.Layout.cardPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Walking time pill shown above the nearest stop.
    private func walkingTimeBadge(minutes: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "figure.walk")
                .font(.system(size: 10, weight: .semibold))
            Text("\(minutes) min walk")
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundColor(AppTheme.Colors.mtaBlue)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(AppTheme.Colors.mtaBlue.opacity(0.08))
                .overlay(
                    Capsule()
                        .strokeBorder(AppTheme.Colors.mtaBlue.opacity(0.15), lineWidth: 0.5)
                )
        )
        .padding(.leading, 40)
        .padding(.vertical, 4)
    }
}

// MARK: - Stop Row View

/// A single stop row with a continuous line, dot indicator, name, transfers,
/// accessibility info, and arrival ETA. Designed after Transit app style.
struct StopRowView: View {
    let stop: StopRowData
    let routeColor: Color
    var showTopLine: Bool = true
    var showBottomLine: Bool = true
    var lineFaded: Bool = false

    private var lineColor: Color {
        lineFaded
            ? AppTheme.Colors.textSecondary.opacity(0.15)
            : routeColor.opacity(0.5)
    }

    private var isTerminal: Bool {
        stop.isFirst || stop.isLast
    }

    // MARK: Dot dimensions
    private var dotSize: CGFloat {
        stop.isCurrent ? 14 : (isTerminal ? 14 : 10)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {

            // ── Left column: continuous line + dot ──
            ZStack(alignment: .center) {
                // Top line segment
                VStack(spacing: 0) {
                    if showTopLine {
                        Rectangle()
                            .fill(lineColor)
                            .frame(width: 3)
                    } else {
                        Color.clear.frame(width: 3)
                    }
                    Color.clear.frame(width: 3)   // space for bottom half
                }

                // Bottom line segment
                VStack(spacing: 0) {
                    Color.clear.frame(width: 3)   // space for top half
                    if showBottomLine {
                        Rectangle()
                            .fill(
                                stop.isPassed
                                    ? AppTheme.Colors.textSecondary.opacity(0.15)
                                    : routeColor.opacity(0.5)
                            )
                            .frame(width: 3)
                    } else {
                        Color.clear.frame(width: 3)
                    }
                }

                // Stop dot
                stopDot
            }
            .frame(width: 30)

            // ── Right column: name, transfers, accessibility ──
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(stop.name)
                        .font(.system(
                            size: (stop.isCurrent || isTerminal) ? 14 : 13,
                            weight: (stop.isCurrent || isTerminal) ? .bold : .medium,
                            design: .rounded
                        ))
                        .foregroundColor(stop.isCurrent ? routeColor : AppTheme.Colors.textPrimary)
                        .lineLimit(1)

                    if !stop.accessibilityOutages.isEmpty {
                        Image(systemName: stop.hasElevatorOutage
                              ? "arrow.up.arrow.down.circle.fill" : "stairs")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 18, height: 18)
                            .background(AppTheme.Colors.alertRed)
                            .clipShape(Circle())
                            .help(stop.accessibilityOutages.first ?? "Accessibility outage")
                    }
                }

                // Transfer badges
                if !stop.transfers.isEmpty {
                    transferBadgeRow
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 10)

            Spacer(minLength: 4)

            // ── Arrival ETA column ──
            arrivalColumn
                .padding(.trailing, AppTheme.Layout.cardPadding)
                .padding(.vertical, 10)
        }
        .padding(.leading, AppTheme.Layout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(stop.isSelected ? routeColor.opacity(0.08) : Color.clear)
                .padding(.horizontal, 4)
        )
        .animation(.easeInOut(duration: 0.2), value: stop.isSelected)
    }

    // MARK: - Stop Dot

    @ViewBuilder
    private var stopDot: some View {
        if stop.isCurrent {
            // Current stop: bright dot with glowing halo
            ZStack {
                Circle()
                    .fill(routeColor.opacity(0.1))
                    .frame(width: 28, height: 28)
                Circle()
                    .fill(routeColor.opacity(0.2))
                    .frame(width: 20, height: 20)
                Circle()
                    .fill(routeColor)
                    .frame(width: 14, height: 14)
                    .shadow(color: routeColor.opacity(0.4), radius: 4, x: 0, y: 1)
                Circle()
                    .fill(AppTheme.Colors.cardFloating)
                    .frame(width: 5, height: 5)
            }
        } else if isTerminal {
            // Terminal stop: outlined ring with center dot
            ZStack {
                Circle()
                    .strokeBorder(routeColor, lineWidth: 2.5)
                    .frame(width: 14, height: 14)
                Circle()
                    .fill(routeColor)
                    .frame(width: 5, height: 5)
            }
        } else {
            // Normal stop: filled circle on the line
            Circle()
                .fill(
                    stop.isPassed
                        ? AppTheme.Colors.textSecondary.opacity(0.3)
                        : routeColor.opacity(0.8)
                )
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .fill(AppTheme.Colors.cardBackground)
                        .frame(width: 4, height: 4)
                )
        }
    }

    /// Compact transfer badge row — subway circles and bus pills properly sized.
    private var transferBadgeRow: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))

            // Show up to 8 transfers inline, then "+N"
            let visible = Array(stop.transfers.prefix(8))
            let overflow = stop.transfers.count - visible.count

            ForEach(visible, id: \.self) { route in
                transferBadge(route)
            }

            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
            }
        }
    }

    /// Individual transfer badge — subway gets circles, buses get compact pills.
    @ViewBuilder
    private func transferBadge(_ route: String) -> some View {
        let subwayIDs: Set<String> = [
            "1", "2", "3", "4", "5", "6", "7",
            "A", "C", "E", "B", "D", "F", "M",
            "G", "J", "Z", "L",
            "N", "Q", "R", "W", "S", "SI",
        ]
        let isSubway = subwayIDs.contains(route.uppercased())
        if isSubway {
            RouteBadge(routeID: route, size: .custom(18, 10))
        } else {
            RouteBadge(routeID: route, size: .custom(16, 8), isBus: true)
        }
    }

    @ViewBuilder
    private var arrivalColumn: some View {
        if let minutes = stop.nextArrivalMinutes, !stop.nextArrivalIsScheduled || minutes >= 0 {
            if stop.nextArrivalIsAtStop {
                // ── At stop / Now ──
                Text("Now")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.successGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.Colors.successGreen.opacity(0.12))
                    .clipShape(Capsule())
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 3) {
                        if !stop.nextArrivalIsScheduled {
                            Circle()
                                .fill(AppTheme.Colors.successGreen)
                                .frame(width: 5, height: 5)
                        }
                        Text("\(minutes) min")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(
                                stop.isPassed
                                    ? AppTheme.Colors.textSecondary.opacity(0.35)
                                    : (stop.nextArrivalIsScheduled
                                       ? AppTheme.Colors.textSecondary
                                       : routeColor)
                            )
                    }
                    if let ts = stop.nextArrivalTimestamp {
                        Text(Date(timeIntervalSince1970: Double(ts)), style: .time)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(
                                AppTheme.Colors.textSecondary
                                    .opacity(stop.isPassed ? 0.3 : 0.5)
                            )
                    }
                }
            }
        } else {
            EmptyView()
        }
    }
}
