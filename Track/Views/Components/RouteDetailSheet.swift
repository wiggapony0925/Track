//
//  RouteDetailSheet.swift
//  Track
//
//  Route detail modal presented when tapping a grouped route card.
//  Displays a swipeable TabView of directions (e.g. Northbound /
//  Southbound) with live arrival countdowns, a mini route map using
//  MapKit's ``Map`` view with ``MKMapItem`` placemarks and polylines,
//  and a "Track" button for Live Activity integration.
//
//  References:
//  - https://developer.apple.com/documentation/mapkit/mkmapitem/init(placemark:)
//  - https://developer.apple.com/documentation/mapkit/map
//

import SwiftUI
import MapKit

/// A sheet that shows route details with swipeable direction tabs.
/// Inspired by subway apps like Citymapper and Transit — focused on
/// quick arrival checking rather than trip planning.
struct RouteDetailSheet: View {
    let group: GroupedNearbyTransitResponse
    @Binding var busVehicles: [BusVehicleResponse]
    @Binding var routeShape: RouteShapeResponse?
    var onTrack: ((NearbyTransitResponse) -> Void)?
    var onGoMode: ((_ routeName: String, _ routeColor: Color) -> Void)?
    var onDismiss: (() -> Void)?

    @State private var selectedDirectionIndex = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Route header
                    routeHeader
                        .padding(.top, 8)

                    // "GO" button — activates live tracking mode
                    goButton
                        .padding(.top, 12)

                    // Mini map showing route shape + stops
                    routeMapSection
                        .padding(.top, 12)

                    // Direction picker (swipeable tabs)
                    if group.directions.count > 1 {
                        directionPicker
                            .padding(.top, 16)
                    }

                    // Arrival list for selected direction
                    arrivalList
                        .padding(.top, 12)

                    Spacer()
                        .frame(height: 24)
                }
            }
            .background(AppTheme.Colors.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onDismiss?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    // MARK: - Route Header

    private var routeHeader: some View {
        VStack(spacing: 8) {
            // Route badge
            ZStack {
                Circle()
                    .fill(routeColor)
                    .frame(width: AppTheme.Layout.badgeSizeLarge,
                           height: AppTheme.Layout.badgeSizeLarge)
                    .shadow(color: routeColor.opacity(0.4),
                            radius: AppTheme.Layout.shadowRadius)
                if group.isBus {
                    Image(systemName: "bus.fill")
                        .font(.system(size: AppTheme.Layout.badgeFontLarge, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text(group.displayName)
                        .font(.system(size: AppTheme.Layout.badgeFontLarge,
                                      weight: .heavy, design: .monospaced))
                        .foregroundColor(subwayTextColor)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }

            Text(group.displayName)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)

            Text(group.isBus ? "Bus" : "Subway")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)

            // Soonest arrival highlight
            HStack(spacing: 4) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 12, weight: .medium))
                Text("Next in \(group.soonestMinutes) min")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundColor(AppTheme.Colors.countdown(group.soonestMinutes))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(AppTheme.Colors.countdown(group.soonestMinutes).opacity(0.12))
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - GO Button

    /// The signature "GO" button that activates live tracking mode.
    /// Inspired by the Transit app — a large, prominent play button
    /// that transforms the interface from planning to cockpit view.
    private var goButton: some View {
        Button {
            onGoMode?(group.displayName, routeColor)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("GO")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppTheme.Colors.goGreen)
            .cornerRadius(AppTheme.Layout.cornerRadius)
            .shadow(color: AppTheme.Colors.goGreen.opacity(0.4), radius: 8, y: 4)
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityLabel("GO — start live tracking for \(group.displayName)")
        .accessibilityHint("Activates hands-free transit tracking mode")
    }

    // MARK: - Route Map

    private var routeMapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "map.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                Text("Route Map")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            Map(bounds: AppTheme.MapConfig.cameraBounds) {
                // Route polylines
                if let shape = routeShape {
                    ForEach(Array(shape.decodedPolylines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(routeColor, lineWidth: 3)
                    }
                    // Stop annotations along the route
                    ForEach(shape.stops) { stop in
                        Annotation(
                            stop.name,
                            coordinate: CLLocationCoordinate2D(
                                latitude: stop.lat, longitude: stop.lon
                            )
                        ) {
                            Circle()
                                .fill(.white)
                                .frame(width: 8, height: 8)
                                .overlay(
                                    Circle()
                                        .stroke(routeColor, lineWidth: 2)
                                )
                        }
                    }
                }

                // Live bus vehicle positions
                ForEach(busVehicles) { vehicle in
                    Annotation(
                        vehicle.nextStop ?? vehicle.displayRouteName,
                        coordinate: CLLocationCoordinate2D(
                            latitude: vehicle.lat, longitude: vehicle.lon
                        )
                    ) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.Colors.mtaBlue)
                                .frame(width: 24, height: 24)
                            Image(systemName: "bus.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .rotationEffect(.degrees(vehicle.bearing ?? 0))
                        }
                    }
                }
            }
            .mapStyle(.standard(emphasis: .muted, showsTraffic: false))
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius))
            .padding(.horizontal, AppTheme.Layout.margin)
        }
    }

    // MARK: - Direction Picker

    private var directionPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(group.directions.enumerated()), id: \.element.id) { index, dir in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedDirectionIndex = index
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(directionLabel(dir.direction))
                                .font(.system(size: 14, weight: selectedDirectionIndex == index ? .bold : .medium))
                                .foregroundColor(
                                    selectedDirectionIndex == index
                                        ? AppTheme.Colors.textPrimary
                                        : AppTheme.Colors.textSecondary
                                )
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)

                            // Count badge
                            Text("\(dir.arrivals.count)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(
                                    selectedDirectionIndex == index
                                        ? .white
                                        : AppTheme.Colors.textSecondary
                                )
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    selectedDirectionIndex == index
                                        ? routeColor
                                        : AppTheme.Colors.cardBackground
                                )
                                .clipShape(Capsule())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .accessibilityLabel("\(directionLabel(dir.direction)), \(dir.arrivals.count) arrivals")
                }
            }
            .background(AppTheme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius))
            .padding(.horizontal, AppTheme.Layout.margin)
        }
    }

    // MARK: - Arrival List

    private var arrivalList: some View {
        let direction = safeDirection
        return VStack(spacing: 0) {
            HStack {
                Text(directionLabel(direction.direction))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.bottom, 6)

            if direction.arrivals.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Text("No upcoming arrivals")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(direction.arrivals.enumerated()), id: \.element.id) { index, arrival in
                        RouteDetailArrivalRow(
                            arrival: arrival,
                            routeColor: routeColor,
                            onTrack: { onTrack?(arrival) }
                        )
                        if index < direction.arrivals.count - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.margin + 44)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius))
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 50, coordinateSpace: .local)
                .onEnded { value in
                    guard group.directions.count > 1 else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if value.translation.width < 0 {
                            // Swipe left → next direction
                            selectedDirectionIndex = min(selectedDirectionIndex + 1,
                                                        group.directions.count - 1)
                        } else if value.translation.width > 0 {
                            // Swipe right → previous direction
                            selectedDirectionIndex = max(selectedDirectionIndex - 1, 0)
                        }
                    }
                }
        )
        .accessibilityHint(group.directions.count > 1 ? "Swipe to switch direction" : "")
    }

    // MARK: - Helpers

    private var safeDirection: DirectionArrivalsResponse {
        guard !group.directions.isEmpty else {
            return DirectionArrivalsResponse(direction: "—", arrivals: [])
        }
        let idx = min(selectedDirectionIndex, group.directions.count - 1)
        return group.directions[idx]
    }

    private var routeColor: Color {
        if let hex = group.colorHex {
            return Color(hex: hex)
        }
        return group.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: group.displayName)
    }

    private var subwayTextColor: Color {
        AppTheme.SubwayColors.textColor(for: group.displayName)
    }

    /// Converts raw direction codes (e.g. "N", "S") to human-readable labels.
    private func directionLabel(_ direction: String) -> String {
        switch direction.uppercased() {
        case "N": return "Northbound"
        case "S": return "Southbound"
        case "E": return "Eastbound"
        case "W": return "Westbound"
        default: return direction
        }
    }
}

