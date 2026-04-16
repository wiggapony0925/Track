// Dashboard content for the "LIRR" transport mode.
// Shows Long Island Rail Road departures grouped by timing.

import SwiftUI
import CoreLocation

/// LIRR-specific dashboard showing rail departures.
struct LIRRDashboard: View {
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
    
    /// Grouped LIRR arrivals for tap-to-detail navigation (from backend)
    private var groupedArrivals: [GroupedNearbyTransitResponse] {
        viewModel.filteredNearbyGroupedLIRRArrivals
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let refLocation: CLLocation? =
                viewModel.effectiveLocation(
                    userLocation: locationManager.currentLocation
                )

            // Evaluate once per body — avoids chains of computed properties
            // each re-reading the ViewModel (displayArrivals → soonArrivals
            // → isOutOfServiceArea → isFarFromService was 4 passes).
            let arrivals = groupedArrivals
            let isFarFromService: Bool = {
                guard !arrivals.isEmpty else { return false }
                let soonest = arrivals.map(\.soonestMinutes).min() ?? 0
                if soonest > 30 { return true }
                let display = viewModel.filteredLIRRArrivals
                let soon = display.filter {
                    $0.minutesAway <= 15
                        && ($0.minutesAway > 0
                            || $0.estimatedTime > Date())
                }
                return soon.isEmpty && !display.isEmpty
            }()

            if !arrivals.isEmpty {
                // MARK: - Far From Service Hero
                if isFarFromService {
                    FarFromTransitView(
                        icon: "train.side.front.car",
                        title: "You're far from LIRR",
                        subtitle: "No LIRR stations close by,"
                            + " but here are the nearest"
                            + " departures we found for you.",
                        accentColor: AppTheme.CommuterRailColors.lirrBlue
                    )
                }

                // Sort by distance from user / drag-search location
                let (nearYou, fartherAway, muchFarther) = viewModel.groupedDisplayBuckets(
                    from: arrivals,
                    referenceLocation: refLocation
                )

                // "Near You" section
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

                // "A Bit Farther" section
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
                }

                // "Much Farther" section
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
                }

            } else if !viewModel.isLoading {
                if !viewModel.searchText.isEmpty && !viewModel.lirrArrivals.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No LIRR results for \"\(viewModel.searchText)\""
                    )
                } else {
                    ErrorStateCard(
                        .noService(
                            icon: "train.side.front.car",
                            title: "No LIRR Service",
                            message: "We couldn't find any LIRR"
                                + " departures right now. Try searching"
                                + " for a specific station"
                                + " or check back later.",
                            brandColor: AppTheme.CommuterRailColors.lirrBlue
                        ),
                        compact: true
                    )
                }
            }

            // Inactive LIRR lines — outside the active/empty conditional
            let inactiveLIRRTotal = viewModel.ghostLIRRRoutes.count
                + viewModel.inactiveLIRRRoutes.count
            if inactiveLIRRTotal > 0 {
                InactiveLinesSectionHeader(
                    count: inactiveLIRRTotal,
                    isCollapsed: $isInactiveCollapsed
                )
                if !isInactiveCollapsed {
                    if !viewModel.ghostLIRRRoutes.isEmpty {
                        GroupedRouteList(
                            groups: viewModel.ghostLIRRRoutes,
                            viewModel: viewModel,
                            locationManager: locationManager,
                            sheetNavigator: sheetNavigator,
                            referenceLocation: refLocation
                        )
                    }
                    if !viewModel.inactiveLIRRRoutes.isEmpty {
                        InactiveRouteList(
                            routes: viewModel.inactiveLIRRRoutes,
                            sheetNavigator: sheetNavigator
                        )
                    }
                }
            }
        }
    }

}

#Preview {
    let vm: HomeViewModel = HomeViewModel()
    let lm: LocationManager = LocationManager()
    let sn: SheetNavigator = SheetNavigator()
    let date: Date = Date()
    LIRRDashboard(
        viewModel: vm,
        locationManager: lm,
        sheetNavigator: sn,
        lastUpdated: date
    )
}
