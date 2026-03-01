//
//  HomeView.swift
//  Track
//
//  Main dashboard view showing nearby transit arrivals.
//  Displays real-time subway and bus data based on the user's
//  current location or a draggable search pin. When a bus route
//  is selected, shows live vehicle positions and the route path
//  on the map.
//
//  REFACTORED: This view now delegates to extracted components:
//  - TrackMapView: All MapKit rendering (annotations, polylines)
//  - MapControlsOverlay: Floating controls (3D toggle, recenter)
//  - UniversalBottomSheet: Single sheet for all navigation
//  - DashboardView: Dashboard content with mode-specific views
//

import SwiftUI
import MapKit
import WidgetKit

struct HomeView: View {
    // MARK: - State
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = HomeViewModel()
    var locationManager: LocationManager
    @State private var sheetNavigator = SheetNavigator()
    @State private var sheetDetent: PresentationDetent = .fraction(0.4)
    @State private var cameraPosition: MapCameraPosition = AppTheme.MapConfig.initialPosition
    @State private var lastUpdated: Date?
    @State private var refreshTimer: Timer?
    @State private var vehiclePollTimer: Timer?
    @State private var hasLoadedInitialData = false
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
    
    var body: some View {
        dataObservedContent
    }
    
    /// Second modifier group: map/route data observers + notifications.
    /// Split from body to keep each expression under the type-checker limit.
    private var dataObservedContent: some View {
        lifecycleObservedContent
            .onChange(of: currentMapCenter?.latitude) { handleMapCenterChange() }
            .onChange(of: viewModel.routeShape?.polylines.count) { handleRouteShapeLoaded() }
            .onChange(of: viewModel.nearestStopCoordinate?.latitude) { handleNearestStopChanged() }
            .onChange(of: viewModel.selectedDirectionIndex) { handleDirectionIndexChanged() }
            .onChange(of: viewModel.groupedTransit.count) { attemptDeepLinkNavigation() }
            .onChange(of: viewModel.tappedVehicleId) { _, newValue in handleTappedVehicle(newValue) }
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
    }
    
    // MARK: - Map & Sheet Content (extracted to reduce body complexity)
    