// MARK: - Arrival Row (inside Route Detail)

/// A single arrival row inside the route detail sheet.
private struct RouteDetailArrivalRow: View {
    let arrival: NearbyTransitResponse
    let routeColor: Color
    var onTrack: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Time circle
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.countdown(arrival.minutesAway).opacity(0.12))
                    .frame(width: 44, height: 44)
                VStack(spacing: 0) {
                    Text("\(arrival.minutesAway)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                    Text("min")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }

            // Stop info
            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.stopName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(arrivalTimeDescription)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Status pill
            Text(statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor)
                .clipShape(Capsule())

            // Track button
            Button {
                onTrack?()
            } label: {
                Image(systemName: "bell.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(routeColor)
            }
            .accessibilityLabel("Track arrival at \(arrival.stopName)")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(arrival.minutesAway) minutes, \(arrival.stopName), \(statusLabel)")
    }

    private var arrivalTimeDescription: String {
        if arrival.minutesAway <= 0 {
            return "Arriving now"
        }
        let arrivalTime = Date().addingTimeInterval(Double(arrival.minutesAway) * 60)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: arrivalTime)
    }

    private var statusLabel: String {
        if arrival.minutesAway <= 0 { return "Now" }
        if arrival.minutesAway <= 2 { return "Approaching" }
        return arrival.status
    }

    private var statusColor: Color {
        if arrival.minutesAway <= 0 { return AppTheme.Colors.alertRed }
        if arrival.minutesAway <= 2 { return AppTheme.Colors.warningYellow }
        return AppTheme.Colors.successGreen
    }
}

// MARK: - Color from hex string

extension Color {
    /// Creates a Color from a CSS hex string like ``"#FF6319"`` or ``"FF6319"``.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: Double
        switch cleaned.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b)
    }
}

#Preview {
    RouteDetailSheet(
        group: GroupedNearbyTransitResponse(
            routeId: "A",
            displayName: "A",
            mode: "subway",
            colorHex: "#0039A6",
            directions: [
                DirectionArrivalsResponse(
                    direction: "N",
                    arrivals: [
                        NearbyTransitResponse(
                            routeId: "A", stopName: "Canal St", direction: "N",
                            minutesAway: 3, status: "On Time", mode: "subway",
                            stopLat: 40.72, stopLon: -74.0
                        ),
                        NearbyTransitResponse(
                            routeId: "A", stopName: "14 St", direction: "N",
                            minutesAway: 8, status: "On Time", mode: "subway",
                            stopLat: 40.74, stopLon: -74.0
                        ),
                    ]
                ),
                DirectionArrivalsResponse(
                    direction: "S",
                    arrivals: [
                        NearbyTransitResponse(
                            routeId: "A", stopName: "Fulton St", direction: "S",
                            minutesAway: 5, status: "On Time", mode: "subway",
                            stopLat: 40.71, stopLon: -74.01
                        ),
                    ]
                ),
            ]
        ),
        busVehicles: .constant([]),
        routeShape: .constant(nil)
    )
}
