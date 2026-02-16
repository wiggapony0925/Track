//
//  NearbyDashboard.swift
//  Track
//
//  Dashboard content for the "Nearby" transport mode.
//  Shows unified transit arrivals (buses and trains) sorted by distance,
//  grouped into "Near You" and "A Little Farther Away" sections.
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
    
    // MARK: - Computed Properties
    
    /// Radius thresholds from settings
    private var nearYouRadius: Double { AppSettings.shared.nearYouRadiusMeters }
    private var fartherAwayRadius: Double { AppSettings.shared.fartherAwayRadiusMeters }
    private var muchFartherAwayRadius: Double { AppSettings.shared.muchFartherAwayRadiusMeters }
    
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
                
                // Separate into "Near You", "Farther Away", and "Much Farther Away" based on distance
                let (nearYou, fartherAway, muchFarther) = separateByDistance(groups: sorted, from: refLocation)
                
                // If nothing is "near you", show the friendly far-from-transit hero
                if nearYou.isEmpty && (!fartherAway.isEmpty || !muchFarther.isEmpty) {
                    FarFromTransitView(
                        icon: "location.slash.circle",
                        title: "Nothing super close",
                        subtitle: "You're a bit far from the nearest stops, but here's what's around you.",
                        accentColor: AppTheme.Colors.mtaBlue
                    )
                }
                
                // Display "Near You" section
                if !nearYou.isEmpty {
                    NearYouSectionHeader(radiusMeters: nearYouRadius, updated: lastUpdated)
                    GroupedRouteList(
                        groups: nearYou,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator
                    )
                }
                
                // Display "A Little Farther Away" section
                if !fartherAway.isEmpty {
                    FartherAwaySectionHeader(radiusMeters: fartherAwayRadius)
                    GroupedRouteList(
                        groups: fartherAway,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator
                    )
                }
                
                // Display "Much Farther Away" section
                if !muchFarther.isEmpty {
                    MuchFartherAwaySectionHeader(radiusMeters: muchFartherAwayRadius)
                    GroupedRouteList(
                        groups: muchFarther,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator
                    )
                }
                
                // Show empty state only when all sections are empty after filtering
                if nearYou.isEmpty && fartherAway.isEmpty && muchFarther.isEmpty && !viewModel.searchText.isEmpty {
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
                
                // Separate flat arrivals by distance
                let (nearYouArrivals, fartherAwayArrivals) = separateArrivalsByDistance(arrivals: sorted, from: refLocation)
                
                if !nearYouArrivals.isEmpty {
                    NearYouSectionHeader(radiusMeters: nearYouRadius, updated: lastUpdated)
                    FlatTransitList(
                        arrivals: nearYouArrivals,
                        viewModel: viewModel,
                        locationManager: locationManager
                    )
                }
                
                if !fartherAwayArrivals.isEmpty {
                    FartherAwaySectionHeader(radiusMeters: fartherAwayRadius)
                    FlatTransitList(
                        arrivals: fartherAwayArrivals,
                        viewModel: viewModel,
                        locationManager: locationManager
                    )
                }
                
            } else if !viewModel.isLoading {
                if let nearest = viewModel.nearestTransit {
                    FarFromTransitView(
                        icon: "figure.walk",
                        title: "Oh no, you're far from transit!",
                        subtitle: "We couldn't find anything nearby, but we found a station a bit further out.",
                        accentColor: AppTheme.Colors.mtaBlue
                    )
                    
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
    
    /// Separates grouped transit into "Near You", "Farther Away", and "Much Farther Away" based on distance thresholds
    private func separateByDistance(
        groups: [GroupedNearbyTransitResponse],
        from location: CLLocation?
    ) -> (nearYou: [GroupedNearbyTransitResponse], fartherAway: [GroupedNearbyTransitResponse], muchFarther: [GroupedNearbyTransitResponse]) {
        guard let location = location else {
            // No location available, put all in nearYou
            return (groups, [], [])
        }
        
        var nearYou: [GroupedNearbyTransitResponse] = []
        var fartherAway: [GroupedNearbyTransitResponse] = []
        var muchFarther: [GroupedNearbyTransitResponse] = []
        
        for group in groups {
            let dist = minDistance(for: group, from: location)
            if dist <= nearYouRadius {
                nearYou.append(group)
            } else if dist <= fartherAwayRadius {
                fartherAway.append(group)
            } else if dist <= muchFartherAwayRadius {
                muchFarther.append(group)
            }
        }
        
        return (nearYou, fartherAway, muchFarther)
    }
    
    /// Separates flat arrivals into "Near You" and "Farther Away" based on distance thresholds
    private func separateArrivalsByDistance(
        arrivals: [NearbyTransitResponse],
        from location: CLLocation?
    ) -> (nearYou: [NearbyTransitResponse], fartherAway: [NearbyTransitResponse]) {
        guard let location = location else {
            return (arrivals, [])
        }
        
        var nearYou: [NearbyTransitResponse] = []
        var fartherAway: [NearbyTransitResponse] = []
        
        for arrival in arrivals {
            let dist = distance(for: arrival, from: location)
            if dist <= nearYouRadius {
                nearYou.append(arrival)
            } else if dist <= fartherAwayRadius {
                fartherAway.append(arrival)
            }
        }
        
        return (nearYou, fartherAway)
    }
}

// MARK: - Section Headers

/// "Near You" section header - compact icon-based indicator
struct NearYouSectionHeader: View {
    let radiusMeters: Double
    let updated: Date?
    
    private var radiusDisplay: String {
        let miles = metersToMiles(radiusMeters)
        if miles < 0.1 {
            return String(format: "%.0f ft", metersToFeet(radiusMeters))
        }
        return String(format: "%.1f mi", miles)
    }
    
    var body: some View {
        HStack(spacing: 6) {
            // Location indicator with distance badge
            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                
                Text(radiusDisplay)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(AppTheme.Colors.successGreen)
            )
            
            Spacer()
            
            if let updated = updated {
                Text(updated, style: .time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

/// "A Little Farther Away" section header - compact icon-based indicator
struct FartherAwaySectionHeader: View {
    let radiusMeters: Double
    
    private var radiusDisplay: String {
        let miles = metersToMiles(radiusMeters)
        return String(format: "%.1f mi", miles)
    }
    
    var body: some View {
        HStack(spacing: 6) {
            // Walking indicator with distance badge
            HStack(spacing: 4) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                
                Text(radiusDisplay)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(AppTheme.Colors.mtaBlue)
            )
            
            Spacer()
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// "Much Farther Away" section header - compact icon-based indicator with car icon
struct MuchFartherAwaySectionHeader: View {
    let radiusMeters: Double
    
    private var radiusDisplay: String {
        let miles = metersToMiles(radiusMeters)
        return String(format: "%.1f mi", miles)
    }
    
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "car.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                
                Text(radiusDisplay)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.orange)
            )
            
            Spacer()
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 10)
        .padding(.bottom, 4)
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
                        // Navigate only after route selection completes successfully
                        // The viewModel sets isRouteDetailPresented = true on success
                        if viewModel.isRouteDetailPresented {
                            sheetNavigator.navigate(to: .routeDetail(group: group, directionIndex: directionIndex))
                        }
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
