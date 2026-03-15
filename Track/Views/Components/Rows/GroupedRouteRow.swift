//
//  GroupedRouteRow.swift
//  Track
//
//  A compact row for a grouped route card. Shows the route badge,
//  display name, direction count, and soonest arrival countdown.
//  Tapping opens the RouteDetailSheet.
//  Extracted from HomeView for reusability.
//

import CoreLocation
import SwiftUI

enum GroupedRouteRowPresentation {
    case standard
    case favorite
}

struct  GroupedRouteRow: View {
    let group: GroupedNearbyTransitResponse
    var hasAlert: Bool = false
    var userLocation: CLLocation? = nil
    var distanceMetersOverride: Double? = nil
    var smartETAProvider: ((NearbyTransitResponse) -> SmartETA)? = nil
    var initialDirectionIndex: Int = 0
    var onDirectionChanged: ((Int) -> Void)? = nil
    var onSelect: ((Int) -> Void)? = nil
    var onTrack: ((Int) -> Void)? = nil
    var presentation: GroupedRouteRowPresentation = .standard

    @State private var currentDirectionIndex = 0
    @State private var showTrackingBanner = false
    @State private var trackingBannerText = ""
    /// True when the direction index is being updated programmatically
    /// (e.g. parent syncing `initialDirectionIndex`). Prevents firing
    /// `onDirectionChanged` which would incorrectly persist a
    /// preference that came from shape enrichment reordering, not a
    /// user swipe.
    @State private var _isSyncing = false


