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

struct GroupedRouteRow: View {
    let group: GroupedNearbyTransitResponse
    var hasAlert: Bool = false
    var userLocation: CLLocation? = nil
    var distanceMetersOverride: Double? = nil
    var smartETAProvider: ((NearbyTransitResponse) -> SmartETA)? = nil
    var initialDirectionIndex: Int = 0
    var onDirectionChanged: ((Int) -> Void)? = nil
    var onSelect: ((Int) -> Void)? = nil
    var onTrack: ((Int) -> Void)? = nil

    @State private var currentDirectionIndex = 0
    @State private var swipeOffset: CGFloat = 0
    @State private var showTrackingBanner = false
    @State private var trackingBannerText = ""

    /// Locks to horizontal once the initial drag direction is determined.
    /// Prevents vertical scroll from accidentally triggering the swipe action.
    @State private var swipeLocked = false
    @State private var swipeDirectionDecided = false

    /// How far right the user must drag to trigger tracking.
    private let swipeThreshold: CGFloat = 80

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
        if group.isBus && group.directions.count == 2 {
            return group.directions
        }
        let real = group.directions.filter { dir in
            // Keep if it has at least one live (non-placeholder) arrival
            if !dir.liveArrivals.isEmpty { return true }
            // Keep if the direction isn't a backend "Opposite" placeholder
            if dir.direction.lowercased() != "opposite" { return true }
            // Drop: "Opposite" direction with no live arrivals
            return false
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

    /// Returns the countdown arrival for a direction, preferring the user's
    /// nearest stop so the card aligns with the route detail sheet.
    ///
    /// Distance resolution priority (mirrors `RouteDetailSheet.nearestStopArrivals`):
    ///  1. `distanceM` — server-side haversine, most accurate.
    ///  2. `stopLat`/`stopLon` — client-side CLLocation distance.
    ///  3. No coordinates at all → treat distance as ∞ (still participates,
    ///     never silently skipped so the fallback stays deterministic).
    private func countdownArrival(for direction: DirectionArrivalsResponse) -> NearbyTransitResponse? {
        let live = direction.liveArrivals
        guard !live.isEmpty else { return nil }

        if let loc = userLocation {
            var nearestStopKey: String?
            var nearestDistance: CLLocationDistance = .greatestFiniteMagnitude

            for arrival in live {
                // Prefer server-side pre-computed distance (most accurate)
                let dist: CLLocationDistance
                if let dm = arrival.distanceM {
                    dist = dm
                } else if let lat = arrival.stopLat, let lon = arrival.stopLon {
                    dist = loc.distance(from: CLLocation(latitude: lat, longitude: lon))
                } else {
                    // No coordinates available — assign max distance so coordinate-rich
                    // arrivals always win, but this arrival still participates in the loop
                    // (no silent skip that could cause row ↔ detail mismatches).
                    dist = .greatestFiniteMagnitude
                }
                if dist < nearestDistance {
                    nearestDistance = dist
                    nearestStopKey = arrival.stopId ?? arrival.stopName
                }
            }

            if let key = nearestStopKey {
                let atNearestStop = live.filter { ($0.stopId ?? $0.stopName) == key }
                if let first = sortedByETA(atNearestStop).first { return first }
            }
        }

        return sortedByETA(live).first
    }

    private func sortedByETA(_ arrivals: [NearbyTransitResponse]) -> [NearbyTransitResponse] {
        arrivals.sorted { lhs, rhs in
            let left = resolvedETA(for: lhs).secondsRemaining
            let right = resolvedETA(for: rhs).secondsRemaining
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    private func resolvedETA(for arrival: NearbyTransitResponse) -> SmartETA {
        smartETAProvider?(arrival)
            ?? ArrivalETAEngine.computeETA(
                vehicleCoord: nil,
                vehicleKey: nil,
                stopCoord: nil,
                arrivalTs: arrival.arrivalTs,
                staticMinutes: arrival.minutesAway,
                mode: arrival.mode
            )
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // ── Swipe-to-track background (only visible during swipe) ──
            if swipeOffset > 0 {
                swipeTrackBackground
                    .transition(.opacity)
            }

            // ── Main row content ──
            mainRowContent
                .offset(x: swipeOffset)
                .simultaneousGesture(swipeToTrackGesture)
        }
        .clipped()
        .overlay(alignment: .top) {
            // ── "Now tracking" confirmation banner ──
            if showTrackingBanner {
                trackingConfirmationBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
    }

    // MARK: - Main Row Content

    private var mainRowContent: some View {
        HStack(spacing: 14) {
            // ── Route Badge ──
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

            // ── Destination + Station info ──
            if visibleDirections.isEmpty {
                Text("No active service")
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    TabView(selection: $currentDirectionIndex) {
                        ForEach(Array(visibleDirections.enumerated()), id: \.element.id) {
                            index, direction in
                            let label =
                                direction.liveArrivals.first?.destination
                                ?? direction.arrivals.first?.destination
                                ?? direction.directionLabel
                                ?? directionLabel(direction.direction)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label)
                                    .font(.custom("Helvetica-Bold", size: 15))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)

                                // Direction terminus (when different from
                                // the main destination label above)
                                let terminus =
                                    direction.directionLabel
                                    ?? direction.direction
                                if !terminus.isEmpty,
                                    terminus.lowercased() != label.lowercased()
                                {
                                    Text("To \(terminus)")
                                        .font(.custom("Helvetica", size: 12))
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                        .lineLimit(1)
                                }

                                // Walking distance — below the direction text
                                if let dist = closestStopDistance,
                                    dist < Double.greatestFiniteMagnitude
                                {
                                    HStack(spacing: 3) {
                                        Image(systemName: "figure.walk")
                                            .font(.system(size: 9, weight: .semibold))
                                        Text(formatDistanceImperial(dist))
                                            .font(.custom("Helvetica-Bold", size: 11))
                                    }
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                                }
                            }
                            .tag(index)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 50)

                    // Pagination dots
                    if visibleDirections.count > 1 {
                        HStack(spacing: 4) {
                            ForEach(0..<visibleDirections.count, id: \.self) { index in
                                Capsule()
                                    .fill(
                                        index == currentDirectionIndex
                                            ? routeColor
                                            : AppTheme.Colors.textSecondary.opacity(0.2)
                                    )
                                    .frame(
                                        width: index == currentDirectionIndex ? 12 : 5, height: 5
                                    )
                                    .animation(
                                        .spring(response: 0.35, dampingFraction: 0.8),
                                        value: currentDirectionIndex)
                            }
                        }
                    }
                }
                .frame(height: 60)
            }

            Spacer(minLength: 4)

            // ── Countdown / Scheduled Time ──
            if !visibleDirections.isEmpty {
                countdownView
            }

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, AppTheme.Layout.margin)
        .background(AppTheme.Colors.cardBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            HapticManager.selection()
            onSelect?(originalDirectionIndex)
        }
        .onAppear {
            // Restore previously swiped direction for this route row.
            let restoredVisible = visibleIndex(forOriginal: initialDirectionIndex)
            if restoredVisible != currentDirectionIndex {
                currentDirectionIndex = restoredVisible
            }
        }
        .onChange(of: initialDirectionIndex) { _, newValue in
            // Keep row direction in sync when parent updates preferences.
            let restoredVisible = visibleIndex(forOriginal: newValue)
            if restoredVisible != currentDirectionIndex {
                currentDirectionIndex = restoredVisible
            }
        }
        .onChange(of: currentDirectionIndex) { _, _ in
            // Persist user's swipe choice using original group index.
            onDirectionChanged?(originalDirectionIndex)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(group.isLIRR ? "LIRR" : group.isMNR ? "Metro-North" : group.isBus ? "Bus" : "Train") \(group.displayName), swipe for directions"
        )
        .accessibilityHint("Double tap to see details. Swipe right to track.")
        .accessibilityAction(named: "Track this route") {
            triggerTracking()
        }
    }

    // MARK: - Swipe-to-Track Background

    /// Blue background with bell icon revealed when the user swipes right.
    private var swipeTrackBackground: some View {
        HStack {
            VStack(spacing: 4) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                Text("Track")
                    .font(.custom("Helvetica-Bold", size: 10))
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(width: swipeThreshold)
            .opacity(min(1.0, swipeOffset / swipeThreshold))
            .scaleEffect(min(1.0, swipeOffset / swipeThreshold * 1.1))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.25, green: 0.58, blue: 0.96)) // Light blue
    }

