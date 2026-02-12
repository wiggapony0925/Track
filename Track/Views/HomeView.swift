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
    /// Tracks whether we've done the first data fetch after receiving a location fix.
    @State private var hasLoadedInitialData = false

    var body: some View {
        ZStack {
            // Map background bounded to NYC 5 boroughs + Long Island.
            Map(position: $cameraPosition,
                bounds: AppTheme.MapConfig.cameraBounds) {

                // User location — replaced by pulsing GO icon when tracking
                if viewModel.isGoModeActive {
                    // Pulsing vehicle icon snapped to the route line
                    if let loc = locationManager.currentLocation?.coordinate {
                        Annotation("You", coordinate: loc) {
                            GoModeUserAnnotation(
                                routeColor: viewModel.goModeRouteColor ?? AppTheme.Colors.mtaBlue
                            )
                        }
                    }
                } else {
                    UserAnnotation()
                }

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
                    ForEach(shape.stops) { stop in
                        Annotation(stop.name, coordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)) {
                            // Passed stops dim in GO mode (checklist behavior)
                            if viewModel.isGoModeActive {
                                GoModeStopAnnotation(
                                    stopName: stop.name,
                                    isPassed: viewModel.isStopPassed(stop),
                                    routeColor: viewModel.goModeRouteColor ?? AppTheme.Colors.mtaBlue
                                )
                            } else {
                                BusStopAnnotation(stopName: stop.name)
                            }
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

                // Route polylines
                if let shape = viewModel.routeShape {
                    ForEach(Array(shape.decodedPolylines.enumerated()), id: \.offset) { _, coords in
                        MapPolyline(coordinates: coords)
                            .stroke(
                                viewModel.goModeRouteColor ?? AppTheme.Colors.mtaBlue,
                                lineWidth: viewModel.isGoModeActive ? 5 : 3
                            )
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
            // Native MapKit controls — compass auto-hides when north-facing,
            // scale auto-shows during zoom, user location button recenters.
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()
            .onLongPressGesture(minimumDuration: 0.5) {
                // Long press handled via MapReader below
            }

            // Floating controls
            VStack {
                // Search pin indicator
                if viewModel.isSearchPinActive {
                    searchPinBanner
                }

                // Selected route indicator (hidden during GO mode — overlay replaces it)
                if viewModel.selectedRouteId != nil && !viewModel.isGoModeActive {
                    selectedRouteBanner
                }

                Spacer()

                // GO mode live tracking overlay (replaces bottom sheet content)
                if viewModel.isGoModeActive {
                    LiveTrackingOverlay(
                        routeName: viewModel.goModeRouteName ?? "—",
                        routeColor: viewModel.goModeRouteColor ?? AppTheme.Colors.mtaBlue,
                        etaMinutes: viewModel.transitEtaMinutes,
                        stops: viewModel.routeShape?.stops ?? [],
                        passedStopIds: viewModel.passedStopIds,
                        onGetOff: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                viewModel.deactivateGoMode()
                            }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                } else {
                    TransportModeToggle(selectedMode: $viewModel.selectedMode)
                        .padding(.bottom, 8)
                }
            }
        }
        // Bottom sheet — hidden during GO mode (the LiveTrackingOverlay replaces it)
        .sheet(isPresented: .constant(!viewModel.isGoModeActive)) {
            dashboardContent
                .presentationDetents([.fraction(0.4), .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
                .interactiveDismissDisabled()
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
                .sheet(isPresented: $viewModel.isRouteDetailPresented) {
                    if let group = viewModel.selectedGroupedRoute {
                        RouteDetailSheet(
                            group: group,
                            busVehicles: $viewModel.busVehicles,
                            routeShape: $viewModel.routeShape,
                            onTrack: { arrival in
                                viewModel.trackNearbyArrival(arrival, location: locationManager.currentLocation)
                            },
                            onGoMode: { routeName, routeColor in
                                viewModel.isRouteDetailPresented = false
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                    viewModel.activateGoMode(routeName: routeName, routeColor: routeColor)
                                }
                                // Calculate transit ETA to the last stop on the route
                                if let loc = locationManager.currentLocation?.coordinate,
                                   let lastStop = viewModel.routeShape?.stops.last {
                                    Task {
                                        await viewModel.fetchTransitETA(
                                            from: loc,
                                            to: CLLocationCoordinate2D(
                                                latitude: lastStop.lat,
                                                longitude: lastStop.lon
                                            )
                                        )
                                    }
                                }
                            },
                            onDismiss: {
                                viewModel.isRouteDetailPresented = false
                                viewModel.selectedGroupedRoute = nil
                                viewModel.clearBusRoute()
                            }
                        )
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                    }
                }
        }
        .onAppear {
            locationManager.requestPermission()
            locationManager.startUpdating()
            // Initial data fetch will happen in onChange once location arrives.
            // Auto-refresh every 30 seconds
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
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
            viewModel.clearBusRoute()
            Task {
                await viewModel.refresh(location: locationManager.currentLocation)
                lastUpdated = Date()
            }
        }
        // When a new location fix arrives, load data (first time) and follow in GO mode
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

            // GO mode auto-follow — keep camera pinned on user
            if viewModel.isGoModeActive {
                withAnimation(.easeInOut(duration: 0.8)) {
                    cameraPosition = .camera(MapCamera(
                        centerCoordinate: loc.coordinate,
                        distance: 2000
                    ))
                }
                viewModel.updatePassedStops(userLocation: loc)
            }
        }
    }

    // MARK: - Search Pin Banner

    private var searchPinBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.circle.fill")
                .foregroundColor(AppTheme.Colors.mtaBlue)
            Text("Searching from pin location")
                .font(.system(size: 13, weight: .medium))
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
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.mtaBlue)
                    .frame(width: 24, height: 24)
                Image(systemName: "bus.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
            }

            if let routeId = viewModel.selectedRouteId {
                let name = stripMTAPrefix(routeId)
                Text("\(name) — \(viewModel.busVehicles.count) buses live")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
            }

            Spacer()

            Button {
                Task { await viewModel.refreshBusVehicles() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
            }
            .accessibilityLabel("Refresh bus positions")

            Button {
                viewModel.clearBusRoute()
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

    // MARK: - Dashboard Content

    private var dashboardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header with settings gear
                HStack {
                    Text("Track")
                        .font(AppTheme.Typography.headerLarge)
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Spacer()

                    // Drop pin button
                    Button {
                        let center = locationManager.currentLocation?.coordinate
                            ?? AppTheme.MapConfig.nycCenter
                        let offset = CLLocationCoordinate2D(
                            latitude: center.latitude + 0.002,
                            longitude: center.longitude + 0.002
                        )
                        Task {
                            await viewModel.setSearchPin(offset, userLocation: locationManager.currentLocation)
                        }
                    } label: {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                    }
                    .accessibilityLabel("Drop search pin")

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .accessibilityLabel("Settings")
                }
                .padding(.horizontal, AppTheme.Layout.margin)

                // Last updated timestamp
                if let lastUpdated = lastUpdated {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .medium))
                        Text("Updated \(lastUpdated, style: .relative)")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .padding(.horizontal, AppTheme.Layout.margin)
                }

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
                        ForEach(Array(viewModel.serviceAlerts.prefix(3).enumerated()), id: \.element.id) { index, alert in
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
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                        .lineLimit(1)
                                    Text(alert.description)
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                        .lineLimit(2)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 8)

                            if index < min(viewModel.serviceAlerts.count, 3) - 1 {
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
                        ForEach(Array(viewModel.elevatorOutages.prefix(5).enumerated()), id: \.element.id) { index, outage in
                            HStack(spacing: 10) {
                                Image(systemName: outage.equipmentType.lowercased().contains("elevator")
                                      ? "arrow.up.arrow.down.circle.fill"
                                      : "stairs")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(AppTheme.Colors.alertRed)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(outage.station)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                        .lineLimit(1)
                                    Text(outage.description)
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                        .lineLimit(2)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 8)

                            if index < min(viewModel.elevatorOutages.count, 5) - 1 {
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
        .background(AppTheme.Colors.background)
        .refreshable {
            await viewModel.refresh(location: locationManager.currentLocation)
            lastUpdated = Date()
        }
    }

    // MARK: - Nearby Transit Dashboard (Unified)

    private var nearbyDashboard: some View {
        Group {
            if !viewModel.groupedTransit.isEmpty {
                sectionHeader("Live Arrivals")

                VStack(spacing: 0) {
                    ForEach(Array(viewModel.groupedTransit.enumerated()), id: \.element.id) { index, group in
                        GroupedRouteRow(group: group)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task { await viewModel.selectGroupedRoute(group) }
                            }
                        if index < viewModel.groupedTransit.count - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.margin + AppTheme.Layout.badgeSizeMedium + 12)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
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
                                Task { await viewModel.selectBusRoute(arrival.routeId) }
                            } : nil
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
        Group {
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
        Group {
            if let stop = viewModel.selectedBusStop {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stop.name)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Live Bus Arrivals")
                        .font(.system(size: 14, weight: .regular))
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
        Group {
            if !viewModel.lirrArrivals.isEmpty {
                sectionHeader("LIRR Departures")

                VStack(spacing: 0) {
                    ForEach(Array(viewModel.lirrArrivals.prefix(15).enumerated()), id: \.element.id) { index, arrival in
                        ArrivalRow(
                            arrival: arrival,
                            prediction: nil,
                            isTracking: viewModel.trackingArrivalId == arrival.id.uuidString,
                            reliabilityWarning: nil,
                            onTrack: {
                                viewModel.trackLIRRArrival(arrival, location: locationManager.currentLocation)
                            }
                        )
                        if index < min(viewModel.lirrArrivals.count, 15) - 1 {
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
