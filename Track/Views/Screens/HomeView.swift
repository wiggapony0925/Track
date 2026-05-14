// Main dashboard view showing nearby transit arrivals.
// Displays real-time subway and bus data based on the user's
// current location or a draggable search pin. When a bus route
// is selected, shows live vehicle positions and the route path
// on the map.
// REFACTORED: This view now delegates to extracted components:
// - TrackMapView: All MapKit rendering (annotations, polylines)
// - MapControlsOverlay: Floating controls (3D toggle, recenter)
// - UniversalBottomSheet: Single sheet for all navigation
// - DashboardView: Dashboard content with mode-specific views

import CoreLocation
import SwiftData
import SwiftUI
import WidgetKit

struct HomeView: View {
    // MARK: - State
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LocationContext.self) private var locationContext
    @Bindable var viewModel: HomeViewModel
    var locationManager: LocationManager
    /// Saved home/work places — sourced from SavedPlacesCache which
    /// PlanViewModel keeps current after each backend sync.
    private var savedHomePlace: SavedLocation? { SavedPlacesCache.shared.homePlace }
    private var savedWorkPlace: SavedLocation? { SavedPlacesCache.shared.workPlace }
    /// When false, the universal bottom sheet is suppressed so it
    /// doesn't bleed through on top of the Plan tab.
    var isActive: Bool = true
    @Binding var selectedTab: AppTab
    @Binding var cameraPosition: TrackCameraPosition
    @Binding var showStations: Bool
    @Binding var currentMapCenter: CLLocationCoordinate2D?
    @Binding var currentMapDistance: Double?
    /// Mirrors `dragSearchSettledCenter` upward so the Chat tab can
    /// bias "near me" answers to the dropped pin.
    @Binding var chatBiasPin: CLLocationCoordinate2D?
    @State private var sheetNavigator = SheetNavigator()
    @State private var sheetDetent: TrackSheetDetent = SheetConstants.defaultDetent
    /// Bridges sheet pixel height to the map's UIKit contentInset in
    /// real-time (60fps) without SwiftUI re-renders.
    @State private var sheetHeightObserver = SheetHeightObserver()
    @State private var userTrackingMode: TrackUserTrackingMode = .none
    /// True when the user has dragged the sheet fully down past the minimum.
    /// Shows the peek-restore button and hides the sheet from view.
    @State private var isSheetCollapsed: Bool = false
    @State private var lastUpdated: Date?
    @State private var refreshTimer: Timer?
    @State private var vehiclePollTimer: Timer?
    @State private var hasLoadedInitialData = false
    /// True when the first data load used a speculative NYC-center location
    /// because no cached GPS was available (first-ever launch). When the real
    /// GPS fix arrives, `handleLocationUpdate` force-refreshes with accurate
    /// coordinates, then clears this flag.
    @State private var usedSpeculativeLocation = false
    
    // Drag-to-search state
    @AppStorage("drag_to_search") private var dragToSearchEnabled = false
    @State private var isDragSearchActive = false
    @State private var isDragSearchPanning = false
    @State private var hasFiredDragHaptic = false
    @State private var dragSearchDebounce: Task<Void, Never>?
    /// Cancellable task for mode-change refreshes — prevents rapid tab
    /// switching from queueing duplicate API calls.
    @State private var modeChangeTask: Task<Void, Never>?
    /// The settled center after a drag-search debounce fires. `nil` while
    /// the user is still panning — the radius circles hide until this is set.
    @State private var dragSearchSettledCenter: CLLocationCoordinate2D?
    /// Last camera movement while drag-search mode was available. Used to
    /// keep live GPS updates from snapping the map back while the user is
    /// positioning the pin but has not crossed the activation threshold yet.
    @State private var lastDragSearchCameraMoveAt: Date?
    /// Stamped when drag-search is dismissed so that the programmatic
    /// recenter animation (which fires many `handleMapCameraIdle` calls
    /// while the camera is still mid-flight) cannot re-activate drag search.
    /// 1 s covers any camera spring animation; drag-search can only re-engage
    /// after this cooldown has elapsed.
    @State private var dragSearchDismissedAt: Date?
    /// True after the user manually pans/zooms the map. While set, GPS
    /// refreshes may update data but must not pull the camera back home.
    @State private var userCameraOverrideActive = false

    /// External tab-selection trigger for the route detail sheet.
    /// Set to `.alerts` when the user taps the alert pill on the map's
    /// route banner — the sheet observes the change and switches tabs,
    /// then nils it back out.
    @State private var routeDetailTabRequest: RouteDetailSheet.RouteDetailTab?
    
    // Live walking update state — recalculates nearest stop + walking route
    // as user walks while a route detail sheet is open.
    /// Last GPS location used for a walking-state update. Used to debounce
    /// so we only recalculate when the user moves 20m+.
    @State private var lastWalkingUpdateLocation: CLLocation?
    /// Cancellable task for debounced walking route refetch.
    @State private var walkingUpdateTask: Task<Void, Never>?
    /// When true, the `.onChange(of: walkingRoute)` handler skips camera
    /// re-zoom because the update came from a live GPS tick, not a route open.
    @State private var suppressWalkingRouteZoom = false

    /// Search popup state. Tapping the FloatingSearchBar opens the
    /// shared ``DestinationSearchView`` sheet so users get the same rich
    /// "Where to?" experience the Plan tab uses, but augmented with
    /// matching transit routes from the live nearby feed.
    @State private var showSearchSheet = false
    @State private var planSearchVM = PlanViewModel()
    
    /// When true, the next `handleTappedVehicle` call was triggered by a chip
    /// tap inside the route detail sheet — the sheet should collapse (not expand)
    /// so the user can see the focused vehicle on the map.
    @State private var focusFromChip = false
    @State private var activeMapActionPopup: MapActionPopupItem?
    @State private var mapActionPopupDismissTask: Task<Void, Never>?

    private static let dragSearchActivationDistanceMeters: CLLocationDistance = 60
    private static let dragSearchGPSSnapRadiusMeters: CLLocationDistance = 45
    private static let dragSearchInteractionGraceSeconds: TimeInterval = 2.0
    
    /// Whether a drag-search API call is in-flight.
    /// Derived from the ViewModel's loading state instead of maintaining
    /// a separate flag — reuses the existing loading infrastructure.
    private var isDragSearching: Bool {
        viewModel.isLoading && viewModel.isSearchPinActive
    }
    
    // MARK: - Effective Location

    /// The location used for all distance/centering/walking calculations.
    /// Delegates to `viewModel.referenceLocation` — the single source of truth
    /// that automatically picks the drag-search pin over the real GPS.
    private var effectiveLocation: CLLocation? { viewModel.referenceLocation }

    /// Convenience coordinate from effectiveLocation.
    private var effectiveCoordinate: CLLocationCoordinate2D? {
        effectiveLocation?.coordinate
    }

    private var activeRouteDetailPage: (
        group: GroupedNearbyTransitResponse,
        initialTab: RouteDetailSheet.RouteDetailTab?
    )? {
        guard case let .routeDetail(group, _, initialTab) = sheetNavigator.currentPage else {
            return nil
        }
        return (group, initialTab)
    }

    private var isRouteDetailOverlayPresented: Bool {
        activeRouteDetailPage != nil
    }

    private var bottomSheetPresentation: Binding<Bool> {
        // The route detail overlay is a full-screen panel that visually
        // covers the bottom sheet, so we keep the sheet mounted in the
        // view tree instead of toggling it off.  Toggling caused two
        // cascading transitions (sheet slides DOWN ~320ms while the
        // overlay slides UP ~250ms) that made tapping a row feel
        // sluggish.  Now only the overlay animates in.
        Binding(
            get: { isActive },
            set: { _ in }
        )
    }
    
    var body: some View {
        dataObservedContent
    }
    
    /// Second modifier group: map/route data observers + notifications.
    /// Split from body to keep each expression under the type-checker limit.
    private var dataObservedContent: some View {
        notificationObservedContent
            .onChange(of: mapCenterChangeKey) { handleMapCenterChange() }
            .onChange(of: viewModel.routeShape?.polylines.count) { handleRouteShapeLoaded() }
            .onChange(of: viewModel.nearestStopCoordinate?.latitude) { handleNearestStopChanged() }
            .onChange(of: viewModel.selectedDirectionIndex) { handleDirectionIndexChanged() }
    }

    /// Third modifier group: remaining data observers.
    private var notificationObservedContent: some View {
        lifecycleObservedContent
            .onChange(of: viewModel.walkingRoute) { _, newRoute in 
                if newRoute != nil && !suppressWalkingRouteZoom {
                    handleNearestStopChanged()
                }
                suppressWalkingRouteZoom = false
            }
            .onChange(of: viewModel.groupedTransit.count) { attemptDeepLinkNavigation() }
            .onChange(of: viewModel.tappedVehicleId) { _, newValue in
                handleTappedVehicle(newValue)
            }
            .onReceive(NotificationCenter.default.publisher(for: .radiusSettingsChanged)) { _ in
                Task {
                    await viewModel.refresh(location: effectiveLocation, force: true)
                    lastUpdated = Date()
                }
            }
    }
    
    /// First modifier group: lifecycle + navigation state observers.
    private var lifecycleObservedContent: some View {
        mapAndSheetContent
            .onAppear {
                onAppearSetup()
                Analytics.shared.screenView("HomeView", reachedVia: "tab")
            }
            .onDisappear { cleanupTimers() }
            .onOpenURL { handleDeepLink($0) }
            .onChange(of: scenePhase) { _, newPhase in handleScenePhaseChange(newPhase) }
            .onChange(of: dragToSearchEnabled) { _, enabled in handleDragToggle(enabled) }
            .onChange(of: viewModel.selectedRouteId) { handleRouteSelection() }
            .onChange(of: viewModel.selectedMode) { handleModeChange() }
            .onChange(of: locationManager.currentLocation) { handleLocationUpdate() }
            .onChange(of: sheetNavigator.currentPage) { oldPage, newPage in
                handleSheetPageChange(from: oldPage, to: newPage)
            }
            .sheet(isPresented: $showSearchSheet, onDismiss: { handleSearchSheetDismiss() }) {
                DestinationSearchView(
                    viewModel: planSearchVM,
                    isOrigin: false,
                    transitMatchesProvider: { query in
                        transitMatchesForSearch(query)
                    },
                    onSelectTransit: { group in
                        handleSearchSheetTransitSelection(group)
                    },
                    transitUserLocation: locationManager.currentLocation
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
            // "Choose on Map" from the search popup toggles
            // ``planSearchVM.showMapPicker``. Mirror Plan tab's presenter
            // here so the chip works identically when invoked from Home.
            .fullScreenCover(
                isPresented: $planSearchVM.showMapPicker,
                onDismiss: { handleSearchSheetDismiss() }
            ) {
                MapLocationPickerView(viewModel: planSearchVM)
            }
    }
    
    // MARK: - Map & Sheet Content (extracted to reduce body complexity)
    
    private var mapAndSheetContent: some View {
        GeometryReader { geo in
            ZStack {
                // MARK: - Map Layer
                MapLibreTrackMapView(
                    cameraPosition: $cameraPosition,
                    viewModel: viewModel,
                    locationManager: locationManager,
                    showStations: $showStations,
                    currentMapCenter: $currentMapCenter,
                    currentMapDistance: $currentMapDistance,
                    userTrackingMode: $userTrackingMode,
                    onRouteStopTap: presentRouteStopDetail,
                    onSystemStationTap: presentTrainStopDetail,
                    onBusStopTap: presentBusStopDetail,
                    onSavedPlaceTap: presentSavedPlaceActionPopup,
                    onUserCameraGesture: {
                        userCameraOverrideActive = true
                        if userTrackingMode != .none {
                            userTrackingMode = .none
                        }
                    },
                    isDragSearchActive: isDragSearchActive,
                    dragSearchSettledCenter: dragSearchSettledCenter,
                    sheetHeightObserver: sheetHeightObserver
                )
                
                // MARK: - Floating Controls
                MapControlsOverlay(
                        viewModel: viewModel,
                        locationManager: locationManager,
                        cameraPosition: $cameraPosition,
                        sheetDetent: $sheetDetent,
                        currentMapCenter: currentMapCenter,
                        currentMapDistance: currentMapDistance,
                        userTrackingMode: $userTrackingMode,
                        onRecenter: {
                            userCameraOverrideActive = false
                            userTrackingMode = .none
                            // Dismiss drag-to-search state without camera snap —
                            // MapControlsOverlay.centerMap() handles camera positioning
                            // so we avoid competing animations.
                            if isDragSearchActive {
                                dismissDragSearchState()
                            }
                        },
                        onAlertsTapped: {
                            // Navigate to the full alerts page and expand the sheet
                            sheetNavigator.navigate(to: .serviceAlerts)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                sheetDetent = .large
                            }
                        },
                        dragToSearchEnabled: $dragToSearchEnabled,
                        isDragSearchActive: isDragSearchActive,
                        onDismissDragSearch: { dismissDragSearch() },
                        onCloseRoute: { closeRouteDetail() },
                        onRouteAlertTapped: {
                            // Tapping the alert pill on the route banner
                            // switches the route-detail sheet to its
                            // Alerts tab and expands the panel so the
                            // alerts list is fully visible.
                            routeDetailTabRequest = .alerts
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                sheetDetent = .large
                            }
                        }
                    )

                // MARK: - Drag-to-Search Overlay
                if dragToSearchEnabled
                    && viewModel.selectedRouteId == nil {
                    DragSearchOverlay(
                        isActive: isDragSearchActive,
                        isSearching: isDragSearching,
                        isPanning: isDragSearchPanning,
                        onDismiss: { dismissDragSearch() }
                    )
                }



            }
            // MARK: - Offline Banner (top safe area)
            // Slides down whenever NWPathMonitor reports no connectivity.
            // Drag-search and the local GTFS bundle keep working — this
            // just tells the user that live arrivals won't update until
            // they're back online.
            .overlay(alignment: .top) {
                OfflineBanner()
            }
            .overlay(alignment: .top) {
                if let activeMapActionPopup {
                    MapActionTopPopup(
                        item: activeMapActionPopup,
                        goNow: { goNow(to: activeMapActionPopup.planLocation) },
                        details: activeMapActionPopup.detailsSelection.map { selection in
                            { presentStopDetail(selection) }
                        },
                        dismiss: dismissMapActionPopup
                    )
                    .padding(.horizontal, 18)
                    .padding(.top, activeMapActionPopup.showsActions ? 8 : 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(40)
                }
            }
            // MARK: - Universal Bottom Sheet
            // Custom drag-controlled overlay (no `.sheet`) — see TrackBottomSheet.
            // Visibility gates on the same `bottomSheetPresentation` predicate the
            // legacy `.sheet(isPresented:)` modifier used.
            .overlay(alignment: .bottom) {
                if bottomSheetPresentation.wrappedValue {
                    UniversalBottomSheet(
                        navigator: sheetNavigator,
                        sheetDetent: $sheetDetent,
                        sheetHeightObserver: sheetHeightObserver,
                        onLiveHeightChange: { h in
                            // Collapse-state mirror for the floating tab
                            // bar grabber. We ONLY flip the boolean here
                            // — never write `sheetDetent` mid-drag.
                            //
                            // Why: the active drag gesture in
                            // `DashboardView` writes `sheetDetent =
                            // .height(clamped)` every frame from the
                            // user's finger. If this callback also wrote
                            // `.height(0)` (and worse, inside a
                            // `withAnimation(.spring)`), the two would
                            // race on the same state every frame —
                            // causing the visible flicker the user sees
                            // when slowly dragging the sheet around the
                            // 80pt boundary. The drag's `.onEnded` is
                            // already responsible for committing to
                            // `.height(0)` when the release lands inside
                            // the vacuum zone, so dropping the write
                            // here loses no behavior.
                            //
                            // Plain assignment (no `withAnimation`) — a
                            // spring animation on a state value that the
                            // gesture is also writing per-frame produces
                            // jitter; the tab-bar morph reads
                            // `isSheetCollapsed` and animates its own
                            // contents internally.
                            if h < 80 && !isSheetCollapsed {
                                isSheetCollapsed = true
                                HapticManager.impact(.light)
                            } else if h > 120 && isSheetCollapsed {
                                isSheetCollapsed = false
                            }
                        },
                        topEdgeOverlay: sheetNavigator.currentPage == .dashboard ? {
                            // Rendered INSIDE TrackBottomSheet's GeometryReader,
                            // positioned by the same `live` height the sheet card
                            // uses. Search bar + sheet move atomically every frame
                            // — no SwiftUI state hop, no chasing lag on fast flicks.
                            AnyView(
                                FloatingSearchBar(
                                    searchText: Binding(
                                        get: { viewModel.searchText },
                                        set: { viewModel.searchText = $0 }
                                    ),
                                    locationName: viewModel.currentLocationName,
                                    isDragSearchActive: viewModel.isSearchPinActive,
                                    homePlace: savedHomePlace,
                                    workPlace: savedWorkPlace,
                                    userCoordinate: locationManager.currentLocation?.coordinate,
                                    onTap: { presentSearchSheet() }
                                )
                            )
                        } : nil
                    ) { page in
                        sheetContent(for: page)
                    }
                    .transition(.move(edge: .bottom))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.95), value: bottomSheetPresentation.wrappedValue)

            // MARK: - Sheet Collapse → Tab Bar Grabber
            // When the sheet is dragged fully down it merges visually with
            // the floating tab bar.  The bar morphs into a grabber that the
            // user can pull up to restore — see `FloatingTabBar`. Wiring is
            // notification-based so neither view needs a direct reference to
            // the other.
            .onChange(of: isSheetCollapsed) { _, newValue in
                NotificationCenter.default.post(
                    name: .homeSheetCollapsedChanged,
                    object: newValue
                )
            }
            .onChange(of: viewModel.selectedMode) { _, newMode in
                NotificationCenter.default.post(
                    name: .homeTransportModeChanged,
                    object: newMode
                )
            }
            .onAppear {
                // Seed the floating tab bar with the current mode on
                // first paint so the grabber matches even if the user
                // never changes tabs before collapsing the sheet.
                NotificationCenter.default.post(
                    name: .homeTransportModeChanged,
                    object: viewModel.selectedMode
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestRestoreHomeSheet)) { _ in
                guard isSheetCollapsed else { return }
                // Bouncy spring so the sheet visibly pops out of the
                // floating navigator instead of just sliding up.
                withAnimation(.interpolatingSpring(stiffness: 140, damping: 14)) {
                    isSheetCollapsed = false
                    sheetDetent = SheetConstants.defaultDetent
                }
                HapticManager.impact(.medium)
            }
            // Live preview while the user is pulling up on the floating
            // tab bar's grabber. Translates pull distance into a real
            // sheet height so the dashboard rises with the finger \u2014 the
            // restore on release is then just the final spring.
            .onReceive(NotificationCenter.default.publisher(for: .homeSheetPullProgress)) { note in
                guard let pulled = note.object as? CGFloat else { return }
                // Don't gate on `isSheetCollapsed` — the live-height
                // callback flips it false partway through the pull and
                // gating would stall the sheet mid-rise.  We do still
                // ignore stray 0-resets fired after restoration.
                guard isSheetCollapsed || pulled > 0 else { return }
                let target = max(0, min(SheetConstants.defaultDetent.resolve(in: 800, topInset: 12),
                                        pulled * 2.4))
                // Direct write — no withAnimation so height tracks the
                // finger at gesture frame-rate without queueing springs.
                sheetDetent = .height(target)
            }
            // MARK: - Route Detail Floating Panel
            .overlay {
                if let routeDetailPage = activeRouteDetailPage {
                    routeDetailScreen(
                        routeGroup: routeDetailPage.group,
                        initialTab: routeDetailPage.initialTab,
                        isExpanded: true,
                        collapseSheetOnFocus: false
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.88), value: isRouteDetailOverlayPresented)
            .onChange(of: isRouteDetailOverlayPresented) { _, isPresented in
                if isPresented {
                    sheetHeightObserver.report(0)
                }
            }
        }
    }



    // MARK: - Modifier Handler Methods (extracted from body)

    // MARK: Search sheet plumbing

    /// Opens the shared ``DestinationSearchView`` sheet pre-seeded with
    /// whatever the user already typed in the floating search bar so the
    /// transition feels seamless.
    ///
    /// Also lazily configures the local ``PlanViewModel`` (modelContext +
    /// locationManager) so saved places, recents, and recommendations are
    /// fetched / restored from cache the very first time the popup opens.
    /// `PlanViewModel.configure` is idempotent — repeat calls are no-ops.
    private func presentSearchSheet() {
        planSearchVM.configure(
            modelContext: modelContext,
            locationManager: locationManager
        )
        planSearchVM.searchText = viewModel.searchText
        planSearchVM.performSearch(query: viewModel.searchText)
        showSearchSheet = true
    }

    /// Filters the live nearby transit feed by the sheet's current query.
    /// Reuses the existing ``HomeViewModel.groupMatchesQuery`` matcher so
    /// the search results stay perfectly consistent with the dashboard.
    private func transitMatchesForSearch(_ rawQuery: String) -> [GroupedNearbyTransitResponse] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { return [] }
        let query = trimmed.lowercased()
        let stationRoutes = viewModel.stationRoutesForQuery(query)
        let base = viewModel.filteredGroupedTransit
        return base.filter {
            viewModel.groupMatchesQuery($0, query: query, stationRoutes: stationRoutes)
        }
    }

    /// Handles a user tapping a transit row in the search popup. Dismisses
    /// the sheet and routes through the existing ``SheetNavigator`` so the
    /// route detail sheet appears with the same UX as a dashboard tap.
    private func handleSearchSheetTransitSelection(_ group: GroupedNearbyTransitResponse) {
        showSearchSheet = false
        HapticManager.impact(.medium)
        // Brief delay so the sheet finishes dismissing before the route
        // detail floating panel takes over the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            sheetNavigator.navigate(to: .routeDetail(group: group, directionIndex: 0))
            Task {
                await viewModel.handleRouteSelection(
                    group,
                    directionIndex: 0,
                    userLocation: locationManager.currentLocation
                )
            }
        }
    }

    /// When the search sheet dismisses with a destination chosen, hand it
    /// off to the Plan tab via the existing ``.quickDestination`` +
    /// ``.switchToTab`` notifications \u2014 the same plumbing the floating
    /// shortcut button uses.
    ///
    /// IMPORTANT ordering: ``PlanView`` is lazily created by ``TabView`` —
    /// if the user has never visited the Trips tab before, it doesn't yet
    /// have an ``onReceive`` subscription. We must therefore (1) flip the
    /// tab first so PlanView mounts and registers its publisher, then
    /// (2) deliver the destination on a later runloop tick so the freshly
    /// mounted view actually receives it.
    private func handleSearchSheetDismiss() {
        let dest = planSearchVM.destination
        // Always reset so the next time the sheet opens, it starts clean.
        planSearchVM.destination = nil
        planSearchVM.searchText = ""
        planSearchVM.locationSearchService.cancel()

        guard let dest else { return }

        NotificationCenter.default.post(name: .switchToTab, object: AppTab.trips)
        Task { @MainActor in
            // ~150 ms gives PlanView enough time to (a) mount, (b) run
            // .onAppear (which configures the locationManager so planTrip
            // can resolve a current-location origin), and (c) attach its
            // .onReceive(.quickDestination) subscription before we post.
            try? await Task.sleep(for: .milliseconds(150))
            NotificationCenter.default.post(name: .quickDestination, object: dest)
        }
    }

    private func presentMapActionPopup(_ item: MapActionPopupItem) {
        mapActionPopupDismissTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            activeMapActionPopup = item
        }
        mapActionPopupDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            dismissMapActionPopup()
        }
        HapticManager.impact(.light)
    }

    private func dismissMapActionPopup() {
        mapActionPopupDismissTask?.cancel()
        mapActionPopupDismissTask = nil
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            activeMapActionPopup = nil
        }
    }

    private func goNow(to destination: PlanLocation) {
        handoffMapDestinationToPlan(destination)
    }

    private func handoffMapDestinationToPlan(_ destination: PlanLocation) {
        dismissMapActionPopup()
        NotificationCenter.default.post(name: .switchToTab, object: AppTab.trips)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            NotificationCenter.default.post(name: .quickDestination, object: destination)
        }
    }

    private func onAppearSetup() {
        setupLocationAndTimers()
        // Cold-launch deep link: check if TrackApp stored a pending flag
        if UserDefaults.standard.bool(forKey: "pending_deep_link") {
            UserDefaults.standard.removeObject(forKey: "pending_deep_link")
            viewModel.pendingDeepLink = true
        }

        // Request an immediate GPS fix with no distance filter so
        // CoreLocation delivers the very first fix ASAP.
        locationManager.requestImmediateFix()

        // Immediately kick off the first fetch using the cached location
        // from the previous session (stored in App Group by LocationManager).
        // This shaves ~1-2s off startup by not waiting for a fresh GPS fix.
        //
        // SPECULATIVE PREFETCH (first-ever launch):
        // When no cached GPS exists (both lat/lon == 0), start fetching with
        // NYC center as a fallback so the backend warms up IN PARALLEL with
        // CoreLocation's first fix. When the real GPS arrives 1-5s later,
        // handleLocationUpdate force-refreshes with accurate coordinates.
        // This eliminates the 2-8s dead wait that otherwise shows skeletons.
        if !hasLoadedInitialData {
            let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
            let lat = defaults.double(forKey: "lastLatitude")
            let lon = defaults.double(forKey: "lastLongitude")
            if lat != 0 && lon != 0 {
                hasLoadedInitialData = true
                let cachedLoc = CLLocation(latitude: lat, longitude: lon)
                CameraHoverEngine.commit(
                    MapCameraPresets.center(on: cachedLoc.coordinate, is3D: false),
                    animation: HoverAnimations.snap,
                    to: $cameraPosition,
                    source: .system
                )

                // Phase 1: Load cached route cards with location awareness.
                // If the user moved significantly since last session, the
                // cache is still loaded for instant display but flagged
                // so we know the first network fetch is critical.
                let loadedSessionCache = viewModel.loadSessionCache(cachedLocation: cachedLoc)
                if !loadedSessionCache {
                    Task {
                        await viewModel.loadOfflineNearbyPreview(
                            location: cachedLoc,
                            reason: "cold launch cached GPS"
                        )
                    }
                }

                // Phase 2: Fetch fresh data in background.
                // If the session cache indicates the user is at (roughly)
                // the same spot, a normal refresh suffices.  If the cache
                // was location-stale or missing, force-refresh.
                Task {
                    await viewModel.refresh(location: cachedLoc, force: true)
                    lastUpdated = Date()
                }
            } else {
                // ── First-ever launch: no cached GPS ──
                // Start a speculative fetch with NYC center so the server
                // wakes up and data arrives during the GPS wait. The user
                // sees nearby routes for Midtown within 2-3s instead of
                // staring at skeletons for 5-10s.
                hasLoadedInitialData = true
                usedSpeculativeLocation = true
                let nyc = AppTheme.MapConfig.nycCenter
                let speculativeLoc = CLLocation(latitude: nyc.latitude, longitude: nyc.longitude)
                let lat = nyc.latitude
                let lng = nyc.longitude
                AppLogger.shared.log(
                    "SPECULATIVE",
                    message: "No cached GPS — starting speculative"
                        + " fetch with NYC center (\(lat), \(lng))")
                Task {
                    await viewModel.loadOfflineNearbyPreview(
                        location: speculativeLoc,
                        reason: "cold launch speculative NYC"
                    )
                }
                Task {
                    await viewModel.refresh(location: speculativeLoc, force: true)
                    lastUpdated = Date()
                }
            }
        }
    }
    
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if newPhase == .active {
            // On the very first .active (cold launch), onAppear already
            // triggers a forced refresh — skip the duplicate network call.
            guard viewModel.hasLoadedOnce else {
                startRefreshTimer()
                return
            }

            // Request an immediate high-accuracy GPS fix with no
            // distance filter.  After the phone was suspended for
            // minutes/hours, the normal 50m filter may take 1-5s to
            // trigger — requestImmediateFix() drops it temporarily
            // so the very first fix is delivered ASAP.
            locationManager.requestImmediateFix()

            // Preserve drag search when returning to the app. Clearing it
            // here would yank the camera away from the user's chosen center.
            if isDragSearchActive {
                Task {
                    if await viewModel.refresh(location: effectiveLocation) {
                        lastUpdated = Date()
                    }
                }
            } else {
                if !userCameraOverrideActive {
                    recenterOnUser()
                }
                // Prefer the live GPS fix over the stale cached reference
                // location.  CLLocation.timestamp tells us how old the fix
                // is — if it was acquired before the app was suspended it
                // may still reflect the user's old position (e.g. school).
                // In that case skip the immediate refresh and let
                // handleLocationUpdate fire once CoreLocation delivers a
                // fresh fix (usually within 1-2s).
                let maxFixAge: TimeInterval = 30
                if let live = locationManager.currentLocation,
                   abs(live.timestamp.timeIntervalSinceNow) < maxFixAge {
                    // Fresh GPS — safe to use
                    Task {
                        if await viewModel.refresh(location: live) {
                            lastUpdated = Date()
                        }
                    }
                } else if let live = locationManager.currentLocation,
                          let lastRefresh = viewModel.lastRefreshLocation,
                          live.distance(from: lastRefresh)
                            >= AppSettings.shared.significantMovementMeters {
                    // GPS is stale but clearly at a different location
                    // than the last fetch — force refresh now.
                    Task {
                        await viewModel.refresh(location: live, force: true)
                        lastUpdated = Date()
                    }
                }
                // Otherwise: GPS is stale and at the same spot as the
                // last fetch (or nil).  Don't refresh with the wrong
                // coordinates — handleLocationUpdate will fire shortly
                // with a fresh fix and trigger the correct fetch.
            }
            
            // Always restart the auto-refresh timer — iOS may have
            // invalidated it while the app was suspended.
            startRefreshTimer()

            // Restart vehicle poll timer if a route was selected before
            // the app went to background (we invalidated it in .background).
            if viewModel.selectedRouteId != nil && vehiclePollTimer == nil {
                handleRouteSelection()
            }
        } else if newPhase == .background {
            // Timers don't fire reliably in the background — invalidate
            // so they can be cleanly restarted on .active.
            refreshTimer?.invalidate()
            refreshTimer = nil
            // Vehicle poll timer fires every 1s for interpolation.
            // Leaving it running in the background wastes CPU/energy
            // and can accumulate stale ticks. Clean it up here;
            // handleRouteSelection() will restart it when the app
            // returns to .active if a route is still selected.
            vehiclePollTimer?.invalidate()
            vehiclePollTimer = nil
        }
    }
    
    private func handleDragToggle(_ enabled: Bool) {
        if !enabled && hasAnySearchPinState {
            dismissDragSearch()
        }
        // Immediately persist to Supabase so the saved preference
        // is not overwritten by the next pull during a full sync.
        Task { await SyncManager.shared.pushUserSettings() }
    }

    private var hasAnySearchPinState: Bool {
        isDragSearchActive
            || viewModel.isSearchPinActive
            || viewModel.searchPinCoordinate != nil
            || chatBiasPin != nil
            || dragSearchSettledCenter != nil
    }

    private var isPositioningDragSearchPin: Bool {
        guard dragToSearchEnabled, viewModel.selectedRouteId == nil else { return false }
        if isDragSearchActive || isDragSearchPanning { return true }
        guard let movedAt = lastDragSearchCameraMoveAt else { return false }
        return Date().timeIntervalSince(movedAt) < Self.dragSearchInteractionGraceSeconds
    }
    
    private func handleMapCenterChange() {
        if let center = currentMapCenter {
            handleMapCameraIdle(center: center)
        }
    }

    /// Single key for the map-center observer.  Replaces a pair of
    /// `.onChange(of: currentMapCenter?.latitude / .longitude)` handlers
    /// that both routed to the same `handleMapCenterChange()` — that
    /// fired the drag-search debounce reschedule + instant-coordinate
    /// publish twice on every map pan frame.
    private var mapCenterChangeKey: String {
        guard let c = currentMapCenter else { return "" }
        return "\(c.latitude),\(c.longitude)"
    }
    
    private func handleRouteShapeLoaded() {
        guard viewModel.selectedRouteId != nil else { return }
        // Only set the sheet detent here.  The actual camera zoom is
        // handled by handleNearestStopChanged — at this point
        // nearestStopCoordinate hasn't been calculated yet, so
        // cameraPositionFittingRoute would fall back to a generic
        // user-location zoom that misses the stop entirely.
        // Don't collapse the sheet if the user has already expanded it.
        guard sheetDetent != .large else { return }
        withAnimation(HoverAnimations.snap) {
            sheetDetent = SheetConstants.defaultDetent
        }
    }
    
    private func handleNearestStopChanged() {
        guard !userCameraOverrideActive else { return }

        // Pass the sheet fraction directly so
        // cameraPositionFittingRoute computes zoom AND center
        // together — guaranteeing both the user and the stop
        // are comfortably visible above the sheet.
        if let fitCamera = viewModel.cameraPositionFittingRoute(
            userLocation: locationManager.currentLocation,
            is3D: false
        ) {
            // Adjust the sheet detent FIRST in its own animation
            // transaction. Doing the detent change inside the same
            // withAnimation as the camera write triggers
            // handleSheetDetentChanged synchronously, which then
            // attempted a second camera write — the dedupe in
            // CameraHoverEngine.commit catches it, but separating
            // the transactions is cleaner and avoids spring overlap.
            if sheetDetent != .large {
                withAnimation(HoverAnimations.snap) {
                    sheetDetent = SheetConstants.defaultDetent
                }
            }
            CameraHoverEngine.commit(
                fitCamera,
                animation: HoverAnimations.routeFit,
                to: $cameraPosition,
                source: .system
            )
        } else if let coordinate = viewModel.nearestStopCoordinate {
            centerMap(on: coordinate)
        }
    }
    
    private func handleDirectionIndexChanged() {
        guard viewModel.selectedRouteId != nil,
              viewModel.routeShape != nil else { return }
        
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            viewModel.updateSimulation()
            viewModel.previousBusPositions.removeAll()
        }
        
        // Recalculate the nearest stop AND re-fetch the walking route
        // for the new direction.  Previously only updateNearestStop was
        // called here, causing the walking polyline to remain stale
        // until the user left and returned to the app.
        viewModel.isStopManuallySelected = false
        Task { @MainActor in
            if let loc = locationManager.currentLocation {
                await viewModel.refreshWalkingState(userLocation: loc)
            } else {
                await viewModel.refreshWalkingState(userLocation: nil)
            }

            if let fitCamera = viewModel.cameraPositionFittingRoute(
                userLocation: locationManager.currentLocation,
                is3D: false
            ) {
                CameraHoverEngine.commit(
                    fitCamera,
                    animation: HoverAnimations.fly,
                    to: $cameraPosition,
                    source: .system
                )
            }
        }
    }
    
    private func handleTappedVehicle(_ newValue: String?) {
        guard let tappedId = newValue, !tappedId.isEmpty else { return }
        
        // If the focus was triggered from a chip tap in the route detail
        // sheet, the sheet is already being collapsed in onFocusVehicle —
        // don't expand it here.
        if focusFromChip {
            focusFromChip = false
            return
        }
        
        if sheetDetent != .large {
            withAnimation(HoverAnimations.snap) {
                sheetDetent = .large
            }
        }
        
        if let coord = viewModel.coordinateForTappedVehicle(tappedId) {
            CameraHoverEngine.commit(
                MapCameraPresets.focusVehicle(at: coord, is3D: false),
                animation: HoverAnimations.fly,
                to: $cameraPosition,
                source: .user
            )
        }
    }
    
    // MARK: - Sheet Content Builder
    
    @ViewBuilder
    private func sheetContent(for page: SheetPage) -> some View {
        switch page {
        case .dashboard:
            DashboardView(
                viewModel: viewModel,
                locationManager: locationManager,
                sheetNavigator: sheetNavigator,
                lastUpdated: $lastUpdated,
                cameraPosition: $cameraPosition,
                sheetDetent: $sheetDetent
            )
            
        case .routeDetail:
            // The route detail screen is rendered as a full-screen overlay
            // (see `activeRouteDetailPage` in the body) — not inside the
            // sheet stack — so we deliberately render nothing here to
            // avoid building the heavy RouteDetailSheet twice.  The sheet
            // stays mounted (with its dashboard underneath) so dismissing
            // the route detail returns to the prior page instantly.
            EmptyView()

        case .stopDetail(let selection):
            StopDetailSheet(
                selection: selection,
                sheetNavigator: sheetNavigator,
                currentLocation: effectiveCoordinate,
                elevatorOutages: viewModel.elevatorOutages,
                serviceAlerts: viewModel.serviceAlerts
            )
            .id(selection.id)
            
        case .profileSettings:
            ProfileSettingsContentView(sheetNavigator: sheetNavigator)
            
        case .serviceAlerts:
            ServiceAlertsPage(
                alerts: viewModel.serviceAlerts,
                sheetNavigator: sheetNavigator,
                lastUpdated: viewModel.alertsLastUpdated
            )
            
        case .widgetSchedules:
            WidgetSchedulesContentView(sheetNavigator: sheetNavigator)

        case .savedAddresses:
            ManageSavedAddressesView(sheetNavigator: sheetNavigator)

        case .manageFavorites:
            ManageFavoritesView(
                sheetNavigator: sheetNavigator,
                groupedTransit: viewModel.groupedTransit,
                userLocation: viewModel.referenceLocation ?? locationManager.currentLocation,
                onSelect: { group, directionIndex in
                    sheetNavigator.navigate(
                        to: .routeDetail(
                            group: group,
                            directionIndex: directionIndex))
                    Task {
                        await viewModel.handleRouteSelection(
                            group, directionIndex: directionIndex,
                            userLocation: locationManager.currentLocation)
                    }
                },
                onTrack: { group, directionIndex in
                    viewModel.setPreferredDirectionIndex(directionIndex, for: group)
                    let dir = group.directions[min(directionIndex, group.directions.count - 1)]
                    guard let arrival = ArrivalHelpers.countdownArrival(
                        for: dir,
                        userLocation: locationManager.currentLocation,
                        provider: { viewModel.smartETA(for: $0) }
                    ) else { return }
                    viewModel.trackNearbyArrival(arrival, location: locationManager.currentLocation)
                },
                onAlertSelect: { group in
                    Task {
                        await viewModel.handleRouteSelection(
                            group, directionIndex: 0,
                            userLocation: locationManager.currentLocation)
                    }
                },
                isStale: viewModel.showStaleRows
            )

#if DEBUG
        case .developerSettings:
            DeveloperSettingsContentView(sheetNavigator: sheetNavigator)
#endif
            
        case .scheduleEditor(let schedule):
            ScheduleEditorView(schedule: schedule) { newSchedule in
                var schedules = WidgetSchedule.loadAll()
                if let index = schedules.firstIndex(where: { $0.id == newSchedule.id }) {
                    schedules[index] = newSchedule
                } else {
                    schedules.append(newSchedule)
                }
                WidgetSchedule.saveAll(schedules)
                
                Task {
                    await SyncManager.shared.uploadSchedule(newSchedule)
                }
                
                WidgetCenter.shared.reloadAllTimelines()
                sheetNavigator.goBack()
            }
        }
    }

    private func routeDetailScreen(
        routeGroup: GroupedNearbyTransitResponse,
        initialTab: RouteDetailSheet.RouteDetailTab?,
        isExpanded: Bool,
        collapseSheetOnFocus: Bool
    ) -> some View {
        // Pass the effective location (search pin center when drag-to-search
        // is active, otherwise the real GPS location) so that distance display,
        // walking directions, and map centering all work from the explored area.
        let effectiveCoord = viewModel.referenceLocation?.coordinate

        // Use the enriched group from the viewModel (which may have
        // additional directions added by enrichGroupWithShapeDirections)
        // instead of the stale group captured at navigation time.
        let enrichedGroup = viewModel.selectedGroupedRoute ?? routeGroup

        // Compute direction-filtered vehicle count (bus + train) from the
        // ViewModel's already-filtered collections so we don't duplicate
        // direction-filtering logic inside the sheet.
        let vehicleCount = enrichedGroup.isBus
            ? viewModel.filteredBusVehicles.count
            : viewModel.filteredTrainVehicles.count

        return RouteDetailSheet(
            group: enrichedGroup,
            vehicleCoordinateLookup: { vid in
                viewModel.coordinateForTappedVehicleAnywhere(vid)
            },
            liveVehicleDetailLookup: { viewModel.liveVehicleDetail(for: $0) },
            trainVehicles: viewModel.filteredTrainVehicles,
            routeShape: $viewModel.routeShape,
            selectedDirectionIndex: $viewModel.selectedDirectionIndex,
            isSelectedArrivalExpress: $viewModel.isSelectedArrivalExpress,
            serviceAlerts: viewModel.serviceAlerts,
            busSchedule: viewModel.busSchedule,
            cachedTrainArrivals: viewModel.cachedTrainArrivals,
            cachedStations: viewModel.cachedStations,
            smartETAProvider: { viewModel.smartETA(for: $0) },
            liveVehicleCount: vehicleCount,
            elevatorOutages: viewModel.elevatorOutages,
            weatherSnapshot: viewModel.weatherSnapshot,
            initialTab: initialTab,
            tabRequest: $routeDetailTabRequest,
            isSheetExpanded: isExpanded,
            cameraPosition: $cameraPosition,
            currentLocation: effectiveCoord,
            selectedStopId: viewModel.selectedStopId,
            isStopManuallySelected: viewModel.isStopManuallySelected,
            onTrack: { arrival in
                viewModel.trackNearbyArrival(arrival, location: locationManager.currentLocation)

                // Only zoom when the vehicle is actually live on the map.
                // Falling back to stop coordinates would pan to an empty
                // spot with no bus marker — confusing the user.
                if viewModel.isVehicleLiveOnMap(arrival),
                   let coord = viewModel.trackedVehicleCoordinate {
                    CameraHoverEngine.commit(
                        MapCameraPresets.focusVehicle(at: coord, is3D: false),
                        animation: HoverAnimations.fly,
                        to: $cameraPosition,
                        source: .user
                    )
                }
            },
            isTracking: { viewModel.isTracking($0) },
            isTrackingAny: viewModel.isTrackingAny,
            isLiveOnMap: { viewModel.isVehicleLiveOnMap($0) },
            onClearHighlight: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    viewModel.tappedVehicleId = nil
                }
            },
            onFocusVehicle: { key in
                // Mark chip-originated selection so handleTappedVehicle does not
                // reinterpret it as a free map tap and fly the route-detail map
                // away from the boarding stop.
                focusFromChip = true

                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    viewModel.tappedVehicleId = key
                }

                if collapseSheetOnFocus {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        sheetDetent = SheetConstants.defaultDetent
                    }
                }
            },
            tappedVehicleId: viewModel.tappedVehicleId,
            onDismiss: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.isRouteDetailPresented = false
                    viewModel.selectedGroupedRoute = nil
                    viewModel.clearRoute()
                    sheetNavigator.popToRoot()
                }

                // Restore drag-search overlay if the user had an active
                // search center before opening the route detail.
                if viewModel.isSearchPinActive, let settled = dragSearchSettledCenter {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isDragSearchActive = true
                    }
                    CameraHoverEngine.commit(
                        MapCameraPresets.center(on: settled, is3D: false),
                        animation: HoverAnimations.fly,
                        to: $cameraPosition,
                        source: .system
                    )
                } else if !userCameraOverrideActive {
                    recenterOnUser()
                }
            },
            onStopSelected: { coord in
                // Update the polyline split anchor so behind/ahead
                // coloring follows the stop the user tapped.
                // nil = user deselected -> clear split (full-color polyline).
                viewModel.nearestStopCoordinate = coord
                if let coord {
                    let stops = viewModel.routeShape?.stopsForDirection(
                        index: viewModel.selectedDirectionIndex,
                        name: viewModel.selectedDirectionName,
                        shapeDirectionId: viewModel.selectedShapeDirectionId,
                        fallbackToCombined: false
                    ) ?? []
                    let coordLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    viewModel.selectedStopId = stops.min { lhs, rhs in
                        CLLocation(latitude: lhs.lat, longitude: lhs.lon).distance(from: coordLoc)
                            < CLLocation(latitude: rhs.lat, longitude: rhs.lon).distance(from: coordLoc)
                    }?.id
                } else {
                    viewModel.selectedStopId = nil
                }

                // Track whether the user manually picked a stop so that
                // GPS-driven refreshWalkingState doesn't overwrite it.
                viewModel.isStopManuallySelected = (coord != nil)

                // Re-fetch the walking route to the newly selected stop
                // so the dashed walking polyline updates on the map.
                if let stopCoord = coord {
                    let origin = viewModel.referenceLocation?.coordinate
                        ?? locationManager.currentLocation?.coordinate
                    if let from = origin {
                        suppressWalkingRouteZoom = true
                        Task {
                            await viewModel.fetchWalkingRoute(
                                from: from,
                                to: stopCoord
                            )
                        }
                    }
                } else {
                    // Deselected -> revert to auto-nearest stop and its walking route.
                    suppressWalkingRouteZoom = true
                    Task {
                        await viewModel.refreshWalkingState(
                            userLocation: locationManager.currentLocation
                                ?? viewModel.lastKnownUserLocation
                        )
                    }
                }
            },
            onRecenter: {
                userCameraOverrideActive = false

                // Re-invoke the route-fitting camera that shows both user
                // location and the nearest stop — same logic as the initial
                // route-open zoom.
                if let fitCamera = viewModel.cameraPositionFittingRoute(
                    userLocation: locationManager.currentLocation,
                    is3D: false
                ) {
                    if collapseSheetOnFocus {
                        withAnimation(HoverAnimations.snap) {
                            sheetDetent = SheetConstants.defaultDetent
                        }
                    }
                    CameraHoverEngine.commit(
                        fitCamera,
                        animation: HoverAnimations.fly,
                        to: $cameraPosition,
                        source: .user
                    )
                } else {
                    let target = effectiveCoordinate ?? AppTheme.MapConfig.nycCenter
                    CameraHoverEngine.commit(
                        MapCameraPresets.center(on: target, is3D: false),
                        animation: HoverAnimations.fly,
                        to: $cameraPosition,
                        source: .user
                    )
                }
                HapticManager.impact(.light)
            },
            onStopDetailRequested: { selection in
                presentStopDetail(selection)
            }
        )
    }

    private func presentRouteStopDetail(_ stop: BusStop) {
        let mode = viewModel.selectedGroupedRoute?.mode ?? "bus"
        let fallbackRouteID = viewModel.selectedGroupedRoute?.routeId
        presentMapActionPopup(.routeStop(stop, mode: mode, fallbackRouteID: fallbackRouteID))
    }

    private func presentTrainStopDetail(
        _ station: MapSystemViewModel.ConsolidatedStation
    ) {
        presentMapActionPopup(.station(station))
    }

    private func presentBusStopDetail(_ stop: BusStop) {
        presentMapActionPopup(.bus(stop))
    }

    private func presentSavedPlaceActionPopup(_ place: SavedLocation) {
        presentMapActionPopup(.savedPlace(place))
    }

    private func presentStopDetail(_ selection: StopDetailSelection) {
        dismissMapActionPopup()

        if case .stopDetail(let currentSelection) = sheetNavigator.currentPage,
           currentSelection == selection {
            return
        }

        if case .stopDetail = sheetNavigator.currentPage {
            sheetNavigator.replace(with: .stopDetail(selection: selection))
        } else {
            sheetNavigator.navigate(to: .stopDetail(selection: selection))
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            sheetDetent = .large
        }
    }
    
    // MARK: - Setup Methods
    
    private func setupLocationAndTimers() {
        locationManager.requestPermission()
        locationManager.startUpdating()
        startRefreshTimer()
    }

    // fetchSavedPlaces() removed — HomeView now reads SavedPlacesCache
    // which PlanViewModel populates from the backend after each login/refresh.
    // The old SwiftData FetchDescriptor approach found nothing because saved
    // locations are never written to the local store.
    
    /// Creates the auto-refresh timer. Safe to call multiple times.
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(AppSettings.shared.refreshIntervalSeconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                // Skip auto-refresh while a drag-search API call is in-flight
                // to avoid duplicate requests and overwriting fresh results.
                guard !isDragSearching else { return }
                
                // Use effective location so auto-refresh during drag-to-search
                // keeps fetching from the explored area, not the user's GPS.
                if await viewModel.refresh(location: effectiveLocation) {
                    lastUpdated = Date()
                }
            }
        }
    }
    
    private func cleanupTimers() {
        refreshTimer?.invalidate()
        vehiclePollTimer?.invalidate()
        refreshTimer = nil
        vehiclePollTimer = nil
    }
    
    // MARK: - State Change Handlers
    
    private func handleRouteSelection() {
        vehiclePollTimer?.invalidate()
        vehiclePollTimer = nil
        
        // Reset live walking update state for the new route
        lastWalkingUpdateLocation = nil
        walkingUpdateTask?.cancel()
        walkingUpdateTask = nil
        suppressWalkingRouteZoom = false
        
        // Hide drag-search overlay when viewing a route — the search pin
        // stays active in the ViewModel so nearestStop / centering still
        // uses the explored area. We'll restore the overlay on dismiss.
        if viewModel.selectedRouteId != nil && isDragSearchActive {
            isDragSearchActive = false
            isDragSearchPanning = false
            // NOTE: keep dragSearchSettledCenter so we can restore on dismiss
        }
        
        if viewModel.selectedRouteId != nil {
            userCameraOverrideActive = false

            let isBus = viewModel.selectedGroupedRoute?.isBus ?? false
            let isCommuterRail = viewModel.selectedGroupedRoute?.isCommuterRail ?? false
            let startTime = Date()
            var consecutiveErrors = 0
            let selectedRouteIdAtStart = viewModel.selectedRouteId
            Task { @MainActor in
                // NOTE: Do NOT fire an initial refresh here.
                // `HomeViewModel.selectGroupedRoute` already kicked off the
                // first vehicle/arrivals fetch the moment `selectedRouteId`
                // was assigned. Calling `refreshSelectedRouteLiveData` again
                // ~380 ms later issued a duplicate network request for the
                // same route, raced the in-flight one, and could flash the
                // map if responses arrived out of order.
                //
                // The burst below at 2/6/12 s acts as post-open settle
                // pulses on top of that initial fetch, then the polling
                // timer takes over.
                var previousDelay: TimeInterval = 0
                for delay in LiveTrackingClock.routeDetailBurstDelaysSeconds {
                    try? await Task.sleep(for: .seconds(max(0, delay - previousDelay)))
                    previousDelay = delay
                    guard viewModel.selectedRouteId == selectedRouteIdAtStart else { return }
                    await refreshSelectedRouteLiveData(
                        isBus: isBus,
                        isCommuterRail: isCommuterRail
                    )
                }
            }
            // Fetch live vehicle positions on the shared route-detail cadence.
            let tickInterval: TimeInterval = 1.0
            let livePollInterval = Int(LiveTrackingClock.vehiclePollIntervalSeconds)
            let timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
                let tick = Int(Date().timeIntervalSince(startTime) / tickInterval)
                
                Task { @MainActor in
                    if isBus {
                        // Buses: MTA SIRI updates GPS roughly every feed cycle.
                        // Poll every 25s for fresh data, interpolate on other ticks.
                        // Back off on errors: skip network calls after 3+ failures.
                        let pollInterval = consecutiveErrors >= 3
                            ? livePollInterval * 2 : livePollInterval
                        if tick % pollInterval == 0 {
                            await viewModel.refreshBusVehicles()
                            if viewModel.errorMessage != nil {
                                consecutiveErrors += 1
                            } else {
                                consecutiveErrors = 0
                            }
                        } else {
                            viewModel.updateBusSimulation()
                        }
                    } else if isCommuterRail {
                        // LIRR / MNR: Same interpolation engine as subway —
                        // simulate every tick, network refresh every 25s.
                        viewModel.updateSimulation()
                        if tick % livePollInterval == 0 {
                            await viewModel.refreshCommuterRailVehicles()
                        }
                    } else {
                        // Subway: Simulate every tick, network refresh every 25s.
                        viewModel.updateSimulation()
                        if tick % livePollInterval == 0 {
                            await viewModel.refreshTrainVehicles()
                        }
                    }
                }
            }
            vehiclePollTimer = timer
        }
    }

    private func refreshSelectedRouteLiveData(
        isBus: Bool,
        isCommuterRail: Bool
    ) async {
        if isBus {
            await viewModel.refreshBusVehicles()
        } else if isCommuterRail {
            viewModel.updateSimulation()
            await viewModel.refreshCommuterRailVehicles()
        } else {
            viewModel.updateSimulation()
            await viewModel.refreshTrainVehicles()
        }
    }
    
    private func handleModeChange() {
        // Only clear route state when a route is actually selected.
        // Unconditional clearRoute() set ~20 @Observable properties to
        // nil/empty, each firing mutation notifications that cascaded
        // through .onChange handlers (camera, timers, walking route)
        // causing jank on every tab switch.
        if viewModel.selectedRouteId != nil {
            viewModel.clearRoute()
        }
        // Cancel any in-flight mode-change refresh so only the latest
        // tab switch actually hits the network.
        modeChangeTask?.cancel()
        modeChangeTask = Task {
            let shouldForceRefresh = !viewModel.hasCachedData(for: viewModel.selectedMode)
            // Use effective location so mode changes during drag-to-search
            // keep showing transit at the explored area, not GPS.
            await viewModel.refresh(location: effectiveLocation, force: shouldForceRefresh)
            lastUpdated = Date()
        }
    }

    /// Cleans up route overlay data when the sheet navigates away from route detail.
    /// This is a safety net: the primary cleanup happens in RouteDetailSheet's
    /// `onDismiss`, but this handler catches edge cases (e.g., mode switch,
    /// programmatic navigation, or SwiftUI lifecycle glitches) where onDismiss
    /// might not fire but the page has already changed.
    private func handleSheetPageChange(from _: SheetPage, to _: SheetPage) {
        let routeDetailStillInStack = sheetNavigator.pageStack.contains { page in
            if case .routeDetail = page { return true }
            return false
        }

        guard !routeDetailStillInStack else { return }
        guard viewModel.isRouteDetailPresented else { return }
        viewModel.isRouteDetailPresented = false
        viewModel.selectedGroupedRoute = nil
        viewModel.clearRoute()
    }

    /// Tears down the route detail sheet and clears the route overlay
    /// from the map.  Used by both RouteDetailSheet's own dismiss
    /// button and the close X on `MapControlsOverlay`'s route banner
    /// so the two paths stay in sync.
    private func closeRouteDetail() {
        withAnimation(.easeInOut(duration: 0.25)) {
            viewModel.isRouteDetailPresented = false
            viewModel.selectedGroupedRoute = nil
            viewModel.clearRoute()
            sheetNavigator.popToRoot()
        }

        // Restore drag-search overlay if the user had an active
        // search center before opening the route detail.
        if viewModel.isSearchPinActive, let settled = dragSearchSettledCenter {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isDragSearchActive = true
            }
            CameraHoverEngine.commit(
                MapCameraPresets.center(on: settled, is3D: false),
                animation: HoverAnimations.fly,
                to: $cameraPosition,
                source: .system
            )
        } else if !userCameraOverrideActive {
            recenterOnUser()
        }
    }
    
    private func handleLocationUpdate() {
        guard let loc = locationManager.currentLocation else { return }
        
        if !hasLoadedInitialData {
            hasLoadedInitialData = true
            
            // Center the map on the user as soon as we get the first fix
            if !userCameraOverrideActive {
                recenterOnUser()
            }
            
            Task {
                await viewModel.refresh(location: loc, force: true)
                lastUpdated = Date()
            }
        } else if usedSpeculativeLocation {
            // ── First real GPS fix after speculative prefetch ──
            // The speculative fetch used NYC center. Now that we have
            // real coordinates, force-refresh to get location-accurate
            // results. The speculative data kept the user entertained
            // and warmed the server — this fetch should be fast.
            usedSpeculativeLocation = false
            // recenterOnUser() already commits a centered camera through
            // the engine; the previous unanimated `cameraPosition = ...`
            // write here was a redundant second commit that produced a
            // visible double-pan on first GPS arrival.
            if !userCameraOverrideActive {
                recenterOnUser()
            }
            AppLogger.shared.log(
                "SPECULATIVE",
                message: "Real GPS fix arrived"
                    + " (\(String(format: "%.4f", loc.coordinate.latitude)),"
                    + " \(String(format: "%.4f", loc.coordinate.longitude)))"
                    + " — replacing speculative data")
            Task {
                await viewModel.refresh(location: loc, force: true)
                lastUpdated = Date()
            }
        } else {
            // Don't recenter if user is exploring via drag-to-search —
            // the next GPS fix would yank the camera back to their real
            // location, undoing the drag. Also guard against panning even if 
            // the threshold hasn't been crossed yet.
            if !isPositioningDragSearchPin && !userCameraOverrideActive {
                // Skip the system recenter when the map is already close to
                // the GPS dot — avoids a redundant write that can make the
                // recenter button's first tap appear to do nothing (the engine
                // sees binding.wrappedValue == targetCamera and no-ops the
                // user commit because the system already wrote it).
                let alreadyCentered: Bool = {
                    guard let center = currentMapCenter else { return false }
                    let cam = CLLocation(latitude: center.latitude, longitude: center.longitude)
                    let gps = CLLocation(latitude: loc.coordinate.latitude,
                                        longitude: loc.coordinate.longitude)
                    return cam.distance(from: gps) < 80
                }()
                if !alreadyCentered {
                    recenterOnUser()
                }
            }
            
            // Live walking update: when a route detail is open, recalculate
            // the walking polyline so it tracks the user's real-time position.
            // Debounced to 20m to avoid excessive MKDirections calls.
            if viewModel.selectedRouteId != nil {
                handleLiveWalkingUpdate(loc)
            }

            // Skip duplicate fetch if user hasn't moved significantly.
            // Use a lower threshold when the cached GPS was stale (fix age
            // > 30s means the user just returned from suspension — their
            // first "accurate" fix may still be coarsely near the old spot).
            guard let lastLoc = viewModel.lastRefreshLocation else { return }
            let moved = loc.distance(from: lastLoc)
            
            // After a long suspension the first fix is critical even if
            // the distance filter says "only 50m".  Use the configured
            // significantMovementMeters (150m) for normal refreshes, but
            // if the refreshLocation was set from a stale cache, force on
            // any detectable movement (> 50m).
            // At transit speed (train/bus), always use the lower threshold
            // so stops refresh as the vehicle moves through them.
            let fixAge = abs(loc.timestamp.timeIntervalSinceNow)
            let isTransitSpeed = loc.speed >= AppSettings.transitSpeedThreshold
            let threshold: Double
            if isTransitSpeed || fixAge >= 5 {
                threshold = max(50, AppSettings.shared.distanceFilterMeters)
            } else {
                threshold = AppSettings.shared.significantMovementMeters
            }
            guard moved >= threshold else { return }

            AppLogger.shared.log(
                "LOCATION",
                message: "📍 GPS fix shows \(Int(moved))m drift"
                    + " from last fetch (threshold=\(Int(threshold))m,"
                    + " fixAge=\(String(format: "%.1f", fixAge))s)"
                    + " — re-fetching"
            )
            Task {
                await viewModel.refresh(location: loc, force: true)
                lastUpdated = Date()
            }
        }
    }
    
    // MARK: - Live Walking Update
    
    /// Recalculates nearest stop + walking route as the user walks while
    /// a route detail sheet is open. Debounced to 20m movement so we don't
    /// spam MKDirections. Does NOT re-zoom the camera unless the nearest
    /// stop actually changes (handled automatically by .onChange).
    private func handleLiveWalkingUpdate(_ loc: CLLocation) {
        // Skip if no route shape loaded yet (still loading)
        guard viewModel.routeShape != nil else { return }
        // Skip when search pin is active — distances are from pin, not GPS
        guard !viewModel.isSearchPinActive else { return }
        // At transit speed, walking directions are meaningless — the user
        // is on a train or bus, not walking to a stop.
        guard !locationManager.isAtTransitSpeed else { return }
        
        // Debounce: only update if moved 20m+ from last walking update
        let walkingThreshold: Double = 20
        if let lastLoc = lastWalkingUpdateLocation {
            let moved = loc.distance(from: lastLoc)
            guard moved >= walkingThreshold else { return }
        }
        
        lastWalkingUpdateLocation = loc
        
        // Cancel any in-flight walking route request
        walkingUpdateTask?.cancel()
        walkingUpdateTask = Task {
            // Suppress the camera re-zoom when the walking route updates
            // from a live GPS tick (user is just walking, not opening a route)
            suppressWalkingRouteZoom = true
            await viewModel.refreshWalkingState(userLocation: loc)
        }
    }
    
    // MARK: - Drag to Search
    
    /// Called on every camera change. Debounces, then:
    ///  1. Activates the drag-search dot once the user pans away from their location
    ///  2. Automatically fires the API to search at the new map center
    ///  3. Sets the settled center so radius circles snap into place
    ///  4. The sheet shows a live loading spinner via viewModel.isLoading
    private func handleMapCameraIdle(center: CLLocationCoordinate2D) {
        // After a dismiss, the programmatic recenter animation fires dozens
        // of camera-idle events while the camera is still flying back to GPS.
        // Those intermediate positions (still far from GPS) would immediately
        // re-activate drag-search, causing the visible bounce / spam-tap issue.
        // Ignore all camera events for 1 s after a dismiss.
        if let dismissedAt = dragSearchDismissedAt,
           Date().timeIntervalSince(dismissedAt) < 1.0 { return }

        guard dragToSearchEnabled,
              viewModel.selectedRouteId == nil else { return }

                lastDragSearchCameraMoveAt = Date()
        
        // Cancel any pending debounce
        dragSearchDebounce?.cancel()
        
        // Instant coordinate feedback — show formatted lat/lon immediately
        // so the header updates on every frame. The geocode will replace
        // this with a real place name once the debounce settles.
        if let userLoc = locationManager.currentLocation {
            let panLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let dist = panLoc.distance(from: userLoc)
            
            if dist > Self.dragSearchActivationDistanceMeters {
                viewModel.setInstantCoordinate(center)
                
                // ── Instant activation ─────────────────────────────────
                // Show the circle the FIRST frame the user pans 60m+ from
                // GPS — no debounce, no waiting. The API call is still
                // gated behind the 350ms debounce below.
                if !isDragSearchActive {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isDragSearchActive = true
                        isDragSearchPanning = true
                    }
                    HapticManager.selection()
                }
            }
        } else if isDragSearchActive {
            viewModel.setInstantCoordinate(center)
        }
        
        // Mark as actively panning — dims the map and shows "Release to search".
        if isDragSearchActive {
            if !isDragSearchPanning {
                withAnimation(.interpolatingSpring(stiffness: 200, damping: 22)) {
                    isDragSearchPanning = true
                }
            }
        }
        
        dragSearchDebounce = Task { @MainActor in
            // Wait for the user to stop panning (350ms of stillness)
            // — snappy feel, safe with the 3 s geocoder time guard.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            
            guard isDragSearchActive else { return }

            let dragLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
            if let userLoc = locationManager.currentLocation,
               dragLoc.distance(from: userLoc) <= Self.dragSearchGPSSnapRadiusMeters {
                clearDragSearchToGPS(stampDismissal: false)
                return
            }

            // Panning stopped outside the GPS snap radius — fire the API
            // search at the actual settled center.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                isDragSearchPanning = false
            }

            // Geocode *after* debounce settles — one request per
            // settled position instead of one per camera frame.
            viewModel.updateLocationName(for: dragLoc)

            await viewModel.setSearchPin(center, userLocation: locationManager.currentLocation)
            lastUpdated = Date()

            // Lock the radius circles and chat bias to the dropped pin.
            dragSearchSettledCenter = center
            chatBiasPin = center
            locationContext.setDroppedPin(center)

            // Satisfying "lock-in" vibration so the user feels the new center
            HapticManager.impact(.medium)
        }
    }
    
    /// Dismisses the drag-search overlay, clears the search pin,
    /// and refreshes data for the user's real location without moving the camera.
    private func dismissDragSearch() {
        dismissDragSearchState()
    }

    /// Dismisses drag-search UI state and refreshes data without
    /// touching the camera. Use when the caller handles camera
    /// positioning separately (e.g. MapControlsOverlay.centerMap).
    private func dismissDragSearchState() {
        dragSearchDebounce?.cancel()

        // Stamp dismissal time so handleMapCameraIdle ignores intermediate
        // camera positions produced by the recenter animation flying back.
        clearDragSearchToGPS(stampDismissal: true)
    }

    private func clearDragSearchToGPS(stampDismissal: Bool) {
        dragSearchDebounce?.cancel()

        if stampDismissal {
            dragSearchDismissedAt = Date()
        }

        // Staggered exit: circle shrinks first, then state clears
        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
            isDragSearchPanning = false
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            isDragSearchActive = false
            hasFiredDragHaptic = false
            dragSearchSettledCenter = nil
        }
        lastDragSearchCameraMoveAt = nil
        chatBiasPin = nil
        locationContext.clearDroppedPin()
        
        HapticManager.notification(.success)
        
        Task {
            await viewModel.clearSearchPin(userLocation: locationManager.currentLocation)
            await viewModel.refresh(location: locationManager.currentLocation, force: true)
            lastUpdated = Date()
        }
    }
    
    // MARK: - Map Centering
    
    /// Re-adjusts the camera whenever the sheet detent changes so the
    /// user's location or route focus stays visible above the sheet.
    /// Mirrors the Apple Transit behaviour where the map center shifts
    /// as the sheet height changes.
    private func handleSheetDetentChanged() {
        // Don't fight with drag-to-search camera positioning
        guard !isDragSearchActive else { return }
        guard !userCameraOverrideActive else { return }

        // When sheet goes full-screen, map is barely visible — skip
        guard sheetDetent != .large else { return }

        if viewModel.selectedRouteId != nil {
            // Route is open — re-fit using the existing algorithm.
            // The dedupe inside CameraHoverEngine.commit suppresses the
            // second commit when handleNearestStopChanged already wrote
            // the same fit camera moments earlier.
            if let fitCamera = viewModel.cameraPositionFittingRoute(
                userLocation: locationManager.currentLocation,
                is3D: false
            ) {
                CameraHoverEngine.commit(
                    fitCamera,
                    animation: HoverAnimations.routeFit,
                    to: $cameraPosition,
                    source: .system
                )
            }
        } else if let coordinate = locationManager.currentLocation?.coordinate {
            // Dashboard — keep user dot visible above sheet
            CameraHoverEngine.commit(
                MapCameraPresets.center(on: coordinate, is3D: false),
                animation: HoverAnimations.routeFit,
                to: $cameraPosition,
                source: .system
            )
        }
    }

    /// Centers the map on the user's current location (no route selected)
    /// or gently tracks the user at transit speed even when a route detail
    /// is open, so the map follows the train.
    private func recenterOnUser() {
        guard let coordinate = locationManager.currentLocation?.coordinate else {
            // No location yet — reset to the .userLocation position so the map
            // will auto-center once CoreLocation delivers a fix.
            if viewModel.selectedRouteId == nil {
                CameraHoverEngine.commit(
                    .userLocation,
                    animation: HoverAnimations.snap,
                    to: $cameraPosition,
                    source: .system
                )
            }
            return
        }

        if viewModel.selectedRouteId != nil {
            // When viewing a route detail at transit speed, gently pan the
            // camera so the user sees the train moving along the map.
            // At walking speed, don't override — the route framing is more useful.
            if locationManager.isAtTransitSpeed {
                CameraHoverEngine.commit(
                    MapCameraPresets.center(on: coordinate, is3D: false),
                    animation: HoverAnimations.gentle,
                    to: $cameraPosition,
                    source: .system
                )
            }
            return
        }

        CameraHoverEngine.commit(
            MapCameraPresets.center(on: coordinate, is3D: false),
            animation: HoverAnimations.routeFit,
            to: $cameraPosition,
            source: .system
        )
    }
    
    private func centerMap(on target: CLLocationCoordinate2D? = nil) {
        userCameraOverrideActive = false

        // Collapse sheet and animate camera. Sheet detent change runs in
        // its own transaction so handleSheetDetentChanged's reactive
        // camera write is dropped by the engine's dedupe (same target
        // within the coalesce window).
        let refCoord = effectiveCoordinate
        let finalTarget = target ?? refCoord ?? AppTheme.MapConfig.nycCenter

        let targetCamera: TrackCameraPosition
        if let destination = target, let ref = refCoord {
            targetCamera = MapCameraPresets.fitTwoPoints(
                from: ref, to: destination, is3D: false)
        } else {
            targetCamera = MapCameraPresets.center(
                on: finalTarget, is3D: false)
        }

        if sheetDetent != .large {
            withAnimation(HoverAnimations.snap) {
                sheetDetent = SheetConstants.defaultDetent
            }
        }
        CameraHoverEngine.commit(
            targetCamera,
            animation: HoverAnimations.routeFit,
            to: $cameraPosition,
            source: .user
        )
    }

    // MARK: - Deep Link

    /// Called when a Live Activity or widget URL opens the app.
    /// Sets a pending flag so the tracked route detail opens automatically.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "track", url.host == "route" else { return }
        
        viewModel.pendingDeepLink = true
        // Clear any stored flag from TrackApp cold-launch handler
        UserDefaults.standard.removeObject(forKey: "pending_deep_link")
        
        // If data is already loaded, navigate immediately
        attemptDeepLinkNavigation()
    }

    /// Tries to navigate to the tracked route's detail page.
    /// Succeeds only when `groupedTransit` is populated with a matching route.
    private func attemptDeepLinkNavigation() {
        guard viewModel.pendingDeepLink else { return }
        guard let match = viewModel.groupForTrackedRoute() else { return }
        
        viewModel.pendingDeepLink = false

        sheetNavigator.navigate(
            to: .routeDetail(
                group: match.group,
                directionIndex: match.directionIndex
            )
        )
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            sheetDetent = SheetConstants.defaultDetent
        }
        
        Task {
            await viewModel.selectGroupedRoute(
                match.group,
                directionIndex: match.directionIndex,
                userLocation: locationManager.currentLocation
            )
        }
    }
}

