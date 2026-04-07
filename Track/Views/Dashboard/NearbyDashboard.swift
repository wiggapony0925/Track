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
    @Binding var is3DMode: Bool

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
                    NearYouSectionHeader(radiusMeters: nearYouRadius, updated: lastUpdated)
                    GroupedRouteList(
                        groups: nearYou,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator,
                        referenceLocation: refLocation
                    )
                } else if viewModel.searchText.isEmpty {
                    NearYouSectionHeader(radiusMeters: nearYouRadius, updated: lastUpdated)
                    EmptyTierHint()
                }

                // Display "A Little Farther Away" section
                if !fartherAway.isEmpty {
                    FartherAwaySectionHeader(radiusMeters: fartherAwayRadius)
                    GroupedRouteList(
                        groups: fartherAway,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator,
                        referenceLocation: refLocation
                    )
                } else if viewModel.searchText.isEmpty {
                    FartherAwaySectionHeader(radiusMeters: fartherAwayRadius)
                    EmptyTierHint()
                }

                // Display "Much Farther Away" section
                if !muchFarther.isEmpty {
                    MuchFartherAwaySectionHeader(radiusMeters: muchFartherAwayRadius)
                    GroupedRouteList(
                        groups: muchFarther,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator,
                        referenceLocation: refLocation
                    )
                } else if viewModel.searchText.isEmpty {
                    MuchFartherAwaySectionHeader(radiusMeters: muchFartherAwayRadius)
                    EmptyTierHint()
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
                    NearYouSectionHeader(radiusMeters: nearYouRadius, updated: lastUpdated)
                    FlatTransitList(
                        arrivals: nearYouArrivals,
                        viewModel: viewModel,
                        locationManager: locationManager
                    )
                }

                if !fartherAwayArrivals.isEmpty {
                    FartherAwaySectionHeader(radiusMeters: fartherAwayRadius)
                    FlatTransitList(
                        arrivals: fartherAwayArrivals,
                        viewModel: viewModel,
                        locationManager: locationManager
                    )
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
                                    on: coordinate, is3D: is3DMode)
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
                        action: .explore(cameraPosition: $cameraPosition, is3DMode: $is3DMode)
                    )
                } else {
                    ErrorStateCard(
                        .noNearbyArrivals,
                        action: .explore(cameraPosition: $cameraPosition, is3DMode: $is3DMode)
                    )
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

    /// Green when showing normal nearby results, yellow when promoted from farther away.
    private var badgeColor: Color {
        isPromoted ? AppTheme.Colors.warningYellow : AppTheme.Colors.successGreen
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)

                Text("Closest")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)

                Text("· \(distanceDisplay)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(badgeColor)
            }

            Spacer()

            if let updated = updated {
                Text(updated, style: .time)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

/// "Near You" section header - compact icon-based indicator
struct NearYouSectionHeader: View {
    let radiusMeters: Double
    let updated: Date?

    private var radiusDisplay: String {
        formatDistanceMiles(radiusMeters)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "location.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)

                Text("Near You")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)

                Text("· \(radiusDisplay)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(AppTheme.Colors.successGreen)
            }

            Spacer()

            if let updated = updated {
                Text(updated, style: .time)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

/// "A Little Farther Away" section header - compact icon-based indicator
struct FartherAwaySectionHeader: View {
    let radiusMeters: Double

    private var radiusDisplay: String {
        formatDistanceMiles(radiusMeters)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)

                Text("A Bit Farther")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)

                Text("· \(radiusDisplay)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(AppTheme.Colors.accent)
            }

            Spacer()
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// "Much Farther Away" section header - compact icon-based indicator with car icon
struct MuchFartherAwaySectionHeader: View {
    let radiusMeters: Double

    private var radiusDisplay: String {
        formatDistanceMiles(radiusMeters)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "car.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)

                Text("Much Farther")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)

                Text("· \(radiusDisplay)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(AppTheme.Colors.warningYellow)
            }

            Spacer()
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// Subtle empty-state shown under a distance tier header when no arrivals
/// fall within that ring.  Always visible so all 3 tiers are present.
struct EmptyTierHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.3))

            Text("Nothing in this range")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.4))

            Spacer()
        }
        .padding(.horizontal, AppTheme.Layout.margin + 4)
        .padding(.vertical, 6)
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
    private var isStale: Bool { viewModel.showStaleRows }

    var body: some View {
        // LazyVStack: rows are only built when they scroll into view.
        // Critical for busy stops with 10+ routes — plain VStack eagerly
        // renders every GroupedRouteRow, including all their arrival chips.
        LazyVStack(spacing: 12) {
            ForEach(groups) { group in
                GroupedRouteRow(
                    group: group,
                    hasAlert: group.hasAlert
                        || !viewModel.serviceAlerts.matching(
                            routeId: group.routeId, mode: group.mode
                        ).isEmpty
                        || !viewModel.serviceAlerts.matching(
                            routeId: group.displayName, mode: group.mode
                        ).isEmpty,
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
                                initialTab: .alerts))
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
        cameraPosition: .constant(.automatic),
        is3DMode: .constant(false)
    )
}
