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
    var onAlertTapped: (() -> Void)? = nil
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
        isFavoritePresentation ? 26 : 24
    }

    private var rowHorizontalPadding: CGFloat {
        isFavoritePresentation ? 18 : 18
    }

    private var rowVerticalPadding: CGFloat {
        isFavoritePresentation ? 18 : 16
    }

    /// Distance from user to the closest stop in this group (meters).
    private var closestStopDistance: Double? {
        if let distanceMetersOverride { return distanceMetersOverride }
        guard let loc = userLocation else { return nil }
        return groupMinDistance(for: group, from: loc)
    }

    /// Directions that have real data — filters out backend placeholder-only tabs
    /// (e.g., Phase C "Opposite Direction" with no live arrivals and all
    /// placeholder minutesAway ≥ 99) **and** directions whose real arrivals
    /// have ALL expired (arrivalTs > 90 s in the past).  Falls back to all
    /// directions only when filtering would leave zero.
    private var visibleDirections: [DirectionArrivalsResponse] {
        let real = group.directions.filter { dir in
            // Keep if it has at least one live (non-placeholder, non-expired) arrival
            if !dir.liveArrivals.isEmpty { return true }

            // Direction had real (non-placeholder) arrivals but they ALL
            // expired (liveArrivals filtered them out) → hide it.
            // Prevents stale "--" cards when cache/SWR data ages past
            // the actual arrival time.
            if dir.arrivals.contains(where: { !$0.isPlaceholder }) {
                return false
            }

            // Drop: "Opposite" direction with no live arrivals
            if dir.direction.lowercased() == "opposite" { return false }
            // Drop compass-code placeholder directions with no live data.
            // These are backend backfill (Phase C) — e.g. "SW" opposite of
            // "EAST SIDE YORK AV CROSSTOWN" — and just show "Southwest"
            // which is unhelpful.  They'll appear once buses start running.
            if DirectionConstants.isFallbackDirection(dir.direction) { return false }
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
        shape
            .fill(AppTheme.Colors.cardBackground)
            .overlay {
                shape.fill(
                    AppTheme.Gradients.tintWash(
                        routeColor,
                        intensity: isFavoritePresentation ? 0.10 : 0.04
                    )
                )
            }
            .overlay {
                // Top-left chrome highlight for glass depth
                shape.fill(
                    LinearGradient(
                        colors: [AppTheme.Colors.glassHighlight.opacity(0.08), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
            }
            .overlay {
                shape.stroke(AppTheme.Colors.borderSubtle, lineWidth: 0.5)
            }
            .shadow(
                color: AppTheme.Colors.shadow.opacity(isFavoritePresentation ? 0.08 : 0.05),
                radius: isFavoritePresentation ? 14 : 10,
                x: 0,
                y: 5
            )
            .shadow(
                color: routeColor.opacity(isFavoritePresentation ? 0.06 : 0.03),
                radius: isFavoritePresentation ? 24 : 18,
                x: 0,
                y: 10
            )
    }

    private var mainRowAccessibilityLabel: String {
        let mode: String = group.isLIRR ? "LIRR" : group.isMNR ? "Metro-North" : group.isBus ? "Bus" : "Train"
        return "\(mode) \(group.displayName), swipe for directions"
    }

    private var mainRowHStack: some View {
        HStack(spacing: 12) {
            routeBadgeView

            if visibleDirections.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No active service")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("Check again soon for the next trip.")
                        .font(.system(size: 12, weight: .regular, design: .default))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                directionInfoColumn
            }

            Spacer(minLength: 10)

            if !visibleDirections.isEmpty {
                countdownPanel
            }
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
        .padding(.horizontal, group.isCommuterRail ? 6 : 8)
        .padding(.vertical, 8)
        .accessibilityHidden(true)
        .overlay(alignment: .topTrailing) {
            if hasAlert {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.cardBackground)
                        .frame(width: 20, height: 20)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.Colors.warningYellow)
                }
                .offset(x: 7, y: -7)
            }
        }
    }

    private var directionInfoColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            directionTabView
            HStack(spacing: 8) {
                walkingDistanceLabel
                paginationDots
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var directionTabView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Array(visibleDirections.enumerated()), id: \.element.id) { index, direction in
                    let label: String = ArrivalHelpers.resolveDirectionLabel(for: direction)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(label)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.4)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 2)

                        if let arrival = countdownArrival(for: direction) {
                            HStack(spacing: 4) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(arrival.stopName)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            .foregroundColor(AppTheme.Colors.textTertiary)
                            .padding(.top, 1)
                        }
                    }
                    .id(index) // Essential for scrollPosition binding
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .containerRelativeFrame(.horizontal) // Force full width of ScrollView
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: Binding<Int?>(
            get: { currentDirectionIndex },
            set: { if let newValue = $0 { currentDirectionIndex = newValue } }
        ))
    }

    @ViewBuilder
    private var walkingDistanceLabel: some View {
        if let dist = closestStopDistance,
            dist < Double.greatestFiniteMagnitude
        {
            HStack(spacing: 3) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 11, weight: .semibold))
                Text(formatDistanceImperial(dist))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundColor(AppTheme.Colors.textTertiary)
            .padding(.trailing, 4)
        }
    }

    @ViewBuilder
    private var paginationDots: some View {
        let dirCount: Int = visibleDirections.count
        if dirCount > 1 {
            HStack(spacing: 4) {
                ForEach(0..<dirCount, id: \.self) { index in
                    let isSelected: Bool = index == currentDirectionIndex
                    Capsule()
                        .fill(
                            isSelected
                                ? routeColor.opacity(0.9)
                                : AppTheme.Colors.textTertiary.opacity(0.20)
                        )
                        .frame(width: isSelected ? 16 : 6, height: 5)
                        .animation(
                            .spring(response: 0.3, dampingFraction: 0.8),
                            value: currentDirectionIndex)
                        .onTapGesture {
                            HapticManager.impact(.light)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                currentDirectionIndex = index
                            }
                        }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    private var countdownPanel: some View {
        VStack(alignment: .trailing, spacing: 0) {
            countdownView
        }
        .padding(.trailing, 4)
    }

    private var chevronPill: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.35))
            .padding(.trailing, 6)
    }

    @ViewBuilder
    private var alertBannerRow: some View {
        if let topAlert = group.alerts.first {
            let severityColor: Color = topAlert.severity == "severe" ? AppTheme.Colors.alertRed : AppTheme.Colors.warningYellow
            let extraCount: Int = group.alerts.count - 1
            Button {
                HapticManager.selection()
                onAlertTapped?()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(severityColor)

                    Text(topAlert.title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if extraCount > 0 {
                        Text("+\(extraCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(severityColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(severityColor.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(severityColor.opacity(0.12))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.bottom, rowVerticalPadding)
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
                .font(.system(size: 12, weight: .bold, design: .rounded))
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
            // ── Live data — smart coun
            let isSched = first.status == "Scheduled"
            
            // ETA IGLOO CARD
            VStack(alignment: .trailing, spacing: 3) {
                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    let eta = resolvedETA(for: first)

                    if eta.isPastArrival {
                        Text("--")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.4))
                    } else {
                        let mins = eta.minutesRemaining
                        let isNow = eta.isAtStop || eta.secondsRemaining <= 30

                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(isNow ? "Now" : "\(mins)")
                                .font(.system(size: isNow ? 20 : 26, weight: .heavy, design: .rounded))
                                .foregroundColor(isSched ? AppTheme.Colors.textSecondary.opacity(0.55) : AppTheme.Colors.textPrimary)
                                .contentTransition(.numericText())

                            if !isNow {
                                Text("min")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundColor(isSched ? AppTheme.Colors.textTertiary.opacity(0.5) : AppTheme.Colors.textTertiary)
                                    .padding(.leading, 1)
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
                // SCHEDULED IGLOO CARD
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(mins)")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                            .contentTransition(.numericText())
                        Text("min")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 9, weight: .bold))
                        Text("Sched")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                    }
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(AppTheme.Colors.textSecondary.opacity(0.15))
                    .clipShape(Capsule())
                }
            } else {
                VStack(spacing: 3) {
                    Text("No Service")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                }
            }
        } else {
            // No arrivals at all
            Text("--")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
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
            HStack(spacing: 3) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                Text("Cancelled")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(AppTheme.Colors.alertRed)
            .clipShape(Capsule())
        } else if isDelayed {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .bold))
                Text("Delayed")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(AppTheme.Colors.alertRed)
            .clipShape(Capsule())
        } else if arrival.isRealTime {
            // Live real-time arrival — vibrant green pill
            HStack(spacing: 3) {
                Circle()
                    .fill(.white)
                    .frame(width: 4, height: 4)
                Text("Live")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(AppTheme.Colors.successGreen)
                    .shadow(color: AppTheme.Colors.successGreen.opacity(0.3), radius: 4, x: 0, y: 1)
            }
            .clipShape(Capsule())
        } else {
            // Purely static GTFS / Scheduled — muted pill
            HStack(spacing: 3) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 8, weight: .bold))
                Text("Sched")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
            }
            .foregroundColor(AppTheme.Colors.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(AppTheme.Colors.textTertiary.opacity(0.12))
            .clipShape(Capsule())
        }
    }
}
