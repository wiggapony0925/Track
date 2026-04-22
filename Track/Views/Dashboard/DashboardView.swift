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
    @Binding var sheetDetent: TrackSheetDetent

    @ObservedObject private var favoritesManager = FavoritesManager.shared

    /// Whether the sheet is at a non-expanded resting position
    /// (default half-height or the dynamic peek position).
    /// Any detent that isn't `.large` is treated as collapsed.
    private var isCollapsed: Bool {
        sheetDetent != .large
    }

    /// Live drag state — captured at gesture start so onChange writes
    /// are relative to where the user touched down, not to live values
    /// already being updated by the gesture.
    @State private var dragStartHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    /// Resolves to the upper bound of the sheet (≈ full screen).
    @State private var maxSheetHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                // MARK: - Navbar (Fixed Header)
                // Stays anchored to the top of the sheet.  Doubles as the
                // primary drag region — pulling it up grows the sheet.
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
                    GeometryReader { p in
                        Color.clear
                            .preference(key: NavbarHeightKey.self, value: p.size.height)
                    }
                }
                .contentShape(Rectangle())
                .gesture(sheetExpandDragGesture)

                // MARK: - Scrollable Content
                // Scrolling is ALWAYS enabled so rows are usable at the
                // default 45% detent.  Sheet expansion is driven solely
                // by the navbar drag gesture above \u2014 the rows themselves
                // never resize the sheet.
                scrollableContent
            }
            .trackScreenBackground()
            .onAppear {
                containerHeight = proxy.size.height
                if case .height(let h) = sheetDetent, h < SheetConstants.minimumHeight {
                    sheetDetent = SheetConstants.defaultDetent
                }
                // Sheet's max height is approximately the screen height
                // minus the safe-area top inset that .large reserves.
                let screenH = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive }?
                    .screen.bounds.height ?? proxy.size.height
                maxSheetHeight = sheetDetent == .large
                    ? proxy.size.height
                    : screenH
            }
            .onChange(of: proxy.size.height) { _, h in containerHeight = h }
        }
    }

    /// Continuous drag gesture that grows / shrinks the sheet in real time.
    /// Uses `.global` coordinate space so translation is measured against
    /// the screen.  This is critical: the navbar that hosts this gesture
    /// moves upward as the sheet grows, and a `.local` gesture would
    /// recompute translation against the moving view every frame,
    /// producing a feedback loop that reads as vertical jitter.
    private var sheetExpandDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if dragStartHeight == 0 {
                    // Capture starting height at the moment of touch-down.
                    dragStartHeight = containerHeight
                }
                let proposed = dragStartHeight - value.translation.height
                let upperBound = max(maxSheetHeight, dragStartHeight)
                let lowerBound = SheetConstants.minimumHeight
                let clamped = min(max(proposed, lowerBound), upperBound)
                sheetDetent = .height(clamped)
            }
            .onEnded { value in
                let upperBound = max(maxSheetHeight, dragStartHeight)
                let proposed = dragStartHeight - value.predictedEndTranslation.height
                dragStartHeight = 0
                // If user flicked decisively upward and we're more than
                // halfway up, snap to .large so scroll-through engages cleanly.
                let goingUp = value.predictedEndTranslation.height < -40
                if goingUp && proposed > upperBound * 0.85 {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                        sheetDetent = .large
                    }
                }
                // Otherwise leave the sheet at whatever .height(...) the
                // last onChanged wrote — freeform behavior, no snap-back.
            }
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
                    Group {
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
                    }
                    // Scoped: only animates the skeleton→favorites swap,
                    // not the entire VStack of dashboard rows.
                    .animation(.easeInOut(duration: 0.3), value: favoritesManager.isLoading)

                    // ── Transit: skeleton OR mode-specific content ────────────
                    Group {
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
                                case .subway:
                                    SubwayDashboard(
                                        viewModel: viewModel,
                                        locationManager: locationManager,
                                        sheetNavigator: sheetNavigator,
                                        lastUpdated: lastUpdated
                                    )
                                case .bus:
                                    BusDashboard(
                                        viewModel: viewModel,
                                        locationManager: locationManager,
                                        sheetNavigator: sheetNavigator,
                                        lastUpdated: lastUpdated
                                    )
                                case .lirr:
                                    LIRRDashboard(
                                        viewModel: viewModel,
                                        locationManager: locationManager,
                                        sheetNavigator: sheetNavigator,
                                        lastUpdated: lastUpdated
                                    )
                                case .mnr:
                                    MNRDashboard(
                                        viewModel: viewModel,
                                        locationManager: locationManager,
                                        sheetNavigator: sheetNavigator,
                                        lastUpdated: lastUpdated
                                    )
                                }
                            }
                            // Lightweight cross-fade between mode dashboards.
                            .transition(.opacity)
                            .animation(
                                .easeInOut(duration: 0.2),
                                value: viewModel.selectedMode
                            )
                        }
                    }
                    // Scoped: only animates the skeleton→content swap.
                    .animation(.easeInOut(duration: 0.3), value: viewModel.isLoading)

                    if let error = viewModel.errorMessage {
                        NetworkErrorBanner(
                            message: error,
                            onDismiss: { viewModel.errorMessage = nil }
                        )
                    }

                    ElevatorOutagesSection(outages: viewModel.elevatorOutages)

                    Spacer().frame(height: 20)
                }
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
    @Previewable @State var detent: TrackSheetDetent = SheetConstants.defaultDetent
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
