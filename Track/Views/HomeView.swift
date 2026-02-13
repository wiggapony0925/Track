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

import SwiftUI
import MapKit

struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    @State private var locationManager = LocationManager()
    @State private var sheetDetent: PresentationDetent = .fraction(0.4)
    @State private var cameraPosition: MapCameraPosition = AppTheme.MapConfig.initialPosition
    @State private var showSettings = false
    @State private var lastUpdated: Date?
    @State private var refreshTimer: Timer?
    @State private var hasLoadedInitialData = false
    @State private var is3DMode = false
    
    // Zoom-level visibility for stations
    @State private var showStations = true

    /// Color of the currently selected route, used for polylines and annotations.
    private var selectedRouteColor: Color {
        if let group = viewModel.selectedGroupedRoute, let hex = group.colorHex {
            return Color(hex: hex)
        }
        if let group = viewModel.selectedGroupedRoute {
            return group.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: group.displayName)
        }
        return AppTheme.Colors.mtaBlue
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
            // Map background bounded to NYC 5 boroughs + Long Island.
            Map(position: $cameraPosition,
                bounds: AppTheme.MapConfig.cameraBounds) {
                // User location
                UserAnnotation()

                // Draggable search pin
                if viewModel.isSearchPinActive, let pin = viewModel.searchPinCoordinate {
                    Annotation("Search here", coordinate: pin) {
                        SearchPinAnnotation()
                    }
                }

                // Bus stop annotations when in bus mode
                if viewModel.selectedMode == .bus {
                    ForEach(viewModel.nearbyBusStops) { stop in
                        Annotation(stop.name, coordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)) {
                            BusStopAnnotation(stopName: stop.name)
                                .onTapGesture {
                                    Task {
                                        await viewModel.fetchBusArrivals(for: stop)
                                    }
                                }
                        }
                    }
                }

                // Route shape stops when a route is selected
                if let shape = viewModel.routeShape {
                    let isBusRoute = viewModel.selectedGroupedRoute?.isBus == true
                    ForEach(shape.stops) { stop in
                        Annotation(stop.name, coordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)) {
                            ZStack {
                                if isBusRoute {
                                    // Bus stops: rounded square marker
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.white)
                                        .frame(width: 12, height: 12)
                                        .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(selectedRouteColor, lineWidth: 3)
                                        .frame(width: 12, height: 12)
                                } else {
                                    // Subway stops: circle marker
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 12, height: 12)
                                        .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                                    Circle()
                                        .stroke(selectedRouteColor, lineWidth: 3)
                                        .frame(width: 12, height: 12)
                                }
                            }
                            .accessibilityLabel(stop.name)
                        }
                    }
                }

                // Live bus vehicle positions on map
                ForEach(viewModel.busVehicles) { vehicle in
                    Annotation(
                        vehicle.nextStop ?? vehicle.displayRouteName,
                        coordinate: CLLocationCoordinate2D(latitude: vehicle.lat, longitude: vehicle.lon)
                    ) {
                        BusVehicleAnnotation(
                            routeName: vehicle.displayRouteName,
                            bearing: vehicle.bearing
                        )
                    }
                }


                // Walking route indicator
                if let walkingRoute = viewModel.walkingRoute {
                    MapPolyline(walkingRoute.polyline)
                        .stroke(Color.gray, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [8, 8]))
                }

                // Route polylines
                if let shape = viewModel.routeShape {
                    let isBusRoute = viewModel.selectedGroupedRoute?.isBus == true
                    let polylines = shape.decodedPolylines
                    
                    if !polylines.isEmpty {
                        // Draw decoded route polylines
                        ForEach(Array(polylines.enumerated()), id: \.offset) { _, coords in
                            if isBusRoute {
                                // Bus routes: dashed line for visual distinction
                                MapPolyline(coordinates: coords)
                                    .stroke(selectedRouteColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: [12, 6]))
                            } else {
                                // Subway routes: solid line
                                MapPolyline(coordinates: coords)
                                    .stroke(selectedRouteColor, lineWidth: 4)
                            }
                        }
                    } else if !shape.stops.isEmpty {
                        // Fallback: draw a line through all stops when polylines are empty
                        let stopCoords = shape.stops.map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                        }
                        MapPolyline(coordinates: stopCoords)
                            .stroke(selectedRouteColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: [12, 6]))
                    }
                } else {
                    // Full system map (all lines) shown by default
                    ForEach(viewModel.cachedSystemMap) { line in
                        ForEach(Array(line.coordinates.enumerated()), id: \.offset) { _, coords in
                            MapPolyline(coordinates: coords)
                                .stroke(line.color, lineWidth: 2)
                        }
                    }

                    // Stations layer (only when zoomed in)
                    if showStations {
                        ForEach(viewModel.cachedStations) { station in
                            Annotation(station.name, coordinate: station.coordinate) {
                                SubwayStationMarker(station: station)
                            }
                        }
                    }
                }
            }
            // Transit-emphasized map style: dims driving roads, highlights transit
            // stations natively via pointsOfInterest.
            .mapStyle(.standard(
                emphasis: .muted,
                pointsOfInterest: .including([.publicTransport]),
                showsTraffic: false
            ))
            .onMapCameraChange(frequency: .continuous) { context in
                // Show stations only when zoomed in past the configured threshold
                let zoomThreshold = AppSettings.shared.stationVisibilityZoomMeters
                let d = context.camera.distance
                if (d < zoomThreshold) != showStations {
                    showStations = d < zoomThreshold
                }
            }
            .ignoresSafeArea()
            // Floating controls overlay
            VStack {
                // MARK: Top Section (Banners & Map Controls)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Search pin indicator
                        if viewModel.isSearchPinActive {
                            searchPinBanner
                        }

                        // Selected route indicator
                        if viewModel.selectedRouteId != nil {
                            selectedRouteBanner
                        }
                    }
                    
                    Spacer()
                }
                
                Spacer()

                // MARK: Bottom Section (Mode Toggle)
                // This stays at the bottom, just above the sheet
                TransportModeToggle(selectedMode: $viewModel.selectedMode)
                    .padding(.bottom, 8)
            }
        }
        // Bottom sheet — single modal that swaps between dashboard and route detail
        .sheet(isPresented: .constant(true)) {
            VStack(spacing: 0) {
                if viewModel.isRouteDetailPresented,
                   let group = viewModel.selectedGroupedRoute {
                    RouteDetailSheet(
                        group: group,
                        busVehicles: $viewModel.busVehicles,
                        routeShape: $viewModel.routeShape,
                        initialDirectionIndex: viewModel.selectedDirectionIndex ?? 0,
                        isSheetExpanded: sheetDetent == .large,
                        is3DMode: $is3DMode,
                        cameraPosition: $cameraPosition,
                        currentLocation: locationManager.currentLocation?.coordinate,
                        searchPinCoordinate: viewModel.searchPinCoordinate,
                        onTrack: { arrival in
                            viewModel.trackNearbyArrival(arrival, location: locationManager.currentLocation)
                        },
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                viewModel.isRouteDetailPresented = false
                                viewModel.selectedGroupedRoute = nil
                                viewModel.clearRoute()
                            }
                        }
                    )
                } else {
                    dashboardContent
                }
            }
            .presentationDetents([.fraction(0.4), .large], selection: $sheetDetent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled)
            .interactiveDismissDisabled()
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
        // Map Controls Overlay - floats above sheet when collapsed, hidden when expanded (controls move into sheet header)
        .overlay(alignment: .topTrailing) {
            if sheetDetent != .large {
                VStack(spacing: 12) {
                    // 3D / 2D Toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            is3DMode.toggle()
                            if let loc = locationManager.currentLocation?.coordinate ?? viewModel.searchPinCoordinate {
                                cameraPosition = .camera(MapCamera(
                                    centerCoordinate: loc,
                                    distance: AppTheme.MapConfig.userZoomDistance,
                                    heading: 0,
                                    pitch: is3DMode ? 45 : 0
                                ))
                            }
                        }
                    } label: {
                        Text(is3DMode ? "2D" : "3D")
                            .font(.custom("Helvetica-Bold", size: 15))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                    }
                    .accessibilityLabel(is3DMode ? "Switch to 2D" : "Switch to 3D")

                    // Recenter / Location Button
                    Button {
                        centerMap()
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                            .frame(width: 44, height: 44)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                    }
                    .accessibilityLabel("Recenter on my location")
                }
                .padding(.trailing, AppTheme.Layout.margin)
                .padding(.bottom, geometry.size.height * 0.42) // Position above the 40% sheet
                .transition(.opacity)
            }
        }
        .onAppear {
            locationManager.requestPermission()
            locationManager.startUpdating()
            // Initial data fetch will happen in onChange once location arrives.
            // Auto-refresh at the interval defined in settings.json
            let interval = TimeInterval(AppSettings.shared.refreshIntervalSeconds)
            refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                Task { @MainActor in
                    await viewModel.refresh(location: locationManager.currentLocation)
                    lastUpdated = Date()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onChange(of: viewModel.selectedMode) {
            viewModel.clearRoute()
            Task {
                await viewModel.refresh(location: locationManager.currentLocation)
                lastUpdated = Date()
            }
        }
        // When a new location fix arrives, load data (first time)
        .onChange(of: locationManager.currentLocation) {
            guard let loc = locationManager.currentLocation else { return }
            
            // First location fix — fetch transit data now that we have coordinates
            if !hasLoadedInitialData {
                hasLoadedInitialData = true
                Task {
                    await viewModel.refresh(location: loc)
                    lastUpdated = Date()
                }
            }
        }
        // When nearest stop is identified (after route selection), pan camera to it.
        .onChange(of: viewModel.nearestStopCoordinate?.latitude) {
            if let coordinate = viewModel.nearestStopCoordinate {
                centerMap(on: coordinate)
            }
        }
        }
    }

    // MARK: - Search Pin Banner

    private var searchPinBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.circle.fill")
                .foregroundColor(AppTheme.Colors.mtaBlue)
            Text("Searching from pin location")
                .font(.custom("Helvetica", size: 13))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            Button {
                Task {
                    await viewModel.clearSearchPin(userLocation: locationManager.currentLocation)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .accessibilityLabel("Clear search pin")
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius))
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 8)
    }

    // MARK: - Selected Route Banner

    private var selectedRouteBanner: some View {
        HStack(spacing: 8) {
            let isSubway = viewModel.selectedGroupedRoute?.isBus == false

            ZStack {
                Circle()
                    .fill(selectedRouteColor)
                    .frame(width: 24, height: 24)
                Image(systemName: isSubway ? "tram.fill" : "bus.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
            }

            if let routeId = viewModel.selectedRouteId {
                let name = stripMTAPrefix(routeId)
                let stopsCount = viewModel.routeShape?.stops.count ?? 0
                
                if let firstStop = viewModel.routeShape?.stops.first?.name,
                   let lastStop = viewModel.routeShape?.stops.last?.name {
                    Text("\(name) — \(firstStop) to \(lastStop)")
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                } else {
                    Text("\(name) — \(stopsCount) stops")
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                }
            }

            Spacer()

            if !isSubway {
                Button {
                    Task { await viewModel.refreshBusVehicles() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(selectedRouteColor)
                }
                .accessibilityLabel("Refresh bus positions")
            }

            Button {
                viewModel.clearRoute()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .accessibilityLabel("Close route view")
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius))
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 4)
    }

    // MARK: - Map Control Helper
    
    /// Smartly centers the map on a target coordinate or the user's location.
    /// Ensures the bottom sheet is collapsed to reveal the map.
    private func centerMap(on target: CLLocationCoordinate2D? = nil) {
        // 1. Always collapse the sheet to half-height to reveal the map
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            sheetDetent = .fraction(0.4)
        }
        
        let userLocation = locationManager.currentLocation?.coordinate
        let finalTarget = target ?? userLocation ?? AppTheme.MapConfig.nycCenter
        
        var center = finalTarget
        var zoomDistance = AppTheme.MapConfig.userZoomDistance
        
        // 2. Determine Smart Zoom settings
        if let destination = target, let user = userLocation {
            // Calculate midpoint
            let midLat = (user.latitude + destination.latitude) / 2
            let midLon = (user.longitude + destination.longitude) / 2
            center = CLLocationCoordinate2D(latitude: midLat, longitude: midLon)
            
            // Calculate distance span
            let userLoc = CLLocation(latitude: user.latitude, longitude: user.longitude)
            let destLoc = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
            let distanceMeters = userLoc.distance(from: destLoc)
            
            // Dynamic altitude: configurable
            zoomDistance = max(AppSettings.shared.smartZoomMinAltitude,
                               min(distanceMeters * AppSettings.shared.smartZoomPaddingMultiplier,
                                   AppSettings.shared.smartZoomMaxAltitude))
        }
        
        // 3. Animate camera
        withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: center,
                distance: zoomDistance,
                heading: 0,
                pitch: (target == nil && is3DMode) ? 45 : 0 // Only pitch if centering on user in 3D mode
            ))
        }
    }

    // MARK: - Dashboard Content

    private var dashboardContent: some View {
        VStack(spacing: 0) {
            // MARK: - Navbar (Fixed Header)
            ModalNavbar(
                searchText: $viewModel.searchText,
                showSettings: $showSettings,
                lastUpdated: lastUpdated,
                onDropPin: {
                    let center = locationManager.currentLocation?.coordinate
                        ?? AppTheme.MapConfig.nycCenter
                    let offset = CLLocationCoordinate2D(
                        latitude: center.latitude + 0.002,
                        longitude: center.longitude + 0.002
                    )
                    Task {
                        await viewModel.setSearchPin(offset, userLocation: locationManager.currentLocation)
                    }
                }
            )
            
            // MARK: - Scrollable Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                // Mode-specific content
                Group {
                    switch viewModel.selectedMode {
                    case .nearby:
                        nearbyDashboard
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    case .subway:
                        subwayDashboard
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    case .bus:
                        busDashboard
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    case .lirr:
                        lirrDashboard
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.selectedMode)

                // Network error banner
                if let error = viewModel.errorMessage {
                    NetworkErrorBanner(
                        message: error,
                        onDismiss: {
                            viewModel.errorMessage = nil
                        }
                    )
                }

                // Service alerts
                if !viewModel.serviceAlerts.isEmpty {
                    sectionHeader("Service Alerts")

                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.serviceAlerts.prefix(AppSettings.shared.maxServiceAlerts).enumerated()), id: \.element.id) { index, alert in
                            HStack(spacing: 10) {
                                if let routeId = alert.routeId {
                                    RouteBadge(routeID: routeId, size: .small)
                                } else {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(AppTheme.Colors.warningYellow)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(alert.title)
                                        .font(.custom("Helvetica-Bold", size: 13))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                        .lineLimit(1)
                                    Text(alert.description)
                                        .font(.custom("Helvetica", size: 12))
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                        .lineLimit(2)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 8)

                            if index < min(viewModel.serviceAlerts.count, AppSettings.shared.maxServiceAlerts) - 1 {
                                Divider()
                                    .padding(.leading, AppTheme.Layout.cardPadding + 34)
                            }
                        }
                    }
                    .background(AppTheme.Colors.cardBackground)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
                    .padding(.horizontal, AppTheme.Layout.margin)
                }

                // Elevator / escalator outages
                if !viewModel.elevatorOutages.isEmpty {
                    sectionHeader("Elevator & Escalator Outages")

                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.elevatorOutages.prefix(AppSettings.shared.maxElevatorOutages).enumerated()), id: \.element.id) { index, outage in
                            HStack(spacing: 10) {
                                Image(systemName: outage.equipmentType.lowercased().contains("elevator")
                                      ? "arrow.up.arrow.down.circle.fill"
                                      : "stairs")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(AppTheme.Colors.alertRed)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(outage.station)
                                        .font(.custom("Helvetica-Bold", size: 13))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                        .lineLimit(1)
                                    Text(outage.description)
                                        .font(.custom("Helvetica", size: 12))
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                        .lineLimit(2)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 8)

                            if index < min(viewModel.elevatorOutages.count, AppSettings.shared.maxElevatorOutages) - 1 {
                                Divider()
                                    .padding(.leading, AppTheme.Layout.cardPadding + 34)
                            }
                        }
                    }
                    .background(AppTheme.Colors.cardBackground)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
                    .padding(.horizontal, AppTheme.Layout.margin)
                }

                // Loading indicator
                if viewModel.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(AppTheme.Colors.mtaBlue)
                        Spacer()
                    }
                    .padding()
                }

                Spacer()
                    .frame(height: 20)
            }
            .padding(.top, AppTheme.Layout.margin)
        }
        }
        .background(AppTheme.Colors.background)
        .refreshable {
            await viewModel.refresh(location: locationManager.currentLocation)
            lastUpdated = Date()
        }
    }

    // MARK: - Nearby Transit Dashboard (Unified)

    private var nearbyDashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !viewModel.groupedTransit.isEmpty {
                let filtered = viewModel.filteredGroupedTransit

                if !filtered.isEmpty {
                    sectionHeader("Live Arrivals")

                    VStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, group in
                            GroupedRouteRow(group: group) { directionIndex in
                                Task {
                                    await viewModel.selectGroupedRoute(group, directionIndex: directionIndex, userLocation: locationManager.currentLocation)
                                }
                            }
                            if index < filtered.count - 1 {
                                Divider()
                                    .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                            }
                        }
                    }
                    .background(AppTheme.Colors.cardBackground)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
                    .padding(.horizontal, AppTheme.Layout.margin)
                } else {
                    // Search active but no matching results
                    emptyStateView(
                        icon: "magnifyingglass",
                        message: "No results for \"\(viewModel.searchText)\""
                    )
                }
            } else if !viewModel.nearbyTransit.isEmpty {
                // Fallback to flat list if grouped endpoint failed
                sectionHeader("Live Arrivals")

                VStack(spacing: 0) {
                    ForEach(Array(viewModel.nearbyTransit.enumerated()), id: \.element.id) { index, arrival in
                        NearbyTransitRow(
                            arrival: arrival,
                            isTracking: viewModel.trackingArrivalId == arrival.id,
                            onTrack: {
                                viewModel.trackNearbyArrival(arrival, location: locationManager.currentLocation)
                            },
                            onSelectRoute: arrival.isBus ? {
                                Task { await viewModel.selectArrival(arrival, userLocation: locationManager.currentLocation) }
                            } : nil,
                            userLocation: locationManager.currentLocation
                        )
                        if index < viewModel.nearbyTransit.count - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            } else if !viewModel.isLoading {
                // No transit within walking distance
                if let nearest = viewModel.nearestTransit {
                    // Show the nearest metro recommendation
                    sectionHeader("Nearest Metro")

                    NearestMetroCard(
                        arrival: nearest,
                        distanceMeters: viewModel.nearestTransitDistance,
                        onCenter: { coordinate in
                            withAnimation(.easeInOut(duration: 0.6)) {
                                cameraPosition = .camera(MapCamera(
                                    centerCoordinate: coordinate,
                                    distance: AppTheme.MapConfig.userZoomDistance
                                ))
                            }
                        }
                    )
                } else {
                    // Outside MTA service area — show location debug card
                    outOfServiceAreaCard
                }
            }
        }
    }

    // MARK: - Subway Dashboard

    private var subwayDashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !viewModel.upcomingArrivals.isEmpty {
                sectionHeader("Nearby Arrivals")

                VStack(spacing: 0) {
                    ForEach(Array(viewModel.upcomingArrivals.enumerated()), id: \.element.id) { index, arrival in
                        ArrivalRow(
                            arrival: arrival,
                            prediction: nil,
                            isTracking: viewModel.trackingArrivalId == arrival.id.uuidString,
                            reliabilityWarning: nil,
                            onTrack: {
                                viewModel.trackSubwayArrival(arrival, location: locationManager.currentLocation)
                            }
                        )
                        if index < viewModel.upcomingArrivals.count - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            } else if !viewModel.isLoading {
                emptyStateView(
                    icon: "tram.fill",
                    message: "No subway arrivals nearby"
                )
            }

            if !viewModel.nearbyStations.isEmpty {
                sectionHeader("Nearby Stations")

                VStack(spacing: 0) {
                    ForEach(Array(viewModel.nearbyStations.enumerated()), id: \.element.stationID) { index, station in
                        NearbyStationRow(
                            name: station.name,
                            distance: station.distance,
                            routeIDs: station.routeIDs
                        )
                        if index < viewModel.nearbyStations.count - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
    }

    // MARK: - Bus Dashboard

    private var busDashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let stop = viewModel.selectedBusStop {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stop.name)
                        .font(.custom("Helvetica-Bold", size: 20))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Live Bus Arrivals")
                        .font(.custom("Helvetica", size: 14))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            }

            if !viewModel.busArrivals.isEmpty {
                sectionHeader("Arriving")

                VStack(spacing: 0) {
                    ForEach(Array(viewModel.busArrivals.enumerated()), id: \.element.id) { index, arrival in
                        BusArrivalRow(
                            arrival: arrival,
                            isTracking: viewModel.trackingArrivalId == arrival.id,
                            reliabilityWarning: nil,
                            onTrack: {
                                viewModel.trackBusArrival(arrival, location: locationManager.currentLocation)
                            }
                        )
                        if index < viewModel.busArrivals.count - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            }

            if !viewModel.nearbyBusStops.isEmpty {
                sectionHeader("Nearby Bus Stops")

                VStack(spacing: 0) {
                    ForEach(Array(viewModel.nearbyBusStops.enumerated()), id: \.element.id) { index, stop in
                        Button {
                            Task {
                                await viewModel.fetchBusArrivals(for: stop)
                            }
                        } label: {
                            NearbyBusStopRow(stop: stop)
                        }
                        .buttonStyle(.plain)
                        if index < viewModel.nearbyBusStops.count - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            } else if !viewModel.isLoading {
                emptyStateView(
                    icon: "bus.fill",
                    message: "No bus stops nearby"
                )
            }
        }
    }

    // MARK: - LIRR Dashboard

    private var lirrDashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !viewModel.lirrArrivals.isEmpty {
                sectionHeader("LIRR Departures")

                VStack(spacing: 0) {
                    ForEach(Array(viewModel.lirrArrivals.prefix(AppSettings.shared.maxLirrArrivals).enumerated()), id: \.element.id) { index, arrival in
                        ArrivalRow(
                            arrival: arrival,
                            prediction: nil,
                            isTracking: viewModel.trackingArrivalId == arrival.id.uuidString,
                            reliabilityWarning: nil,
                            onTrack: {
                                viewModel.trackLIRRArrival(arrival, location: locationManager.currentLocation)
                            }
                        )
                        if index < min(viewModel.lirrArrivals.count, AppSettings.shared.maxLirrArrivals) - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            } else if !viewModel.isLoading {
                emptyStateView(
                    icon: "train.side.front.car",
                    message: "No LIRR departures available"
                )
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppTheme.Typography.sectionHeader)
            .foregroundColor(AppTheme.Colors.textSecondary)
            .textCase(.uppercase)
            .lineLimit(1)
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 8)
    }

    private func emptyStateView(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text(message)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Out of Service Area Card

    /// Themed card shown when no nearby transit is found and
    /// no nearest metro recommendation is available.
    private var outOfServiceAreaCard: some View {
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
        }
        .padding(AppTheme.Layout.cardPadding)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

#Preview {
    HomeView()
}
