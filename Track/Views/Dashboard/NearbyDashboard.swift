//
//  NearbyDashboard.swift
//  Track
//
//  Dashboard content for the "Nearby" transport mode.
//  Shows unified transit arrivals (buses and trains) sorted by distance.
//

import SwiftUI
import CoreLocation
import MapKit

/// Nearby transit dashboard showing all nearby buses and trains.
struct NearbyDashboard: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    let lastUpdated: Date?
    @Binding var cameraPosition: MapCameraPosition
    @Binding var is3DMode: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Use active search pin OR user location for distance calculation
            let refLocation = viewModel.effectiveLocation(userLocation: locationManager.currentLocation)
            
            if !viewModel.groupedTransit.isEmpty {
                let filtered = viewModel.filteredGroupedTransit
                
                // Sort groups by distance (closest entrance/stop)
                let sorted = filtered.sorted { group1, group2 in
                    guard let loc = refLocation else { return group1.soonestMinutes < group2.soonestMinutes }
                    return minDistance(for: group1, from: loc) < minDistance(for: group2, from: loc)
                }
                
                // Display ALL nearby transit sorted by distance
                if !sorted.isEmpty {
                    DashboardSectionHeader(title: "Buses & Trains Arriving", updated: lastUpdated)
                    GroupedRouteList(
                        groups: sorted,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator
                    )
                }
                
                if filtered.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        message: "No results for \"\(viewModel.searchText)\""
                    )
                }
                
            } else if !viewModel.nearbyTransit.isEmpty {
                // Fallback: Flat list sorted by distance
                let sorted = viewModel.nearbyTransit.sorted { arrival1, arrival2 in
                    guard let loc = refLocation else { return arrival1.minutesAway < arrival2.minutesAway }
                    return distance(for: arrival1, from: loc) < distance(for: arrival2, from: loc)
                }
                
                if !sorted.isEmpty {
                    DashboardSectionHeader(title: "Buses & Trains Arriving", updated: lastUpdated)
                    FlatTransitList(
                        arrivals: sorted,
                        viewModel: viewModel,
                        locationManager: locationManager
                    )
                }
                
            } else if !viewModel.isLoading {
                if let nearest = viewModel.nearestTransit {
                    DashboardSectionHeader(title: "Nearest Metro", updated: nil)
                    NearestMetroCard(
                        arrival: nearest,
                        distanceMeters: viewModel.nearestTransitDistance,
                        onCenter: { coordinate in
                            withAnimation(.easeInOut(duration: 0.6)) {
                                cameraPosition = .camera(MapCamera(
                                    centerCoordinate: coordinate,
                                    distance: AppTheme.MapConfig.userZoomDistance,
                                    heading: 0,
                                    pitch: is3DMode ? 60 : 0
                                ))
                            }
                        }
                    )
                } else {
                    OutOfServiceAreaCard(
                        cameraPosition: $cameraPosition,
                        is3DMode: $is3DMode
                    )
                }
            }
        }
    }
    
    // MARK: - Distance Helpers
    
    private func minDistance(for group: GroupedNearbyTransitResponse, from location: CLLocation) -> CLLocationDistance {
        let allArrivals = group.directions.flatMap { $0.arrivals }
        let distances = allArrivals.compactMap { arrival -> CLLocationDistance? in
            guard let lat = arrival.stopLat, let lon = arrival.stopLon else { return nil }
            return location.distance(from: CLLocation(latitude: lat, longitude: lon))
        }
        return distances.min() ?? Double.greatestFiniteMagnitude
    }
    
    private func distance(for arrival: NearbyTransitResponse, from location: CLLocation) -> CLLocationDistance {
        guard let lat = arrival.stopLat, let lon = arrival.stopLon else { return Double.greatestFiniteMagnitude }
        return location.distance(from: CLLocation(latitude: lat, longitude: lon))
    }
}

// MARK: - Grouped Route List

struct GroupedRouteList: View {
    let groups: [GroupedNearbyTransitResponse]
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                GroupedRouteRow(group: group) { directionIndex in
                    RouteAnalyticsManager.shared.logInteraction(routeId: group.routeId)
                    Task {
                        await viewModel.selectGroupedRoute(group, directionIndex: directionIndex, userLocation: locationManager.currentLocation)
                        sheetNavigator.navigate(to: .routeDetail(group: group, directionIndex: directionIndex))
                    }
                }
                if index < groups.count - 1 {
                    Divider()
                        .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                }
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius, style: .continuous))
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

// MARK: - Flat Transit List

struct FlatTransitList: View {
    let arrivals: [NearbyTransitResponse]
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(arrivals.enumerated()), id: \.element.id) { index, arrival in
                NearbyTransitRow(
                    arrival: arrival,
                    isTracking: viewModel.isTracking(arrival),
                    onTrack: {
                        viewModel.trackNearbyArrival(arrival, location: locationManager.currentLocation)
                    },
                    onSelectRoute: arrival.isBus ? {
                        RouteAnalyticsManager.shared.logInteraction(routeId: arrival.routeId)
                        Task { await viewModel.selectArrival(arrival, userLocation: locationManager.currentLocation) }
                    } : nil,
                    userLocation: locationManager.currentLocation
                )
                if index < arrivals.count - 1 {
                    Divider()
                        .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                }
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius, style: .continuous))
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

// MARK: - Out of Service Area Card

struct OutOfServiceAreaCard: View {
    @Binding var cameraPosition: MapCameraPosition
    @Binding var is3DMode: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tram.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                Text("No Nearby Transit")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Spacer()
            }
            
            Text("We couldn't find any arrivals nearby. Try moving closer to a subway station or bus stop, or use the search pin to explore a different area.")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            
            Button {
                withAnimation(.easeInOut(duration: 1.0)) {
                    cameraPosition = .camera(MapCamera(
                        centerCoordinate: AppTheme.MapConfig.nycCenter,
                        distance: AppTheme.MapConfig.userZoomDistance * 1.5,
                        heading: 0,
                        pitch: is3DMode ? 60 : 0
                    ))
                }
            } label: {
                Text("Explore New York City")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.Colors.mtaBlue)
                    .cornerRadius(10)
            }
            .padding(.top, 4)
        }
        .padding(AppTheme.Layout.cardPadding)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

#Preview {
    NearbyDashboard(
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        sheetNavigator: SheetNavigator(),
        lastUpdated: Date(),
        cameraPosition: .constant(.automatic),
        is3DMode: .constant(false)
    )
}
