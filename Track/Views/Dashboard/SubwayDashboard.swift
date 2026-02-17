//
//  SubwayDashboard.swift
//  Track
//
//  Dashboard content for the "Subway" transport mode.
//  Shows nearby subway arrivals split into "Near You" and "A Little
//  Farther Away" sections — same distance-based pattern as the Nearby tab.
//

import SwiftUI
import CoreLocation

/// Subway-specific dashboard showing nearby arrivals and stations.
struct SubwayDashboard: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    let lastUpdated: Date?
    
    // MARK: - Distance Settings
    
    private var nearYouRadius: Double { AppSettings.shared.nearYouRadiusMeters }
    private var fartherAwayRadius: Double { AppSettings.shared.fartherAwayRadiusMeters }
    private var muchFartherAwayRadius: Double { AppSettings.shared.muchFartherAwayRadiusMeters }
    
    /// Grouped subway arrivals for tap-to-detail navigation
    private var groupedArrivals: [GroupedNearbyTransitResponse] {
        viewModel.filteredNearbyGroupedSubwayArrivals
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let refLocation = viewModel.effectiveLocation(userLocation: locationManager.currentLocation)
            
            if !groupedArrivals.isEmpty {
                // Sort by distance from user
                let sorted = groupedArrivals.sorted { g1, g2 in
                    guard let loc = refLocation else { return g1.soonestMinutes < g2.soonestMinutes }
                    return minDistance(for: g1, from: loc) < minDistance(for: g2, from: loc)
                }
                
                // Separate into 3 tiers
                let (nearYou, fartherAway, muchFarther) = separateByDistance(groups: sorted, from: refLocation)
                
                // Check if "Near You" was populated by adaptive promotion
                let wasPromoted: Bool = {
                    guard let loc = refLocation, !nearYou.isEmpty else { return false }
                    return minDistance(for: nearYou[0], from: loc) > nearYouRadius
                }()
                
                // "Near You" section (~1.5 mi)
                if !nearYou.isEmpty {
                    if wasPromoted {
                        ClosestToYouSectionHeader(
                            closestMeters: refLocation.map { minDistance(for: nearYou[0], from: $0) },
                            updated: lastUpdated,
                            isPromoted: viewModel.isSearchPinActive
                        )
                    } else {
                        NearYouSectionHeader(radiusMeters: nearYouRadius, updated: lastUpdated)
                    }
                    GroupedRouteList(
                        groups: nearYou,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator
                    )
                } else {
                    NearYouSectionHeader(radiusMeters: nearYouRadius, updated: lastUpdated)
                    EmptyTierHint()
                }
                
                // "A Little Farther Away" section (~2.5 mi)
                FartherAwaySectionHeader(radiusMeters: fartherAwayRadius)
                if !fartherAway.isEmpty {
                    GroupedRouteList(
                        groups: fartherAway,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator
                    )
                } else {
                    EmptyTierHint()
                }
                
                // "Much Farther Away" section (~5 mi)
                MuchFartherAwaySectionHeader(radiusMeters: muchFartherAwayRadius)
                if !muchFarther.isEmpty {
                    GroupedRouteList(
                        groups: muchFarther,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator
                    )
                } else {
                    EmptyTierHint()
                }
                
                // Empty after search filter
                if nearYou.isEmpty && fartherAway.isEmpty && muchFarther.isEmpty && !viewModel.searchText.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No subway results for \"\(viewModel.searchText)\""
                    )
                }
                
            } else if !viewModel.isLoading {
                // Only show empty state if data has actually loaded
                if !viewModel.searchText.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No subway results for \"\(viewModel.searchText)\""
                    )
                } else {
                    NoServiceEmptyState(
                        icon: "tram.fill",
                        title: "No Subway Nearby",
                        message: "We couldn't find any subway arrivals within your search radius. Try expanding your radius in Settings.",
                        brandColor: AppTheme.Colors.mtaBlue
                    )
                }
            }
        }
    }
    
    // MARK: - Distance Helpers (delegated to DistanceBucketUtils)
    
    private func minDistance(for group: GroupedNearbyTransitResponse, from location: CLLocation) -> CLLocationDistance {
        groupMinDistance(for: group, from: location)
    }
    
    private func separateByDistance(
        groups: [GroupedNearbyTransitResponse],
        from location: CLLocation?
    ) -> (nearYou: [GroupedNearbyTransitResponse], fartherAway: [GroupedNearbyTransitResponse], muchFarther: [GroupedNearbyTransitResponse]) {
        separateGroupsByDistance(groups: groups, from: location)
    }
}

#Preview {
    SubwayDashboard(
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        sheetNavigator: SheetNavigator(),
        lastUpdated: Date()
    )
}
