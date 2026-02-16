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
import CoreLocation

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
                // Sort by distance from user
                let sorted = groupedArrivals.sorted { g1, g2 in
                    guard let loc = refLocation else { return g1.soonestMinutes < g2.soonestMinutes }
                    return minDistance(for: g1, from: loc) < minDistance(for: g2, from: loc)
                }
                
                // Separate into 3 tiers
                let (nearYou, fartherAway, muchFarther) = separateByDistance(groups: sorted, from: refLocation)
                
                // If nothing is "near you", show friendly hero
                if nearYou.isEmpty && (!fartherAway.isEmpty || !muchFarther.isEmpty) {
                    FarFromTransitView(
                        icon: "bus.fill",
                        title: "You're far from bus stops",
                        subtitle: "No buses are super close, but here's what's around you.",
                        accentColor: AppTheme.Colors.mtaBlue
                    )
                }
                
                // "Near You" section (~1.5 mi)
                if !nearYou.isEmpty {
                    NearYouSectionHeader(radiusMeters: nearYouRadius, updated: lastUpdated)
                    GroupedRouteList(
                        groups: nearYou,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator
                    )
                }
                
                // "A Little Farther Away" section (~2.5 mi)
                if !fartherAway.isEmpty {
                    FartherAwaySectionHeader(radiusMeters: fartherAwayRadius)
                    GroupedRouteList(
                        groups: fartherAway,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator
                    )
                }
                
                // "Much Farther Away" section (~5 mi)
                if !muchFarther.isEmpty {
                    MuchFartherAwaySectionHeader(radiusMeters: muchFartherAwayRadius)
                    GroupedRouteList(
                        groups: muchFarther,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator
                    )
                }
                
                // Empty after search filter
                if nearYou.isEmpty && fartherAway.isEmpty && muchFarther.isEmpty && !viewModel.searchText.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No bus results for \"\(viewModel.searchText)\""
                    )
                }
                
            } else if !viewModel.isLoading {
                EmptyStateView(
                    icon: "bus.fill",
                    message: "No bus arrivals nearby"
                )
            }
        }
    }
    
    // MARK: - Distance Helpers
    
    private func minDistance(for group: GroupedNearbyTransitResponse, from location: CLLocation) -> CLLocationDistance {
        let allArrivals = group.directions.flatMap { $0.arrivals }
        let distances = allArrivals.compactMap { arrival -> CLLocationDistance? in
            guard let lat = arrival.stopLat, let lon = arrival.stopLon else { return nil }
            return location.distance(from: CLLocation(latitude: lat, longitude: lon))
        }
        return distances.min() ?? Double.greatestFiniteMagnitude
    }
    
    private func separateByDistance(
        groups: [GroupedNearbyTransitResponse],
        from location: CLLocation?
    ) -> (nearYou: [GroupedNearbyTransitResponse], fartherAway: [GroupedNearbyTransitResponse], muchFarther: [GroupedNearbyTransitResponse]) {
        guard let location = location else {
            return (groups, [], [])
        }
        
        var nearYou: [GroupedNearbyTransitResponse] = []
        var fartherAway: [GroupedNearbyTransitResponse] = []
        var muchFarther: [GroupedNearbyTransitResponse] = []
        
        for group in groups {
            let dist = minDistance(for: group, from: location)
            if dist <= nearYouRadius {
                nearYou.append(group)
            } else if dist <= fartherAwayRadius {
                fartherAway.append(group)
            } else if dist <= muchFartherAwayRadius {
                muchFarther.append(group)
            }
        }
        
        return (nearYou, fartherAway, muchFarther)
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
