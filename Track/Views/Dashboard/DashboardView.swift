// Main dashboard content displayed in the bottom sheet.
// Contains the modal navbar, transport mode-specific content,
// service alerts, and other dashboard sections.

import SwiftUI
import CoreLocation

/// Main dashboard content showing transit arrivals based on selected mode.
struct DashboardView: View {
    // MARK: - Dependencies

    let viewModel: HomeViewModel
    let locationManager: LocationManager
    let sheetNavigator: SheetNavigator
    @Binding var lastUpdated: Date?
    @Binding var cameraPosition: TrackCameraPosition
    @Binding var sheetDetent: PresentationDetent

    @ObservedObject private var favoritesManager = FavoritesManager.shared

    /// Whether the sheet is at a non-expanded resting position
    /// (default half-height or the dynamic peek position).
    /// Any detent that isn't `.large` is treated as collapsed.
    private var isCollapsed: Bool {
        sheetDetent != .large
    }

    private var searchTextBinding: Binding<String> {
        Binding(get: { viewModel.searchText }, set: { viewModel.searchText = $0 })
    }
    private var showSettingsBinding: Binding<Bool> {
        Binding(get: { false }, set: { _ in sheetNavigator.navigate(to: .settings) })
    }
    private var selectedModeBinding: Binding<TransportMode> {
        Binding(get: { viewModel.selectedMode }, set: { viewModel.selectedMode = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Navbar (Fixed Header)
            ModalNavbar(
                searchText: searchTextBinding,
                showSettings: showSettingsBinding,
                selectedMode: selectedModeBinding,
                lastUpdated: lastUpdated,
                isRefreshing: viewModel.isRefreshing,
                weatherSnapshot: viewModel.weatherSnapshot,
                locationName: viewModel.currentLocationName,
                isDragSearchActive: viewModel.isSearchPinActive
            )
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: NavbarHeightKey.self, value: proxy.size.height)
                }
            }
            
            // MARK: - Scrollable Content
            scrollableContent
                .scrollDisabled(isCollapsed)
                .simultaneousGesture(
                    isCollapsed
                        ? DragGesture(minimumDistance: 12)
                            .onEnded { value in
                                // Upward swipe → step up through detents
                                if value.translation.height < -20 {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                                        if sheetDetent != SheetConstants.defaultDetent {
                                            sheetDetent = SheetConstants.defaultDetent
                                        } else {
                                            sheetDetent = .large
                                        }
                                    }
                                }
                            }
                        : nil
                )
        }
        .trackScreenBackground()
    }
    private var scrollableContent: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let initialLoad = !viewModel.hasLoadedOnce && viewModel.isLoading
                    let showTransitSkeleton = initialLoad && !hasTransitData

                    // ── Favorites: skeleton OR real section ───────────────────
                    // Shown immediately on load alongside the transit skeleton
                    // so both placeholders are visible at the same time.
                    // Transitions to the real section once favorites have loaded.
                    let favsLoading = favoritesManager.isLoading
                        && favoritesManager.favorites.isEmpty
                    if initialLoad || favsLoading {
                        FavoritesSectionSkeleton()
                            .transition(.opacity)
                    } else {
                        FavoritesSection(
                            groupedTransit: viewModel.groupedTransit,
                            userLocation: viewModel.referenceLocation ?? locationManager.currentLocation,
                            sheetNavigator: sheetNavigator,
                            onSelect: { group, directionIndex in
                                sheetNavigator.navigate(
                                    to: .routeDetail(
                                        group: group,
                                        directionIndex: directionIndex
                                    )
                                )
                                Task {
                                    await viewModel.handleRouteSelection(
                                        group,
                                        directionIndex: directionIndex,
                                        userLocation: locationManager.currentLocation
                                    )
                                }
                            },
                            selectedMode: viewModel.selectedMode,
                            smartETAProvider: { viewModel.smartETA(for: $0) },
                            isStale: viewModel.showStaleRows
                        )
                        .transition(.opacity.animation(.easeIn(duration: 0.25)))
                    }

                    // ── Transit: skeleton OR mode-specific content ────────────
                    if showTransitSkeleton {
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
                                    cameraPosition: $cameraPosition
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
                        .animation(
                            .spring(response: 0.4, dampingFraction: 0.7),
                            value: viewModel.selectedMode
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
            .refreshable {
                let loc: CLLocation? = if !viewModel.isSearchPinActive,
                                          let live = locationManager.currentLocation,
                                          abs(live.timestamp.timeIntervalSinceNow) < 30 {
                    live
                } else {
                    viewModel.referenceLocation
                }
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
    @Previewable @State var cameraPosition: TrackCameraPosition = .automatic
    @Previewable @State var detent: PresentationDetent = SheetConstants.defaultDetent
    let vm: HomeViewModel = HomeViewModel()
    let lm: LocationManager = LocationManager()
    let sn: SheetNavigator = SheetNavigator()

    DashboardView(
        viewModel: vm,
        locationManager: lm,
        sheetNavigator: sn,
        lastUpdated: $lastUpdated,
        cameraPosition: $cameraPosition,
        sheetDetent: $detent
    )
}
