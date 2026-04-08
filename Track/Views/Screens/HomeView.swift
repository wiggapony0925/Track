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
import SwiftUI
import WidgetKit

struct HomeView: View {
    // MARK: - State
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = HomeViewModel()
    var locationManager: LocationManager
    @State private var sheetNavigator = SheetNavigator()
    @State private var sheetDetent: PresentationDetent = SheetConstants.defaultDetent
    @State private var cameraPosition: TrackCameraPosition = .userLocation
    /// Bridges sheet pixel height to the map's UIKit contentInset in
    /// real-time (60fps) without SwiftUI re-renders.
    @State private var sheetHeightObserver = SheetHeightObserver()
    @State private var lastUpdated: Date?
    @State private var refreshTimer: Timer?
    @State private var vehiclePollTimer: Timer?
    @State private var hasLoadedInitialData = false
    /// True when the first data load used a speculative NYC-center location
    /// because no cached GPS was available (first-ever launch). When the real
    /// GPS fix arrives, `handleLocationUpdate` force-refreshes with accurate
    /// coordinates, then clears this flag.
    @State private var usedSpeculativeLocation = false
    @State private var is3DMode = false
    
    // Zoom-level visibility for stations
    @State private var showStations = true
    
    // Track current map state for smooth 3D transitions
    @State private var currentMapCenter: CLLocationCoordinate2D?
    @State private var currentMapDistance: Double?
    
    // Drag-to-search state
    @AppStorage("drag_to_search") private var dragToSearchEnabled = true
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
    
    /// When true, the next `handleTappedVehicle` call was triggered by a chip
    /// tap inside the route detail sheet — the sheet should collapse (not expand)
    /// so the user can see the focused vehicle on the map.
    @State private var focusFromChip = false
    
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
        Binding(
            get: { !isRouteDetailOverlayPresented },
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
            .onChange(of: currentMapCenter?.latitude) { handleMapCenterChange() }
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
            .onAppear { onAppearSetup() }
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
    }
    
    // MARK: - Map & Sheet Content (extracted to reduce body complexity)
    
