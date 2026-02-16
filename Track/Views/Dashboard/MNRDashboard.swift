//
//  MNRDashboard.swift
//  Track
//
//  Dashboard content for the "Metro-North" transport mode.
//  Shows Metro-North Railroad departures.
//

import SwiftUI
import CoreLocation

/// Metro-North specific dashboard showing rail departures.
struct MNRDashboard: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let lastUpdated: Date?
    
    /// Get filtered arrivals based on search
    private var displayArrivals: [TrainArrival] {
        viewModel.filteredMNRArrivals
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !displayArrivals.isEmpty {
                DashboardSectionHeader(title: "Metro-North Departures", updated: lastUpdated)
                
                VStack(spacing: 0) {
                    ForEach(Array(displayArrivals.prefix(AppSettings.shared.maxLirrArrivals).enumerated()), id: \.element.id) { index, arrival in
                        ArrivalRow(
                            arrival: arrival,
                            prediction: nil,
                            isTracking: viewModel.isTracking(arrival),
                            reliabilityWarning: nil,
                            onTrack: {
                                viewModel.trackMNRArrival(arrival, location: locationManager.currentLocation)
                            }
                        )
                        if index < min(displayArrivals.count, AppSettings.shared.maxLirrArrivals) - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            } else if !viewModel.isLoading {
                if !viewModel.searchText.isEmpty && !viewModel.mnrArrivals.isEmpty {
                    // Search returned no results but there are arrivals available
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No Metro-North results for \"\(viewModel.searchText)\""
                    )
                } else {
                    EmptyStateView(
                        icon: "train.side.rear.car",
                        message: "No Metro-North departures available"
                    )
                }
            }
        }
    }
}

#Preview {
    MNRDashboard(
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        lastUpdated: Date()
    )
}
