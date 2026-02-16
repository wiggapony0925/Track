//
//  SubwayDashboard.swift
//  Track
//
//  Dashboard content for the "Subway" transport mode.
//  Shows nearby subway arrivals and stations.
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
    
    /// Grouped subway arrivals for tap-to-detail navigation
    private var groupedArrivals: [GroupedNearbyTransitResponse] {
        viewModel.groupedSubwayArrivals
    }
    
    /// Get filtered stations based on search
    private var displayStations: [(stationID: String, name: String, distance: Double, routeIDs: [String])] {
        viewModel.filteredNearbyStations
    }
    
    /// Whether the user appears to be far from subway service
    private var isFarFromService: Bool {
        guard !groupedArrivals.isEmpty else { return false }
        let soonest = groupedArrivals.map(\.soonestMinutes).min() ?? 0
        return soonest > 30
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !groupedArrivals.isEmpty {
                // Show friendly "far away" hero when user is distant
                if isFarFromService {
                    FarFromTransitView(
                        icon: "tram.fill",
                        title: "You're far from the subway",
                        subtitle: "Looks like there aren't any trains close by right now. Here are the nearest departures we found.",
                        accentColor: AppTheme.Colors.mtaBlue
                    )
                }
                
                DashboardSectionHeader(title: isFarFromService ? "Nearest Departures" : "Nearby Arrivals", updated: lastUpdated)
                
                GroupedRouteList(
                    groups: groupedArrivals,
                    viewModel: viewModel,
                    locationManager: locationManager,
                    sheetNavigator: sheetNavigator
                )
            } else if !viewModel.isLoading {
                if !viewModel.searchText.isEmpty && !viewModel.upcomingArrivals.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No subway results for \"\(viewModel.searchText)\""
                    )
                } else {
                    EmptyStateView(
                        icon: "tram.fill",
                        message: "No subway arrivals nearby"
                    )
                }
            }
            
            if !displayStations.isEmpty {
                DashboardSectionHeader(
                    title: "Nearby Stations",
                    updated: groupedArrivals.isEmpty ? lastUpdated : nil
                )
                
                VStack(spacing: 0) {
                    ForEach(Array(displayStations.enumerated()), id: \.element.stationID) { index, station in
                        NearbyStationRow(
                            name: station.name,
                            distance: station.distance,
                            routeIDs: station.routeIDs
                        )
                        if index < displayStations.count - 1 {
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
