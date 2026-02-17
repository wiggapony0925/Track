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
    let sheetNavigator: SheetNavigator
    let lastUpdated: Date?
    
    /// Grouped MNR arrivals for tap-to-detail navigation (from backend)
    private var groupedArrivals: [GroupedNearbyTransitResponse] {
        viewModel.nearbyGroupedMNRArrivals
    }
    
    /// Get filtered arrivals based on search
    private var displayArrivals: [TrainArrival] {
        viewModel.filteredMNRArrivals
    }
    
    /// Arrivals within 15 minutes (soon)
    private var soonArrivals: [TrainArrival] {
        displayArrivals.filter { $0.minutesAway <= 15 && ($0.minutesAway > 0 || $0.estimatedTime > Date()) }
    }
    
    /// Check if user is likely far from Metro-North service area
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
                        icon: "train.side.rear.car",
                        title: "You're far from Metro-North",
                        subtitle: "No Metro-North stations close by, but here are the nearest departures we found for you.",
                        accentColor: AppTheme.CommuterRailColors.mnrBlue
                    )
                }
                
                // MARK: - Tappable Route Cards
                CommuterRailSectionHeader(
                    title: isFarFromService ? "Nearest Departures" : (soonArrivals.isEmpty ? "Upcoming Departures" : "Arriving Soon"),
                    iconName: "train.side.rear.car",
                    color: AppTheme.CommuterRailColors.mnrBlue,
                    updated: lastUpdated
                )
                
                GroupedRouteList(
                    groups: groupedArrivals,
                    viewModel: viewModel,
                    locationManager: locationManager,
                    sheetNavigator: sheetNavigator,
                    referenceLocation: viewModel.effectiveLocation(userLocation: locationManager.currentLocation)
                )
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
        sheetNavigator: SheetNavigator(),
        lastUpdated: Date()
    )
}
