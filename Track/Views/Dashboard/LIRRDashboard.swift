//
//  LIRRDashboard.swift
//  Track
//
//  Dashboard content for the "LIRR" transport mode.
//  Shows Long Island Rail Road departures grouped by timing.
//

import SwiftUI

/// LIRR-specific dashboard showing rail departures.
struct LIRRDashboard: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    let lastUpdated: Date?
    
    // MARK: - Distance Settings
    
    private var nearYouRadius: Double { AppSettings.shared.nearYouRadiusMeters }
    private var fartherAwayRadius: Double { AppSettings.shared.fartherAwayRadiusMeters }
    private var muchFartherAwayRadius: Double { AppSettings.shared.muchFartherAwayRadiusMeters }
    
    /// Grouped LIRR arrivals for tap-to-detail navigation (from backend)
    private var groupedArrivals: [GroupedNearbyTransitResponse] {
        viewModel.filteredNearbyGroupedLIRRArrivals
    }
    
    /// Get filtered arrivals based on search
    private var displayArrivals: [TrainArrival] {
        viewModel.filteredLIRRArrivals
    }
    
    /// Arrivals within 15 minutes (soon)
    private var soonArrivals: [TrainArrival] {
        displayArrivals.filter { $0.minutesAway <= 15 && ($0.minutesAway > 0 || $0.estimatedTime > Date()) }
    }
    
    /// Check if user is likely far from LIRR service area
    private var isOutOfServiceArea: Bool {
        soonArrivals.isEmpty && !displayArrivals.isEmpty
    }
    
    /// Whether the soonest departure is far away (30+ min)
    private var isFarFromService: Bool {
        guard !groupedArrivals.isEmpty else { return false }
        let soonest = groupedArrivals.map(\.soonestMinutes).min() ?? 0
        return soonest > 30 || isOutOfServiceArea
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let refLocation = viewModel.effectiveLocation(userLocation: locationManager.currentLocation)

            if !groupedArrivals.isEmpty {
                // MARK: - Far From Service Hero
                if isFarFromService {
                    FarFromTransitView(
                        icon: "train.side.front.car",
                        title: "You're far from LIRR",
                        subtitle: "No LIRR stations close by, but here are the nearest departures we found for you.",
                        accentColor: AppTheme.CommuterRailColors.lirrBlue
                    )
                }

                // Sort by distance from user / drag-search location
                let (nearYou, fartherAway, muchFarther) = viewModel.groupedDisplayBuckets(
                    from: groupedArrivals,
                    referenceLocation: refLocation
                )

                // "Near You" section
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

                // "A Bit Farther" section
                if !fartherAway.isEmpty {
                    FartherAwaySectionHeader(radiusMeters: fartherAwayRadius)
                    GroupedRouteList(
                        groups: fartherAway,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator,
                        referenceLocation: refLocation
                    )
                }

                // "Much Farther" section
                if !muchFarther.isEmpty {
                    MuchFartherAwaySectionHeader(radiusMeters: muchFartherAwayRadius)
                    GroupedRouteList(
                        groups: muchFarther,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator,
                        referenceLocation: refLocation
                    )
                }
            } else if !viewModel.isLoading {
                if !viewModel.searchText.isEmpty && !viewModel.lirrArrivals.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No LIRR results for \"\(viewModel.searchText)\""
                    )
                } else {
                    // Complete empty state - no data at all
                    NoServiceEmptyState(
                        icon: "train.side.front.car",
                        title: "No LIRR Service",
                        message: "We couldn't find any LIRR departures right now. Try searching for a specific station or check back later.",
                        brandColor: AppTheme.CommuterRailColors.lirrBlue
                    )
                }
            }
        }
    }

}

#Preview {
    LIRRDashboard(
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        sheetNavigator: SheetNavigator(),
        lastUpdated: Date()
    )
}