    private var mapAndSheetContent: some View {
        GeometryReader { _ in
            ZStack {
                // MARK: - Map Layer
                MapLibreTrackMapView(
                    cameraPosition: $cameraPosition,
                    viewModel: viewModel,
                    locationManager: locationManager,
                    showStations: $showStations,
                    currentMapCenter: $currentMapCenter,
                    currentMapDistance: $currentMapDistance,
                    onRouteStopTap: presentRouteStopDetail,
                    onSystemStationTap: presentTrainStopDetail,
                    isDragSearchActive: isDragSearchActive,
                    dragSearchSettledCenter: dragSearchSettledCenter,
                    sheetHeightObserver: sheetHeightObserver
                )
                
                // MARK: - Floating Controls
                MapControlsOverlay(
                        viewModel: viewModel,
                        locationManager: locationManager,
                        cameraPosition: $cameraPosition,
                        is3DMode: $is3DMode,
                        sheetDetent: $sheetDetent,
                        currentMapCenter: currentMapCenter,
                        currentMapDistance: currentMapDistance,
                        onRecenter: {
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
            // MARK: - Universal Bottom Sheet
            .sheet(isPresented: bottomSheetPresentation) {
                UniversalBottomSheet(
                    navigator: sheetNavigator,
                    sheetDetent: $sheetDetent,
                    sheetHeightObserver: sheetHeightObserver
                ) { page in
                    sheetContent(for: page)
                }
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
            .animation(.spring(response: 0.4, dampingFraction: 0.88), value: isRouteDetailOverlayPresented)
            .onChange(of: isRouteDetailOverlayPresented) { _, isPresented in
                if isPresented {
                    sheetHeightObserver.report(0)
                }
            }
        }
    }
    
    // MARK: - Modifier Handler Methods (extracted from body)
    
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
                cameraPosition = MapCameraPresets.center(on: cachedLoc.coordinate, is3D: false)

                // Phase 1: Load cached route cards with location awareness.
                // If the user moved significantly since last session, the
                // cache is still loaded for instant display but flagged
                // so we know the first network fetch is critical.
                viewModel.loadSessionCache(cachedLocation: cachedLoc)

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

            // Clear any drag search when returning to the app
            if isDragSearchActive {
                // dismissDragSearch already calls clearSearchPin + refresh
                dismissDragSearch()
            } else {
                recenterOnUser()
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
        if !enabled && isDragSearchActive {
            dismissDragSearch()
        }
    }
    
    private func handleMapCenterChange() {
        if let center = currentMapCenter {
            handleMapCameraIdle(center: center)
        }
    }
    
    private func handleRouteShapeLoaded() {
        guard viewModel.selectedRouteId != nil else { return }
        // Only set the sheet detent here.  The actual camera zoom is
        // handled by handleNearestStopChanged — at this point
        // nearestStopCoordinate hasn't been calculated yet, so
        // cameraPositionFittingRoute would fall back to a generic
        // user-location zoom that misses the stop entirely.
        withAnimation(MapCameraPresets.snapAnimation) {
            sheetDetent = SheetConstants.defaultDetent
        }
    }
    
    private func handleNearestStopChanged() {
        // Pass the sheet fraction directly so
        // cameraPositionFittingRoute computes zoom AND center
        // together — guaranteeing both the user and the stop
        // are comfortably visible above the sheet.
        if let fitCamera = viewModel.cameraPositionFittingRoute(
            userLocation: locationManager.currentLocation,
            is3D: is3DMode
        ) {
            withAnimation(MapCameraPresets.snapAnimation) {
                sheetDetent = SheetConstants.defaultDetent
            }
            withAnimation(MapCameraPresets.smoothAnimation) {
                cameraPosition = fitCamera
            }
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
        if let loc = locationManager.currentLocation {
            Task {
                await viewModel.refreshWalkingState(userLocation: loc)
            }
        } else {
            viewModel.updateNearestStop(userLocation: nil)
        }
        
        if let fitCamera = viewModel.cameraPositionFittingRoute(
            userLocation: locationManager.currentLocation,
            is3D: is3DMode
        ) {
            withAnimation(MapCameraPresets.flyAnimation) {
                cameraPosition = fitCamera
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
            withAnimation(MapCameraPresets.snapAnimation) {
                sheetDetent = .large
            }
        }
        
        if let coord = viewModel.coordinateForTappedVehicle(tappedId) {
            withAnimation(MapCameraPresets.flyAnimation) {
                cameraPosition = MapCameraPresets.focusVehicle(at: coord, is3D: is3DMode)
            }
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
                is3DMode: $is3DMode,
                sheetDetent: $sheetDetent
            )
            
        case .routeDetail(let group, _, let initialTab):
            routeDetailScreen(
                routeGroup: group,
                initialTab: initialTab,
                isExpanded: sheetDetent == .large,
                collapseSheetOnFocus: true
            )

        case .stopDetail(let selection):
            StopDetailSheet(
                selection: selection,
                sheetNavigator: sheetNavigator,
                currentLocation: effectiveCoordinate,
                elevatorOutages: viewModel.elevatorOutages,
                serviceAlerts: viewModel.serviceAlerts
            )
            .id(selection.id)
            
        case .settings:
            SettingsContentView(sheetNavigator: sheetNavigator)

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

        case .manageFavorites:
            ManageFavoritesView(
                sheetNavigator: sheetNavigator,
                groupedTransit: viewModel.groupedTransit,
                userLocation: locationManager.currentLocation,
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
                if let bus = viewModel.busVehicles.first(where: { $0.vehicleId == vid }) {
                    return CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
                }
                return nil
            },
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
            isSheetExpanded: isExpanded,
            is3DMode: $is3DMode,
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
                    withAnimation(MapCameraPresets.flyAnimation) {
                        cameraPosition = MapCameraPresets
                            .focusVehicle(at: coord, is3D: is3DMode)
                    }
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
                // Mark that this focus came from a chip so handleTappedVehicle
                // doesn't reopen the dashboard sheet while we are focusing a marker.
                focusFromChip = true

                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    viewModel.tappedVehicleId = key
                }

                if collapseSheetOnFocus {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        sheetDetent = SheetConstants.defaultDetent
                    }
                }

                if let key, let coord = viewModel.coordinateForTappedVehicle(key) {
                    withAnimation(MapCameraPresets.flyAnimation) {
                        cameraPosition = MapCameraPresets
                            .focusVehicle(at: coord, is3D: is3DMode)
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
                    withAnimation(MapCameraPresets.flyAnimation) {
                        cameraPosition = MapCameraPresets.center(on: settled, is3D: is3DMode)
                    }
                } else {
                    recenterOnUser()
                }
            },
            onStopSelected: { coord in
                // Update the polyline split anchor so behind/ahead
                // coloring follows the stop the user tapped.
                // nil = user deselected -> clear split (full-color polyline).
                viewModel.nearestStopCoordinate = coord

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
                } else if let userLoc = locationManager.currentLocation {
                    // Deselected -> revert to auto-nearest stop and its walking route.
                    suppressWalkingRouteZoom = true
                    Task {
                        await viewModel.refreshWalkingState(userLocation: userLoc)
                    }
                }
            },
            onRecenter: {
                // Re-invoke the route-fitting camera that shows both user
                // location and the nearest stop — same logic as the initial
                // route-open zoom.
                if let fitCamera = viewModel.cameraPositionFittingRoute(
                    userLocation: locationManager.currentLocation,
                    is3D: is3DMode
                ) {
                    if collapseSheetOnFocus {
                        withAnimation(MapCameraPresets.snapAnimation) {
                            sheetDetent = SheetConstants.defaultDetent
                        }
                    }
                    withAnimation(MapCameraPresets.flyAnimation) {
                        cameraPosition = fitCamera
                    }
                } else {
                    let target = effectiveCoordinate ?? AppTheme.MapConfig.nycCenter
                    withAnimation(MapCameraPresets.flyAnimation) {
                        cameraPosition = MapCameraPresets.center(on: target, is3D: is3DMode)
                    }
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
        presentStopDetail(.routeStop(stop, mode: mode, fallbackRouteID: fallbackRouteID))
    }

    private func presentTrainStopDetail(
        _ station: MapSystemViewModel.ConsolidatedStation
    ) {
        presentStopDetail(.station(station))
    }

    private func presentStopDetail(_ selection: StopDetailSelection) {
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
            let isBus = viewModel.selectedGroupedRoute?.isBus ?? false
            let isCommuterRail = viewModel.selectedGroupedRoute?.isCommuterRail ?? false
            let startTime = Date()
            var consecutiveErrors = 0
            // Run simulation every second for smoother marker glide.
            // Keep network poll cadence unchanged via tick divisors below.
            let tickInterval: TimeInterval = 1.0
            let timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
                let tick = Int(Date().timeIntervalSince(startTime) / tickInterval)
                
                Task { @MainActor in
                    if isBus {
                        // Buses: MTA SIRI updates GPS every ~30s.
                        // Poll every 10s for fresh data, interpolate on other ticks.
                        // Back off on errors: skip network calls after 3+ failures.
                        // ticks (×1s = 10s / 30s)
                        let pollInterval = consecutiveErrors >= 3
                            ? 30 : 10
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
                        // simulate every tick, network refresh every 10s.
                        viewModel.updateSimulation()
                        if tick % 10 == 0 { // 10 ticks × 1s = 10s
                            await viewModel.refreshCommuterRailVehicles()
                        }
                    } else {
                        // Subway: Simulate every tick, network refresh every 6s
                        viewModel.updateSimulation()
                        if tick % 6 == 0 { // 6 ticks × 1s = 6s
                            await viewModel.refreshTrainVehicles()
                        }
                    }
                }
            }
            vehiclePollTimer = timer
        }
    }
    
    private func handleModeChange() {
        viewModel.clearRoute()
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
    
    private func handleLocationUpdate() {
        guard let loc = locationManager.currentLocation else { return }
        
        if !hasLoadedInitialData {
            hasLoadedInitialData = true
            
            // Center the map on the user as soon as we get the first fix
            recenterOnUser()
            
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
            recenterOnUser()
            cameraPosition = MapCameraPresets.center(on: loc.coordinate, is3D: false)
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
            // location, undoing the drag.
            if !isDragSearchActive {
                recenterOnUser()
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
    ///  1. Activates the drag-search dot if user panned 300m+ from their location
    ///  2. Automatically fires the API to search at the new map center
    ///  3. Sets the settled center so radius circles snap into place
    ///  4. The sheet shows a live loading spinner via viewModel.isLoading
    private func handleMapCameraIdle(center: CLLocationCoordinate2D) {
        guard dragToSearchEnabled,
              viewModel.selectedRouteId == nil else { return }
        
        // Cancel any pending debounce
        dragSearchDebounce?.cancel()
        
        // Mark as actively panning — dims the map and shows "Release to search".
        // The radius circles now track currentMapCenter live, so we don't need
        // to clear dragSearchSettledCenter during panning.
        if isDragSearchActive {
            if !isDragSearchPanning {
                isDragSearchPanning = true
                // Give a quick vibration each time the user starts a new pan gesture
                HapticManager.impact(.light)
            }
        } else {
            // Not yet active — fire a single haptic hint when the user pans
            // far enough that drag-to-search is about to activate.
            if !hasFiredDragHaptic,
               let userCoord = locationManager.currentLocation?.coordinate {
                let userLoc = CLLocation(
                    latitude: userCoord.latitude,
                    longitude: userCoord.longitude)
                let panLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
                if userLoc.distance(from: panLoc) > 60 {
                    hasFiredDragHaptic = true
                    HapticManager.impact(.light)
                }
            }
        }
        
        dragSearchDebounce = Task { @MainActor in
            // Wait for the user to stop panning (500ms of stillness)
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            
            guard let userCoord = locationManager.currentLocation?.coordinate else { return }
            
            let userLoc = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
            let panLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let distanceMoved = userLoc.distance(from: panLoc)
            
            // Threshold: activate when panned 100m+ from real location so
            // the drag-search dot appears almost immediately when the user
            // moves the map — it "emerges" from the GPS circle.
            let threshold: Double = 100
            
            if distanceMoved > threshold {
                // Show the center dot
                if !isDragSearchActive {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isDragSearchActive = true
                    }
                    HapticManager.selection()
                }
                
                // Panning stopped — isDragSearching is now derived from
                // viewModel.isLoading && viewModel.isSearchPinActive,
                // so it activates automatically when setSearchPin fires.
                withAnimation(.easeOut(duration: 0.15)) {
                    isDragSearchPanning = false
                }
                
                await viewModel.setSearchPin(center, userLocation: locationManager.currentLocation)
                lastUpdated = Date()
                
                // Snap the radius circles into place at the settled location
                dragSearchSettledCenter = center
                
                // Satisfying "lock-in" vibration so the user feels the new center
                HapticManager.impact(.medium)
            } else {
                // Panned back near the user — auto-dismiss
                if isDragSearchActive {
                    dismissDragSearch()
                }
            }
        }
    }
    
    /// Dismisses the drag-search overlay, clears the search pin,
    /// refreshes data for the user's real location, and recenters.
    private func dismissDragSearch() {
        dismissDragSearchState()
        // Snap back to user location
        recenterOnUser()
    }

    /// Dismisses drag-search UI state and refreshes data without
    /// touching the camera. Use when the caller handles camera
    /// positioning separately (e.g. MapControlsOverlay.centerMap).
    private func dismissDragSearchState() {
        dragSearchDebounce?.cancel()
        
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            isDragSearchActive = false
            isDragSearchPanning = false
            hasFiredDragHaptic = false
            dragSearchSettledCenter = nil
        }
        
        HapticManager.selection()
        
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

        // When sheet goes full-screen, map is barely visible — skip
        guard sheetDetent != .large else { return }

        if viewModel.selectedRouteId != nil {
            // Route is open — re-fit using the existing algorithm
            if let fitCamera = viewModel.cameraPositionFittingRoute(
                userLocation: locationManager.currentLocation,
                is3D: is3DMode
            ) {
                withAnimation(MapCameraPresets.smoothAnimation) {
                    cameraPosition = fitCamera
                }
            }
        } else if let coordinate = locationManager.currentLocation?.coordinate {
            // Dashboard — keep user dot visible above sheet
            withAnimation(MapCameraPresets.smoothAnimation) {
                cameraPosition = MapCameraPresets.center(on: coordinate, is3D: is3DMode)
            }
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
                cameraPosition = .userLocation
            }
            return
        }

        if viewModel.selectedRouteId != nil {
            // When viewing a route detail at transit speed, gently pan the
            // camera so the user sees the train moving along the map.
            // At walking speed, don't override — the route framing is more useful.
            if locationManager.isAtTransitSpeed {
                withAnimation(MapCameraPresets.smoothAnimation) {
                    cameraPosition = MapCameraPresets.center(on: coordinate, is3D: is3DMode)
                }
            }
            return
        }
        
        withAnimation(MapCameraPresets.flyAnimation) {
            cameraPosition = MapCameraPresets.center(on: coordinate, is3D: is3DMode)
        }
    }
    
    private func centerMap(on target: CLLocationCoordinate2D? = nil) {
        withAnimation(MapCameraPresets.snapAnimation) {
            sheetDetent = SheetConstants.defaultDetent
        }
        
        // Use effective location (search pin center during drag-to-search,
        // otherwise real GPS) so the map centers relative to the explored area.
        let refCoord = effectiveCoordinate
        let finalTarget = target ?? refCoord ?? AppTheme.MapConfig.nycCenter
        
        if let destination = target, let ref = refCoord {
            withAnimation(MapCameraPresets.smoothAnimation) {
                cameraPosition = MapCameraPresets.fitTwoPoints(
                    from: ref, to: destination, is3D: is3DMode)
            }
        } else {
            withAnimation(MapCameraPresets.smoothAnimation) {
                cameraPosition = MapCameraPresets.center(
                    on: finalTarget, is3D: is3DMode)
            }
        }
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

#Preview {
    HomeView(locationManager: LocationManager())
}
