//
//  LIRRDashboard.swift
//  Track
//
//  Dashboard content for the "LIRR" transport mode.
//  Shows Long Island Rail Road departures grouped by timing.
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
    
    /// Arrivals within 15 minutes (soon)
    private var soonArrivals: [TrainArrival] {
        displayArrivals.filter { $0.minutesAway <= 15 }
    }
    
    /// Arrivals more than 15 minutes away
    private var laterArrivals: [TrainArrival] {
        displayArrivals.filter { $0.minutesAway > 15 }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !displayArrivals.isEmpty {
                // MARK: - Arriving Soon Section
                if !soonArrivals.isEmpty {
                    CommuterRailSectionHeader(title: "Arriving Soon", iconName: "train.side.front.car", color: AppTheme.CommuterRailColors.lirrBlue, updated: lastUpdated)
                    
                    VStack(spacing: 0) {
                        ForEach(Array(soonArrivals.prefix(AppSettings.shared.maxLirrArrivals).enumerated()), id: \.element.id) { index, arrival in
                            CommuterRailArrivalRow(
                                arrival: arrival,
                                brandColor: AppTheme.CommuterRailColors.lirrBlue,
                                isTracking: viewModel.isTracking(arrival),
                                onTrack: {
                                    viewModel.trackLIRRArrival(arrival, location: locationManager.currentLocation)
                                }
                            )
                            if index < min(soonArrivals.count, AppSettings.shared.maxLirrArrivals) - 1 {
                                Divider()
                                    .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                            }
                        }
                    }
                    .background(AppTheme.Colors.cardBackground)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
                    .padding(.horizontal, AppTheme.Layout.margin)
                }
                
                // MARK: - Later Section
                if !laterArrivals.isEmpty {
                    CommuterRailSectionHeader(title: "Later", iconName: "clock", color: AppTheme.Colors.textSecondary, updated: soonArrivals.isEmpty ? lastUpdated : nil)
                    
                    VStack(spacing: 0) {
                        ForEach(Array(laterArrivals.prefix(AppSettings.shared.maxLirrArrivals).enumerated()), id: \.element.id) { index, arrival in
                            CommuterRailArrivalRow(
                                arrival: arrival,
                                brandColor: AppTheme.CommuterRailColors.lirrBlue,
                                isTracking: viewModel.isTracking(arrival),
                                onTrack: {
                                    viewModel.trackLIRRArrival(arrival, location: locationManager.currentLocation)
                                }
                            )
                            if index < min(laterArrivals.count, AppSettings.shared.maxLirrArrivals) - 1 {
                                Divider()
                                    .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                            }
                        }
                    }
                    .background(AppTheme.Colors.cardBackground)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
                    .padding(.horizontal, AppTheme.Layout.margin)
                }
            } else if !viewModel.isLoading {
                if !viewModel.searchText.isEmpty && !viewModel.lirrArrivals.isEmpty {
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
