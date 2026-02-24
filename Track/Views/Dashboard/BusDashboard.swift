//
//  BusDashboard.swift
//  Track
//
//  Dashboard content for the "Bus" transport mode.
//  Shows nearby bus arrivals split into "Near You" and "A Little
//  Farther Away" sections — same distance-based pattern as the
//  Nearby and Subway tabs.
//

import SwiftUI

/// Bus-specific dashboard showing grouped bus arrivals.
struct BusDashboard: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    let lastUpdated: Date?
    
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
            let refLocation = viewModel.effectiveLocation(userLocation: locationManager.currentLocation)
            
            if !groupedArrivals.isEmpty {
                // Separate using shared display-distance source so categories
                // and row distance are based on the same nearest-stop logic.
                let (nearYou, fartherAway, muchFarther) = viewModel.groupedDisplayBuckets(
                    from: groupedArrivals,
                    referenceLocation: refLocation
                )
                
                // "Near You" section (~1.5 mi)
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
                
                // "A Little Farther Away" section (~2.5 mi)
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
                
                // "Much Farther Away" section (~5 mi)
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
                
                // Empty after search filter
                if nearYou.isEmpty && fartherAway.isEmpty && muchFarther.isEmpty && !viewModel.searchText.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No bus results for \"\(viewModel.searchText)\""
                    )
                }
                
            } else if !viewModel.isLoading {
                if !viewModel.searchText.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No bus results for \"\(viewModel.searchText)\""
                    )
                } else {
                    NoServiceEmptyState(
                        icon: "bus.fill",
                        title: "No Buses Nearby",
                        message: "We couldn't find any bus arrivals within your search radius. Try expanding your radius in Settings.",
                        brandColor: AppTheme.Colors.mtaBlue
                    )
                }
            }
        }
    }
    
}

#Preview {
    BusDashboard(
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        sheetNavigator: SheetNavigator(),
        lastUpdated: Date()
    )
}
