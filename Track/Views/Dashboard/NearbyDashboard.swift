// Dashboard content for the "Nearby" transport mode.
// Shows unified transit arrivals (buses and trains) sorted by distance,
// grouped into "Near You" and "A Little Farther Away" sections.

import CoreLocation
import SwiftUI

/// Nearby transit dashboard showing all nearby buses and trains.
struct NearbyDashboard: View {
    // MARK: - Dependencies

    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    let lastUpdated: Date?
    @Binding var cameraPosition: TrackCameraPosition

    // MARK: - Section Collapse State

    @State private var isNearYouCollapsed = false
    @State private var isFartherCollapsed = false
    @State private var isMuchFartherCollapsed = false
    @State private var isInactiveCollapsed = true

    // MARK: - Computed Properties

    /// Radius thresholds from settings
    private var nearYouRadius: Double { AppSettings.shared.nearYouRadiusMeters }
    private var fartherAwayRadius: Double { AppSettings.shared.fartherAwayRadiusMeters }
    private var muchFartherAwayRadius: Double { AppSettings.shared.muchFartherAwayRadiusMeters }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Use active search pin OR user location for distance calculation
            let refLocation = viewModel.referenceLocation

            if !viewModel.groupedTransit.isEmpty {
                let filtered = viewModel.filteredGroupedTransit

                // Separate using the same distance source as row display distance
                // so list value + category ring remain perfectly aligned.
                let (nearYou, fartherAway, muchFarther) = viewModel.groupedDisplayBuckets(
                    from: filtered,
                    referenceLocation: refLocation
                )

                // Display "Near You" section
                if !nearYou.isEmpty {
                    NearYouSectionHeader(
                        radiusMeters: nearYouRadius,
                        updated: lastUpdated,
                        isCollapsed: $isNearYouCollapsed
                    )
                    if !isNearYouCollapsed {
                        GroupedRouteList(
                            groups: nearYou,
                            viewModel: viewModel,
                            locationManager: locationManager,
                            sheetNavigator: sheetNavigator,
                            referenceLocation: refLocation
                        )
                    }
                } else if viewModel.searchText.isEmpty {
                    NearYouSectionHeader(
                        radiusMeters: nearYouRadius,
                        updated: lastUpdated,
                        isCollapsed: $isNearYouCollapsed
                    )
                    if !isNearYouCollapsed {
                        EmptyTierHint()
                    }
                }

                // Display "A Little Farther Away" section
                if !fartherAway.isEmpty {
                    FartherAwaySectionHeader(
                        radiusMeters: fartherAwayRadius,
                        isCollapsed: $isFartherCollapsed
                    )
                    if !isFartherCollapsed {
                        GroupedRouteList(
                            groups: fartherAway,
                            viewModel: viewModel,
                            locationManager: locationManager,
                            sheetNavigator: sheetNavigator,
                            referenceLocation: refLocation
                        )
                    }
                } else if viewModel.searchText.isEmpty {
                    FartherAwaySectionHeader(
                        radiusMeters: fartherAwayRadius,
                        isCollapsed: $isFartherCollapsed
                    )
                    if !isFartherCollapsed {
                        EmptyTierHint()
                    }
                }

                // Display "Much Farther Away" section
                if !muchFarther.isEmpty {
                    MuchFartherAwaySectionHeader(
                        radiusMeters: muchFartherAwayRadius,
                        isCollapsed: $isMuchFartherCollapsed
                    )
                    if !isMuchFartherCollapsed {
                        GroupedRouteList(
                            groups: muchFarther,
                            viewModel: viewModel,
                            locationManager: locationManager,
                            sheetNavigator: sheetNavigator,
                            referenceLocation: refLocation
                        )
                    }
                } else if viewModel.searchText.isEmpty {
                    MuchFartherAwaySectionHeader(
                        radiusMeters: muchFartherAwayRadius,
                        isCollapsed: $isMuchFartherCollapsed
                    )
                    if !isMuchFartherCollapsed {
                        EmptyTierHint()
                    }
                }

                // Show empty state only when all sections are empty after filtering
                if nearYou.isEmpty && fartherAway.isEmpty && muchFarther.isEmpty
                    && !viewModel.searchText.isEmpty
                {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No results for \"\(viewModel.searchText)\""
                    )
                }

            } else if !viewModel.nearbyTransit.isEmpty {
                // Fallback: Flat list sorted by distance
                let sorted = viewModel.nearbyTransit.sorted { arrival1, arrival2 in
                    guard let loc = refLocation else {
                        return arrival1.minutesAway < arrival2.minutesAway
                    }
                    return distance(for: arrival1, from: loc) < distance(for: arrival2, from: loc)
                }

                // Separate flat arrivals by distance
                let (nearYouArrivals, fartherAwayArrivals) = separateArrivalsByDistance(
                    arrivals: sorted, from: refLocation)

                if !nearYouArrivals.isEmpty {
                    NearYouSectionHeader(
                        radiusMeters: nearYouRadius,
                        updated: lastUpdated,
                        isCollapsed: $isNearYouCollapsed
                    )
                    if !isNearYouCollapsed {
                        FlatTransitList(
                            arrivals: nearYouArrivals,
                            viewModel: viewModel,
                            locationManager: locationManager
                        )
                    }
                }

                if !fartherAwayArrivals.isEmpty {
                    FartherAwaySectionHeader(
                        radiusMeters: fartherAwayRadius,
                        isCollapsed: $isFartherCollapsed
                    )
                    if !isFartherCollapsed {
                        FlatTransitList(
                            arrivals: fartherAwayArrivals,
                            viewModel: viewModel,
                            locationManager: locationManager
                        )
                    }
                }

            } else if !viewModel.isLoading {
                if let nearest = viewModel.nearestTransit {
                    FarFromTransitView(
                        icon: "figure.walk",
                        title: "Oh no, you're far from transit!",
                        subtitle:
                            "We couldn't find anything nearby, "
                            + "but we found a station a bit further out.",
                        accentColor: AppTheme.Colors.mtaBlue
                    )

                    DashboardSectionHeader(title: "Nearest Metro", updated: nil)
                    NearestMetroCard(
                        arrival: nearest,
                        distanceMeters: viewModel.nearestTransitDistance,
                        onCenter: { coordinate in
                            withAnimation(.easeInOut(duration: 0.6)) {
                                cameraPosition = MapCameraPresets.center(
                                    on: coordinate, is3D: false)
                            }
                        }
                    )
                } else if viewModel.isNetworkError {
                    ErrorStateCard(.networkOffline, onRetry: {
                        Task {
                            await viewModel.refreshNearbyTransit(
                                location: viewModel.referenceLocation
                            )
                        }
                    })
                } else if viewModel.isBackendError, let msg = viewModel.errorMessage {
                    ErrorStateCard(.backendError(message: msg), onRetry: {
                        Task {
                            await viewModel.refreshNearbyTransit(
                                location: viewModel.referenceLocation
                            )
                        }
                    })
                } else if viewModel.isOutsideServiceArea {
                    ErrorStateCard(
                        .outsideServiceArea,
                        action: .explore(cameraPosition: $cameraPosition)
                    )
                } else {
                    ErrorStateCard(
                        .noNearbyArrivals,
                        action: .explore(cameraPosition: $cameraPosition)
                    )
                }
            }

            // Display "Inactive Lines" section — routes with no active service.
            // Placed outside the grouped/flat/empty conditionals so it always
            // appears when there are ghost or GTFS-only inactive routes.
            let inactiveTotal = viewModel.ghostRoutes.count
                + viewModel.inactiveGroupedTransit.count
            if inactiveTotal > 0 {
                InactiveLinesSectionHeader(
                    count: inactiveTotal,
                    isCollapsed: $isInactiveCollapsed
                )
                .id("inactive-section-anchor")
                if !isInactiveCollapsed {
                    // Ghost routes (in grouped feed but 0 arrivals) —
                    // rendered as full GroupedRouteRow for tap-to-detail.
                    if !viewModel.ghostRoutes.isEmpty {
                        GroupedRouteList(
                            groups: viewModel.ghostRoutes,
                            viewModel: viewModel,
                            locationManager: locationManager,
                            sheetNavigator: sheetNavigator,
                            referenceLocation: refLocation
                        )
                    }
                    // Truly inactive routes (GTFS catalog only, no feed presence)
                    if !viewModel.inactiveGroupedTransit.isEmpty {
                        InactiveRouteList(
                            routes: viewModel.inactiveGroupedTransit,
                            sheetNavigator: sheetNavigator
                        )
                    }
                }
            }
        }
    }

    // MARK: - Distance Helpers (delegated to DistanceBucketUtils)

    /// Convenience wrapper for flat arrival distance.
    private func distance(for arrival: NearbyTransitResponse, from location: CLLocation)
        -> CLLocationDistance
    {
        arrivalDistance(for: arrival, from: location)
    }

    private func separateArrivalsByDistance(
        arrivals: [NearbyTransitResponse],
        from location: CLLocation?
    ) -> (nearYou: [NearbyTransitResponse], fartherAway: [NearbyTransitResponse]) {
        separateFlatArrivalsByDistance(arrivals: arrivals, from: location)
    }
}