    /// Route color derived from group data or theme defaults.
    private var routeColor: Color {
        if let hex = group.colorHex {
            return Color(hex: hex)
        }
        if group.isLIRR { return AppTheme.CommuterRailColors.lirrBlue }
        if group.isMNR { return AppTheme.CommuterRailColors.mnrBlue }
        return group.isBus
            ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: group.displayName)
    }

    private var isFavoritePresentation: Bool {
        presentation == .favorite
    }

    private var containerCornerRadius: CGFloat {
        isFavoritePresentation ? 24 : AppTheme.Layout.cornerRadius
    }

    private var rowHorizontalPadding: CGFloat {
        isFavoritePresentation ? 18 : AppTheme.Layout.margin
    }

    private var rowVerticalPadding: CGFloat {
        isFavoritePresentation ? 16 : 14
    }

    /// Distance from user to the closest stop in this group (meters).
    private var closestStopDistance: Double? {
        if let distanceMetersOverride { return distanceMetersOverride }
        guard let loc = userLocation else { return nil }
        return groupMinDistance(for: group, from: loc)
    }

    /// Directions that have real data — filters out backend placeholder-only tabs
    /// (e.g., Phase C "Opposite Direction" with no live arrivals and all
    /// placeholder minutesAway ≥ 99). Falls back to all directions if
    /// filtering would leave zero.
    private var visibleDirections: [DirectionArrivalsResponse] {
        let real = group.directions.filter { dir in
            // Keep if it has at least one live (non-placeholder) arrival
            if !dir.liveArrivals.isEmpty { return true }
            // Drop: "Opposite" direction with no live arrivals
            if dir.direction.lowercased() == "opposite" { return false }
            // Drop compass-code placeholder directions with no live data.
            // These are backend backfill (Phase C) — e.g. "SW" opposite of
            // "EAST SIDE YORK AV CROSSTOWN" — and just show "Southwest"
            // which is unhelpful.  They'll appear once buses start running.
            if DirectionConstants.isFallbackDirection(dir.direction) && dir.liveArrivals.isEmpty {
                return false
            }
            return true
        }
        return real.isEmpty ? group.directions : real
    }

    /// Maps the current `visibleDirections` index back to the original
    /// `group.directions` index so parent callbacks (selectGroupedRoute,
    /// trackNearbyArrival) receive the correct index.
    private var originalDirectionIndex: Int {
        let dir = currentDirection
        return group.directions.firstIndex(where: { $0.id == dir.id })
            ?? min(currentDirectionIndex, group.directions.count - 1)
    }

    /// Currently visible direction (clamped to bounds).
    private var currentDirection: DirectionArrivalsResponse {
        guard !visibleDirections.isEmpty else {
            return DirectionArrivalsResponse(direction: "—", arrivals: [])
        }
        return visibleDirections[min(currentDirectionIndex, visibleDirections.count - 1)]
    }

    /// Maps an original group direction index to the visible direction index.
    private func visibleIndex(forOriginal original: Int) -> Int {
        guard group.directions.indices.contains(original) else {
            return min(currentDirectionIndex, max(0, visibleDirections.count - 1))
        }
        let targetId = group.directions[original].id
        if let idx = visibleDirections.firstIndex(where: { $0.id == targetId }) {
            return idx
        }
        return min(original, max(0, visibleDirections.count - 1))
    }

    /// Delegates to `ArrivalHelpers.countdownArrival` — the shared,
    /// canonical implementation used by both the row and the detail sheet.
    private func countdownArrival(for direction: DirectionArrivalsResponse) -> NearbyTransitResponse? {
        ArrivalHelpers.countdownArrival(
            for: direction,
            userLocation: userLocation,
            provider: smartETAProvider
        )
    }

    private func resolvedETA(for arrival: NearbyTransitResponse) -> SmartETA {
        ArrivalHelpers.resolvedETA(for: arrival, provider: smartETAProvider)
    }

    var body: some View {
        mainRowContent
            .overlay(alignment: .top) {
                // ── "Now tracking" confirmation banner ──
                if showTrackingBanner {
                    trackingConfirmationBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .onAppear { debugLogHomeRow() }
            .onChange(of: group.directions) { _, _ in debugLogHomeRow() }
    }

    /// Stores the last printed [HOME_ROW] message per route so identical
    /// lines aren't repeated. Data *changes* still print immediately.
    @MainActor private static var _lastHomeRowMessage: [String: String] = [:]

    /// Logs what the home row is displaying so the console shows
    /// route, mode, direction, and the countdown minutesAway.
    /// Deduplicates by content: identical re-renders are suppressed,
    /// but any data change (flickering) prints right away.
    private func debugLogHomeRow() {
        #if DEBUG
        let mode = group.isBus ? "BUS" : group.isLIRR ? "LIRR" : group.isMNR ? "MNR" : "SUBWAY"
        let dir = currentDirection
        let dirLabel = dir.directionLabel ?? dir.direction
        let countdown = countdownArrival(for: dir)
        let countdownMin: String = {
            if let c = countdown {
                let eta = resolvedETA(for: c)
                return "\(eta.minutesRemaining)min (raw=\(c.minutesAway), stop=\(c.stopName))"
            }
            return "none"
        }()
        let allLive = dir.liveArrivals
        let allMins = allLive.prefix(6).map { a -> String in
            let eta = resolvedETA(for: a)
            let vid = a.vehicleId ?? a.tripId ?? "?"
            return "\(eta.minutesRemaining)m(raw=\(a.minutesAway),id=\(vid.suffix(6)))"
        }
        let msg = "[HOME_ROW] \(mode) \(group.displayName) → \(dirLabel)  countdown=\(countdownMin)  arrivals=[\(allMins.joined(separator: ", "))]"
        let key = group.id
        if Self._lastHomeRowMessage[key] != msg {
            Self._lastHomeRowMessage[key] = msg
            print(msg)
        }
        #endif
    }

    // MARK: - Main Row Content

    private var mainRowContent: some View {
        VStack(spacing: 0) {
            mainRowHStack
                .padding(.vertical, rowVerticalPadding)
                .padding(.horizontal, rowHorizontalPadding)

            alertBannerRow
        }
        .background { rowBackground }
        .contentShape(RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous))
        .onTapGesture {
            HapticManager.selection()
            onSelect?(originalDirectionIndex)
        }
        .onLongPressGesture(minimumDuration: 0.5, perform: {
            triggerTracking()
        })
        .onAppear {
            let restoredVisible: Int = visibleIndex(forOriginal: initialDirectionIndex)
            if restoredVisible != currentDirectionIndex {
                _isSyncing = true
                currentDirectionIndex = restoredVisible
            }
        }
        .onChange(of: initialDirectionIndex) { _, newValue in
            let restoredVisible: Int = visibleIndex(forOriginal: newValue)
            if restoredVisible != currentDirectionIndex {
                _isSyncing = true
                currentDirectionIndex = restoredVisible
            }
        }
        .onChange(of: currentDirectionIndex) { _, _ in
            if _isSyncing {
                _isSyncing = false
                return
            }
            onDirectionChanged?(originalDirectionIndex)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mainRowAccessibilityLabel)
        .accessibilityHint("Double tap to see details. Long press to track.")
        .accessibilityAction(named: "Track this route") {
            triggerTracking()
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
        if isFavoritePresentation {
            shape
                .fill(AppTheme.Gradients.floating)
                .overlay {
                    shape.stroke(routeColor.opacity(0.18), lineWidth: 1)
                }
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(routeColor)
                        .frame(width: 5)
                        .padding(.vertical, 16)
                        .padding(.leading, 10)
                }
                .shadow(color: AppTheme.Colors.shadow.opacity(0.18), radius: 14, x: 0, y: 8)
                .shadow(color: routeColor.opacity(0.10), radius: 18, x: 0, y: 6)
        } else {
            shape.fill(AppTheme.Colors.cardBackground)
        }
    }

    private var mainRowAccessibilityLabel: String {
        let mode: String = group.isLIRR ? "LIRR" : group.isMNR ? "Metro-North" : group.isBus ? "Bus" : "Train"
        return "\(mode) \(group.displayName), swipe for directions"
    }

    private var mainRowHStack: some View {
        HStack(spacing: 14) {
            routeBadgeView

            if visibleDirections.isEmpty {
                Text("No active service")
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                Spacer()
            } else {
                directionInfoColumn
            }

            Spacer(minLength: 4)

            if !visibleDirections.isEmpty {
                countdownView
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
        }
    }

    private var routeBadgeView: some View {
        RouteBadge(
            routeID: group.displayName,
            size: .medium,
            isBus: group.isBus,
            hexColor: group.colorHex,
            mode: group.mode
        )
        .accessibilityHidden(true)
        .overlay(alignment: .topTrailing) {
            if hasAlert {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.cardBackground)
                        .frame(width: 18, height: 18)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.Colors.warningYellow)
                }
                .offset(x: 6, y: -6)
            }
        }
    }

    private var directionInfoColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            directionTabView
            walkingDistanceLabel
            paginationDots
        }
    }

    private var directionTabView: some View {
        TabView(selection: $currentDirectionIndex) {
            ForEach(Array(visibleDirections.enumerated()), id: \.element.id) { index, direction in
                let label: String = ArrivalHelpers.resolveDirectionLabel(for: direction)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.custom("Helvetica-Bold", size: 15))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if let arrival = countdownArrival(for: direction) {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text(arrival.stopName)
                                .font(.custom("Helvetica", size: 11))
                                .lineLimit(1)
                        }
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                    }
                }
                .tag(index)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 38)
    }

    @ViewBuilder
    private var walkingDistanceLabel: some View {
        if let dist = closestStopDistance,
            dist < Double.greatestFiniteMagnitude
        {
            HStack(spacing: 3) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 9, weight: .semibold))
                Text(formatDistanceImperial(dist))
                    .font(.custom("Helvetica-Bold", size: 11))
            }
            .foregroundColor(
                isFavoritePresentation
                    ? routeColor.opacity(0.82)
                    : AppTheme.Colors.textSecondary.opacity(0.7)
            )
        }
    }

    @ViewBuilder
    private var paginationDots: some View {
        let dirCount: Int = visibleDirections.count
        if dirCount > 1 {
            HStack(spacing: 5) {
                ForEach(0..<dirCount, id: \.self) { index in
                    let isSelected: Bool = index == currentDirectionIndex
                    Capsule()
                        .fill(
                            isSelected
                                ? routeColor
                                : AppTheme.Colors.textSecondary.opacity(0.2)
                        )
                        .frame(width: isSelected ? 14 : 6, height: 6)
                        .animation(
                            .spring(response: 0.35, dampingFraction: 0.8),
                            value: currentDirectionIndex)
                        .onTapGesture {
                            HapticManager.impact(.light)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                currentDirectionIndex = index
                            }
                        }
                }
            }
            .padding(.top, 1)
        }
    }

    @ViewBuilder
    private var alertBannerRow: some View {
        if let topAlert = group.alerts.first {
            let severityColor: Color = topAlert.severity == "severe" ? AppTheme.Colors.alertRed : AppTheme.Colors.warningYellow
            let extraCount: Int = group.alerts.count - 1
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(severityColor)
                Text(topAlert.title)
                    .font(.custom("Helvetica", size: 11))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                Spacer()
                if extraCount > 0 {
                    Text("+\(extraCount)")
                        .font(.custom("Helvetica-Bold", size: 10))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.bottom, isFavoritePresentation ? 10 : 6)
        }
    }



    // MARK: - Tracking Trigger

    /// Called when the long-press completes — triggers tracking and shows banner.
    private func triggerTracking() {
        HapticManager.notification(.success)
        onTrack?(originalDirectionIndex)

        // Build banner text from current direction
        let dir = currentDirection
        let destination = dir.directionLabel
            ?? dir.liveArrivals.first?.destination
            ?? dir.direction
        trackingBannerText = "Now tracking \(group.displayName) → \(destination)"

        // Pop in
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7, blendDuration: 0)) {
            showTrackingBanner = true
        }

        // Auto-dismiss after 2.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.35)) {
                showTrackingBanner = false
            }
        }
    }

    // MARK: - Tracking Confirmation Banner

    /// Compact pill banner that slides in from the top to confirm tracking.
    private var trackingConfirmationBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            Text(trackingBannerText)
                .font(.custom("Helvetica-Bold", size: 12))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(AppTheme.Gradients.accent)
                .shadow(color: AppTheme.Colors.accentGlow.opacity(0.55), radius: 12, x: 0, y: 4)
        )
    }

    // MARK: - Countdown View

    /// Shows the arrival countdown, scheduled time, or empty state
    /// depending on data availability.
    @ViewBuilder
    private var countdownView: some View {
        let dir = currentDirection

        // Prefer the first live (non-placeholder) arrival for the countdown.
        // If only placeholders exist, show "Sched" indicator instead of fake times.
        let liveFirst = dir.liveArrivals.first
        let hasOnlyPlaceholders = liveFirst == nil && !dir.arrivals.isEmpty

        let countdownFirst = countdownArrival(for: dir)

        if let first = countdownFirst {
            // ── Live data — smart countdown using ArrivalETAEngine ──
            VStack(spacing: 2) {
                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    let eta = resolvedETA(for: first)

                    // Same isPastArrival guard that RouteDetailSheet uses in its
                    // TimelineView — prevents the row showing a ghost "Now" for
                    // a bus that already left while the sheet has already removed
                    // its chip.  Without this, the 90s liveArrivals window and
                    // the real-time isPastArrival check were out of sync.
                    if eta.isPastArrival {
                        // Bus departed — show "--" until the next backend poll
                        // replaces this arrival with a newer one.
                        Text("--")
                            .font(.custom("Helvetica-Bold", size: 20))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                    } else {
                        let mins = eta.minutesRemaining
                        let isNow = eta.isAtStop || eta.secondsRemaining <= 30
                        let isSched = first.status == "Scheduled"

                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(isNow ? "Now" : "\(mins)")
                                .font(.custom("Helvetica-Bold", size: isNow ? 20 : 26))
                                .foregroundColor(isSched ? AppTheme.Colors.textSecondary.opacity(0.45) : AppTheme.Colors.countdown(mins))
                                .contentTransition(.numericText())

                            if !isNow {
                                Text("min")
                                    .font(.custom("Helvetica", size: 12))
                                    .foregroundColor(isSched ? AppTheme.Colors.textSecondary.opacity(0.35) : AppTheme.Colors.textSecondary)
                            }
                        }
                    }
                }
                statusPill(for: first)
            }
        } else if hasOnlyPlaceholders {
            // Direction exists but only has scheduled/placeholder arrivals.
            // Delegate to ArrivalHelpers — single source of truth for
            // scheduled ETA resolution (uses arrivalTs, not stale minutesAway).
            let soonestScheduled = ArrivalHelpers.soonestScheduledMinutes(
                for: dir, provider: smartETAProvider
            )
            if let mins = soonestScheduled {
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(mins)")
                            .font(.custom("Helvetica-Bold", size: 26))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.45))
                            .contentTransition(.numericText())
                        Text("min")
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.35))
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 7, weight: .bold))
                        Text("Sched")
                            .font(.custom("Helvetica-Bold", size: 9))
                    }
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppTheme.Colors.textSecondary.opacity(0.08))
                    .clipShape(Capsule())
                }
            } else {
                VStack(spacing: 3) {
                    Text("No Service")
                        .font(.custom("Helvetica-Bold", size: 10))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                }
            }
        } else {
            // No arrivals at all
            Text("--")
                .font(.custom("Helvetica-Bold", size: 20))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
        }
    }

    /// Compact status pill below the countdown number.
    ///
    /// Uses `isRealTime` (backend-authoritative) as the single source of truth
    /// for live vs scheduled.  Previous logic required `status` to contain
    /// "on time" / "good" — which never matched SIRI bus `PresentableDistance`
    /// strings like "< 1 stop away" or "En Route", leaving those rows with
    /// **no pill at all**.
    @ViewBuilder
    private func statusPill(for arrival: NearbyTransitResponse) -> some View {
        let status = arrival.status.lowercased()
        let isDelayed = status.contains("delay")

        if arrival.isCancelled {
            Text("Cancelled")
                .font(.custom("Helvetica-Bold", size: 9))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AppTheme.Colors.alertRed)
                .clipShape(Capsule())
        } else if isDelayed {
            Text("Delayed")
                .font(.custom("Helvetica-Bold", size: 9))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AppTheme.Colors.alertRed)
                .clipShape(Capsule())
        } else if arrival.isRealTime {
            // Live real-time arrival (SIRI, GTFS-RT, OBA) — green "Live" pill.
            // Covers subway "On Time", bus "< 1 stop away", rail "On Time", etc.
            HStack(spacing: 3) {
                Circle()
                    .fill(AppTheme.Colors.successGreen)
                    .frame(width: 5, height: 5)
                Text("Live")
                    .font(.custom("Helvetica-Bold", size: 9))
                    .foregroundColor(AppTheme.Colors.successGreen)
            }
        } else {
            // Purely static GTFS / backend-flagged as scheduled
            HStack(spacing: 2) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 7, weight: .bold))
                Text("Sched")
                    .font(.custom("Helvetica-Bold", size: 9))
            }
            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppTheme.Colors.textSecondary.opacity(0.08))
            .clipShape(Capsule())
        }
    }
}
