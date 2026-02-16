//
//  LIRRDashboard.swift
//  Track
//
//  Dashboard content for the "LIRR" transport mode.
//  Shows Long Island Rail Road departures.
//

import SwiftUI
import CoreLocation

/// LIRR-specific dashboard showing rail departures.
struct LIRRDashboard: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let lastUpdated: Date?
    
    /// Get filtered arrivals based on search
    private var displayArrivals: [TrainArrival] {
        viewModel.filteredLIRRArrivals
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !displayArrivals.isEmpty {
                DashboardSectionHeader(title: "LIRR Departures", updated: lastUpdated)
                
                VStack(spacing: 0) {
                    ForEach(Array(displayArrivals.prefix(AppSettings.shared.maxLirrArrivals).enumerated()), id: \.element.id) { index, arrival in
                        ArrivalRow(
                            arrival: arrival,
                            prediction: nil,
                            isTracking: viewModel.isTracking(arrival),
                            reliabilityWarning: nil,
                            onTrack: {
                                viewModel.trackLIRRArrival(arrival, location: locationManager.currentLocation)
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
                if !viewModel.searchText.isEmpty && !viewModel.lirrArrivals.isEmpty {
                    // Search returned no results but there are arrivals available
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No LIRR results for \"\(viewModel.searchText)\""
                    )
                } else {
                    EmptyStateView(
                        icon: "train.side.front.car",
                        message: "No LIRR departures available"
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
        lastUpdated: Date()
    )
}
