//
//  RouteDetailSheet.swift
//  Track
//
//  Route detail view presented when tapping a grouped route card.
//  Uses the same AppTheme design system, RouteBadge, and card layout
//  patterns as the rest of the app. No separate map — the MAIN map
//  behind this sheet draws the route polylines and live vehicles.
//

import SwiftUI
import MapKit

struct RouteDetailSheet: View {
    let group: GroupedNearbyTransitResponse
    @Binding var busVehicles: [BusVehicleResponse]
    @Binding var routeShape: RouteShapeResponse?
    var serviceAlerts: [TransitAlert] = []
    var cachedStations: [HomeViewModel.CachedSubwayStation] = []
    var onTrack: ((NearbyTransitResponse) -> Void)?
    var isTracking: ((NearbyTransitResponse) -> Bool)?
    var onDismiss: (() -> Void)?
    
    // Map controls (shown in header when sheet is expanded)
    var isSheetExpanded: Bool = false
    @Binding var is3DMode: Bool
    @Binding var cameraPosition: MapCameraPosition
    var currentLocation: CLLocationCoordinate2D?
    var selectedStopId: String?
    
    /// Number of live vehicles (buses or trains) filtered by the current direction.
    /// Provided by the ViewModel's `filteredBusVehicles` / `filteredTrainVehicles`
    /// to avoid duplicating direction-filtering logic here.
    var liveVehicleCount: Int = 0
    
    /// Selected direction index - bound to viewModel so map can filter polylines
    @Binding var selectedDirectionIndex: Int
    
    /// Which content tab is active: arrivals, stops, or alerts.
    @State private var selectedTab: RouteDetailTab = .arrivals
    
    /// Favorites manager for heart button
    @State private var isFavorited = false
    
    /// Available tabs for this route.
    enum RouteDetailTab: String, CaseIterable {
        case arrivals = "Arrivals"
        case stops = "Stops"
        case alerts = "Alerts"
    }

    init(group: GroupedNearbyTransitResponse,
         busVehicles: Binding<[BusVehicleResponse]>,
         routeShape: Binding<RouteShapeResponse?>,
         selectedDirectionIndex: Binding<Int>,
         serviceAlerts: [TransitAlert] = [],
         cachedStations: [HomeViewModel.CachedSubwayStation] = [],
         liveVehicleCount: Int = 0,
         isSheetExpanded: Bool = false,
         is3DMode: Binding<Bool> = .constant(false),
         cameraPosition: Binding<MapCameraPosition> = .constant(.automatic),
         currentLocation: CLLocationCoordinate2D? = nil,
         selectedStopId: String? = nil,
         onTrack: ((NearbyTransitResponse) -> Void)? = nil,
         isTracking: ((NearbyTransitResponse) -> Bool)? = nil,
         onDismiss: (() -> Void)? = nil) {
        self.group = group
        self._busVehicles = busVehicles
        self._routeShape = routeShape
        self._selectedDirectionIndex = selectedDirectionIndex
        self.serviceAlerts = serviceAlerts
        self.cachedStations = cachedStations
        self.liveVehicleCount = liveVehicleCount
        self.onTrack = onTrack
        self.isTracking = isTracking
        self.onDismiss = onDismiss
        self.isSheetExpanded = isSheetExpanded
        self._is3DMode = is3DMode
        self._cameraPosition = cameraPosition
        self.currentLocation = currentLocation
        self.selectedStopId = selectedStopId
    }

