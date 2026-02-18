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
                
                // Check if the "Near You" section was populated via adaptive promotion
                // (i.e. no routes were truly within nearYouRadius, but closest were promoted)
                let wasPromoted: Bool = {
                    guard let loc = refLocation, !nearYou.isEmpty else { return false }
                    // If the closest route in "Near You" is beyond the radius, it was promoted
                    return minDistance(for: nearYou[0], from: loc) > nearYouRadius
                }()
                
                // Display "Near You" section (includes promoted closest routes when applicable)
                if !nearYou.isEmpty {
                    if wasPromoted {
                        // Adaptive header — the results were promoted from a farther bucket
                        ClosestToYouSectionHeader(
                            closestMeters: refLocation.map { minDistance(for: nearYou[0], from: $0) },
                            updated: lastUpdated,
                            isPromoted: viewModel.isSearchPinActive
                        )
                    } else {
                        NearYouSectionHeader(radiusMeters: nearYouRadius, updated: lastUpdated)
                    }
                    GroupedRouteList(
                        groups: nearYou,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator,
                        referenceLocation: refLocation
                    )
                } else {
                    NearYouSectionHeader(radiusMeters: nearYouRadius, updated: lastUpdated)
                    EmptyTierHint()
                }
                
                // Display "A Little Farther Away" section
                FartherAwaySectionHeader(radiusMeters: fartherAwayRadius)
                if !fartherAway.isEmpty {
                    GroupedRouteList(
                        groups: fartherAway,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator,
                        referenceLocation: refLocation
                    )
                } else {
                    EmptyTierHint()
                }
                
                // Display "Much Farther Away" section
                MuchFartherAwaySectionHeader(radiusMeters: muchFartherAwayRadius)
                if !muchFarther.isEmpty {
                    GroupedRouteList(
                        groups: muchFarther,
                        viewModel: viewModel,
                        locationManager: locationManager,
                        sheetNavigator: sheetNavigator,
                        referenceLocation: refLocation
                    )
                } else {
                    EmptyTierHint()
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
    
    // MARK: - Distance Helpers (delegated to DistanceBucketUtils)
    
    /// Convenience wrapper so call sites within this file stay concise.
    private func minDistance(for group: GroupedNearbyTransitResponse, from location: CLLocation) -> CLLocationDistance {
        groupMinDistance(for: group, from: location)
    }
    
    /// Convenience wrapper for flat arrival distance.
    private func distance(for arrival: NearbyTransitResponse, from location: CLLocation) -> CLLocationDistance {
        arrivalDistance(for: arrival, from: location)
    }
    
    private func separateByDistance(
        groups: [GroupedNearbyTransitResponse],
        from location: CLLocation?
    ) -> (nearYou: [GroupedNearbyTransitResponse], fartherAway: [GroupedNearbyTransitResponse], muchFarther: [GroupedNearbyTransitResponse]) {
        separateGroupsByDistance(groups: groups, from: location)
    }
    
    private func separateArrivalsByDistance(
        arrivals: [NearbyTransitResponse],
        from location: CLLocation?
    ) -> (nearYou: [NearbyTransitResponse], fartherAway: [NearbyTransitResponse]) {
        separateFlatArrivalsByDistance(arrivals: arrivals, from: location)
    }
}

// MARK: - Section Headers

/// Adaptive header shown when no stops fall within the "Near You" radius.
/// Displays the actual distance to the closest promoted result so the user
/// understands why the results are farther than usual.
struct ClosestToYouSectionHeader: View {
    let closestMeters: Double?
    let updated: Date?
    var isPromoted: Bool = true
    
    private var distanceDisplay: String {
        guard let meters = closestMeters else { return "Nearby" }
        return formatDistanceImperial(meters, suffix: "away")
    }
    
    /// Green when showing normal nearby results, yellow when promoted from farther away.
    private var badgeColor: Color {
        isPromoted ? AppTheme.Colors.warningYellow : AppTheme.Colors.successGreen
    }
    
    var body: some View {
        HStack(spacing: 6) {
            // Closest-to-you badge with walking icon
            HStack(spacing: 4) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                
                Text("Closest · \(distanceDisplay)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(badgeColor)
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

/// "Near You" section header - compact icon-based indicator
struct NearYouSectionHeader: View {
    let radiusMeters: Double
    let updated: Date?
    
    private var radiusDisplay: String {
        formatDistanceMiles(radiusMeters)
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
        formatDistanceMiles(radiusMeters)
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
        formatDistanceMiles(radiusMeters)
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

/// Subtle empty-state shown under a distance tier header when no arrivals
/// fall within that ring.  Always visible so all 3 tiers are present.
struct EmptyTierHint: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
            Text("Nothing in this range")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.vertical, 6)
    }
}

// MARK: - Grouped Route List

struct GroupedRouteList: View {
    let groups: [GroupedNearbyTransitResponse]
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    var referenceLocation: CLLocation? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                GroupedRouteRow(
                    group: group,
                    hasAlert: !viewModel.serviceAlerts.matching(routeId: group.routeId, mode: group.mode).isEmpty
                        || !viewModel.serviceAlerts.matching(routeId: group.displayName, mode: group.mode).isEmpty,
                    userLocation: referenceLocation
                ) { directionIndex in
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
                    isLiveOnMap: viewModel.isVehicleLiveOnMap(arrival),
                    onTrack: {
                        viewModel.trackNearbyArrival(arrival, location: locationManager.currentLocation)
                    },
                    onSelectRoute: arrival.isBus ? {
                        RouteAnalyticsManager.shared.logInteraction(routeId: arrival.routeId)
                        Task { await viewModel.selectArrival(arrival, userLocation: locationManager.currentLocation) }
                    } : nil,
                    userLocation: viewModel.effectiveLocation(userLocation: locationManager.currentLocation)
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
