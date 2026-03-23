//
//  NearbyTransitRow.swift
//  Track
//
//  Displays a single nearby transit arrival (bus or train) in the unified list.
//  Tapping expands the row to show arrival details, direction, and status.
//  Extracted from HomeView for reusability and to keep HomeView focused on layout.
//

import CoreLocation
import SwiftUI

struct NearbyTransitRow: View {
    let arrival: NearbyTransitResponse
    var isTracking: Bool = false
    /// True when the user is tracking a DIFFERENT route — shows "Switch" instead of "Track".
    var isTrackingAnother: Bool = false
    var isSelected: Bool = false  // Added for stop selection
    /// Whether this arrival has a live vehicle on the map (bus GPS or train GTFS-RT).
    var isLiveOnMap: Bool = false
    /// Vehicle ID tapped on the map marker. When it matches this arrival's
    /// `vehicleId` or `tripId`, the row auto-expands and highlights.
    var tappedVehicleId: String? = nil
    var onTrack: (() -> Void)?
    var onSelectRoute: (() -> Void)?
    /// Callback to clear the map highlight when the user taps a highlighted row.
    var onClearHighlight: (() -> Void)?
    /// Callback when the row expands — passes the vehicle key so the map
    /// can highlight the corresponding marker without starting full tracking.
    var onFocusVehicle: ((String?) -> Void)?
    var userLocation: CLLocation?
    /// Optional smart ETA provider — when set, uses vehicle-position-aware
    /// countdown instead of raw arrivalTs. Provided by the parent ViewModel.
    var smartETAProvider: ((NearbyTransitResponse) -> SmartETA)? = nil

    // Hoisted state
    var isExpanded: Bool
    var onExpand: (() -> Void)?

    /// Whether this row's arrival matches the vehicle tapped on the map.
    private var isMapHighlighted: Bool {
        guard let tapped = tappedVehicleId, !tapped.isEmpty else { return false }
        if let vid = arrival.vehicleId, vid == tapped { return true }
        if let tid = arrival.tripId, tid == tapped { return true }
        return false
    }

    private var rowBackgroundColor: Color {
        if isMapHighlighted { return AppTheme.Colors.mtaBlue.opacity(0.15) }
        if isSelected { return AppTheme.Colors.mtaBlue.opacity(0.1) }
        return AppTheme.Colors.cardBackground
    }

