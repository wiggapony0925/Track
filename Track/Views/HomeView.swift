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
    @State private var hasCenteredOnUser = false

    var body: some View {
        ZStack {
            // Map background bounded to NYC 5 boroughs + Long Island.
            // Uses MapCameraBounds to restrict panning (300 m – 150 km zoom),
            // and a transit-emphasized map style that dims driving elements.
            // Ref: https://developer.apple.com/documentation/mapkit/mapcamerabounds
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
            // Transit-emphasized map style: dims driving roads, highlights transit lines/stations.
            .mapStyle(.standard(emphasis: .muted, showsTraffic: false))
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
            Task {
                await viewModel.refresh(location: locationManager.currentLocation)
                lastUpdated = Date()
            }
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
        // Center map on user location — initial fix + GO mode auto-follow
        .onChange(of: locationManager.currentLocation) {
            guard let loc = locationManager.currentLocation else { return }

            if !hasCenteredOnUser {
                // First location fix — center the map on the user
                hasCenteredOnUser = true
                withAnimation(.easeInOut(duration: 0.6)) {
                    cameraPosition = .camera(MapCamera(
                        centerCoordinate: loc.coordinate,
                        distance: AppTheme.MapConfig.userZoomDistance
                    ))
                }
            }

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
                let name = routeId.hasPrefix("MTA NYCT_") ? String(routeId.dropFirst(9)) : routeId
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

                    // Recenter on user location
                    Button {
                        if let loc = locationManager.currentLocation {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                cameraPosition = .camera(MapCamera(
                                    centerCoordinate: loc.coordinate,
                                    distance: AppTheme.MapConfig.userZoomDistance
                                ))
                            }
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                    }
                    .accessibilityLabel("Recenter on my location")

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
                emptyStateView(
                    icon: "location.fill",
                    message: "No transit nearby"
                )
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
}

// MARK: - Search Pin Annotation

/// A draggable search pin for exploring transit at other locations.
private struct SearchPinAnnotation: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Colors.alertRed)
                .frame(width: 36, height: 36)
                .shadow(color: AppTheme.Colors.alertRed.opacity(0.4), radius: AppTheme.Layout.shadowRadius)
            Image(systemName: "mappin")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppTheme.Colors.textOnColor)
        }
        .accessibilityLabel("Search pin — drag to explore")
    }
}

// MARK: - Bus Vehicle Annotation

/// A map pin showing a live bus position with its route name and bearing.
private struct BusVehicleAnnotation: View {
    let routeName: String
    let bearing: Double?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.mtaBlue)
                    .frame(width: AppTheme.Layout.badgeSizeMedium, height: AppTheme.Layout.badgeSizeMedium)
                    .shadow(color: AppTheme.Colors.mtaBlue.opacity(0.4), radius: AppTheme.Layout.shadowRadius)
                Image(systemName: "bus.fill")
                    .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
                    .rotationEffect(.degrees(bearing ?? 0))
            }
            Text(routeName)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(AppTheme.Colors.textOnColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(AppTheme.Colors.mtaBlue)
                .clipShape(Capsule())
        }
        .accessibilityLabel("Bus \(routeName)")
    }
}

// MARK: - Nearby Transit Row

