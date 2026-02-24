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

    @ObservedObject private var favoritesManager = FavoritesManager.shared

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
                    let initialLoad = !viewModel.hasLoadedOnce && viewModel.isLoading

                    // ── Favorites: skeleton OR real section ───────────────────
                    // Shown immediately on load alongside the transit skeleton
                    // so both placeholders are visible at the same time.
                    // Transitions to the real section once favorites have loaded.
                    if initialLoad || (favoritesManager.isLoading && favoritesManager.favorites.isEmpty) {
                        FavoritesSectionSkeleton()
                            .transition(.opacity)
                    } else {
                        FavoritesSection(
                            groupedTransit: viewModel.groupedTransit,
                            onSelect: { group, directionIndex in
                                sheetNavigator.navigate(to: .routeDetail(group: group, directionIndex: directionIndex))
                                Task {
                                    await viewModel.selectGroupedRoute(group, directionIndex: directionIndex, userLocation: locationManager.currentLocation)
                                }
                            }
                        )
                        .transition(.opacity.animation(.easeIn(duration: 0.25)))
                    }

                    // ── Transit: skeleton OR mode-specific content ────────────
                    if initialLoad {
                        TransitLoadingSkeleton()
                            .transition(.opacity)
                    } else {
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
                    }

                    // ── Service alerts, errors, outages ───────────────────────
                    if !viewModel.isLoading || hasTransitData {
                        ServiceAlertsSection(
                            alerts: viewModel.serviceAlerts.filtered(for: viewModel.selectedMode),
                            lastUpdated: viewModel.alertsLastUpdated
                        )
                    }

                    if let error = viewModel.errorMessage {
                        NetworkErrorBanner(
                            message: error,
                            onDismiss: { viewModel.errorMessage = nil }
                        )
                    }

                    ElevatorOutagesSection(outages: viewModel.elevatorOutages)

                    Spacer().frame(height: 20)
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel.isLoading)
                .animation(.easeInOut(duration: 0.3), value: favoritesManager.isLoading)
                .padding(.top, 4)
            }
        }
        .background(AppTheme.Colors.background)
        .refreshable {
            // Use effectiveLocation so pull-to-refresh during drag-to-search
            // fetches from the explored area, not the user's GPS.
            let loc = viewModel.effectiveLocation(userLocation: locationManager.currentLocation)
            await viewModel.refresh(location: loc, force: true)
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
            return !viewModel.filteredNearbyGroupedSubwayArrivals.isEmpty
        case .bus:
            return !viewModel.filteredNearbyGroupedBusArrivals.isEmpty
        case .lirr:
            return !viewModel.filteredNearbyGroupedLIRRArrivals.isEmpty
        case .mnr:
            return !viewModel.filteredNearbyGroupedMNRArrivals.isEmpty
        }
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
