//
//  BusDashboard.swift
//  Track
//
//  Dashboard content for the "Bus" transport mode.
//  Shows bus arrivals and nearby bus stops.
//

import SwiftUI

/// Bus-specific dashboard showing arrivals and nearby stops.
struct BusDashboard: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let lastUpdated: Date?
    
    /// Get filtered arrivals based on search
    private var displayArrivals: [BusArrival] {
        viewModel.filteredBusArrivals
    }
    
    /// Get filtered bus stops based on search
    private var displayStops: [BusStop] {
        viewModel.filteredBusStops
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let stop = viewModel.selectedBusStop {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stop.name)
                        .font(.custom("Helvetica-Bold", size: 20))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Live Bus Arrivals")
                        .font(.custom("Helvetica", size: 14))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            }
            
            if !displayArrivals.isEmpty {
                DashboardSectionHeader(title: "Arriving", updated: lastUpdated)
                
                VStack(spacing: 0) {
                    ForEach(Array(displayArrivals.enumerated()), id: \.element.id) { index, arrival in
                        BusArrivalRow(
                            arrival: arrival,
                            isTracking: viewModel.isTracking(arrival),
                            reliabilityWarning: nil,
                            onTrack: {
                                viewModel.trackBusArrival(arrival, location: locationManager.currentLocation)
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
            }
            
            if !displayStops.isEmpty {
                DashboardSectionHeader(
                    title: "Nearby Bus Stops",
                    updated: displayArrivals.isEmpty ? lastUpdated : nil
                )
                
                VStack(spacing: 0) {
                    ForEach(Array(displayStops.enumerated()), id: \.element.id) { index, stop in
                        Button {
                            Task {
                                await viewModel.fetchBusArrivals(for: stop)
                            }
                        } label: {
                            NearbyBusStopRow(stop: stop)
                        }
                        .buttonStyle(.plain)
                        if index < displayStops.count - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            } else if !viewModel.isLoading {
                if !viewModel.searchText.isEmpty && !viewModel.nearbyBusStops.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No bus results for \"\(viewModel.searchText)\""
                    )
                } else {
                    EmptyStateView(
                        icon: "bus.fill",
                        message: "No bus stops nearby"
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
        lastUpdated: Date()
    )
}