private struct MapActionPopupItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let iconName: String
    let accent: Color
    let planLocation: PlanLocation
    let detailsSelection: StopDetailSelection?
    let showsActions: Bool

    static func savedPlace(_ place: SavedLocation) -> MapActionPopupItem {
        MapActionPopupItem(
            id: "saved-\(place.id.uuidString)",
            title: place.name,
            subtitle: place.address.isEmpty ? place.resolvedCategory.label : place.address,
            iconName: place.iconName,
            accent: AppTheme.Colors.accent,
            planLocation: .saved(place),
            detailsSelection: nil,
            showsActions: true
        )
    }

    static func bus(_ stop: BusStop) -> MapActionPopupItem {
        routeStop(stop, mode: "bus", fallbackRouteID: nil, showsActions: true)
    }

    static func routeStop(
        _ stop: BusStop,
        mode: String,
        fallbackRouteID: String?,
        showsActions: Bool = false
    ) -> MapActionPopupItem {
        let selection = StopDetailSelection.routeStop(
            stop,
            mode: mode,
            fallbackRouteID: fallbackRouteID
        )
        return MapActionPopupItem(
            id: selection.id,
            title: stop.name,
            subtitle: selection.kind.title,
            iconName: selection.kind.iconName,
            accent: accentColor(for: selection),
            planLocation: .custom(
                name: stop.name,
                address: selection.kind.title,
                lat: stop.lat,
                lon: stop.lon
            ),
            detailsSelection: selection,
            showsActions: showsActions
        )
    }

    static func station(_ station: MapSystemViewModel.ConsolidatedStation) -> MapActionPopupItem {
        let selection = StopDetailSelection.station(station)
        return MapActionPopupItem(
            id: selection.id,
            title: station.name,
            subtitle: selection.kind.title,
            iconName: selection.kind.iconName,
            accent: accentColor(for: selection),
            planLocation: .custom(
                name: station.name,
                address: selection.kind.title,
                lat: station.coordinate.latitude,
                lon: station.coordinate.longitude
            ),
            detailsSelection: selection,
            showsActions: true
        )
    }

    private static func accentColor(for selection: StopDetailSelection) -> Color {
        switch selection.kind {
        case .bus: return AppTheme.Colors.accent
        case .subway:
            if let route = selection.routeIDs.first {
                return AppTheme.SubwayColors.color(for: route)
            }
            return AppTheme.Colors.accent
        case .lirr: return AppTheme.CommuterRailColors.lirrBlue
        case .mnr: return AppTheme.CommuterRailColors.mnrBlue
        }
    }
}

