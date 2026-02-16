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
    
    /// Check if user is likely far from LIRR service area
    private var isOutOfServiceArea: Bool {
        soonArrivals.isEmpty && !displayArrivals.isEmpty
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !displayArrivals.isEmpty {
                // MARK: - Out of Service Area Notice
                if isOutOfServiceArea {
                    OutOfAreaNoticeView(
                        message: "No LIRR trains nearby",
                        subtitle: "Showing closest available departures"
                    )
                }
                
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
                
                // MARK: - Later / Closest Section
                if !laterArrivals.isEmpty {
                    let sectionTitle = soonArrivals.isEmpty ? "Closest Departures" : "Later"
                    CommuterRailSectionHeader(title: sectionTitle, iconName: soonArrivals.isEmpty ? "mappin.circle" : "clock", color: soonArrivals.isEmpty ? AppTheme.CommuterRailColors.lirrBlue : AppTheme.Colors.textSecondary, updated: soonArrivals.isEmpty ? lastUpdated : nil)
                    
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
                    // Complete empty state - no data at all
                    NoServiceEmptyState(
                        icon: "train.side.front.car",
                        title: "No LIRR Service",
                        message: "We couldn't find any LIRR departures right now. Try searching for a specific station or check back later.",
                        brandColor: AppTheme.CommuterRailColors.lirrBlue
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