// MARK: - Section Headers

/// Adaptive header shown when no stops fall within the "Near You" radius.
/// Displays the actual distance to the closest promoted result so the user
/// understands why the results are farther than usual.
struct ClosestToYouSectionHeader: View {
    let closestMeters: Double?
    let updated: Date?
    var isPromoted: Bool = true

    private var distanceDisplay: String {
        guard let meters = closestMeters else { return "Nearby" }
        return formatDistanceImperial(meters, suffix: "away")
    }

    private var badgeColor: Color {
        isPromoted ? AppTheme.Colors.warningYellow : AppTheme.Colors.successGreen
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)

            Text("Closest")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)

            Text("· \(distanceDisplay)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.Colors.textTertiary)

            Spacer()

            if let updated = updated {
                Text(updated, style: .time)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// "Near You" section header - tappable to collapse/expand
struct NearYouSectionHeader: View {
    let radiusMeters: Double
    let updated: Date?
    @Binding var isCollapsed: Bool

    private var radiusDisplay: String {
        formatDistanceMiles(radiusMeters)
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(AppTheme.Colors.successGreen)
                    .frame(width: 8, height: 8)

                Text("Near You")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text("· \(radiusDisplay)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)

                Spacer()

                if let updated = updated {
                    Text(updated, style: .time)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// "A Little Farther Away" section header - tappable to collapse/expand
struct FartherAwaySectionHeader: View {
    let radiusMeters: Double
    @Binding var isCollapsed: Bool

    private var radiusDisplay: String {
        formatDistanceMiles(radiusMeters)
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(AppTheme.Colors.accent)
                    .frame(width: 8, height: 8)

                Text("A Bit Farther")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text("· \(radiusDisplay)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// "Much Farther Away" section header - tappable to collapse/expand
struct MuchFartherAwaySectionHeader: View {
    let radiusMeters: Double
    @Binding var isCollapsed: Bool

    private var radiusDisplay: String {
        formatDistanceMiles(radiusMeters)
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(AppTheme.Colors.warningYellow)
                    .frame(width: 8, height: 8)

                Text("Much Farther")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text("· \(radiusDisplay)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// Subtle empty-state shown under a distance tier header when no arrivals
/// fall within that ring.  Always visible so all 3 tiers are present.
struct EmptyTierHint: View {
    var body: some View {
        Text("Nothing in this range")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.35))
            .padding(.horizontal, AppTheme.Layout.margin + 14)
            .padding(.vertical, 6)
    }
}

// MARK: - Inactive Lines Section

/// Section header for routes with no active service (collapsed by default)
struct InactiveLinesSectionHeader: View {
    let count: Int
    @Binding var isCollapsed: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.Colors.textTertiary)

                Text("Inactive Lines")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textTertiary)

                Text("· \(count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.7))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/// List of inactive routes rendered as individual cards matching `GroupedRouteRow` style.
struct InactiveRouteList: View {
    let routes: [InactiveRouteResponse]
    let sheetNavigator: SheetNavigator

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(routes) { route in
                InactiveRouteRow(route: route, sheetNavigator: sheetNavigator)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

/// Single card for an inactive route — matches the active `GroupedRouteRow` visual style.
/// Tappable: opens the route detail sheet with an empty-directions stub.
struct InactiveRouteRow: View {
    let route: InactiveRouteResponse
    let sheetNavigator: SheetNavigator

    private var isBus: Bool { route.mode == "bus" }
    private var isCommuterRail: Bool { route.mode == "lirr" || route.mode == "mnr" }

    private var serviceLabel: String {
        if let busType = route.busServiceType, !busType.isEmpty {
            return busType
        }
        return route.mode.capitalized
    }

    var body: some View {
        HStack(spacing: 12) {
            // Route badge — same RouteBadge component used in active rows
            RouteBadge(
                routeID: route.displayName,
                size: .medium,
                isBus: isBus,
                hexColor: route.colorHex,
                mode: route.mode,
                busServiceType: route.busServiceType
            )
            .padding(.horizontal, isCommuterRail ? 6 : 8)
            .padding(.vertical, 8)

            // Center — "No active service" label
            VStack(alignment: .leading, spacing: 5) {
                Text("No active service")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text(serviceLabel)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Build a lightweight stub group so the route-detail sheet
            // can render the "No active service" empty state.
            let stub = GroupedNearbyTransitResponse(
                routeId: route.routeId,
                displayName: route.displayName,
                mode: route.mode,
                colorHex: route.colorHex,
                directions: [],
                sortingKey: route.sortingKey,
                busServiceType: route.busServiceType
            )
            sheetNavigator.navigate(to: .routeDetail(group: stub, directionIndex: 0))
        }
    }
}

// MARK: - Grouped Route List

struct GroupedRouteList: View {
    let groups: [GroupedNearbyTransitResponse]
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    var referenceLocation: CLLocation? = nil

    /// When true, rows render desaturated and non-interactive while
    /// fresh data is being fetched from the backend.
    /// Passed in explicitly to avoid a transitive @Observable read
    /// of `viewModel.showStaleRows` (which depends on timer state).
    var isStale: Bool = false

    var body: some View {
        // LazyVStack: rows are only built when they scroll into view.
        // Critical for busy stops with 10+ routes — plain VStack eagerly
        // renders every GroupedRouteRow, including all their arrival chips.
        LazyVStack(spacing: 12) {
            ForEach(groups) { group in
                GroupedRouteRow(
                    group: group,
                    hasAlert: group.hasAlert
                        || viewModel.hasActiveAlert(
                            routeId: group.routeId, mode: group.mode)
                        || viewModel.hasActiveAlert(
                            routeId: group.displayName, mode: group.mode),
                    userLocation: referenceLocation,
                    distanceMetersOverride: viewModel.displayDistanceMeters(
                        for: group, from: referenceLocation),
                    smartETAProvider: { viewModel.smartETA(for: $0) },
                    initialDirectionIndex: viewModel.preferredDirectionIndex(for: group),
                    onDirectionChanged: { newIndex in
                        viewModel.setPreferredDirectionIndex(newIndex, for: group)
                    },
                    onSelect: { directionIndex in
                        sheetNavigator.navigate(
                            to: .routeDetail(group: group, directionIndex: directionIndex))
                        Task {
                            await viewModel.handleRouteSelection(
                                group, directionIndex: directionIndex,
                                userLocation: locationManager.currentLocation)
                        }
                    },
                    onTrack: { directionIndex in
                        viewModel.setPreferredDirectionIndex(directionIndex, for: group)
                        let dir = group.directions[
                            min(directionIndex, group.directions.count - 1)]
                        guard let arrival = ArrivalHelpers.countdownArrival(
                            for: dir,
                            userLocation: locationManager.currentLocation,
                            provider: { viewModel.smartETA(for: $0) }
                        ) else { return }
                        viewModel.trackNearbyArrival(
                            arrival, location: locationManager.currentLocation)
                    },
                    onAlertTapped: {
                        let directionIndex = viewModel.preferredDirectionIndex(for: group)
                        sheetNavigator.navigate(
                            to: .routeDetail(
                                group: group,
                                directionIndex: directionIndex,
                                initialTab: .stops))
                        Task {
                            await viewModel.handleRouteSelection(
                                group, directionIndex: directionIndex,
                                userLocation: locationManager.currentLocation)
                        }
                    },
                    isStale: isStale
                )
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

// MARK: - Flat Transit List

struct FlatTransitList: View {
    let arrivals: [NearbyTransitResponse]
    let viewModel: HomeViewModel
    let locationManager: LocationManager

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(arrivals.enumerated()), id: \.element.id) { index, arrival in
                let thisIsTracking = viewModel.isTracking(arrival)
                NearbyTransitRow(
                    arrival: arrival,
                    isTracking: thisIsTracking,
                    isTrackingAnother: !thisIsTracking && viewModel.isTrackingAny,
                    isLiveOnMap: viewModel.isVehicleLiveOnMap(arrival),
                    onTrack: {
                        viewModel.trackNearbyArrival(
                            arrival, location: locationManager.currentLocation)
                    },
                    onSelectRoute: arrival.isBus
                        ? {
                            RouteAnalyticsManager.shared.logInteraction(routeId: arrival.routeId)
                            Task {
                                await viewModel.selectArrival(
                                    arrival, userLocation: locationManager.currentLocation)
                            }
                        } : nil,
                    userLocation: viewModel.referenceLocation,
                    isExpanded: viewModel.selectedExpandedArrivalID == arrival.id,
                    onExpand: {
                        viewModel.toggleArrivalExpansion(arrival.id)
                    }
                )
                if index < arrivals.count - 1 {
                    Divider()
                        .padding(
                            .leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                }
            }
        }
        .padding(.vertical, 8)
        .trackFloatingChrome(cornerRadius: AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}



#Preview {
    NearbyDashboard(
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        sheetNavigator: SheetNavigator(),
        lastUpdated: Date(),
        cameraPosition: .constant(.automatic)
    )
}
