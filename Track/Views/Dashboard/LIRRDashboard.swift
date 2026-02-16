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
    let sheetNavigator: SheetNavigator
    let lastUpdated: Date?
    
    /// Grouped LIRR arrivals for tap-to-detail navigation
    private var groupedArrivals: [GroupedNearbyTransitResponse] {
        viewModel.groupedLIRRArrivals
    }
    
    /// Get filtered arrivals based on search
    private var displayArrivals: [TrainArrival] {
        viewModel.filteredLIRRArrivals
    }
    
    /// Arrivals within 15 minutes (soon)
    private var soonArrivals: [TrainArrival] {
        displayArrivals.filter { $0.minutesAway <= 15 && ($0.minutesAway > 0 || $0.estimatedTime > Date()) }
    }
    
    /// Arrivals more than 15 minutes away
    private var laterArrivals: [TrainArrival] {
        displayArrivals.filter { $0.minutesAway > 15 }
    }
    
    /// Check if user is likely far from LIRR service area
    private var isOutOfServiceArea: Bool {
        soonArrivals.isEmpty && !displayArrivals.isEmpty
    }
    
    /// Whether the soonest departure is far away (30+ min)
    private var isFarFromService: Bool {
        guard !groupedArrivals.isEmpty else { return false }
        let soonest = groupedArrivals.map(\.soonestMinutes).min() ?? 0
        return soonest > 30 || isOutOfServiceArea
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !groupedArrivals.isEmpty {
                // MARK: - Far From Service Hero
                if isFarFromService {
                    FarFromTransitView(
                        icon: "train.side.front.car",
                        title: "You're far from LIRR",
                        subtitle: "No LIRR stations close by, but here are the nearest departures we found for you.",
                        accentColor: AppTheme.CommuterRailColors.lirrBlue
                    )
                }
                
                // MARK: - Tappable Route Cards
                CommuterRailSectionHeader(
                    title: isFarFromService ? "Nearest Departures" : (soonArrivals.isEmpty ? "Upcoming Departures" : "Arriving Soon"),
                    iconName: "train.side.front.car",
                    color: AppTheme.CommuterRailColors.lirrBlue,
                    updated: lastUpdated
                )
                
                GroupedRouteList(
                    groups: groupedArrivals,
                    viewModel: viewModel,
                    locationManager: locationManager,
                    sheetNavigator: sheetNavigator
                )
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
        sheetNavigator: SheetNavigator(),
        lastUpdated: Date()
    )
}
