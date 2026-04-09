// Dashboard content for the "Bus" transport mode.
// Shows nearby bus arrivals split into "Near You" and "A Little
// Farther Away" sections — same distance-based pattern as the
// Nearby and Subway tabs.

import SwiftUI
import CoreLocation

/// Bus-specific dashboard showing grouped bus arrivals.
struct BusDashboard: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    let lastUpdated: Date?

    // MARK: - Section Collapse State

    @State private var isNearYouCollapsed = false
    @State private var isFartherCollapsed = false
    @State private var isMuchFartherCollapsed = false
    @State private var isInactiveCollapsed = true
    
    // MARK: - Distance Settings
    
    private var nearYouRadius: Double { AppSettings.shared.nearYouRadiusMeters }
    private var fartherAwayRadius: Double { AppSettings.shared.fartherAwayRadiusMeters }
    private var muchFartherAwayRadius: Double { AppSettings.shared.muchFartherAwayRadiusMeters }
    
    /// Grouped bus arrivals from the nearby/grouped API (bus-only)
    private var groupedArrivals: [GroupedNearbyTransitResponse] {
        viewModel.filteredNearbyGroupedBusArrivals
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let refLocation: CLLocation? =
                viewModel.effectiveLocation(
                    userLocation: locationManager.currentLocation
                )
            
            if !groupedArrivals.isEmpty {
                bucketedContent(referenceLocation: refLocation)
            } else if !viewModel.isLoading {
                busEmptyState
            }

            // Inactive bus lines — outside the active/empty conditional
            let inactiveBusTotal = viewModel.ghostBusRoutes.count
                + viewModel.inactiveBusRoutes.count
            if inactiveBusTotal > 0 {
                InactiveLinesSectionHeader(
                    count: inactiveBusTotal,
                    isCollapsed: $isInactiveCollapsed
                )
                if !isInactiveCollapsed {
                    if !viewModel.ghostBusRoutes.isEmpty {
                        GroupedRouteList(
                            groups: viewModel.ghostBusRoutes,
                            viewModel: viewModel,
                            locationManager: locationManager,
                            sheetNavigator: sheetNavigator,
                            referenceLocation: refLocation
                        )
                    }
                    if !viewModel.inactiveBusRoutes.isEmpty {
                        InactiveRouteList(
                            routes: viewModel.inactiveBusRoutes,
                            sheetNavigator: sheetNavigator
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bucketedContent(referenceLocation refLocation: CLLocation?) -> some View {
                let buckets: (
                    [GroupedNearbyTransitResponse],
                    [GroupedNearbyTransitResponse],
                    [GroupedNearbyTransitResponse]
                ) = viewModel.groupedDisplayBuckets(
                    from: groupedArrivals,
                    referenceLocation: refLocation
                )
                let nearYou: [GroupedNearbyTransitResponse] = buckets.0
                let fartherAway: [GroupedNearbyTransitResponse] = buckets.1
                let muchFarther: [GroupedNearbyTransitResponse] = buckets.2
                
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
                
                if nearYou.isEmpty && fartherAway.isEmpty
                    && muchFarther.isEmpty
                    && !viewModel.searchText.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No bus results for \"\(viewModel.searchText)\""
                    )
                }

    }

    @ViewBuilder
    private var busEmptyState: some View {
                if !viewModel.searchText.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No bus results for \"\(viewModel.searchText)\""
                    )
                } else {
                    ErrorStateCard(
                        .noService(
                            icon: "bus.fill",
                            title: "No Buses Nearby",
                            message: "We couldn't find any bus arrivals"
                                + " within your search radius."
                                + " Try expanding your radius in Settings.",
                            brandColor: AppTheme.Colors.mtaBlue
                        ),
                        compact: true
                    )
                }
    }
    
}

#Preview {
    let vm: HomeViewModel = HomeViewModel()
    let lm: LocationManager = LocationManager()
    let sn: SheetNavigator = SheetNavigator()
    let date: Date = Date()
    BusDashboard(
        viewModel: vm,
        locationManager: lm,
        sheetNavigator: sn,
        lastUpdated: date
    )
}
