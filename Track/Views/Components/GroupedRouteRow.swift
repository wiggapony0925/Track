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
    var onSelect: ((Int) -> Void)? = nil

    @State private var currentDirectionIndex = 0

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
                                direction.arrivals.first?.destination
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
        .contentShape(Rectangle())
        .onTapGesture {
            HapticManager.selection()
            onSelect?(currentDirectionIndex)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(group.isLIRR ? "LIRR" : group.isMNR ? "Metro-North" : group.isBus ? "Bus" : "Train") \(group.displayName), swipe for directions"
        )
        .accessibilityHint("Double tap to see details for current direction")
    }

    // MARK: - Countdown View

    /// Shows the arrival countdown, scheduled time, or empty state
    /// depending on data availability.
    @ViewBuilder
    private var countdownView: some View {
        let dir = currentDirection

        if let first = dir.arrivals.first {
            let isPlaceholder = first.minutesAway >= 99 && first.arrivalTs == nil

            if isPlaceholder {
                // ── Scheduled but not live ──
                // Show the scheduled time greyed out instead of "No live"
                if let ts = first.arrivalTs {
                    let date = Date(timeIntervalSince1970: TimeInterval(ts))
                    let mins = max(0, Int(date.timeIntervalSinceNow / 60))
                    VStack(spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(mins)")
                                .font(.custom("Helvetica-Bold", size: 22))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                            Text("min")
                                .font(.custom("Helvetica", size: 11))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                        }
                        Text("Sched")
                            .font(.custom("Helvetica-Bold", size: 9))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.Colors.textSecondary.opacity(0.08))
                            .clipShape(Capsule())
                    }
                } else {
                    // Truly no data — minimal indicator
                    VStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                        Text("Sched")
                            .font(.custom("Helvetica-Bold", size: 9))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                    }
                }
            } else {
                // ── Live data ──
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(first.minutesAway)")
                            .font(.custom("Helvetica-Bold", size: 26))
                            .foregroundColor(AppTheme.Colors.countdown(first.minutesAway))
                            .contentTransition(.numericText())
                        Text("min")
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }

                    // Status indicator
                    statusPill(for: first)
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
