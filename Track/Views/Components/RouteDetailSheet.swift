//
//  RouteDetailSheet.swift
//  Track
//
//  Route detail view presented when tapping a grouped route card.
//  Uses the same AppTheme design system, RouteBadge, and card layout
//  patterns as the rest of the app. No separate map — the MAIN map
//  behind this sheet draws the route polylines and live vehicles.
//

import SwiftUI

struct RouteDetailSheet: View {
    let group: GroupedNearbyTransitResponse
    @Binding var busVehicles: [BusVehicleResponse]
    @Binding var routeShape: RouteShapeResponse?
    var onTrack: ((NearbyTransitResponse) -> Void)?
    var onDismiss: (() -> Void)?
    
    @State private var selectedDirectionIndex: Int

    init(group: GroupedNearbyTransitResponse,
         busVehicles: Binding<[BusVehicleResponse]>,
         routeShape: Binding<RouteShapeResponse?>,
         initialDirectionIndex: Int = 0,
         onTrack: ((NearbyTransitResponse) -> Void)? = nil,
         onDismiss: (() -> Void)? = nil) {
        self.group = group
        self._busVehicles = busVehicles
        self._routeShape = routeShape
        self.onTrack = onTrack
        self.onDismiss = onDismiss
        self._selectedDirectionIndex = State(initialValue: initialDirectionIndex)
    }

