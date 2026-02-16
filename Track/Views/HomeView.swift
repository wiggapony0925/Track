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
                    currentMapDistance: $currentMapDistance
                )
                
                // MARK: - Floating Controls
                VStack {
                    // Top banners section
                    MapControlsOverlay(
                        viewModel: viewModel,
                        locationManager: locationManager,
                        cameraPosition: $cameraPosition,
                        is3DMode: $is3DMode,
                        sheetDetent: $sheetDetent,
                        currentMapCenter: currentMapCenter,
                        currentMapDistance: currentMapDistance,
                        sheetHeightFraction: 0.42
                    )
                    
                    Spacer()
                    
                    // MARK: - Transport Mode Toggle
                    TransportModeToggle(selectedMode: $viewModel.selectedMode)
                        .padding(.bottom, 8)
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
        // MARK: - State Change Handlers
        .onChange(of: viewModel.selectedRouteId) {
            handleRouteSelection()
        }
        .onChange(of: viewModel.selectedMode) {
            handleModeChange()
        }
        .onChange(of: locationManager.currentLocation) {
            handleLocationUpdate()
        }
        .onChange(of: viewModel.nearestStopCoordinate?.latitude) {
            if let coordinate = viewModel.nearestStopCoordinate {
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
                is3DMode: $is3DMode
            )
            
        case .routeDetail(let group, let directionIndex):
            RouteDetailSheet(
                group: group,
                busVehicles: $viewModel.busVehicles,
                routeShape: $viewModel.routeShape,
                initialDirectionIndex: directionIndex,
                isSheetExpanded: sheetDetent == .large,
                is3DMode: $is3DMode,
                cameraPosition: $cameraPosition,
                currentLocation: locationManager.currentLocation?.coordinate,
                searchPinCoordinate: viewModel.searchPinCoordinate,
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
                }
            )
            
        case .settings:
            SettingsContentView(sheetNavigator: sheetNavigator)
            
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
        
        // Auto-refresh at the interval defined in settings
        let interval = TimeInterval(AppSettings.shared.refreshIntervalSeconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                await viewModel.refresh(location: locationManager.currentLocation)
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
        
        if viewModel.selectedRouteId != nil {
            let isBus = viewModel.selectedGroupedRoute?.isBus ?? true
            let startTime = Date()
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let tick = Int(Date().timeIntervalSince(startTime))
                
                Task { @MainActor in
                    if isBus {
                        if tick % 3 == 0 {
                            await viewModel.refreshBusVehicles()
                        }
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
            await viewModel.refresh(location: locationManager.currentLocation)
            lastUpdated = Date()
        }
    }
    
    private func handleLocationUpdate() {
        guard let loc = locationManager.currentLocation else { return }
        
        if !hasLoadedInitialData {
            hasLoadedInitialData = true
            Task {
                await viewModel.refresh(location: loc)
                lastUpdated = Date()
            }
        }
    }
    
    // MARK: - Map Centering
    
    private func centerMap(on target: CLLocationCoordinate2D? = nil) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            sheetDetent = .fraction(0.4)
        }
        
        let userLocation = locationManager.currentLocation?.coordinate
        let finalTarget = target ?? userLocation ?? AppTheme.MapConfig.nycCenter
        
        var center = finalTarget
        var zoomDistance = AppTheme.MapConfig.userZoomDistance
        
        if let destination = target, let user = userLocation {
            let midLat = (user.latitude + destination.latitude) / 2
            let midLon = (user.longitude + destination.longitude) / 2
            center = CLLocationCoordinate2D(latitude: midLat, longitude: midLon)
            
            let userLoc = CLLocation(latitude: user.latitude, longitude: user.longitude)
            let destLoc = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
            let distanceMeters = userLoc.distance(from: destLoc)
            
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
