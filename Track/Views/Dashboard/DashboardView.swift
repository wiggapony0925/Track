//
//  DashboardView.swift
//  Track
//
//  Main dashboard content displayed in the bottom sheet.
//  Contains the modal navbar, transport mode-specific content,
//  service alerts, and other dashboard sections.
//

import SwiftUI
import CoreLocation
import MapKit

/// Main dashboard content showing transit arrivals based on selected mode.
struct DashboardView: View {
    // MARK: - Dependencies
    
    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    @Binding var lastUpdated: Date?
    @Binding var cameraPosition: MapCameraPosition
    @Binding var is3DMode: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Navbar (Fixed Header)
            ModalNavbar(
                searchText: Binding(
                    get: { viewModel.searchText },
                    set: { viewModel.searchText = $0 }
                ),
                showSettings: Binding(
                    get: { false },
                    set: { _ in sheetNavigator.navigate(to: .settings) }
                ),
                selectedMode: Binding(
                    get: { viewModel.selectedMode },
                    set: { viewModel.selectedMode = $0 }
                ),
                lastUpdated: lastUpdated
            )
            
            // MARK: - Scrollable Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Favorites section (shows only when user has favorites)
                    FavoritesSection(
                        groupedTransit: viewModel.groupedTransit,
                        onSelect: { group, directionIndex in
                            Task {
                                await viewModel.selectGroupedRoute(group, directionIndex: directionIndex, userLocation: locationManager.currentLocation)
                                if viewModel.isRouteDetailPresented {
                                    sheetNavigator.navigate(to: .routeDetail(group: group, directionIndex: directionIndex))
                                }
                            }
                        }
                    )
                    
                    // Loading skeleton — shown while transit data is being
                    // fetched (including drag-to-search) so the user sees a
                    // placeholder instead of stale content or just alerts.
                    if viewModel.isLoading && !hasTransitData {
                        TransitLoadingSkeleton()
                            .transition(.opacity)
                    }
                    
                    // Mode-specific content (trains/buses first — the primary content)
                    Group {
                        switch viewModel.selectedMode {
                        case .nearby:
                            NearbyDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                sheetNavigator: sheetNavigator,
                                lastUpdated: lastUpdated,
                                cameraPosition: $cameraPosition,
                                is3DMode: $is3DMode
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .subway:
                            SubwayDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                sheetNavigator: sheetNavigator,
                                lastUpdated: lastUpdated
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .bus:
                            BusDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                sheetNavigator: sheetNavigator,
                                lastUpdated: lastUpdated
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .lirr:
                            LIRRDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                sheetNavigator: sheetNavigator,
                                lastUpdated: lastUpdated
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .mnr:
                            MNRDashboard(
                                viewModel: viewModel,
                                locationManager: locationManager,
                                sheetNavigator: sheetNavigator,
                                lastUpdated: lastUpdated
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.selectedMode)
                    
                    // Service alerts — below arrivals so trains/buses show first.
                    // Only show when transit data has loaded to prevent alerts
                    // from appearing before the primary content.
                    if !viewModel.isLoading || hasTransitData {
                        ServiceAlertsSection(
                            alerts: viewModel.serviceAlerts.filtered(for: viewModel.selectedMode),
                            lastUpdated: viewModel.alertsLastUpdated
                        )
                    }
                    
                    // Network error banner
                    if let error = viewModel.errorMessage {
                        NetworkErrorBanner(
                            message: error,
                            onDismiss: {
                                viewModel.errorMessage = nil
                            }
                        )
                    }
                    
                    // Elevator outages section
                    ElevatorOutagesSection(outages: viewModel.elevatorOutages)
                    
                    Spacer()
                        .frame(height: 20)
                }
                .padding(.top, 4)
            }
        }
        .background(AppTheme.Colors.background)
        .refreshable {
            // Use effectiveLocation so pull-to-refresh during drag-to-search
            // fetches from the explored area, not the user's GPS.
            let loc = viewModel.effectiveLocation(userLocation: locationManager.currentLocation)
            await viewModel.refresh(location: loc)
            lastUpdated = Date()
        }
    }
    
    // MARK: - Helpers
    
    /// Whether any transit data is currently available for the selected mode.
    /// Used to decide whether to show the loading skeleton vs service alerts.
    private var hasTransitData: Bool {
        switch viewModel.selectedMode {
        case .nearby:
            return !viewModel.groupedTransit.isEmpty || !viewModel.nearbyTransit.isEmpty
        case .subway:
            return !viewModel.nearbyGroupedSubwayArrivals.isEmpty
        case .bus:
            return !viewModel.nearbyGroupedBusArrivals.isEmpty
        case .lirr:
            return !viewModel.nearbyGroupedLIRRArrivals.isEmpty
        case .mnr:
            return !viewModel.nearbyGroupedMNRArrivals.isEmpty
        }
    }
}

// MARK: - Transit Loading Skeleton

/// Shimmer placeholder shown while transit data is being fetched.
/// Prevents service alerts from appearing as the first visible content.
/// Uses the reusable skeleton shapes from ShimmerEffect.swift.
struct TransitLoadingSkeleton: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 12) {
                    // Route badge placeholder
                    SkeletonBar(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Text lines placeholder
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBar(
                            width: CGFloat([120, 100, 140][index % 3]),
                            height: 14
                        )
                        SkeletonBar(
                            width: CGFloat([80, 65, 90][index % 3]),
                            height: 12,
                            opacity: 0.07
                        )
                    }

                    Spacer()

                    // Countdown placeholder
                    VStack(alignment: .trailing, spacing: 4) {
                        SkeletonBar(width: 40, height: 22)
                        SkeletonBar(width: 50, height: 16, opacity: 0.08)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.vertical, 10)
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius, style: .continuous))
        .padding(.horizontal, AppTheme.Layout.margin)
        .shimmer()
    }
}

#Preview {
    @Previewable @State var lastUpdated: Date? = Date()
    @Previewable @State var cameraPosition: MapCameraPosition = .automatic
    @Previewable @State var is3DMode: Bool = false
    
    DashboardView(
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        sheetNavigator: SheetNavigator(),
        lastUpdated: $lastUpdated,
        cameraPosition: $cameraPosition,
        is3DMode: $is3DMode
    )
}