    /// Route color from the group data or the theme palette.
    private var routeColor: Color {
        if let hex = group.colorHex {
            return Color(hex: hex)
        }
        return group.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: group.displayName)
    }

    /// Current direction bucket, clamped to bounds.
    private var safeDirection: DirectionArrivalsResponse {
        guard !group.directions.isEmpty else {
            return DirectionArrivalsResponse(direction: "—", arrivals: [])
        }
        let idx = min(selectedDirectionIndex, group.directions.count - 1)
        return group.directions[idx]
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: - Header Row
                routeHeader

                // MARK: - Countdown Chips
                countdownSection

                // MARK: - Direction Picker
                if group.directions.count > 1 {
                    directionPicker
                }

                // MARK: - Arrivals List
                arrivalsList

                // MARK: - Route Info Footer
                routeInfoFooter

                Spacer()
                    .frame(height: 20)
            }
            .padding(.top, AppTheme.Layout.margin)
        }
        .background(AppTheme.Colors.background)
    }

    // MARK: - Header

    private var routeHeader: some View {
        HStack(spacing: 12) {
            // Reuse existing RouteBadge for subway, custom badge for bus
            if group.isBus {
                ZStack {
                    Circle()
                        .fill(routeColor)
                        .frame(width: AppTheme.Layout.badgeSizeLarge,
                               height: AppTheme.Layout.badgeSizeLarge)
                    Image(systemName: "bus.fill")
                        .font(.system(size: AppTheme.Layout.badgeFontLarge, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textOnColor)
                }
            } else {
                RouteBadge(routeID: group.displayName, size: .large)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(group.displayName)
                    .font(AppTheme.Typography.headerLarge)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if group.directions.indices.contains(selectedDirectionIndex) {
                    let dir = group.directions[selectedDirectionIndex]
                    Text(directionLabel(dir.direction))
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Close button
            Button {
                onDismiss?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    // MARK: - Countdown Chips

    private var countdownSection: some View {
        let direction = safeDirection
        let nextArrivals = Array(direction.arrivals.prefix(4))

        return VStack(alignment: .leading, spacing: 8) {
            Text("Next Arrivals")
                .font(AppTheme.Typography.sectionHeader)
                .foregroundColor(AppTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, AppTheme.Layout.margin)

            if nextArrivals.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("No upcoming arrivals")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(nextArrivals.enumerated()), id: \.element.id) { index, arrival in
                            VStack(spacing: 4) {
                                // Big countdown number
                                Text("\(arrival.minutesAway)")
                                    .font(.system(size: index == 0 ? 36 : 28,
                                                  weight: .black, design: .rounded))
                                    .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))

                                Text("min")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(AppTheme.Colors.textSecondary)

                                // Status pill
                                Text(arrival.status)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(AppTheme.Colors.textOnColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(transitStatusColor(for: arrival.status))
                                    .clipShape(Capsule())
                            }
                            .frame(width: index == 0 ? 90 : 76)
                            .padding(.vertical, 12)
                            .background(AppTheme.Colors.cardBackground)
                            .cornerRadius(AppTheme.Layout.cornerRadius)
                        }
                    }
                    .padding(.horizontal, AppTheme.Layout.margin)
                }
            }
        }
    }

    // MARK: - Direction Picker

    private var directionPicker: some View {
        HStack(spacing: 0) {
            ForEach(Array(group.directions.enumerated()), id: \.element.id) { index, dir in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedDirectionIndex = index
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(shortDirectionLabel(dir.direction))
                            .font(.system(size: 14, weight: selectedDirectionIndex == index ? .bold : .medium))
                            .foregroundColor(
                                selectedDirectionIndex == index
                                    ? AppTheme.Colors.textPrimary
                                    : AppTheme.Colors.textSecondary
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Text("\(dir.arrivals.count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textOnColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                selectedDirectionIndex == index
                                    ? routeColor
                                    : AppTheme.Colors.textSecondary
                            )
                            .clipShape(Capsule())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        selectedDirectionIndex == index
                            ? routeColor.opacity(0.12)
                            : Color.clear
                    )
                }
                .accessibilityLabel("\(directionLabel(dir.direction)), \(dir.arrivals.count) arrivals")
            }
        }
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius))
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    // MARK: - Arrivals List (same card pattern as HomeView)

    private var arrivalsList: some View {
        let direction = safeDirection

        return VStack(alignment: .leading, spacing: 8) {
            Text("Arrivals")
                .font(AppTheme.Typography.sectionHeader)
                .foregroundColor(AppTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, AppTheme.Layout.margin)

            if direction.arrivals.isEmpty {
                // Empty state — matches HomeView's emptyStateView pattern
                VStack(spacing: 8) {
                    Image(systemName: "tram.fill")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Text("No arrivals in this direction")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(direction.arrivals.enumerated()), id: \.element.id) { index, arrival in
                        // Row — same HStack layout as NearbyTransitRow
                        // Use the shared NearbyTransitRow which implements the requested "Transit" style
                        NearbyTransitRow(
                            arrival: arrival,
                            isTracking: false, // Tracking feedback handled by HomeView/Toast for now
                            onTrack: {
                                onTrack?(arrival)
                            }
                        )
                        .padding(.horizontal, 0) // NearbyTransitRow has internal padding
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(arrival.stopName), \(arrival.minutesAway) minutes, \(arrival.status)")

                        // Divider between rows — same pattern as HomeView
                        if index < direction.arrivals.count - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 50, coordinateSpace: .local)
                .onEnded { value in
                    guard group.directions.count > 1 else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if value.translation.width < 0 {
                            selectedDirectionIndex = min(selectedDirectionIndex + 1,
                                                        group.directions.count - 1)
                        } else if value.translation.width > 0 {
                            selectedDirectionIndex = max(selectedDirectionIndex - 1, 0)
                        }
                    }
                }
        )
        .accessibilityHint(group.directions.count > 1 ? "Swipe to switch direction" : "")
    }

    // MARK: - Route Info Footer

    private var routeInfoFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Route stops count
            if let shape = routeShape, !shape.stops.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Text("\(shape.stops.count) stops on route")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }

            // Live vehicles count
            if !busVehicles.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Colors.successGreen)
                    Text("\(busVehicles.count) \(group.isBus ? "buses" : "trains") live on map")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.successGreen)
                }
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
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
                            destination: "Inwood-207 St",
                            minutesAway: 3, status: "On Time", mode: "subway",
                            stopLat: 40.72, stopLon: -74.0
                        ),
                        NearbyTransitResponse(
                            routeId: "A", stopName: "14 St", direction: "N",
                            destination: "Inwood-207 St",
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
                            destination: "Far Rockaway",
                            minutesAway: 5, status: "Delayed", mode: "subway",
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