    private var rowBorderColor: Color {
        if isMapHighlighted { return AppTheme.Colors.mtaBlue }
        if isSelected { return AppTheme.Colors.mtaBlue }
        return Color.clear
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                leftBadgeAndInfo

                Spacer(minLength: 8)

                // MARK: Right Side (Time + Status)
                rightSideContent
            }
            .padding(.vertical, 16)
            .padding(.horizontal, AppTheme.Layout.margin)
            .background(rowBackgroundColor)
            .cornerRadius(AppTheme.Layout.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius)
                    .stroke(rowBorderColor, lineWidth: isMapHighlighted ? 2.5 : 2)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // If map highlight is active, clear it first
                if isMapHighlighted {
                    onClearHighlight?()
                } else {
                    // Toggle expansion via parent callback
                    onExpand?()
                }
            }

            // Expanded detail section
            if isExpanded {
                expandedDetailSection
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel({
            let eta = resolvedETA(for: arrival)
            let timeText = eta.isAtStop ? "arriving now" : "\(eta.minutesRemaining) minutes away"
            return "\(arrival.isBus ? "Bus" : "Train") \(arrival.displayName), \(arrival.stopName), \(timeText)"
        }())
        .accessibilityHint(
            isExpanded ? "Expanded. Shows arrival details." : "Tap to see arrival details")
    }

    // MARK: - Expanded Detail Section

    private var expandedDetailSection: some View {
        let trackIcon: String = isTracking
            ? "antenna.radiowaves.left.and.right"
            : isTrackingAnother
                ? "arrow.triangle.2.circlepath" : "location.fill"
        let trackLabel: String = isTracking
            ? "Tracking"
            : isTrackingAnother
                ? "Switch to This" : "Track Live Route"
        let trackBg: Color = isTracking
            ? AppTheme.Colors.successGreen
            : isTrackingAnother
                ? AppTheme.Colors.warningYellow
                : AppTheme.Colors.mtaBlue

        return VStack(alignment: .leading, spacing: 8) {
            Divider()

            // Next arrival details
            expandedArrivalDetail

            // Direction info
            HStack(spacing: 10) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Direction")
                        .font(.custom("Helvetica-Bold", size: 11))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .textCase(.uppercase)
                    Text(arrival.direction)
                        .font(.custom("Helvetica", size: 14))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                }
            }

            // Track button
            Button {
                onTrack?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: trackIcon)
                        .font(.system(size: 12, weight: .bold))
                    Text(trackLabel)
                        .font(.custom("Helvetica-Bold", size: 13))
                }
                .foregroundColor(AppTheme.Colors.textOnColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(trackBg)
                .cornerRadius(AppTheme.Layout.cornerRadius)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var expandedArrivalDetail: some View {
        HStack(spacing: 10) {
            Image(systemName: arrival.isBus ? "bus.fill" : "tram.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.Colors.mtaBlue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Next Arrival")
                    .font(.custom("Helvetica-Bold", size: 11))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                // Smart ETA for expanded detail — consistent with main countdown
                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    let eta: SmartETA = resolvedETA(for: arrival)
                    let mins: Int = eta.minutesRemaining
                    let isNow: Bool = eta.isAtStop || eta.secondsRemaining <= 30
                    let timeStr: String = {
                        if let ts = arrival.arrivalTs {
                            return Date(timeIntervalSince1970: Double(ts))
                                .formatted(date: .omitted, time: .shortened)
                        }
                        return ""
                    }()
                    Text(isNow || mins <= 0
                        ? "Arriving now"
                        : "In \(mins) min" + (timeStr.isEmpty ? "" : " — \(timeStr)"))
                        .font(.custom("Helvetica-Bold", size: 14))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                }
            }

            Spacer()

            // Status pill
            Text(arrival.status)
                .font(.custom("Helvetica-Bold", size: 11))
                .foregroundColor(AppTheme.Colors.textOnColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(transitStatusColor(for: arrival.status))
                .clipShape(Capsule())
        }
    }

    // MARK: - Left Side (Badge + Station Info)

    private var leftBadgeAndInfo: some View {
        HStack(spacing: 14) {
            RouteBadge(
                routeID: arrival.displayName,
                size: .custom(54, 22),
                isBus: arrival.isBus,
                mode: arrival.mode
            )
            .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(arrival.stopName)
                    .font(.custom("Helvetica-Bold", size: 17))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textSecondary)

                    Text(shortDirectionLabel(arrival.destination ?? arrival.direction))
                        .font(.custom("Helvetica-Bold", size: 14))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }

                distanceOrModeLabel
            }
        }
    }

    @ViewBuilder
    private var distanceOrModeLabel: some View {
        if let stopLat: Double = arrival.stopLat, let stopLon: Double = arrival.stopLon {
            if let userLocation: CLLocation = userLocation {
                let stopLoc: CLLocation = CLLocation(latitude: stopLat, longitude: stopLon)
                let distance: Double = userLocation.distance(from: stopLoc)
                HStack(spacing: 4) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 10, weight: .medium))
                    Text(formatDistance(distance))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.8))
            }
        } else {
            let modeLabel: String = arrival.isLIRR
                ? "LIRR"
                : arrival.isMNR ? "Metro-North" : arrival.isBus ? "Bus" : "Subway"
            Text(modeLabel)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
        }
    }

    // MARK: - Right Side Content (extracted to reduce body type-check)

    private var rightSideContent: some View {
        VStack(alignment: .trailing, spacing: 6) {
            countdownContent
            statusPillContent
            liveIndicatorContent
        }
    }

    @ViewBuilder
    private var countdownContent: some View {
        if arrival.isPlaceholder {
            Image(systemName: "clock")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
        } else {
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                let eta: SmartETA = resolvedETA(for: arrival)
                let mins: Int = eta.minutesRemaining
                let isNow: Bool = !arrival.isScheduledOnly
                    && (eta.isAtStop || eta.secondsRemaining <= 30)
                let countdownColor: Color = arrival.isScheduledOnly
                    ? AppTheme.Colors.textSecondary.opacity(0.55)
                    : AppTheme.Colors.countdown(mins)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(isNow ? "Now" : "\(mins)")
                        .font(.custom("Helvetica-Bold", size: isNow ? 22 : 32))
                        .foregroundColor(countdownColor)

                    if !isNow {
                        Text("min")
                            .font(.custom("Helvetica-Bold", size: 13))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .offset(y: -2)
                    }
                }
            }
        }
    }

    private var statusPillContent: some View {
        let pillColor: Color = arrival.isCancelled
            ? AppTheme.Colors.alertRed
            : transitStatusColor(for: arrival.status)
        let label = arrival.isCancelled ? "CANCELLED" : arrival.status
        return HStack(spacing: 4) {
            Circle()
                .fill(pillColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.custom("Helvetica-Bold", size: 11))
                .textCase(.uppercase)
        }
        .foregroundColor(pillColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(pillColor.opacity(0.12))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var liveIndicatorContent: some View {
        if arrival.isCancelled {
            cancelledPill
        } else if isLiveOnMap && !arrival.isScheduledOnly {
            liveOnMapPill
        } else if arrival.isScheduledOnly {
            scheduledPill
        } else if let ts = arrival.arrivalTs {
            arrivalTimePill(ts: ts)
        } else if arrival.vehicleId != nil || arrival.tripId != nil {
            enRoutePill
        } else {
            scheduledPill
        }
    }

    private var liveOnMapPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(AppTheme.Colors.successGreen)
                .frame(width: 5, height: 5)
                .shadow(color: AppTheme.Colors.successGreen.opacity(0.6), radius: 3)
            Text("In Route")
                .font(.custom("Helvetica-Bold", size: 9))
                .textCase(.uppercase)
        }
        .foregroundColor(AppTheme.Colors.successGreen)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(AppTheme.Colors.successGreen.opacity(0.1))
        .clipShape(Capsule())
        .onTapGesture {
            let key: String? = arrival.vehicleId ?? arrival.tripId
            onFocusVehicle?(key)
        }
    }

    private var scheduledPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 8, weight: .semibold))
            Text("Scheduled")
                .font(.custom("Helvetica-Bold", size: 9))
                .textCase(.uppercase)
        }
        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(AppTheme.Colors.textSecondary.opacity(0.06))
        .clipShape(Capsule())
    }

    private func arrivalTimePill(ts: Int) -> some View {
        let arrivalDate: Date = Date(timeIntervalSince1970: Double(ts))
        return HStack(spacing: 4) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 8, weight: .semibold))
            Text(arrivalDate, style: .time)
                .font(.custom("Helvetica-Bold", size: 9))
        }
        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(AppTheme.Colors.textSecondary.opacity(0.08))
        .clipShape(Capsule())
    }

    private var enRoutePill: some View {
        HStack(spacing: 4) {
            Image(systemName: "bus.fill")
                .font(.system(size: 8, weight: .semibold))
            Text("En Route")
                .font(.custom("Helvetica-Bold", size: 9))
                .textCase(.uppercase)
        }
        .foregroundColor(AppTheme.Colors.mtaBlue.opacity(0.7))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(AppTheme.Colors.mtaBlue.opacity(0.08))
        .clipShape(Capsule())
    }

    private var cancelledPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 8, weight: .semibold))
            Text("Cancelled")
                .font(.custom("Helvetica-Bold", size: 9))
                .textCase(.uppercase)
        }
        .foregroundColor(AppTheme.Colors.alertRed)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(AppTheme.Colors.alertRed.opacity(0.1))
        .clipShape(Capsule())
    }

    // MARK: - Helper Functions

    /// Formats walking distance to the stop.
    private func formatDistance(_ meters: Double) -> String {
        formatWalkingDistance(meters)
    }

    /// Resolves the best available ETA for an arrival.
    /// Delegates to `ArrivalHelpers.resolvedETA` — single source of truth.
    private func resolvedETA(for arrival: NearbyTransitResponse) -> SmartETA {
        ArrivalHelpers.resolvedETA(for: arrival, provider: smartETAProvider)
    }
}
