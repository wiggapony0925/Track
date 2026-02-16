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
    let lastUpdated: Date?
    
    /// Get filtered arrivals based on search
    private var displayArrivals: [TrainArrival] {
        viewModel.filteredSubwayArrivals
    }
    
    /// Get filtered stations based on search
    private var displayStations: [(stationID: String, name: String, distance: Double, routeIDs: [String])] {
        viewModel.filteredNearbyStations
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !displayArrivals.isEmpty {
                DashboardSectionHeader(title: "Nearby Arrivals", updated: lastUpdated)
                
                VStack(spacing: 0) {
                    ForEach(Array(displayArrivals.enumerated()), id: \.element.id) { index, arrival in
                        ArrivalRow(
                            arrival: arrival,
                            prediction: nil,
                            isTracking: viewModel.isTracking(arrival),
                            reliabilityWarning: nil,
                            onTrack: {
                                viewModel.trackSubwayArrival(arrival, location: locationManager.currentLocation)
                            }
                        )
                        if index < displayArrivals.count - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
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
                    updated: displayArrivals.isEmpty ? lastUpdated : nil
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
        lastUpdated: Date()
    )
}
