//
//  NearbyTransitRow.swift
//  Track
//
//  Displays a single nearby transit arrival (bus or train) in the unified list.
//  Tapping expands the row to show arrival details, direction, and status.
//  Extracted from HomeView for reusability and to keep HomeView focused on layout.
//

import SwiftUI
import CoreLocation

struct NearbyTransitRow: View {
    let arrival: NearbyTransitResponse
    var isTracking: Bool = false
    var isSelected: Bool = false // Added for stop selection
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
    
    @State private var isExpanded = false
    
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
                        Text(arrival.isLIRR ? "LIRR" : arrival.isMNR ? "Metro-North" : arrival.isBus ? "Bus" : "Subway")
                            .font(.system(size: 11, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                    }
                }
                
                Spacer(minLength: 8)
                
                // MARK: Right Side (Time + Status)
                VStack(alignment: .trailing, spacing: 6) {
                    // Minutes countdown
                    if let ts = arrival.arrivalTs {
                        // Live countdown using local system time vs arrival timestamp
                        TimelineView(.periodic(from: .now, by: 1.0)) { context in
                            let secondsUntil = Double(ts) - context.date.timeIntervalSince1970
                            let mins = max(0, Int(secondsUntil / 60))
                            let isNow = secondsUntil <= 30
                            
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
                    } else {
                        // Fallback to static minutesAway
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(arrival.minutesAway)")
                                .font(.custom("Helvetica-Bold", size: 32))
                                .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                            Text("min")
                                .font(.custom("Helvetica-Bold", size: 13))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .offset(y: -2)
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
                        // Show scheduled clock time when vehicle is NOT live on the map
                        // so users still see when the train/bus is expected.
                        if let ts = arrival.arrivalTs {
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
                        } else {
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
            .background(isMapHighlighted ? AppTheme.Colors.mtaBlue.opacity(0.15) : isSelected ? AppTheme.Colors.mtaBlue.opacity(0.1) : AppTheme.Colors.cardBackground)
            .cornerRadius(AppTheme.Layout.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius)
                    .stroke(isMapHighlighted ? AppTheme.Colors.mtaBlue : isSelected ? AppTheme.Colors.mtaBlue : Color.clear, lineWidth: isMapHighlighted ? 2.5 : 2)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    // If this row is map-highlighted, tapping it clears the highlight
                    // and collapses instead of toggling open again.
                    if isMapHighlighted {
                        isExpanded = false
                        onClearHighlight?()
                    } else {
                        isExpanded.toggle()
                        // When expanding, tell the map to highlight the matching marker
                        if isExpanded, isLiveOnMap {
                            let key = arrival.vehicleId ?? arrival.tripId
                            onFocusVehicle?(key)
                        } else if !isExpanded {
                            // Collapsing — clear the highlight
                            onFocusVehicle?(nil)
                        }
                    }
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
                            Text(formatArrivalTime(minutesAway: arrival.minutesAway))
                                .font(.custom("Helvetica-Bold", size: 14))
                                .foregroundColor(AppTheme.Colors.textPrimary)
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
                            Image(systemName: isTracking
                                  ? "antenna.radiowaves.left.and.right"
                                  : "location.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text(isTracking
                                 ? "Tracking"
                                 : "Track Live Route")
                                .font(.custom("Helvetica-Bold", size: 13))
                        }
                        .foregroundColor(AppTheme.Colors.textOnColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isTracking ? AppTheme.Colors.successGreen : AppTheme.Colors.mtaBlue)
                        .cornerRadius(AppTheme.Layout.cornerRadius)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(arrival.isBus ? "Bus" : "Train") \(arrival.displayName), \(arrival.stopName), \(arrival.minutesAway) minutes away")
        .accessibilityHint(isExpanded ? "Expanded. Shows arrival details." : "Tap to see arrival details")
        .onChange(of: tappedVehicleId) { _, newValue in
            if let newValue, !newValue.isEmpty,
               (arrival.vehicleId == newValue) || (arrival.tripId == newValue) {
                // Map marker tapped → expand this matching row
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    isExpanded = true
                }
            } else if isExpanded && !isMapHighlighted {
                // Highlight cleared or moved to another row — collapse this row
                // so only the newly tapped vehicle's row stays expanded.
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    isExpanded = false
                }
            }
        }
    }
    
    // MARK: - Helper Functions
    
    /// Formats walking distance to the stop.
    private func formatDistance(_ meters: Double) -> String {
        formatWalkingDistance(meters)
    }
}