/// Displays a single nearby transit arrival (bus or train) in the unified list.
/// Tapping expands the row to show arrival details, direction, and status.
private struct NearbyTransitRow: View {
    let arrival: NearbyTransitResponse
    var isTracking: Bool = false
    var onTrack: (() -> Void)?
    var onSelectRoute: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Mode badge
                ZStack {
                    Circle()
                        .fill(arrival.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: arrival.displayName))
                        .frame(width: AppTheme.Layout.badgeSizeMedium, height: AppTheme.Layout.badgeSizeMedium)
                    if arrival.isBus {
                        Image(systemName: "bus.fill")
                            .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .bold))
                            .foregroundColor(AppTheme.Colors.textOnColor)
                    } else {
                        Text(arrival.displayName)
                            .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .heavy, design: .monospaced))
                            .foregroundColor(AppTheme.SubwayColors.textColor(for: arrival.displayName))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    }
                }
                .accessibilityHidden(true)

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(arrival.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if isTracking {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(AppTheme.Colors.successGreen)
                        }
                    }
                    Text(arrival.stopName)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // View route button for buses
                if arrival.isBus, let onSelectRoute = onSelectRoute {
                    Button {
                        onSelectRoute()
                    } label: {
                        Image(systemName: "map")
                            .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .medium))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                    }
                    .accessibilityLabel("View \(arrival.displayName) route on map")
                }

                // Countdown
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(arrival.minutesAway)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("min")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }

                // Expand chevron
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, AppTheme.Layout.margin)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }

            // Expanded detail section
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    // Next arrival details
                    HStack(spacing: 10) {
                        Image(systemName: arrival.isBus ? "bus.fill" : "tram.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next Arrival")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .textCase(.uppercase)
                            Text(arrivalTimeDescription)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                        }

                        Spacer()

                        // Status pill
                        Text(arrival.status)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textOnColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(statusColor)
                            .clipShape(Capsule())
                    }

                    // Direction info
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Direction")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .textCase(.uppercase)
                            Text(arrival.direction)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                        }
                    }

                    // Track button
                    Button {
                        onTrack?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isTracking ? "antenna.radiowaves.left.and.right" : "bell.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text(isTracking ? "Tracking" : "Track This Arrival")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(AppTheme.Colors.textOnColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isTracking ? AppTheme.Colors.successGreen : AppTheme.Colors.mtaBlue)
                        .cornerRadius(AppTheme.Layout.cornerRadius)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(arrival.isBus ? "Bus" : "Train") \(arrival.displayName), \(arrival.stopName), \(arrival.minutesAway) minutes away")
        .accessibilityHint(isExpanded ? "Expanded. Shows arrival details." : "Tap to see arrival details")
    }

    private var arrivalTimeDescription: String {
        if arrival.minutesAway <= 0 {
            return "Arriving now"
        } else if arrival.minutesAway == 1 {
            return "In 1 minute"
        } else {
            let arrivalTime = Date().addingTimeInterval(Double(arrival.minutesAway) * 60)
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "In \(arrival.minutesAway) min — \(formatter.string(from: arrivalTime))"
        }
    }

    private var statusColor: Color {
        let lower = arrival.status.lowercased()
        if lower.contains("on time") {
            return AppTheme.Colors.successGreen
        } else if lower.contains("delayed") || lower.contains("late") {
            return AppTheme.Colors.alertRed
        } else if lower.contains("approaching") || lower.contains("at stop") {
            return AppTheme.Colors.successGreen
        }
        return AppTheme.Colors.mtaBlue
    }
}

// MARK: - Nearby Bus Stop Row

/// Displays a nearby bus stop in the list. Tapping selects it.
private struct NearbyBusStopRow: View {
    let stop: BusStop

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.mtaBlue)
                    .frame(width: AppTheme.Layout.badgeSizeMedium, height: AppTheme.Layout.badgeSizeMedium)
                Image(systemName: "bus.fill")
                    .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
            }
            .accessibilityHidden(true)

            Text(stop.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            if let direction = stop.direction {
                Text(direction == "0" ? "→" : "←")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bus stop: \(stop.name)")
    }
}

// MARK: - Grouped Route Row

/// A compact row for a grouped route card. Shows the route badge,
/// display name, direction count, and soonest arrival countdown.
/// Tapping opens the ``RouteDetailSheet``.
private struct GroupedRouteRow: View {
    let group: GroupedNearbyTransitResponse

    var body: some View {
        HStack(spacing: 12) {
            // Mode badge
            ZStack {
                Circle()
                    .fill(badgeColor)
                    .frame(width: AppTheme.Layout.badgeSizeMedium,
                           height: AppTheme.Layout.badgeSizeMedium)
                if group.isBus {
                    Image(systemName: "bus.fill")
                        .font(.system(size: AppTheme.Layout.badgeFontMedium, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text(group.displayName)
                        .font(.system(size: AppTheme.Layout.badgeFontMedium,
                                      weight: .heavy, design: .monospaced))
                        .foregroundColor(AppTheme.SubwayColors.textColor(for: group.displayName))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
            .accessibilityHidden(true)

            // Route info
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 4) {
                    ForEach(group.directions, id: \.direction) { dir in
                        Text(shortDirection(dir.direction))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    if group.directions.count > 1 {
                        Text("·")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("\(group.directions.count) directions")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                }
            }

            Spacer(minLength: 4)

            // Soonest countdown
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(group.soonestMinutes)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.countdown(group.soonestMinutes))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(group.isBus ? "Bus" : "Train") \(group.displayName), next in \(group.soonestMinutes) minutes"
        )
        .accessibilityHint("Tap to see arrivals in both directions")
    }

    private var badgeColor: Color {
        if let hex = group.colorHex {
            return Color(hex: hex)
        }
        return group.isBus
            ? AppTheme.Colors.mtaBlue
            : AppTheme.SubwayColors.color(for: group.displayName)
    }

    private func shortDirection(_ d: String) -> String {
        switch d.uppercased() {
        case "N": return "↑ North"
        case "S": return "↓ South"
        case "E": return "→ East"
        case "W": return "← West"
        default: return d
        }
    }
}

#Preview {
    HomeView()
}
