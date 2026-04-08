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
    /// Estimated clock time for the soonest vehicle to reach this stop.
    /// Interpolated from the first departure when no per-stop live data exists.
    var estimatedTimestamp: Int? = nil
    let isFirst: Bool
    let isLast: Bool
    /// True when an express train skips this stop.
    var isSkipped: Bool = false
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
    /// Display name of the currently viewed route (e.g. "7", "M11").
    /// Used to show a highlighted badge in each stop's transfer row.
    var currentRouteID: String? = nil
    /// Mode of the currently viewed route ("subway", "bus", etc.).
    var currentRouteMode: String? = nil
    var userLocation: CLLocationCoordinate2D? = nil
    var showsHeader: Bool = true
    var usesEmbeddedSurface: Bool = false
    var onStopTapped: ((StopRowData) -> Void)?

    @State private var showPreviousStops = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                headerRow
            }

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

    private var headerRow: some View {
        HStack(spacing: 8) {
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

    @ViewBuilder
    private var stopsContent: some View {
        let nearest = nearestStopIndex
        let firstUpcomingIndex = stops.firstIndex(where: { !$0.isPassed })
            ?? stops.count
        let passedCount = firstUpcomingIndex

        let content = VStack(spacing: 0) {
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
                            currentRouteID: currentRouteID,
                            currentRouteMode: currentRouteMode,
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
                    currentRouteID: currentRouteID,
                    currentRouteMode: currentRouteMode,
                    // When collapsed with previous stops, the toggle's line
                    // connects into the first upcoming stop — always show top line.
                    showTopLine: (passedCount > 0 && offset == 0)
                        ? true : !stop.isFirst,
                    showBottomLine: !stop.isLast,
                    lineFaded: stop.isPassed
                )
                .opacity(stop.isPassed ? 0.5 : 1.0)
                .contentShape(Rectangle())
                .onTapGesture { onStopTapped?(stop) }
            }
        }
        .padding(.vertical, usesEmbeddedSurface ? 2 : 8)

        if usesEmbeddedSurface {
            content
                .padding(.horizontal, AppTheme.Layout.margin + 2)
        } else {
            content
                .trackCardBackground(cornerRadius: AppTheme.Layout.cornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius)
                        .strokeBorder(routeColor.opacity(0.06), lineWidth: 1)
                )
                .padding(.horizontal, AppTheme.Layout.margin)
        }
    }

    /// MTA-style collapsible toggle for previous (passed) stops.
    /// Keeps the route line running through the toggle — matching the
    /// continuous-line aesthetic in the MTA app screenshot.
    private func previousStopsToggle(count: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                showPreviousStops.toggle()
            }
        } label: {
            HStack(alignment: .center, spacing: 0) {
                // Continuous route-colored line segment with a gap for the label
                ZStack {
                    // Vertical line (faded, same as passed-stop line)
                    Rectangle()
                        .fill(routeColor.opacity(0.25))
                        .frame(width: 3)
                }
                .frame(width: 30, height: 40)

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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Walking time pill shown above the nearest stop — includes a
    /// continuous route-colored line segment on the left so the vertical
    /// timeline is never broken.
    private func walkingTimeBadge(minutes: Int) -> some View {
        HStack(alignment: .center, spacing: 0) {
            // Continuous line segment matching the stop row line
            Rectangle()
                .fill(routeColor.opacity(0.5))
                .frame(width: 3, height: 32)
                .frame(width: 30)

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
            .padding(.leading, 10)

            Spacer()
        }
        .padding(.leading, AppTheme.Layout.cardPadding)
    }
}

// MARK: - Stop Row View

/// A single stop row with a continuous line, dot indicator, name, transfers,
/// accessibility info, and arrival ETA. Designed after Transit app style.
struct StopRowView: View {
    let stop: StopRowData
    let routeColor: Color
    /// Display name of the route being viewed (e.g. "7", "M11").
    var currentRouteID: String? = nil
    /// Mode of the route being viewed ("subway", "bus", etc.).
    var currentRouteMode: String? = nil
    var showTopLine: Bool = true
    var showBottomLine: Bool = true
    var lineFaded: Bool = false

    private var lineColor: Color {
        if stop.isSkipped {
            return AppTheme.Colors.textSecondary.opacity(0.10)
        }
        return lineFaded
            ? AppTheme.Colors.textSecondary.opacity(0.15)
            : routeColor.opacity(0.76)
    }

    private var isTerminal: Bool {
        stop.isFirst || stop.isLast
    }

    // MARK: Dot dimensions
    private var dotSize: CGFloat {
        stop.isCurrent ? 14 : (isTerminal ? 14 : 10)
    }

    /// Bottom-half line color — transitions from faded to route color at the
    /// current stop so the line below the current stop is always bright.
    private var bottomLineColor: Color {
        if stop.isSkipped {
            return AppTheme.Colors.textSecondary.opacity(0.10)
        }
        return stop.isPassed
            ? AppTheme.Colors.textSecondary.opacity(0.15)
            : routeColor.opacity(0.82)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {

            // ── Left column: continuous line + dot ──
            // Uses two Rectangles in a single VStack so both halves always
            // claim equal space — no pixel gaps between adjacent rows.
            ZStack {
                VStack(spacing: 0) {
                    if stop.isSkipped {
                        // Dashed line for skipped stops — visual "gap" effect
                        Rectangle()
                            .fill(showTopLine ? lineColor : Color.clear)
                            .mask(
                                VStack(spacing: 2) {
                                    ForEach(0..<12, id: \.self) { _ in
                                        Rectangle().frame(height: 3)
                                    }
                                }
                            )
                        Rectangle()
                            .fill(showBottomLine ? bottomLineColor : Color.clear)
                            .mask(
                                VStack(spacing: 2) {
                                    ForEach(0..<12, id: \.self) { _ in
                                        Rectangle().frame(height: 3)
                                    }
                                }
                            )
                    } else {
                        Rectangle()
                            .fill(showTopLine ? lineColor : Color.clear)
                        Rectangle()
                            .fill(showBottomLine ? bottomLineColor : Color.clear)
                    }
                }
                .frame(width: 3)

                // Stop dot
                stopDot
            }
            .frame(width: 30)

            // ── Right column: name, transfers, accessibility ──
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.system(
                        size: stop.isSkipped ? 12
                            : (stop.isCurrent || isTerminal) ? 15 : 14,
                        weight: stop.isSkipped ? .regular
                            : (stop.isCurrent || isTerminal) ? .bold : .semibold,
                        design: .rounded
                    ))
                    .foregroundColor(
                        stop.isSkipped
                            ? AppTheme.Colors.textSecondary.opacity(0.4)
                            : (stop.isCurrent ? routeColor : AppTheme.Colors.textPrimary)
                    )
                    .strikethrough(stop.isSkipped, color: AppTheme.Colors.textSecondary.opacity(0.3))
                    .lineLimit(1)

                if !stop.accessibilityOutages.isEmpty && !stop.isSkipped {
                    HStack(spacing: 5) {
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

                // Transfer badges — show when we have current route or transfers
                if (!stop.transfers.isEmpty || currentRouteID != nil) && !stop.isSkipped {
                    transferBadgeRow
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, stop.isSkipped ? 5 : 10)

            Spacer(minLength: 4)

            // ── Arrival ETA column — hidden for skipped stops ──
            if !stop.isSkipped {
                arrivalColumn
                    .padding(.trailing, AppTheme.Layout.cardPadding)
                    .padding(.vertical, 10)
            }
        }
        .padding(.leading, AppTheme.Layout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(stop.isSelected ? routeColor.opacity(0.08) : Color.clear)
                .padding(.horizontal, 4)
        )
        .animation(.easeInOut(duration: 0.25), value: stop.isSelected)
        .animation(.easeInOut(duration: 0.3), value: stop.isSkipped)
    }

    // MARK: - Stop Dot

    @ViewBuilder
    private var stopDot: some View {
        if stop.isSkipped {
            // Skipped (express) stop: tiny hollow ring, barely visible
            Circle()
                .strokeBorder(
                    AppTheme.Colors.textSecondary.opacity(0.20),
                    lineWidth: 1
                )
                .frame(width: 6, height: 6)
        } else if stop.isCurrent {
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

    /// Compact transfer badge row — current route highlighted, then transfers.
    private var transferBadgeRow: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))

            // Current route badge — always shown first, highlighted
            if let routeID = currentRouteID {
                RouteBadge(
                    routeID: routeID,
                    size: .custom(18, 10),
                    isBus: currentRouteMode == "bus",
                    mode: currentRouteMode
                )
            }

            // Show up to 6 transfer badges, then "+N"
            let visible = Array(stop.transfers.prefix(6))
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
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.successGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppTheme.Colors.successGreen.opacity(0.10))
                    .clipShape(Capsule())
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    // Absolute timestamp — primary (like Transit app)
                    if let ts = stop.nextArrivalTimestamp {
                        Text(Date(timeIntervalSince1970: Double(ts)), style: .time)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(
                                stop.isPassed
                                    ? AppTheme.Colors.textSecondary.opacity(0.35)
                                    : AppTheme.Colors.textPrimary
                            )
                    }

                    // Relative ETA — secondary with live dot
                    HStack(spacing: 3) {
                        if !stop.nextArrivalIsScheduled {
                            Circle()
                                .fill(AppTheme.Colors.successGreen)
                                .frame(width: 5, height: 5)
                        }
                        Text("\(minutes) min")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(
                                stop.isPassed
                                    ? AppTheme.Colors.textSecondary.opacity(0.3)
                                    : (stop.nextArrivalIsScheduled
                                       ? AppTheme.Colors.textTertiary
                                       : AppTheme.Colors.successGreen)
                            )
                    }
                }
            }
        } else if let est = stop.estimatedTimestamp {
            // Estimated clock time (interpolated from soonest departure)
            Text(Date(timeIntervalSince1970: Double(est)), style: .time)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(
                    stop.isPassed
                        ? AppTheme.Colors.textSecondary.opacity(0.3)
                        : AppTheme.Colors.textSecondary
                )
        } else {
            EmptyView()
        }
    }
}
