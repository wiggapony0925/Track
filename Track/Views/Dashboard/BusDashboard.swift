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
    let sheetNavigator: SheetNavigator
    let lastUpdated: Date?
    
    /// Grouped bus arrivals for tap-to-detail navigation
    private var groupedArrivals: [GroupedNearbyTransitResponse] {
        viewModel.groupedBusArrivals
    }
    
    /// Get filtered bus stops based on search
    private var displayStops: [BusStop] {
        viewModel.filteredBusStops
    }
    
    /// Whether the user appears to be far from bus service
    private var isFarFromService: Bool {
        // If there are stops but no arrivals, or soonest is 30+ min away
        if groupedArrivals.isEmpty && viewModel.selectedBusStop != nil && !viewModel.isLoading {
            return true
        }
        guard !groupedArrivals.isEmpty else { return false }
        let soonest = groupedArrivals.map(\.soonestMinutes).min() ?? 0
        return soonest > 30
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
            
            // Show friendly "far away" hero when user is distant
            if isFarFromService {
                FarFromTransitView(
                    icon: "bus.fill",
                    title: "You're far from bus stops",
                    subtitle: "No buses are arriving soon near you, but here's what we found nearby.",
                    accentColor: AppTheme.Colors.mtaBlue
                )
            }
            
            if !groupedArrivals.isEmpty {
                DashboardSectionHeader(title: isFarFromService ? "Nearest Arrivals" : "Arriving", updated: lastUpdated)
                
                GroupedRouteList(
                    groups: groupedArrivals,
                    viewModel: viewModel,
                    locationManager: locationManager,
                    sheetNavigator: sheetNavigator
                )
            }
            
            if !displayStops.isEmpty {
                DashboardSectionHeader(
                    title: "Nearby Bus Stops",
                    updated: groupedArrivals.isEmpty ? lastUpdated : nil
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
                } else if groupedArrivals.isEmpty {
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
        sheetNavigator: SheetNavigator(),
        lastUpdated: Date()
    )
}
