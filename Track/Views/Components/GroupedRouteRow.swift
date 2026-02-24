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

    /// Currently visible direction (clamped to bounds).
    private var currentDirection: DirectionArrivalsResponse {
        guard !group.directions.isEmpty else {
            return DirectionArrivalsResponse(direction: "—", arrivals: [])
        }
        return group.directions[min(currentDirectionIndex, group.directions.count - 1)]
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
            if group.directions.isEmpty {
                Text("No active service")
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    TabView(selection: $currentDirectionIndex) {
                        ForEach(Array(group.directions.enumerated()), id: \.element.id) {
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

                                // Station name + walking distance
                                HStack(spacing: 4) {
                                    // Show terminus so users know which direction this is
                                    let terminus =
                                        direction.directionLabel
                                        ?? direction.direction
                                    // Avoid repeating the main label above
                                    if !terminus.isEmpty,
                                        terminus.lowercased() != label.lowercased()
                                    {
                                        Text("To \(terminus)")
                                            .font(.custom("Helvetica", size: 12))
                                            .foregroundColor(AppTheme.Colors.textSecondary)
                                            .lineLimit(1)
                                    }

                                    if let dist = closestStopDistance,
                                        dist < Double.greatestFiniteMagnitude
                                    {
                                        HStack(spacing: 2) {
                                            Image(systemName: "figure.walk")
                                                .font(.system(size: 9, weight: .medium))
                                            Text(formatDistanceImperial(dist))
                                                .font(.custom("Helvetica", size: 11))
                                        }
                                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                                    }
                                }
                            }
                            .tag(index)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 38)

                    // Pagination dots
                    if group.directions.count > 1 {
                        HStack(spacing: 4) {
                            ForEach(0..<group.directions.count, id: \.self) { index in
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
                .frame(height: 50)
            }

            Spacer(minLength: 4)

            // ── Countdown / Scheduled Time ──
            if !group.directions.isEmpty {
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
            onSelect?(currentDirectionIndex)
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
        onTrack?(currentDirectionIndex)

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

        if let first = liveFirst {
            // ── Live data — smart countdown using ArrivalETAEngine ──
            VStack(spacing: 2) {
                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    let eta = ArrivalETAEngine.computeETA(
                        vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
                        arrivalTs: first.arrivalTs,
                        staticMinutes: first.minutesAway,
                        mode: first.mode)
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
            // Direction exists but only has backend placeholder arrivals
            VStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                Text("Sched")
                    .font(.custom("Helvetica-Bold", size: 9))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
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