private struct MapActionTopPopup: View {
    let item: MapActionPopupItem
    let goNow: () -> Void
    let details: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(item.accent.opacity(0.16))
                        .frame(width: 38, height: 38)

                    Image(systemName: item.iconName)
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(item.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(item.subtitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(2)
                }

                if item.showsActions {
                    Spacer(minLength: 8)

                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(AppTheme.Colors.cardInset))
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer(minLength: 0)
                }
            }

            if item.showsActions {
                HStack(spacing: 9) {
                    popupButton(title: "Go", icon: "arrow.up.circle.fill", fill: item.accent, text: .white, action: goNow)
                    if let details {
                        popupButton(title: "Details", icon: "info.circle.fill", fill: AppTheme.Colors.cardInset, text: AppTheme.Colors.textPrimary, action: details)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 390)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(AppTheme.Colors.cardElevated.opacity(0.98))
                .shadow(color: AppTheme.Colors.shadow.opacity(0.30), radius: 22, y: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.borderSubtle.opacity(0.7), lineWidth: 1)
        }
    }

    private func popupButton(
        title: String,
        icon: String,
        fill: Color,
        text: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .heavy))
                Text(title)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(text)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(fill)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HomeView(
        viewModel: HomeViewModel(),
        locationManager: LocationManager(),
        selectedTab: .constant(.home),
        cameraPosition: .constant(.userLocation),
        showStations: .constant(true),
        currentMapCenter: .constant(nil),
        currentMapDistance: .constant(nil),
        chatBiasPin: .constant(nil)
    )
    .environment(LocationContext())
}
