//
//  MNRDashboard.swift
//  Track
//
//  Dashboard content for the "Metro-North" transport mode.
//  Shows Metro-North Railroad departures grouped by timing.
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
    
    /// Arrivals within 15 minutes (soon)
    private var soonArrivals: [TrainArrival] {
        displayArrivals.filter { $0.minutesAway <= 15 }
    }
    
    /// Arrivals more than 15 minutes away
    private var laterArrivals: [TrainArrival] {
        displayArrivals.filter { $0.minutesAway > 15 }
    }
    
    /// Check if user is likely far from Metro-North service area
    private var isOutOfServiceArea: Bool {
        soonArrivals.isEmpty && !displayArrivals.isEmpty
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !displayArrivals.isEmpty {
                // MARK: - Out of Service Area Notice
                if isOutOfServiceArea {
                    OutOfAreaNoticeView(
                        icon: "train.side.rear.car",
                        message: "No Metro-North trains nearby",
                        subtitle: "Showing closest available departures"
                    )
                }
                
                // MARK: - Arriving Soon Section
                if !soonArrivals.isEmpty {
                    CommuterRailSectionHeader(title: "Arriving Soon", iconName: "train.side.rear.car", color: AppTheme.CommuterRailColors.mnrBlue, updated: lastUpdated)
                    
                    VStack(spacing: 0) {
                        ForEach(Array(soonArrivals.prefix(AppSettings.shared.maxLirrArrivals).enumerated()), id: \.element.id) { index, arrival in
                            CommuterRailArrivalRow(
                                arrival: arrival,
                                brandColor: AppTheme.CommuterRailColors.mnrBlue,
                                isTracking: viewModel.isTracking(arrival),
                                onTrack: {
                                    viewModel.trackMNRArrival(arrival, location: locationManager.currentLocation)
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
                
                // MARK: - Later / Closest Section
                if !laterArrivals.isEmpty {
                    let sectionTitle = soonArrivals.isEmpty ? "Closest Departures" : "Later"
                    CommuterRailSectionHeader(title: sectionTitle, iconName: soonArrivals.isEmpty ? "mappin.circle" : "clock", color: soonArrivals.isEmpty ? AppTheme.CommuterRailColors.mnrBlue : AppTheme.Colors.textSecondary, updated: soonArrivals.isEmpty ? lastUpdated : nil)
                    
                    VStack(spacing: 0) {
                        ForEach(Array(laterArrivals.prefix(AppSettings.shared.maxLirrArrivals).enumerated()), id: \.element.id) { index, arrival in
                            CommuterRailArrivalRow(
                                arrival: arrival,
                                brandColor: AppTheme.CommuterRailColors.mnrBlue,
                                isTracking: viewModel.isTracking(arrival),
                                onTrack: {
                                    viewModel.trackMNRArrival(arrival, location: locationManager.currentLocation)
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
                if !viewModel.searchText.isEmpty && !viewModel.mnrArrivals.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No Metro-North results for \"\(viewModel.searchText)\""
                    )
                } else {
                    // Complete empty state - no data at all
                    NoServiceEmptyState(
                        icon: "train.side.rear.car",
                        title: "No Metro-North Service",
                        message: "We couldn't find any Metro-North departures right now. Try searching for a specific station or check back later.",
                        brandColor: AppTheme.CommuterRailColors.mnrBlue
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
