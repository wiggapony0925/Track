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
    @State private var locationManager = LocationManager()
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
    @AppStorage("auto_refresh_enabled") private var autoRefreshEnabled = true
    @State private var isDragSearchActive = false
    @State private var isDragSearching = false
    @State private var isDragSearchPanning = false
    @State private var hasFiredDragHaptic = false
    @State private var dragSearchDebounce: Task<Void, Never>?
    /// The settled center after a drag-search debounce fires. `nil` while
    /// the user is still panning — the radius circles hide until this is set.
    @State private var dragSearchSettledCenter: CLLocationCoordinate2D?
    
    // MARK: - Effective Location
    
    /// The location used for all distance/centering calculations.
    /// Returns the drag-search center when active, otherwise the real GPS.
    /// Ensures tapping a route during drag-search uses the explored area,
    /// not the user's physical position.
    private var effectiveLocation: CLLocation? {
        viewModel.effectiveLocation(userLocation: locationManager.currentLocation)
    }
    
    /// Convenience coordinate from effectiveLocation.
    private var effectiveCoordinate: CLLocationCoordinate2D? {
        effectiveLocation?.coordinate
    }
    
    var body: some View {
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
        // MARK: - Lifecycle
        .onAppear {
            setupLocationAndTimers()
        }
        .onDisappear {
            cleanupTimers()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Clear any drag search when returning to the app
                if isDragSearchActive {
                    dismissDragSearch()
                } else {
                    recenterOnUser()
                }
            }
        }
        // MARK: - State Change Handlers
        .onChange(of: dragToSearchEnabled) { _, enabled in
            // Immediately clean up when the user toggles the setting off
            if !enabled && isDragSearchActive {
                dismissDragSearch()
            }
        }
        .onChange(of: autoRefreshEnabled) { _, enabled in
            // Start or stop the auto-refresh timer live
            if enabled {
                startRefreshTimer()
            } else {
                refreshTimer?.invalidate()
                refreshTimer = nil
            }
        }
        .onChange(of: viewModel.selectedRouteId) {
            handleRouteSelection()
        }
        .onChange(of: viewModel.selectedMode) {
            handleModeChange()
        }
        .onChange(of: locationManager.currentLocation) {
            handleLocationUpdate()
        }
        .onChange(of: currentMapCenter?.latitude) {
            // Debounced drag-to-search: fires when the map center changes
            if let center = currentMapCenter {
                handleMapCameraIdle(center: center)
            }
        }
        .onChange(of: viewModel.routeShape?.polylines.count) {
            // Route shape loaded (possibly after nearestStopCoordinate was set) —
            // re-fit the map to show the full route.
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
        .onChange(of: viewModel.nearestStopCoordinate?.latitude) {
            // When a route is selected and shape data is loaded, fit the
            // entire route on the map. Falls back to centering on the
            // nearest stop if shape data isn't available yet.
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
                isDragSearching: isDragSearching
            )
            
        case .routeDetail(let group, _):
            // Pass the effective location (search pin center when drag-to-search
            // is active, otherwise the real GPS location) so that distance display,
            // walking directions, and map centering all work from the explored area.
            let effectiveCoord = viewModel.effectiveLocation(
                userLocation: locationManager.currentLocation
            )?.coordinate
            
            RouteDetailSheet(
                group: group,
                busVehicles: $viewModel.busVehicles,
                routeShape: $viewModel.routeShape,
                selectedDirectionIndex: $viewModel.selectedDirectionIndex,
                isSheetExpanded: sheetDetent == .large,
                is3DMode: $is3DMode,
                cameraPosition: $cameraPosition,
                currentLocation: effectiveCoord,
                selectedStopId: viewModel.selectedStopId,
                onTrack: { arrival in
                    viewModel.trackNearbyArrival(arrival, location: locationManager.currentLocation)
                },
                isTracking: { viewModel.isTracking($0) },
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
            
        case .serviceAlerts:
            ServiceAlertsPage(
                alerts: viewModel.serviceAlerts,
                sheetNavigator: sheetNavigator
            )
            
        case .widgetSchedules:
            WidgetSchedulesContentView(sheetNavigator: sheetNavigator)
            
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
        
        if autoRefreshEnabled {
            startRefreshTimer()
        }
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
                await viewModel.refresh(location: effectiveLocation)
                lastUpdated = Date()
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
            isDragSearching = false
            isDragSearchPanning = false
            // NOTE: keep dragSearchSettledCenter so we can restore on dismiss
        }
        
        if viewModel.selectedRouteId != nil {
            let isBus = viewModel.selectedGroupedRoute?.isBus ?? false
            let isCommuterRail = viewModel.selectedGroupedRoute?.isCommuterRail ?? false
            let startTime = Date()
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let tick = Int(Date().timeIntervalSince(startTime))
                
                Task { @MainActor in
                    if isBus {
                        if tick % 2 == 0 {
                            await viewModel.refreshBusVehicles()
                        }
                    } else if isCommuterRail {
                        // No real-time vehicle tracking for commuter rail yet —
                        // skip frequent polling to save battery & network.
                    } else {
                        viewModel.updateSimulation()
                        if tick % 3 == 0 {
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
        Task {
            // Use effective location so mode changes during drag-to-search
            // keep showing transit at the explored area, not GPS.
            await viewModel.refresh(location: effectiveLocation)
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
                await viewModel.refresh(location: loc)
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
        // Only clear the settled center if the camera moved significantly from it
        // (prevents tiny drift/animation from flickering the radius circles).
        if isDragSearchActive {
            if !isDragSearchPanning {
                isDragSearchPanning = true
                // Give a quick vibration each time the user starts a new pan gesture
                HapticManager.impact(.light)
            }
            
            if let settled = dragSearchSettledCenter {
                let settledLoc = CLLocation(latitude: settled.latitude, longitude: settled.longitude)
                let newLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
                if settledLoc.distance(from: newLoc) > 50 {
                    // User actually panned away — hide radius until re-settled
                    dragSearchSettledCenter = nil
                }
            }
        } else {
            // Not yet active — fire a single haptic hint when the user pans
            // far enough that drag-to-search is about to activate.
            if !hasFiredDragHaptic,
               let userCoord = locationManager.currentLocation?.coordinate {
                let userLoc = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                let panLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
                if userLoc.distance(from: panLoc) > 200 {
                    hasFiredDragHaptic = true
                    HapticManager.impact(.light)
                }
            }
        }
        
        dragSearchDebounce = Task { @MainActor in
            // Wait for the user to stop panning (800ms of stillness)
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            
            guard let userCoord = locationManager.currentLocation?.coordinate else { return }
            
            let userLoc = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
            let panLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let distanceMoved = userLoc.distance(from: panLoc)
            
            // Threshold: only activate when panned 300m+ from real location
            let threshold: Double = 300
            
            if distanceMoved > threshold {
                // Show the center dot
                if !isDragSearchActive {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isDragSearchActive = true
                    }
                    HapticManager.selection()
                }
                
                // Mark as searching (panning stopped, API is firing)
                withAnimation(.easeOut(duration: 0.15)) {
                    isDragSearchPanning = false
                    isDragSearching = true
                }
                
                await viewModel.setSearchPin(center, userLocation: locationManager.currentLocation)
                lastUpdated = Date()
                
                // Snap the radius circles into place at the settled location
                dragSearchSettledCenter = center
                
                withAnimation(.easeOut(duration: 0.2)) {
                    isDragSearching = false
                }
                
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
            isDragSearching = false
            isDragSearchPanning = false
            hasFiredDragHaptic = false
            dragSearchSettledCenter = nil
        }
        
        HapticManager.selection()
        
        Task {
            await viewModel.clearSearchPin(userLocation: locationManager.currentLocation)
            await viewModel.refresh(location: locationManager.currentLocation)
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
}

#Preview {
    HomeView()
}