    private var mapAndSheetContent: some View {
        GeometryReader { geometry in
            ZStack {
                // MARK: - Map Layer
                TrackMapView(
                    cameraPosition: $cameraPosition,
                    viewModel: viewModel,
                    locationManager: locationManager,
                    showStations: $showStations,
                    currentMapCenter: $currentMapCenter,
                    currentMapDistance: $currentMapDistance,
                    isDragSearchActive: isDragSearchActive,
                    dragSearchSettledCenter: dragSearchSettledCenter
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
                    sheetHeightFraction: 0.42,
                    onRecenter: {
                        // Dismiss drag-to-search and restore real location
                        if isDragSearchActive {
                            dismissDragSearch()
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
                if dragToSearchEnabled && viewModel.selectedRouteId == nil {
                    DragSearchOverlay(
                        isActive: isDragSearchActive,
                        isSearching: isDragSearching,
                        isPanning: isDragSearchPanning,
                        onDismiss: { dismissDragSearch() }
                    )
                }
            }
            // MARK: - Universal Bottom Sheet
            .sheet(isPresented: .constant(true)) {
                UniversalBottomSheet(
                    navigator: sheetNavigator,
                    sheetDetent: $sheetDetent
                ) { page in
                    sheetContent(for: page)
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

        // Immediately kick off the first fetch using the cached location
        // from the previous session (stored in App Group by LocationManager).
        // This shaves ~1-2s off startup by not waiting for a fresh GPS fix.
        if !hasLoadedInitialData {
            let defaults = UserDefaults(suiteName: kAppGroupIdentifier) ?? .standard
            let lat = defaults.double(forKey: "lastLatitude")
            let lon = defaults.double(forKey: "lastLongitude")
            if lat != 0 && lon != 0 {
                hasLoadedInitialData = true
                let cachedLoc = CLLocation(latitude: lat, longitude: lon)
                cameraPosition = .camera(
                    MapCamera(centerCoordinate: cachedLoc.coordinate, distance: AppTheme.MapConfig.userZoomDistance)
                )
                Task {
                    await viewModel.refresh(location: cachedLoc, force: true)
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

            // Clear any drag search when returning to the app
            if isDragSearchActive {
                // dismissDragSearch already calls clearSearchPin + refresh
                dismissDragSearch()
            } else {
                recenterOnUser()
                // Refresh with the best location available right now.
                // Prefer the live GPS fix over the stale cached reference
                // location — if CoreLocation hasn't delivered a fix yet,
                // handleLocationUpdate will fire shortly and correct it.
                let refreshLoc = locationManager.currentLocation ?? effectiveLocation
                Task {
                    if await viewModel.refresh(location: refreshLoc) {
                        lastUpdated = Date()
                    }
                }
            }
            
            // Always restart the auto-refresh timer — iOS may have
            // invalidated it while the app was suspended.
            startRefreshTimer()
        } else if newPhase == .background {
            // Timers don't fire reliably in the background — invalidate
            // so they can be cleanly restarted on .active.
            refreshTimer?.invalidate()
            refreshTimer = nil
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
        if viewModel.selectedRouteId != nil,
           let fitCamera = viewModel.cameraPositionFittingRoute(
               userLocation: locationManager.currentLocation,
               is3D: is3DMode
           ) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                sheetDetent = .fraction(0.4)
            }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) {
                cameraPosition = fitCamera
            }
        }
    }
    
    private func handleNearestStopChanged() {
        if let fitCamera = viewModel.cameraPositionFittingRoute(
            userLocation: locationManager.currentLocation,
            is3D: is3DMode
        ) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                sheetDetent = .fraction(0.4)
            }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) {
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
        
        // Recalculate the nearest stop for the new direction so the
        // arrivals list and countdown chips show the closest stop first.
        viewModel.updateNearestStop(
            userLocation: locationManager.currentLocation
        )
        
        if let fitCamera = viewModel.cameraPositionFittingRoute(
            userLocation: locationManager.currentLocation,
            is3D: is3DMode
        ) {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                cameraPosition = fitCamera
            }
        }
    }
    
    private func handleTappedVehicle(_ newValue: String?) {
        guard let tappedId = newValue, !tappedId.isEmpty else { return }
        
        if sheetDetent != .large {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                sheetDetent = .large
            }
        }
        
        if let coord = viewModel.coordinateForTappedVehicle(tappedId) {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                cameraPosition = .camera(MapCamera(
                    centerCoordinate: coord,
                    distance: 1500,
                    heading: 0,
                    pitch: is3DMode ? 60 : 0
                ))
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
                is3DMode: $is3DMode
            )
            
        case .routeDetail(let group, _):
            // Pass the effective location (search pin center when drag-to-search
            // is active, otherwise the real GPS location) so that distance display,
            // walking directions, and map centering all work from the explored area.
            let effectiveCoord = viewModel.referenceLocation?.coordinate
            
            // Use the enriched group from the viewModel (which may have
            // additional directions added by enrichGroupWithShapeDirections)
            // instead of the stale group captured at navigation time.
            let enrichedGroup = viewModel.selectedGroupedRoute ?? group
            
            // Compute direction-filtered vehicle count (bus + train) from the
            // ViewModel's already-filtered collections so we don't duplicate
            // direction-filtering logic inside the sheet.
            let vehicleCount = enrichedGroup.isBus
                ? viewModel.filteredBusVehicles.count
                : viewModel.filteredTrainVehicles.count
            
            RouteDetailSheet(
                group: enrichedGroup,
                busVehicles: $viewModel.busVehicles,
                routeShape: $viewModel.routeShape,
                selectedDirectionIndex: $viewModel.selectedDirectionIndex,
                serviceAlerts: viewModel.serviceAlerts,
                busSchedule: viewModel.busSchedule,
                cachedTrainArrivals: viewModel.cachedTrainArrivals,
                cachedStations: viewModel.cachedStations,
                smartETAProvider: { viewModel.smartETA(for: $0) },
                liveVehicleCount: vehicleCount,
                elevatorOutages: viewModel.elevatorOutages,
                isSheetExpanded: sheetDetent == .large,
                is3DMode: $is3DMode,
                cameraPosition: $cameraPosition,
                currentLocation: effectiveCoord,
                selectedStopId: viewModel.selectedStopId,
                onTrack: { arrival in
                    viewModel.trackNearbyArrival(arrival, location: locationManager.currentLocation)
                    
                    // Zoom the map to center on the tracked vehicle/stop marker
                    if let coord = viewModel.trackedVehicleCoordinate {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                            cameraPosition = .camera(MapCamera(
                                centerCoordinate: coord,
                                distance: 1500,
                                heading: 0,
                                pitch: is3DMode ? 60 : 0
                            ))
                        }
                    }
                },
                isTracking: { viewModel.isTracking($0) },
                isLiveOnMap: { viewModel.isVehicleLiveOnMap($0) },
                onClearHighlight: {
                    // Clear the map highlight when the user taps a highlighted row
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        viewModel.tappedVehicleId = nil
                    }
                },
                onFocusVehicle: { key in
                    // Row expanded/collapsed — highlight the matching marker on the map
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        viewModel.tappedVehicleId = key
                    }
                    // Zoom to the marker if a key was provided
                    if let key, let coord = viewModel.coordinateForTappedVehicle(key) {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                            cameraPosition = .camera(MapCamera(
                                centerCoordinate: coord,
                                distance: 1500,
                                heading: 0,
                                pitch: is3DMode ? 60 : 0
                            ))
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
                        // Fly back to the drag search center
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                            cameraPosition = .camera(MapCamera(
                                centerCoordinate: settled,
                                distance: AppTheme.MapConfig.userZoomDistance,
                                heading: 0,
                                pitch: is3DMode ? 60 : 0
                            ))
                        }
                    } else {
                        recenterOnUser()
                    }
                }
            )
            
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
                    sheetNavigator.navigate(to: .routeDetail(group: group, directionIndex: directionIndex))
                    Task {
                        await viewModel.handleRouteSelection(
                            group, directionIndex: directionIndex,
                            userLocation: locationManager.currentLocation)
                    }
                },
                onTrack: { group, directionIndex in
                    viewModel.setPreferredDirectionIndex(directionIndex, for: group)
                    let dir = group.directions[min(directionIndex, group.directions.count - 1)]
                    guard let arrival = dir.liveArrivals.first else { return }
                    viewModel.trackNearbyArrival(arrival, location: locationManager.currentLocation)
                }
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
                        let pollInterval = consecutiveErrors >= 3 ? 30 : 10 // ticks (×1s = 10s / 30s)
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
        } else {
            // Re-center the map on the fresh GPS fix.
            recenterOnUser()

            // On cold launch the onAppear already kicked a forced refresh
            // using the cached location. If the first live GPS fix arrives
            // within a few seconds and the user hasn't meaningfully moved,
            // skip the duplicate fetch — it just contends for bandwidth and
            // re-renders the same data.
            guard let lastLoc = viewModel.lastRefreshLocation else { return }
            let moved = loc.distance(from: lastLoc)
            guard moved >= AppSettings.shared.significantMovementMeters else { return }

            AppLogger.shared.log(
                "LOCATION",
                message: "📍 GPS fix shows \(Int(moved))m drift from last fetch — re-fetching at current position"
            )
            Task {
                await viewModel.refresh(location: loc, force: true)
                lastUpdated = Date()
            }
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
                let userLoc = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
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
        
        // Snap back to user location
        recenterOnUser()
    }
    
    // MARK: - Map Centering
    
    /// Centers the map on the user's current location (no route selected)
    /// or does nothing if a route detail is already being shown.
    private func recenterOnUser() {
        // Don't override the camera when viewing a specific route
        guard viewModel.selectedRouteId == nil else { return }
        
        guard let coordinate = locationManager.currentLocation?.coordinate else {
            // No location yet — reset to the .userLocation position so MapKit
            // will auto-center once CoreLocation delivers a fix.
            cameraPosition = AppTheme.MapConfig.initialPosition
            return
        }
        
        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: coordinate,
                distance: AppTheme.MapConfig.userZoomDistance,
                heading: 0,
                pitch: is3DMode ? 60 : 0
            ))
        }
    }
    
    private func centerMap(on target: CLLocationCoordinate2D? = nil) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            sheetDetent = .fraction(0.4)
        }
        
        // Use effective location (search pin center during drag-to-search,
        // otherwise real GPS) so the map centers relative to the explored area.
        let refCoord = effectiveCoordinate
        let finalTarget = target ?? refCoord ?? AppTheme.MapConfig.nycCenter
        
        var center = finalTarget
        var zoomDistance = AppTheme.MapConfig.userZoomDistance
        
        if let destination = target, let ref = refCoord {
            let midLat = (ref.latitude + destination.latitude) / 2
            let midLon = (ref.longitude + destination.longitude) / 2
            center = CLLocationCoordinate2D(latitude: midLat, longitude: midLon)
            
            let refLoc = CLLocation(latitude: ref.latitude, longitude: ref.longitude)
            let destLoc = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
            let distanceMeters = refLoc.distance(from: destLoc)
            
            zoomDistance = max(AppSettings.shared.smartZoomMinAltitude,
                               min(distanceMeters * AppSettings.shared.smartZoomPaddingMultiplier,
                                   AppSettings.shared.smartZoomMaxAltitude))
        }
        
        withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: center,
                distance: zoomDistance,
                heading: 0,
                pitch: is3DMode ? 60 : 0
            ))
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
            sheetDetent = .fraction(0.4)
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