    // MARK: - Swipe Gesture

    /// Drag gesture that reveals the tracking action on right-swipe.
    /// Ignores vertical drags (scrolling) by locking direction on first movement.
    private var swipeToTrackGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height

                // First significant movement — decide if this is horizontal or vertical
                if !swipeDirectionDecided {
                    // Need enough movement to decide
                    guard abs(dx) > 10 || abs(dy) > 10 else { return }
                    swipeDirectionDecided = true
                    // Lock to horizontal only when clearly swiping right (not vertical scroll)
                    swipeLocked = dx > 0 && abs(dx) > abs(dy) * 1.5
                }

                // If locked as vertical (scroll), do nothing
                guard swipeLocked else { return }

                let translation = max(0, dx)
                withAnimation(.interactiveSpring()) {
                    if translation > swipeThreshold {
                        let overShoot = translation - swipeThreshold
                        swipeOffset = swipeThreshold + overShoot * 0.3
                    } else {
                        swipeOffset = translation
                    }
                }
            }
            .onEnded { value in
                defer {
                    // Reset direction lock for next gesture
                    swipeLocked = false
                    swipeDirectionDecided = false
                }

                guard swipeLocked else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        swipeOffset = 0
                    }
                    return
                }

                if value.translation.width > swipeThreshold {
                    // ── Confirmed track! ──
                    // Quick overshoot animation then snap back
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                        swipeOffset = swipeThreshold + 20
                    }
                    // Snap back after a beat
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            swipeOffset = 0
                        }
                    }
                    triggerTracking()
                } else {
                    // Didn't reach threshold — snap back
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        swipeOffset = 0
                    }
                }
            }
    }

    // MARK: - Tracking Trigger

    /// Called when the swipe threshold is exceeded — triggers tracking and shows banner.
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
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.22, green: 0.52, blue: 0.90),
                            Color(red: 0.30, green: 0.62, blue: 1.0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(color: Color(red: 0.25, green: 0.58, blue: 0.96).opacity(0.4), radius: 10, x: 0, y: 4)
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
                    let mins = eta.minutesRemaining
                    let isNow = eta.isAtStop || eta.secondsRemaining <= 30

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(isNow ? "Now" : "\(mins)")
                            .font(.custom("Helvetica-Bold", size: isNow ? 20 : 26))
                            .foregroundColor(AppTheme.Colors.countdown(mins))
                            .contentTransition(.numericText())

                        if !isNow {
                            Text("min")
                                .font(.custom("Helvetica", size: 12))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        }
                    }
                }
                statusPill(for: first)
            }
        } else if hasOnlyPlaceholders {
            // Direction exists but only has backend placeholder arrivals.
            // Check if other directions have live data and hint to swipe.
            let otherDirectionsHaveLive = visibleDirections.contains { $0.id != dir.id && !$0.liveArrivals.isEmpty }
            VStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                Text(otherDirectionsHaveLive ? "Swipe →" : "Sched")
                    .font(.custom("Helvetica-Bold", size: 9))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(otherDirectionsHaveLive ? 0.6 : 0.4))
            }
        } else {
            // No arrivals at all
            Text("--")
                .font(.custom("Helvetica-Bold", size: 20))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
        }
    }

    /// Compact status pill below the countdown number.
    @ViewBuilder
    private func statusPill(for arrival: NearbyTransitResponse) -> some View {
        let status = arrival.status.lowercased()
        let isOnTime = status.contains("on time") || status.contains("good")
        let isDelayed = status.contains("delay")

        if isDelayed {
            Text("Delayed")
                .font(.custom("Helvetica-Bold", size: 9))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AppTheme.Colors.alertRed)
                .clipShape(Capsule())
        } else if arrival.status == "Scheduled" {
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
        } else if isOnTime {
            // Only show for non-obvious states — "On Time" is the default, keep it minimal
            Circle()
                .fill(AppTheme.Colors.successGreen)
                .frame(width: 6, height: 6)
        }
    }
}
