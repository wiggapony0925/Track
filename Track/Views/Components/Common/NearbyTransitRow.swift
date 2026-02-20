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
    /// Optional pre-resolved ETA context (vehicle coord, stop coord, polyline).
    /// When set, this takes priority over the bare `smartETAProvider` closure,
    /// giving any call site vehicle-position awareness without a full closure.
    var etaContext: ETAContext? = nil

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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // MARK: Route Badge (Larger & More Prominent)
                RouteBadge(
                    routeID: arrival.displayName,
                    size: .custom(54, 22),
                    isBus: arrival.isBus,
                    mode: arrival.mode
                )
                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
                .accessibilityHidden(true)

                // MARK: Station & Destination Info
                VStack(alignment: .leading, spacing: 4) {
                    // Station name
                    Text(arrival.stopName)
                        .font(.custom("Helvetica-Bold", size: 17))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    // Direction with arrow
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textSecondary)

                        Text(shortDirectionLabel(arrival.destination ?? arrival.direction))
                            .font(.custom("Helvetica-Bold", size: 14))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }

                    // Distance (if available) or mode type
                    if let stopLat = arrival.stopLat, let stopLon = arrival.stopLon {
                        if let userLocation = userLocation {
                            let distance = userLocation.distance(
                                from: CLLocation(latitude: stopLat, longitude: stopLon)
                            )
                            HStack(spacing: 4) {
                                Image(systemName: "figure.walk")
                                    .font(.system(size: 10, weight: .medium))
                                Text(formatDistance(distance))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.8))
                        }
                    } else {
                        Text(
                            arrival.isLIRR
                                ? "LIRR"
                                : arrival.isMNR ? "Metro-North" : arrival.isBus ? "Bus" : "Subway"
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                    }
                }

                Spacer(minLength: 8)

                // MARK: Right Side (Time + Status)
                VStack(alignment: .trailing, spacing: 6) {
                    // Minutes countdown
                    if arrival.isPlaceholder {
                        // Backend backfill placeholder — should not normally
                        // render (filtered by RouteDetailSheet) but guard
                        // against it leaking through.
                        Image(systemName: "clock")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                    } else {
                        // Smart countdown: uses vehicle position + polyline when
                        // a provider or etaContext is set, falls back to arrivalTs → static minutesAway.
                        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                            let eta: SmartETA = resolvedETA(for: arrival)
                            let mins = eta.minutesRemaining
                            let isNow = eta.isAtStop || eta.secondsRemaining <= 30

                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(isNow ? "Now" : "\(mins)")
                                    .font(.custom("Helvetica-Bold", size: isNow ? 22 : 32))
                                    .foregroundColor(AppTheme.Colors.countdown(mins))

                                if !isNow {
                                    Text("min")
                                        .font(.custom("Helvetica-Bold", size: 13))
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                        .offset(y: -2)
                                }
                            }
                        }
                    }

                    // Status pill
                    HStack(spacing: 4) {
                        Circle()
                            .fill(transitStatusColor(for: arrival.status))
                            .frame(width: 6, height: 6)

                        Text(arrival.status)
                            .font(.custom("Helvetica-Bold", size: 11))
                            .textCase(.uppercase)
                    }
                    .foregroundColor(transitStatusColor(for: arrival.status))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(transitStatusColor(for: arrival.status).opacity(0.12))
                    .clipShape(Capsule())

                    // "In Route" live indicator — shows when this vehicle
                    // has a live GPS/GTFS-RT position on the map.
                    // Tapping it focuses the map on this vehicle's marker.
                    if isLiveOnMap {
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
                            let key = arrival.vehicleId ?? arrival.tripId
                            onFocusVehicle?(key)
                        }
                    } else {
                        // Vehicle is NOT live on the map (no GPS marker matched).
                        if let ts = arrival.arrivalTs {
                            // Has an arrival timestamp — show the clock time.
                            let arrivalDate = Date(timeIntervalSince1970: Double(ts))
                            HStack(spacing: 4) {
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
                        } else if arrival.vehicleId != nil || arrival.tripId != nil {
                            // Real GTFS-RT arrival (has vehicleId/tripId) but no
                            // arrivalTs and no live marker on the map yet.
                            // This is NOT a schedule-only row — the feed confirms
                            // a vehicle exists; it just lacks a precise ETA or GPS.
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
                        } else {
                            // Truly static / schedule-only arrival — no vehicle
                            // or trip info from any real-time feed.
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
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
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, AppTheme.Layout.margin)
            .background(
                isMapHighlighted
                    ? AppTheme.Colors.mtaBlue.opacity(0.15)
                    : isSelected
                        ? AppTheme.Colors.mtaBlue.opacity(0.1) : AppTheme.Colors.cardBackground
            )
            .cornerRadius(AppTheme.Layout.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius)
                    .stroke(
                        isMapHighlighted
                            ? AppTheme.Colors.mtaBlue
                            : isSelected ? AppTheme.Colors.mtaBlue : Color.clear,
                        lineWidth: isMapHighlighted ? 2.5 : 2)
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
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    // Next arrival details
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
                                let mins = eta.minutesRemaining
                                let isNow = eta.isAtStop || eta.secondsRemaining <= 30
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
                            Image(
                                systemName: isTracking
                                    ? "antenna.radiowaves.left.and.right"
                                    : "location.fill"
                            )
                            .font(.system(size: 12, weight: .bold))
                            Text(
                                isTracking
                                    ? "Tracking"
                                    : "Track Live Route"
                            )
                            .font(.custom("Helvetica-Bold", size: 13))
                        }
                        .foregroundColor(AppTheme.Colors.textOnColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            isTracking ? AppTheme.Colors.successGreen : AppTheme.Colors.mtaBlue
                        )
                        .cornerRadius(AppTheme.Layout.cornerRadius)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(arrival.isBus ? "Bus" : "Train") \(arrival.displayName), \(arrival.stopName), \(arrival.minutesAway) minutes away"
        )
        .accessibilityHint(
            isExpanded ? "Expanded. Shows arrival details." : "Tap to see arrival details")
    }

    // MARK: - Helper Functions

    /// Formats walking distance to the stop.
    private func formatDistance(_ meters: Double) -> String {
        formatWalkingDistance(meters)
    }

    /// Resolves the best available ETA for an arrival:
    /// 1. etaContext (explicit vehicle coord + stop + polyline)
    /// 2. smartETAProvider closure
    /// 3. ArrivalETAEngine with arrivalTs / staticMinutes only
    private func resolvedETA(for arrival: NearbyTransitResponse) -> SmartETA {
        if let ctx = etaContext {
            return ArrivalETAEngine.computeETA(
                vehicleCoord: ctx.vehicleCoord,
                vehicleKey: ctx.vehicleKey,
                stopCoord: ctx.stopCoord,
                polyline: ctx.polyline,
                arrivalTs: arrival.arrivalTs,
                staticMinutes: arrival.minutesAway,
                mode: arrival.mode)
        }
        return smartETAProvider?(arrival)
            ?? ArrivalETAEngine.computeETA(
                vehicleCoord: nil, vehicleKey: nil, stopCoord: nil,
                arrivalTs: arrival.arrivalTs,
                staticMinutes: arrival.minutesAway,
                mode: arrival.mode)
    }
}