    /// Route color from the group data or the theme palette.
    private var routeColor: Color {
        if let hex = group.colorHex {
            return Color(hex: hex)
        }
        if group.isLIRR { return AppTheme.CommuterRailColors.lirrBlue }
        if group.isMNR { return AppTheme.CommuterRailColors.mnrBlue }
        return group.isBus ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: group.displayName)
    }

    /// Current direction bucket, clamped to bounds.
    private var safeDirection: DirectionArrivalsResponse {
        guard !group.directions.isEmpty else {
            return DirectionArrivalsResponse(direction: "—", arrivals: [])
        }
        let idx = min(selectedDirectionIndex, group.directions.count - 1)
        return group.directions[idx]
    }
    
    /// Alerts that match this route (by routeId or displayName), filtered to the same mode.
    private var routeAlerts: [TransitAlert] {
        let byId = serviceAlerts.matching(routeId: group.routeId, mode: group.mode)
        let byName = serviceAlerts.matching(routeId: group.displayName, mode: group.mode)
        // Merge without duplicates
        var seen = Set<String>()
        var result: [TransitAlert] = []
        for alert in byId + byName {
            if seen.insert(alert.id).inserted {
                result.append(alert)
            }
        }
        return result.sortedBySeverityAndTime()
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: - Header Row
                routeHeader

                // MARK: - Alert Banner (most recent alert, if any)
                if let topAlert = routeAlerts.first {
                    routeAlertBanner(topAlert)
                }

                // MARK: - Direction Picker (above countdown so user picks direction first)
                if group.directions.count > 1 {
                    directionPicker
                }
                
                // MARK: - Content Tab Picker
                contentTabPicker
                
                // MARK: - Tab Content
                switch selectedTab {
                case .arrivals:
                    // Countdown Chips
                    countdownSection
                    // Arrivals List
                    arrivalsList
                    
                case .stops:
                    stopsListSection
                    
                case .alerts:
                    if !routeAlerts.isEmpty {
                        routeAlertsSection
                    } else {
                        noAlertsEmptyState
                    }
                }

                // MARK: - Route Info Footer
                routeInfoFooter

                Spacer()
                    .frame(height: 24)
            }
            .padding(.top, AppTheme.Layout.margin)
        }
        .background(AppTheme.Colors.background)
        .onAppear {
            let dir = safeDirection
            isFavorited = FavoritesManager.shared.isFavorite(
                routeId: group.routeId,
                stopId: dir.arrivals.first?.stopId ?? "",
                direction: dir.direction
            )
        }
    }

    // MARK: - Header

    private var routeHeader: some View {
        HStack(spacing: 14) {
            // Unified badge with mode-specific styling
            RouteBadge(routeID: group.displayName, size: .large, hexColor: group.colorHex, mode: group.mode)
                .shadow(color: routeColor.opacity(0.3), radius: 6, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 5) {
                Text(group.displayName)
                    .font(AppTheme.Typography.headerLarge)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if group.directions.indices.contains(selectedDirectionIndex) {
                    let dir = group.directions[selectedDirectionIndex]
                    let headsign = routeShape?.directions
                        .first(where: { $0.directionId == selectedDirectionIndex })?
                        .headsign
                    let subtitle = (headsign != nil && !headsign!.isEmpty)
                        ? "→ \(headsign!)"
                        : dir.directionLabel ?? directionLabel(dir.direction)
                    Text(subtitle)
                        .font(.custom("Helvetica", size: 15))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
                
                // Mode badge
                Text(group.isCommuterRail ? (group.isLIRR ? "LIRR" : "Metro-North") : group.isBus ? "Bus" : "Subway")
                    .font(.custom("Helvetica-Bold", size: 10))
                    .foregroundColor(routeColor)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(routeColor.opacity(0.1))
                    .clipShape(Capsule())
            }

            Spacer()

            // Map controls (shown as compact icons when sheet is expanded)
            if isSheetExpanded {
                HStack(spacing: 8) {
                    // 3D / 2D Toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            is3DMode.toggle()
                            if let loc = currentLocation {
                                cameraPosition = .camera(MapCamera(
                                    centerCoordinate: loc,
                                    distance: AppTheme.MapConfig.userZoomDistance,
                                    heading: 0,
                                    pitch: is3DMode ? 60 : 0
                                ))
                            }
                        }
                    } label: {
                        Image(systemName: is3DMode ? "view.2d" : "view.3d")
                            .font(.custom("Helvetica-Bold", size: 18))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .accessibilityLabel(is3DMode ? "Switch to 2D" : "Switch to 3D")

                    // Recenter / Location Button
                    Button {
                        let target = currentLocation ?? AppTheme.MapConfig.nycCenter
                        withAnimation(.spring(duration: 0.8)) {
                            cameraPosition = .camera(MapCamera(
                                centerCoordinate: target,
                                distance: AppTheme.MapConfig.userZoomDistance,
                                heading: 0,
                                pitch: is3DMode ? 60 : 0
                            ))
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.custom("Helvetica-Bold", size: 18))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                    }
                    .accessibilityLabel("Recenter on my location")
                }
            }
            
            // Favorite button
            if SupabaseManager.shared.isAuthenticated {
                Button {
                    let dir = safeDirection
                    let firstArrival = dir.arrivals.first
                    Task {
                        let nowFav = await FavoritesManager.shared.toggleFavorite(
                            routeId: group.routeId,
                            routeDisplayName: group.displayName,
                            stopId: firstArrival?.stopId ?? "",
                            stopName: firstArrival?.stopName ?? dir.direction,
                            direction: dir.direction,
                            destination: firstArrival?.destination,
                            mode: group.mode,
                            stopLat: firstArrival?.stopLat,
                            stopLon: firstArrival?.stopLon
                        )
                        withAnimation(.spring(response: 0.3)) {
                            isFavorited = nowFav
                        }
                        HapticManager.notification(isFavorited ? .success : .warning)
                    }
                } label: {
                    Image(systemName: isFavorited ? "heart.fill" : "heart")
                        .font(.custom("Helvetica", size: 22))
                        .foregroundColor(isFavorited ? .red : AppTheme.Colors.textSecondary)
                        .symbolEffect(.bounce, value: isFavorited)
                }
                .accessibilityLabel(isFavorited ? "Remove from favorites" : "Add to favorites")
            }

            // Close button
            Button {
                onDismiss?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.custom("Helvetica", size: 24))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    // MARK: - Countdown Chips

    private var countdownSection: some View {
        let direction = safeDirection
        let nextArrivals = Array(direction.arrivals.prefix(AppSettings.shared.maxRouteDetailArrivals))

        return VStack(alignment: .leading, spacing: 10) {
            Text("Next Arrivals")
                .font(.custom("Helvetica-Bold", size: 13))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.horizontal, AppTheme.Layout.margin)

            if nextArrivals.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                        Text("No upcoming arrivals")
                            .font(.custom("Helvetica", size: 14))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 24)
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(nextArrivals.enumerated()), id: \.element.id) { index, arrival in
                            VStack(spacing: 6) {
                                // Big countdown number
                                Text("\(arrival.minutesAway)")
                                    .font(.custom("Helvetica-Bold", size: index == 0 ? 40 : 30))
                                    .foregroundColor(AppTheme.Colors.countdown(arrival.minutesAway))

                                Text("min")
                                    .font(.custom("Helvetica-Bold", size: 12))
                                    .foregroundColor(AppTheme.Colors.textSecondary)

                                // Status pill
                                Text(arrival.status)
                                    .font(.custom("Helvetica-Bold", size: 10))
                                    .foregroundColor(AppTheme.Colors.textOnColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(transitStatusColor(for: arrival.status))
                                    .clipShape(Capsule())
                            }
                            .frame(width: index == 0 ? 100 : 80)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(AppTheme.Colors.cardBackground)
                                    .shadow(color: .black.opacity(index == 0 ? 0.08 : 0.04), radius: index == 0 ? 8 : 4, x: 0, y: 2)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(
                                        index == 0 ? routeColor.opacity(0.3) : Color.clear,
                                        lineWidth: index == 0 ? 1.5 : 0
                                    )
                            )
                        }
                    }
                    .padding(.horizontal, AppTheme.Layout.margin)
                    .padding(.vertical, 2) // Extra space for shadow to render
                }
            }
        }
    }

    // MARK: - Direction Picker

    private var directionPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Direction")
                .font(.custom("Helvetica-Bold", size: 13))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.horizontal, AppTheme.Layout.margin)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(group.directions.enumerated()), id: \.element.id) { index, dir in
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selectedDirectionIndex = index
                            }
                        } label: {
                            let headsign = routeShape?.directions
                                .first(where: { $0.directionId == index })?
                                .headsign
                            let rawLabel = (headsign != nil && !headsign!.isEmpty)
                                ? headsign!
                                : dir.directionLabel ?? shortDirectionLabel(dir.direction)
                            // Truncate long labels to keep pills compact
                            let label = rawLabel.count > 24 ? String(rawLabel.prefix(22)) + "…" : rawLabel
                            let isActive = selectedDirectionIndex == index

                            HStack(spacing: 6) {
                                // Direction arrow icon
                                Image(systemName: directionIcon(for: index, total: group.directions.count))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(isActive ? .white : routeColor)

                                // Direction label
                                Text(label)
                                    .font(.custom("Helvetica-Bold", size: 13))
                                    .foregroundColor(isActive ? .white : AppTheme.Colors.textPrimary)
                                    .lineLimit(1)

                                // Arrival count
                                if dir.arrivals.count > 0 {
                                    Text("\(dir.arrivals.count)")
                                        .font(.custom("Helvetica-Bold", size: 11))
                                        .foregroundColor(isActive ? routeColor : .white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(isActive ? Color.white.opacity(0.9) : routeColor)
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isActive ? routeColor : AppTheme.Colors.cardBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isActive ? Color.clear : routeColor.opacity(0.2), lineWidth: 1)
                            )
                            .shadow(color: isActive ? routeColor.opacity(0.3) : .clear, radius: 4, x: 0, y: 2)
                        }
                        .accessibilityLabel("\(dir.directionLabel ?? directionLabel(dir.direction)), \(dir.arrivals.count) arrivals")
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
    }
    
    /// Returns an appropriate SF Symbol arrow for the direction index.
    private func directionIcon(for index: Int, total: Int) -> String {
        if total <= 2 {
            return index == 0 ? "arrow.up" : "arrow.down"
        }
        // For 3+ directions, use compass-style arrows
        let icons = ["arrow.up", "arrow.down", "arrow.left", "arrow.right",
                     "arrow.up.right", "arrow.down.left", "arrow.up.left", "arrow.down.right"]
        return icons[index % icons.count]
    }

    // MARK: - Arrivals List (same card pattern as HomeView)

    private var arrivalsList: some View {
        let direction = safeDirection

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Arrivals")
                    .font(.custom("Helvetica-Bold", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                
                Spacer()
                
                if !direction.arrivals.isEmpty {
                    Text("\(direction.arrivals.count) stop\(direction.arrivals.count == 1 ? "" : "s")")
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            if direction.arrivals.isEmpty {
                // Empty state — matches HomeView's emptyStateView pattern
                VStack(spacing: 10) {
                    Image(systemName: group.isCommuterRail ? "train.side.front.car" : group.isBus ? "bus.fill" : "tram.fill")
                        .font(.system(size: 36, weight: .light))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                    Text("No arrivals in this direction")
                        .font(.custom("Helvetica", size: 15))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(direction.arrivals.enumerated()), id: \.element.id) { index, arrival in
                        NearbyTransitRow(
                            arrival: arrival,
                            isTracking: isTracking?(arrival) ?? false,
                            isSelected: selectedStopId != nil && arrival.stopId == selectedStopId,
                            onTrack: {
                                onTrack?(arrival)
                            },
                            userLocation: currentLocation.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
                        )
                        .background(AppTheme.Colors.cardBackground)
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
                        .padding(.horizontal, AppTheme.Layout.margin)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(arrival.stopName), \(arrival.minutesAway) minutes, \(arrival.status)")
                    }
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 50, coordinateSpace: .local)
                .onEnded { value in
                    guard group.directions.count > 1 else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        if value.translation.width < 0 {
                            selectedDirectionIndex = min(selectedDirectionIndex + 1,
                                                        group.directions.count - 1)
                        } else if value.translation.width > 0 {
                            selectedDirectionIndex = max(selectedDirectionIndex - 1, 0)
                        }
                    }
                }
        )
        .accessibilityHint(group.directions.count > 1 ? "Swipe left or right to switch direction" : "")
    }

    // MARK: - Content Tab Picker

    /// Horizontal pill-style picker for Arrivals / Stops / Alerts tabs.
    private var contentTabPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RouteDetailTab.allCases, id: \.self) { tab in
                    let isActive = selectedTab == tab
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tabIcon(for: tab))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(isActive ? .white : routeColor)

                            Text(tab.rawValue)
                                .font(.custom("Helvetica-Bold", size: 13))
                                .foregroundColor(isActive ? .white : AppTheme.Colors.textPrimary)
                                .lineLimit(1)

                            // Badge: show alert count on Alerts tab
                            if tab == .alerts && !routeAlerts.isEmpty {
                                Text("\(routeAlerts.count)")
                                    .font(.custom("Helvetica-Bold", size: 11))
                                    .foregroundColor(isActive ? routeColor : .white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(isActive ? Color.white.opacity(0.9) : AppTheme.Colors.warningYellow)
                                    .clipShape(Capsule())
                            }
                            
                            // Badge: show stop count on Stops tab
                            if tab == .stops, let shape = routeShape {
                                let stopCount = shape.stopsForDirection(selectedDirectionIndex).count
                                if stopCount > 0 {
                                    Text("\(stopCount)")
                                        .font(.custom("Helvetica-Bold", size: 11))
                                        .foregroundColor(isActive ? routeColor : .white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(isActive ? Color.white.opacity(0.9) : routeColor)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isActive ? routeColor : AppTheme.Colors.cardBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isActive ? Color.clear : routeColor.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: isActive ? routeColor.opacity(0.3) : .clear, radius: 4, x: 0, y: 2)
                    }
                    .accessibilityLabel("\(tab.rawValue) tab")
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
        }
    }

    /// SF Symbol icon for each content tab.
    private func tabIcon(for tab: RouteDetailTab) -> String {
        switch tab {
        case .arrivals: return "clock.fill"
        case .stops: return "mappin.and.ellipse"
        case .alerts: return "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Stops List

    /// List of all stops for the current direction, with transfer indicators.
    private var stopsListSection: some View {
        let dirStops: [BusStop] = routeShape?.stopsForDirection(selectedDirectionIndex) ?? []

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stops")
                    .font(.custom("Helvetica-Bold", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer()

                if !dirStops.isEmpty {
                    Text("\(dirStops.count) stop\(dirStops.count == 1 ? "" : "s")")
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            if dirStops.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                    Text("Stop information unavailable")
                        .font(.custom("Helvetica", size: 15))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    Text("Route shape data hasn't loaded yet.")
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(dirStops.enumerated()), id: \.element.id) { index, stop in
                        stopRow(stop, index: index, total: dirStops.count)

                        if index < dirStops.count - 1 {
                            // Connecting line between stops
                            HStack(spacing: 0) {
                                Spacer().frame(width: 27)
                                Rectangle()
                                    .fill(routeColor.opacity(0.25))
                                    .frame(width: 2, height: 12)
                                Spacer()
                            }
                            .padding(.leading, AppTheme.Layout.cardPadding)
                        }
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
    }

    /// A single stop row with transfer line badges.
    private func stopRow(_ stop: BusStop, index: Int, total: Int) -> some View {
        let transfers = transferRoutes(for: stop)
        let isFirst = index == 0
        let isLast = index == total - 1

        return HStack(alignment: .center, spacing: 12) {
            // Stop dot on the line
            ZStack {
                Circle()
                    .fill(routeColor)
                    .frame(width: (isFirst || isLast) ? 14 : 10,
                           height: (isFirst || isLast) ? 14 : 10)
                if isFirst || isLast {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(stop.name)
                    .font(.custom("Helvetica-Bold", size: 14))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)

                // Transfer badges
                if !transfers.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.swap")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.textSecondary)

                            ForEach(transfers, id: \.self) { route in
                                RouteBadge(routeID: route,
                                           size: .custom(20, 10))
                            }
                        }
                    }
                }
            }

            Spacer()

            // Stop sequence number
            Text("\(index + 1)")
                .font(.custom("Helvetica", size: 11))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 8)
    }

    /// Finds subway transfer routes at a given stop by matching against cached stations.
    /// Uses name-based matching (case-insensitive, trimmed) to connect bus/subway stops
    /// to known subway stations and their served routes.
    private func transferRoutes(for stop: BusStop) -> [String] {
        // Skip transfer detection for non-subway if no station data available
        guard !cachedStations.isEmpty else { return [] }

        let stopName = stop.name.lowercased().trimmingCharacters(in: .whitespaces)
        let currentRoute = group.displayName

        // 1) Try exact name match first
        if let match = cachedStations.first(where: {
            $0.name.lowercased().trimmingCharacters(in: .whitespaces) == stopName
        }) {
            return match.routes.filter { $0 != currentRoute }.sorted()
        }

        // 2) Try proximity-based match (~100m) for nearby subway stations
        let stopCoord = CLLocation(latitude: stop.lat, longitude: stop.lon)
        let nearbyThreshold: CLLocationDistance = 100 // meters

        let nearbyStations = cachedStations.filter { station in
            let stationLoc = CLLocation(latitude: station.coordinate.latitude,
                                        longitude: station.coordinate.longitude)
            return stopCoord.distance(from: stationLoc) <= nearbyThreshold
        }

        // Collect all routes from nearby stations, excluding the current route
        var routes = Set<String>()
        for station in nearbyStations {
            for route in station.routes where route != currentRoute {
                routes.insert(route)
            }
        }

        return routes.sorted()
    }

    // MARK: - No Alerts Empty State

    /// Shown on the Alerts tab when there are no active alerts for this route.
    private var noAlertsEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(AppTheme.Colors.successGreen)

            Text("All Clear")
                .font(.custom("Helvetica-Bold", size: 17))
                .foregroundColor(AppTheme.Colors.textPrimary)

            Text("No active service alerts for the \(group.displayName)")
                .font(.custom("Helvetica", size: 14))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    // MARK: - Alert Banner (top of sheet)
    
    /// Compact alert banner shown at the top of the route detail,
    /// right below the header and above the direction picker.
    /// Shows a "Latest alert • X ago" timestamp above the main banner strip.
    private func routeAlertBanner(_ alert: TransitAlert) -> some View {
        let isSevere = alert.severity == "severe"
        let bannerColor = isSevere ? AppTheme.Colors.alertRed : AppTheme.Colors.warningYellow
        
        return VStack(alignment: .leading, spacing: 4) {
            // "Latest alert • X ago" label
            HStack(spacing: 6) {
                Circle()
                    .fill(bannerColor)
                    .frame(width: 6, height: 6)
                
                Text("Latest alert")
                    .font(.custom("Helvetica-Bold", size: 10))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                
                if let ts = alert.updatedAt {
                    Text("•")
                        .font(.system(size: 8))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                    HStack(spacing: 0) {
                        Text(Date(timeIntervalSince1970: TimeInterval(ts)), style: .relative)
                        Text(" ago")
                    }
                    .font(.custom("Helvetica", size: 10))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                }
                
                Spacer()
                
                if routeAlerts.count > 1 {
                    Text("\(routeAlerts.count) alerts")
                        .font(.custom("Helvetica", size: 10))
                        .foregroundColor(bannerColor)
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            
            // Main banner strip
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                
                Text(alert.title)
                    .font(.custom("Helvetica-Bold", size: 12))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Spacer(minLength: 0)
                
                if routeAlerts.count > 1 {
                    Text("+\(routeAlerts.count - 1)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(bannerColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.white.opacity(0.9))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(bannerColor)
                    .shadow(color: bannerColor.opacity(0.3), radius: 6, x: 0, y: 3)
            )
            .padding(.horizontal, AppTheme.Layout.margin)
        }
    }

    // MARK: - Route Alerts Section
    
    private var routeAlertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.warningYellow)
                
                Text("Active Alerts")
                    .font(.custom("Helvetica-Bold", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                
                Spacer()
                
                Text("\(routeAlerts.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            routeAlerts.contains(where: { $0.severity == "severe" })
                                ? AppTheme.Colors.alertRed
                                : AppTheme.Colors.warningYellow
                        )
                    )
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            
            VStack(spacing: 0) {
                ForEach(Array(routeAlerts.enumerated()), id: \.element.id) { index, alert in
                    RouteDetailAlertRow(alert: alert)
                    
                    if index < routeAlerts.count - 1 {
                        Divider()
                            .padding(.leading, AppTheme.Layout.cardPadding + 34)
                    }
                }
            }
            .background(AppTheme.Colors.cardBackground)
            .cornerRadius(AppTheme.Layout.cornerRadius)
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            .padding(.horizontal, AppTheme.Layout.margin)
        }
    }

    // MARK: - Route Info Footer

    private var routeInfoFooter: some View {
        let hasStops = routeShape != nil && !routeShape!.stops.isEmpty
        let hasVehicles = liveVehicleCount > 0
        
        // Only show if there's info to display
        if hasStops || hasVehicles {
            return AnyView(
                HStack(spacing: 16) {
                    if hasStops {
                        let dirStops = routeShape!.stopsForDirection(selectedDirectionIndex)
                        HStack(spacing: 6) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(routeColor)
                            Text("\(dirStops.count) stops")
                                .font(.custom("Helvetica-Bold", size: 13))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(routeColor.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    
                    if hasVehicles {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(AppTheme.Colors.successGreen)
                                .frame(width: 7, height: 7)
                                .overlay(
                                    Circle()
                                        .fill(AppTheme.Colors.successGreen.opacity(0.3))
                                        .frame(width: 14, height: 14)
                                )
                            Text("\(liveVehicleCount) live \(group.isBus ? "buses" : "trains")")
                                .font(.custom("Helvetica-Bold", size: 13))
                                .foregroundColor(AppTheme.Colors.successGreen)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AppTheme.Colors.successGreen.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            )
        } else {
            return AnyView(EmptyView())
        }
    }
}

// MARK: - Route Detail Alert Row

/// A compact alert row shown inside the RouteDetailSheet for matching alerts.
struct RouteDetailAlertRow: View {
    let alert: TransitAlert
    @State private var isExpanded = false
    
    private var severityColor: Color {
        alert.severity == "severe" ? AppTheme.Colors.alertRed : AppTheme.Colors.warningYellow
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // Severity icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(severityColor)
                    .frame(width: 26, height: 26)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(alert.title)
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(isExpanded ? nil : 2)
                    
                    if isExpanded && !alert.description.isEmpty {
                        Text(alert.description)
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    
                    HStack(spacing: 8) {
                        // Severity pill
                        Text(alert.severity == "severe" ? "⚠️ Severe" : "Warning")
                            .font(.custom("Helvetica-Bold", size: 10))
                            .foregroundColor(severityColor)
                        
                        // Timestamp
                        if let ts = alert.updatedAt {
                            HStack(spacing: 0) {
                                Text(Date(timeIntervalSince1970: TimeInterval(ts)), style: .relative)
                                Text(" ago")
                            }
                            .font(.custom("Helvetica", size: 10))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                        }
                    }
                    .padding(.top, 2)
                }
                
                Spacer(minLength: 0)
                
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, AppTheme.Layout.cardPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }
        }
    }
}

#Preview {
    RouteDetailSheet(
        group: GroupedNearbyTransitResponse(
            routeId: "A",
            displayName: "A",
            mode: "subway",
            colorHex: "#0039A6",
            directions: [
                DirectionArrivalsResponse(
                    direction: "N",
                    arrivals: [
                        NearbyTransitResponse(
                            routeId: "A", stopName: "Canal St", direction: "N",
                            destination: "Inwood-207 St",
                            minutesAway: 3, status: "On Time", mode: "subway",
                            stopLat: 40.72, stopLon: -74.0, arrivalTs: Int(Date().timeIntervalSince1970 + 180),
                            vehicleId: "V123", tripId: "T456", stopId: "A32"
                        ),
                        NearbyTransitResponse(
                            routeId: "A", stopName: "14 St", direction: "N",
                            destination: "Inwood-207 St",
                            minutesAway: 8, status: "On Time", mode: "subway",
                            stopLat: 40.74, stopLon: -74.0, arrivalTs: Int(Date().timeIntervalSince1970 + 480),
                            vehicleId: "V124", tripId: "T457", stopId: "A28"
                        ),
                    ]
                ),
                DirectionArrivalsResponse(
                    direction: "S",
                    arrivals: [
                        NearbyTransitResponse(
                            routeId: "A", stopName: "Fulton St", direction: "S",
                            destination: "Far Rockaway",
                            minutesAway: 5, status: "Delayed", mode: "subway",
                            stopLat: 40.71, stopLon: -74.01, arrivalTs: Int(Date().timeIntervalSince1970 + 300),
                            vehicleId: "V125", tripId: "T458", stopId: "A34"
                        ),
                    ]
                ),
            ]
        ),
        busVehicles: .constant([]),
        routeShape: .constant(nil),
        selectedDirectionIndex: .constant(0)
    )
}
