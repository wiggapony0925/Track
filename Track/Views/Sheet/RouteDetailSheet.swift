//
//  RouteDetailSheet.swift
//  Track
//
//  Route detail view presented when tapping a grouped route card.
//  Uses the same AppTheme design system, RouteBadge, and card layout
//  patterns as the rest of the app. No separate map — the MAIN map
//  behind this sheet draws the route polylines and live vehicles.
//

import MapKit
import SwiftUI

struct RouteDetailSheet: View {
    let group: GroupedNearbyTransitResponse
    @Binding var busVehicles: [BusVehicleResponse]
    @Binding var routeShape: RouteShapeResponse?
    var serviceAlerts: [TransitAlert] = []
    var busSchedule: BusScheduleResponse?
    /// Cached train arrivals from the ViewModel — used to show scheduled departures
    /// for train directions with no live arrivals displayed.
    var cachedTrainArrivals: [TrainArrival] = []
    var cachedStations: [HomeViewModel.CachedSubwayStation] = []
    var onTrack: ((NearbyTransitResponse) -> Void)?
    /// Optional shared smart ETA provider from HomeViewModel.
    /// When provided, Route Detail and Home rows use the same ETA source.
    var smartETAProvider: ((NearbyTransitResponse) -> SmartETA)? = nil
    var isTracking: ((NearbyTransitResponse) -> Bool)?
    /// Whether the user is tracking ANY route (used to show "Switch" on non-tracked rows).
    var isTrackingAny: Bool = false
    /// Returns true if the arrival has a live vehicle position on the map.
    var isLiveOnMap: ((NearbyTransitResponse) -> Bool)?
    /// Called when the user taps a highlighted row to clear the map highlight.
    var onClearHighlight: (() -> Void)?
    /// Called when the user expands an arrival row to focus its map marker.
    /// Passes the vehicle key (vehicleId/tripId) or nil to clear focus.
    var onFocusVehicle: ((String?) -> Void)?
    /// Vehicle ID that was tapped on the map marker — used to auto-scroll
    /// and highlight the matching arrival row.
    var tappedVehicleId: String? = nil
    var onDismiss: (() -> Void)?
    /// Called when the user manually selects a stop (from the stops list).
    /// Passes the stop's coordinate so the ViewModel can update the
    /// nearestStopCoordinate and rebuild the behind/ahead polyline split.
    /// Pass nil to reset to auto-detected nearest stop.
    var onStopSelected: ((CLLocationCoordinate2D?) -> Void)?

    // Map controls (shown in header when sheet is expanded)
    var isSheetExpanded: Bool = false
    @Binding var is3DMode: Bool
    @Binding var cameraPosition: MapCameraPosition
    var currentLocation: CLLocationCoordinate2D?
    /// When the user has dragged the search pin, this is the pin's coordinate.
    /// Used as the reference point for nearest-stop filtering when GPS is unavailable.
    var searchCenter: CLLocationCoordinate2D?
    var selectedStopId: String?

    /// Number of live vehicles (buses or trains) filtered by the current direction.
    /// Provided by the ViewModel's `filteredBusVehicles` / `filteredTrainVehicles`
    /// to avoid duplicating direction-filtering logic here.
    var liveVehicleCount: Int = 0
    /// Active elevator/escalator outages — used to badge stops with accessibility warnings.
    var elevatorOutages: [ElevatorStatus] = []

    /// Selected direction index - bound to viewModel so map can filter polylines
    @Binding var selectedDirectionIndex: Int

    /// Which content tab is active: arrivals, departures, or alerts.
    @State private var selectedTab: RouteDetailTab = .stops

    /// Stop ID selected by tapping a stop row — filters the Departures tab.
    @State private var inSheetSelectedStopId: String?

    /// Track expanded row ID locally in the sheet
    @State private var expandedArrivalID: String?

    /// Controls the brief stop-origin highlight on first open.
    /// Auto-clears after 1.5 s so only the first arrival at the tapped
    /// stop flashes blue momentarily — not every arrival at that stop.
    @State private var stopHighlightActive: Bool = true

    /// Favorites manager for heart button
    @State private var isFavorited = false
    @State private var showSignInPrompt = false
    @ObservedObject private var supabase = SupabaseManager.shared
    @ObservedObject private var favoritesManager = FavoritesManager.shared

    /// True while the first arrivals batch is still in-flight.
    /// Drives skeleton placeholders so the sheet never looks empty on open.
    @State private var isLoadingArrivals: Bool = true

    /// Debounced snapshot of the nearest-stop arrivals shown in countdown chips.
    /// Refreshes when the set of vehicles changes (appeared / vanished).
    /// The TimelineView re-sorts chips by live ETA every second, so this only
    /// controls WHICH arrivals are in the chip list, not their order.
    @State private var stableNearestArrivals: [NearbyTransitResponse] = []

    /// Timestamp of the last time `stableNearestArrivals` was updated.
    /// Used to debounce live→scheduled flapping: the SIRI feed can drop a
    /// live vehicle for a single poll and fall back to GTFS-static, then
    /// the vehicle reappears on the next poll.  A 30 s debounce gives the
    /// feed 2-3 chances to recover before we downgrade the chips to grey.
    @State private var lastStableRefreshDate: Date = .now

    /// Cached per-direction vehicle badge counts.
    /// Updated only when `group` changes (backend poll) — NOT on every body
    /// evaluation — so the 1 Hz bus-interpolation tick doesn't redundantly
    /// recompute `uniqueVehicleCount` for every direction pill.
    @State private var directionBadgeCounts: [String: Int] = [:]

    /// Cached per-stop arrival lookup for the stops list.
    /// Rebuilt only when `group` changes — avoids recomputing `liveArrivals`
    /// on every 1 Hz interpolation tick when the Stops tab is visible.
    @State private var cachedArrivalByStop: [String: NearbyTransitResponse] = [:]

    /// Cached departure count for the Departures tab badge.
    /// Avoids calling the expensive `prioritizedArrivals` on every body evaluation.
    @State private var cachedDepartureCount: Int = 0

    /// ID of the chip the user tapped to highlight on the map.
    /// Tapping the same chip again deselects it.  Only live (non-scheduled)
    /// chips can be selected — this zooms the map to the vehicle marker
    /// and scales the chip up slightly.
    @State private var selectedChipId: String?

    /// Per-direction stop key lock: [directionIndex: stopId ?? stopName].
    /// Each direction remembers its nearest stop independently so that:
    ///  • Direction changes (including shape-enrichment reorders) never invalidate
    ///    another direction's resolved stop.
    ///  • `prioritizedArrivals` never flip-flops to a different nearby stop between
    ///    backend refresh cycles for a given direction.
    @State private var lockedStopKeyPerDirection: [Int: String] = [:]
    /// Headsign of the user's selected direction — locked so that backend
    /// re-sorts of `group.directions` never flip the sheet to a different dir.
    @State private var lockedDirectionHeadsign: String?

    /// Convenience: locked stop key for the currently-displayed direction.
    private var lockedNearestStopKey: String? { lockedStopKeyPerDirection[selectedDirectionIndex] }

    /// Two-tier chip status tied directly to map markers.
    ///  • `.onRoute`   – vehicle has a live marker on the map (green)
    ///  • `.scheduled`  – no live marker / GTFS-static only (grey)
    private enum ChipStatus {
        case onRoute, scheduled
    }

    /// Derives the chip status from the backend `isRealTime` flag — the
    /// single source of truth for whether a prediction is backed by live
    /// telemetry (SIRI, GTFS-RT, OBA) vs purely static GTFS.
    ///
    /// Previous logic used `isLiveOnMap` (vehicle GPS marker on the map),
    /// which caused SIRI-tracked buses to show "Scheduled" until their
    /// GPS loaded — contradicting the home-row "Live" pill.
    private func chipStatus(for arrival: NearbyTransitResponse) -> ChipStatus {
        // Backend says real-time → live, regardless of map marker state
        if arrival.isRealTime { return .onRoute }
        // Fallback: if somehow isRealTime is false but it IS on the map,
        // still treat it as live (belt-and-suspenders).
        if isLiveOnMap?(arrival) == true { return .onRoute }
        return .scheduled
    }

    /// Available tabs for this route.
    enum RouteDetailTab: String, CaseIterable {
        case stops = "Stops"
        case departures = "Departures"
        case alerts = "Alerts"
    }

    init(
        group: GroupedNearbyTransitResponse,
        busVehicles: Binding<[BusVehicleResponse]>,
        routeShape: Binding<RouteShapeResponse?>,
        selectedDirectionIndex: Binding<Int>,
        serviceAlerts: [TransitAlert] = [],
        busSchedule: BusScheduleResponse? = nil,
        cachedTrainArrivals: [TrainArrival] = [],
        cachedStations: [HomeViewModel.CachedSubwayStation] = [],
        smartETAProvider: ((NearbyTransitResponse) -> SmartETA)? = nil,
        liveVehicleCount: Int = 0,
        elevatorOutages: [ElevatorStatus] = [],
        isSheetExpanded: Bool = false,
        is3DMode: Binding<Bool> = .constant(false),
        cameraPosition: Binding<MapCameraPosition> = .constant(.automatic),
        currentLocation: CLLocationCoordinate2D? = nil,
        searchCenter: CLLocationCoordinate2D? = nil,
        selectedStopId: String? = nil,
        onTrack: ((NearbyTransitResponse) -> Void)? = nil,
        isTracking: ((NearbyTransitResponse) -> Bool)? = nil,
        isTrackingAny: Bool = false,
        isLiveOnMap: ((NearbyTransitResponse) -> Bool)? = nil,
        onClearHighlight: (() -> Void)? = nil,
        onFocusVehicle: ((String?) -> Void)? = nil,
        tappedVehicleId: String? = nil,
        onDismiss: (() -> Void)? = nil,
        onStopSelected: ((CLLocationCoordinate2D?) -> Void)? = nil
    ) {
        self.group = group
        self._busVehicles = busVehicles
        self._routeShape = routeShape
        self._selectedDirectionIndex = selectedDirectionIndex
        self.serviceAlerts = serviceAlerts
        self.busSchedule = busSchedule
        self.cachedTrainArrivals = cachedTrainArrivals
        self.cachedStations = cachedStations
        self.smartETAProvider = smartETAProvider
        self.liveVehicleCount = liveVehicleCount
        self.elevatorOutages = elevatorOutages
        self.onTrack = onTrack
        self.isTracking = isTracking
        self.isTrackingAny = isTrackingAny
        self.isLiveOnMap = isLiveOnMap
        self.onClearHighlight = onClearHighlight
        self.onFocusVehicle = onFocusVehicle
        self.tappedVehicleId = tappedVehicleId
        self.onDismiss = onDismiss
        self.onStopSelected = onStopSelected
        self.isSheetExpanded = isSheetExpanded
        self._is3DMode = is3DMode
        self._cameraPosition = cameraPosition
        self.currentLocation = currentLocation
        self.searchCenter = searchCenter
        self.selectedStopId = selectedStopId
    }

    /// Route color from the group data or the theme palette.
    private var routeColor: Color {
        if let hex = group.colorHex {
            return Color(hex: hex)
        }
        if group.isLIRR { return AppTheme.CommuterRailColors.lirrBlue }
        if group.isMNR { return AppTheme.CommuterRailColors.mnrBlue }
        return group.isBus
            ? AppTheme.Colors.mtaBlue : AppTheme.SubwayColors.color(for: group.displayName)
    }

    /// The name of the currently selected direction, used to match headsigns in RouteShape.
    private var selectedDirectionName: String? {
        guard selectedDirectionIndex >= 0, selectedDirectionIndex < group.directions.count else { return nil }
        return group.directions[selectedDirectionIndex].direction
    }

    /// Resolves the best display label for a direction.
    ///
    /// Priority:
    /// 1. Route shape headsign (GTFS terminal name — most reliable, e.g. "Far Rockaway-Mott Av")
    /// 2. Last stop name in the route shape's stop list for that direction
    /// 3. First unique destination from live arrivals
    /// 4. Compass fallback ("↑ North")
    ///
    /// **Intentionally skips `directionLabel`** from the backend because for
    /// subway routes it concatenates ALL branch destinations
    /// ("Southbound → Far Rockaway / Lefferts Blvd") which causes duplicated
    /// or overly long labels.  The headsign/last-stop approach gives ONE clean
    /// terminal name per direction pill.
    private func resolvedDirectionLabel(for dir: DirectionArrivalsResponse, at index: Int) -> String {
        let matchedDir = routeShape?.matchedDirection(index: index, name: dir.direction)
        return ArrivalHelpers.resolveDirectionLabel(
            for: dir,
            shapeHeadsign: matchedDir?.headsign,
            shapeLastStopName: matchedDir?.stops.last?.name,
            skipBackendLabel: true,
            useShortCompass: true
        )
    }

    /// Current direction bucket, clamped to bounds.
    private var safeDirection: DirectionArrivalsResponse {
        guard !group.directions.isEmpty else {
            return DirectionArrivalsResponse(direction: "—", arrivals: [])
        }
        // Prefer the direction whose headsign matches the locked one so that
        // backend re-sorts of the directions array don't flip the sheet to a
        // different direction (e.g. Q37 "KEW GARDENS" ↔ "SOUTH OZONE PARK").
        if let locked = lockedDirectionHeadsign {
            if let match = group.directions.first(where: { $0.direction == locked }) {
                return match
            }
            // Locked direction is temporarily absent from this poll's response.
            // Return an empty shell so nothing updates downstream while we wait
            // for it to reappear — prevents flipping to a different direction.
            return DirectionArrivalsResponse(direction: locked, arrivals: [])
        }
        let idx = max(0, min(selectedDirectionIndex, group.directions.count - 1))
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

                // MARK: - Alert Banner
                if let topAlert = routeAlerts.first {
                    routeAlertBanner(topAlert)
                } else if let inlineAlert = group.alerts.first {
                    // Fall back to inline alert from grouped response
                    inlineAlertBanner(inlineAlert)
                } else if isLoadingArrivals {
                    alertBannerSkeleton
                }

                // MARK: - Next Arrivals (always at top)
                countdownSection

                // MARK: - Direction Picker
                if group.directions.count > 1 {
                    directionPicker
                } else if isLoadingArrivals {
                    directionPickerSkeleton
                }

                // MARK: - Content Tab Picker (below direction)
                contentTabPicker

                // MARK: - Tab Content
                switch selectedTab {
                case .stops:
                    stopsListSection

                case .departures:
                    arrivalsList

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
            isFavorited = favoritesManager.isFavorite(routeId: group.routeId, mode: group.mode)
            // Seed loading state: if the current direction already has arrivals
            // (e.g. sheet re-opened after data landed), skip the skeleton phase.
            isLoadingArrivals = safeDirection.arrivals.isEmpty
            // Seed stable arrivals on first appear.
            // Use .distantPast so the next onChange(of: group) in the same
            // frame isn't blocked by the anti-flap 15 s gate — the enrichment
            // / reorder that fires immediately after open may change the vehicle
            // set, and we must allow that correction through.
            stableNearestArrivals = nearestStopArrivals
            lastStableRefreshDate = .distantPast
            // Cache direction badge counts so the 1 Hz interpolation tick
            // doesn't recompute them every body evaluation.
            refreshDirectionBadgeCounts()
            // Cache per-stop arrival lookup for the stops list.
            refreshArrivalByStopCache()
            // Lock the nearest stop key for this direction so subsequent refreshes don't hop stops
            if lockedDirectionHeadsign == nil {
                lockedDirectionHeadsign = safeDirection.direction
            }
            if lockedStopKeyPerDirection[selectedDirectionIndex] == nil,
               let first = stableNearestArrivals.first {
                lockedStopKeyPerDirection[selectedDirectionIndex] = first.stopId ?? first.stopName
            }
            #if DEBUG
            AppLogger.shared.log(
                "ROUTE_DETAIL",
                message:
                    "VIEW_OPEN route=\(group.routeId) dir=\(safeDirection.direction) live=\(safeDirection.liveArrivals.count)"
            )
            #endif
        }
        .onChange(of: group) { _, _ in
            // Refresh cached badge counts when backend data changes.
            refreshDirectionBadgeCounts()
            // Refresh per-stop arrival cache for the stops list.
            refreshArrivalByStopCache()
            // If the user's locked direction is temporarily absent from this
            // backend poll, ignore the update entirely rather than flipping to
            // whichever direction happens to be at index 0.
            if let locked = lockedDirectionHeadsign,
               !group.directions.contains(where: { $0.direction == locked }) {
                #if DEBUG
                print("[ARRIVAL_DIFF] ⏭ SKIP — locked dir '\(locked)' absent from poll")
                #endif
                return
            }
            // Clear loading skeleton the moment any arrivals arrive.
            if !safeDirection.arrivals.isEmpty {
                withAnimation(.easeOut(duration: 0.3)) {
                    isLoadingArrivals = false
                }
            }

            // Update the stable countdown only when it meaningfully changes:
            // different leading vehicle/trip, or ETA shifts > 60 s.
            let fresh = nearestStopArrivals
            // Lock the nearest stop key for this direction on first resolution
            if lockedStopKeyPerDirection[selectedDirectionIndex] == nil, let first = fresh.first {
                lockedStopKeyPerDirection[selectedDirectionIndex] = first.stopId ?? first.stopName
            }

            if shouldRefreshStableArrivals(fresh) {
                stableNearestArrivals = fresh
                lastStableRefreshDate = .now
            }

            // Force-refresh when ALL current stable arrivals are past due.
            // Without this, the TimelineView shows a blank scroll (isPastArrival
            // kills every chip, but nextArrivals is non-empty so the empty state
            // never renders).
            if !stableNearestArrivals.isEmpty {
                let allPast = stableNearestArrivals.allSatisfy { smartETA(for: $0).isPastArrival }
                if allPast {
                    stableNearestArrivals = fresh
                    lastStableRefreshDate = .now
                    #if DEBUG
                    print("[STABLE_CHIPS] ♻️ FORCE-REFRESH: all \(stableNearestArrivals.count) stable arrivals are past due")
                    #endif
                }
            }
        }
        .task(id: group.id) {
            // Safety timeout: if no arrivals arrive within 6 s (e.g. truly no service),
            // stop showing skeletons and let the real empty-state render.
            try? await Task.sleep(for: .seconds(6))
            withAnimation(.easeOut(duration: 0.3)) {
                isLoadingArrivals = false
            }
        }
        .onChange(of: favoritesManager.favorites) { _, _ in
            isFavorited = favoritesManager.isFavorite(routeId: group.routeId, mode: group.mode)
        }
        .onChange(of: selectedStopId) { _, newId in
            // Bridge map-tap stop selection into the sheet's stop filter.
            // When the user taps a stop marker on the map, the ViewModel
            // updates selectedStopId. We mirror that to inSheetSelectedStopId
            // so the countdown chips and departures board both respond.
            if let sid = newId, !sid.isEmpty {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    inSheetSelectedStopId = sid
                }
            }
        }
        .onChange(of: inSheetSelectedStopId) { _, _ in
            // When the user selects a stop (map tap or stops list tap),
            // immediately refresh the countdown chips to show arrivals
            // at the selected stop.
            selectedChipId = nil
            onFocusVehicle?(nil)
            let fresh = nearestStopArrivals
            stableNearestArrivals = fresh
            lastStableRefreshDate = .now
            #if DEBUG
            print("[STOP_SELECT] inSheetSelectedStopId=\(inSheetSelectedStopId ?? "nil") chips=\(fresh.count)")
            #endif
        }
        .onChange(of: selectedDirectionIndex) { _, _ in
            // Reset stable countdown chips immediately when the user switches direction
            // so they see the new direction's nearest-stop times right away rather than
            // waiting for the next group poll cycle to trigger shouldRefreshStableArrivals.
            // CRITICAL: Always assign — even when empty — so stale chips from the
            // previous direction are cleared.  Without this, switching to a direction
            // with no live arrivals keeps showing the old direction's chips.
            // Also clear stop selection — it belongs to the previous direction.
            inSheetSelectedStopId = nil
            selectedChipId = nil
            onFocusVehicle?(nil)
            onStopSelected?(nil)
            let freshArrivals = nearestStopArrivals
            stableNearestArrivals = freshArrivals
            // Use .distantPast so a group onChange in the same frame (shape
            // enrichment reorder) can correct the vehicle set immediately
            // instead of being blocked by the anti-flap 15 s gate.
            lastStableRefreshDate = .distantPast
            // Rebuild per-stop arrival cache for the new direction's stops tab.
            refreshArrivalByStopCache()
            isFavorited = favoritesManager.isFavorite(routeId: group.routeId, mode: group.mode)
            #if DEBUG
            let direction = safeDirection
            AppLogger.shared.log(
                "ROUTE_DETAIL",
                message:
                    "DIR_CHANGE route=\(group.routeId) mode=\(group.mode) selectedDirIdx=\(selectedDirectionIndex) dir=\(direction.direction) all=\(direction.arrivals.count) live=\(direction.liveArrivals.count)"
            )
            #endif
                    logETAParity(reason: "dir_change")
        }
        .alert("Sign In to Save Favorites", isPresented: $showSignInPrompt) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Create a free account to save your favorite routes and access them across all your devices.")
        }
    }

    // MARK: - Header

    private var routeHeader: some View {
        HStack(spacing: 14) {
            // Unified badge with mode-specific styling
            RouteBadge(
                routeID: group.displayName, size: .large, hexColor: group.colorHex, mode: group.mode
            )
            .shadow(color: routeColor.opacity(0.3), radius: 6, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 5) {
                Text(group.displayName)
                    .font(AppTheme.Typography.headerLarge)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if group.directions.indices.contains(selectedDirectionIndex) {
                    let dir = group.directions[selectedDirectionIndex]
                    let subtitle = "→ \(resolvedDirectionLabel(for: dir, at: selectedDirectionIndex))"
                    Text(subtitle)
                        .font(.custom("Helvetica", size: 15))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }

                // Mode badge + Express/Local badge
                HStack(spacing: 6) {
                    Text(
                        group.isCommuterRail
                            ? (group.isLIRR ? "LIRR" : "Metro-North") : group.isBus ? "Bus" : "Subway"
                    )
                    .font(.custom("Helvetica-Bold", size: 10))
                    .foregroundColor(routeColor)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(routeColor.opacity(0.1))
                    .clipShape(Capsule())

                    // Express / Local / Mixed service type (route-level, from GTFS)
                    if let serviceType = routeShape?.serviceType, !serviceType.isEmpty {
                        serviceTypeBadge(serviceType)
                    } else if routeShape == nil && !group.isBus {
                        // Shape loading — show shimmer placeholder for service type
                        SkeletonBar(width: 52, height: 20, opacity: 0.08)
                            .clipShape(Capsule())
                            .shimmer()
                    }
                }
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
                                cameraPosition = MapCameraPresets.center(on: loc, is3D: is3DMode)
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
                        withAnimation(MapCameraPresets.smoothAnimation) {
                            cameraPosition = MapCameraPresets.center(on: target, is3D: is3DMode)
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.custom("Helvetica-Bold", size: 18))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                    }
                    .accessibilityLabel("Recenter on my location")
                }
            }

            // Favorite + Close buttons — always visible, side by side
            HStack(spacing: 14) {
                // Heart button — always shown
                Button {
                    guard supabase.isAuthenticated else {
                        showSignInPrompt = true
                        return
                    }
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
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(isFavorited ? .red : AppTheme.Colors.textSecondary)
                        .symbolEffect(.bounce, value: isFavorited)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(isFavorited ? "Remove from favorites" : "Add to favorites")

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
        }
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    // MARK: - Passed-Stop Filter

    /// Returns `true` when a live vehicle has physically moved PAST the
    /// user's stop on the direction polyline — meaning the user can no
    /// longer catch it.  Only applies to vehicles that are live on the map
    /// (we have GPS); scheduled / non-map arrivals always return `false`.
    ///
    /// A 150 m grace buffer past the stop accommodates GPS jitter and the
    /// bus dwelling slightly past the stop marker while doors are open.
    private func hasVehiclePassedStop(
        _ arrival: NearbyTransitResponse,
        stopFraction: Double,
        polyline: [CLLocationCoordinate2D]
    ) -> Bool {
        guard polyline.count >= 2 else { return false }
        // Backend says the vehicle is arriving NOW — never filter it out.
        // This prevents chips=0 when the bus is physically at the stop but
        // its polyline fraction is slightly past the stop marker.
        if arrival.minutesAway <= 0 { return false }
        // Only check vehicles that are actually on the map
        guard isLiveOnMap?(arrival) ?? false else { return false }

        // Get vehicle coordinate
        let vehicleCoord: CLLocationCoordinate2D?
        if arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty,
           let bus = busVehicles.first(where: { $0.vehicleId == vid }) {
            vehicleCoord = CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
        } else {
            // TODO: Add train vehicle lookup when trainVehicles binding is available
            vehicleCoord = nil
        }
        guard let vc = vehicleCoord,
              let snap = VehicleInterpolator.snap(coordinate: vc, to: polyline),
              snap.distanceFromPolyline < 500  // must be on-route
        else { return false }

        // How far past the stop (in meters) the vehicle is
        let totalLength = VehicleInterpolator.polylineLength(polyline)
        let pastDistance = (snap.fractionAlongPolyline - stopFraction) * totalLength

        // Vehicle is past the stop by more than the grace buffer → gone
        return pastDistance > 150
    }

    /// Builds the direction polyline and stop fraction used by the passed-stop
    /// filter and polyline-distance sort.  Computed once per body evaluation.
    private var directionPolylineAndStopFraction: (polyline: [CLLocationCoordinate2D], stopFraction: Double?) {
        let polyline: [CLLocationCoordinate2D] = {
            guard let shape = routeShape else { return [] }
            return shape.polylinesForDirection(
                index: selectedDirectionIndex, name: selectedDirectionName
            ).flatMap { $0 }
        }()

        let liveOnly = safeDirection.liveArrivals

        let nearestStopKey: String? = {
            if let userStop = inSheetSelectedStopId, !userStop.isEmpty { return userStop }
            if let lockedKey = lockedStopKeyPerDirection[selectedDirectionIndex] {
                if liveOnly.contains(where: { ($0.stopId ?? $0.stopName) == lockedKey }) {
                    return lockedKey
                }
            }
            let refLoc: CLLocation? = (currentLocation ?? searchCenter).map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
            }
            var bestKey: String?
            var bestDist: CLLocationDistance = .greatestFiniteMagnitude
            for arrival in liveOnly {
                let dist: CLLocationDistance
                if let dm = arrival.distanceM { dist = dm }
                else if let loc = refLoc, let lat = arrival.stopLat, let lon = arrival.stopLon {
                    dist = loc.distance(from: CLLocation(latitude: lat, longitude: lon))
                } else { dist = .greatestFiniteMagnitude }
                if dist < bestDist { bestDist = dist; bestKey = arrival.stopId ?? arrival.stopName }
            }
            return bestKey
        }()

        let stopFraction: Double? = {
            guard polyline.count >= 2 else { return nil }
            let stopCoord: CLLocationCoordinate2D? = {
                if let nk = nearestStopKey {
                    if let a = liveOnly.first(where: { ($0.stopId ?? $0.stopName) == nk }),
                       let lat = a.stopLat, let lon = a.stopLon {
                        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }
                    if let shape = routeShape {
                        let stops = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
                        if let s = stops.first(where: { $0.id == nk || $0.name == nk }) {
                            return CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
                        }
                    }
                }
                return nil
            }()
            guard let sc = stopCoord else { return nil }
            return VehicleInterpolator.snap(coordinate: sc, to: polyline)?.fractionAlongPolyline
        }()

        return (polyline, stopFraction)
    }

    // MARK: - Countdown Chips

    /// Primary arrivals source for the Departures board.
    ///
    /// Ordering strategy — matches the user's mental model of "what's heading
    /// to my stop, in the order I'd see them arrive":
    ///
    ///  1. **Filter out passed vehicles** — any live vehicle whose GPS shows it
    ///     has physically moved past the user's stop on the polyline is removed.
    ///  2. **Live vehicles first** — sorted by polyline distance to stop
    ///     (closest → farthest).  Stable because distance changes monotonically.
    ///  3. **Non-live real-time arrivals** — sorted by ETA.
    ///  4. **Scheduled arrivals last** — sorted by ETA.
    ///  5. Deduplicate by vehicle/trip key throughout.
    private var prioritizedArrivals: [NearbyTransitResponse] {
        let direction = safeDirection
        let liveOnly = direction.liveArrivals
        guard !liveOnly.isEmpty else { return [] }

        let (polyline, stopFraction) = directionPolylineAndStopFraction

        // ── Pre-filter: remove vehicles that have passed the stop ──
        let reachable: [NearbyTransitResponse]
        if let sf = stopFraction {
            reachable = liveOnly.filter { !hasVehiclePassedStop($0, stopFraction: sf, polyline: polyline) }
        } else {
            reachable = liveOnly
        }
        guard !reachable.isEmpty else { return [] }

        // ── Helper: get vehicle's distance-to-stop along polyline ──
        func vehicleDistanceToStop(_ arrival: NearbyTransitResponse) -> Double? {
            guard let sf = stopFraction, polyline.count >= 2 else { return nil }
            let vehicleCoord: CLLocationCoordinate2D?
            if arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty,
               let bus = busVehicles.first(where: { $0.vehicleId == vid }) {
                vehicleCoord = CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
            } else {
                vehicleCoord = nil
            }
            guard let vc = vehicleCoord,
                  let snap = VehicleInterpolator.snap(coordinate: vc, to: polyline),
                  snap.distanceFromPolyline < 500
            else { return nil }
            let totalLength = VehicleInterpolator.polylineLength(polyline)
            return abs(snap.fractionAlongPolyline - sf) * totalLength
        }

        // ── Partition into three tiers ──
        var liveWithDistance: [(arrival: NearbyTransitResponse, distance: Double)] = []
        var realtimeNoMap: [NearbyTransitResponse] = []
        var scheduled: [NearbyTransitResponse] = []

        for arrival in reachable {
            let onMap = isLiveOnMap?(arrival) ?? false
            if onMap, let dist = vehicleDistanceToStop(arrival) {
                liveWithDistance.append((arrival, dist))
            } else if onMap || !arrival.isScheduledOnly {
                realtimeNoMap.append(arrival)
            } else {
                scheduled.append(arrival)
            }
        }

        // Sort each tier
        liveWithDistance.sort { $0.distance < $1.distance }
        let sortedLive = liveWithDistance.map(\.arrival)
        let sortedRealtime = sortArrivalsByETA(realtimeNoMap)
        let sortedScheduled = sortArrivalsByETA(scheduled)

        let combined = sortedLive + sortedRealtime + sortedScheduled

        // ── Deduplicate by vehicle/trip key ──
        var seen = Set<String>()
        return combined.filter { arrival in
            guard let key = arrival.vehicleId ?? arrival.tripId else {
                return true
            }
            return seen.insert(key).inserted
        }
    }

    /// Arrivals used by the countdown chips at the top of the detail sheet.
    ///
    /// Uses the same nearest-stop filtering as ``GroupedRouteRow.countdownArrival``
    /// so the chip times always agree with the home-row countdown.
    ///
    /// Strategy (mirrors GroupedRouteRow exactly):
    ///  1. Find the stop closest to the user's reference location.
    ///  2. Return arrivals at that stop, sorted by ETA.
    ///  3. Fall back to all live arrivals when no location is available.
    /// Arrivals shown in the countdown chips, ordered so chip #1 always matches
    /// the home-row countdown (same vehicle / same stop as `GroupedRouteRow`).
    ///
    /// The backend now returns ONE prediction per vehicle — at the stop with the
    /// smallest `distance_m` from the user.  We mirror `GroupedRouteRow.countdownArrival`:
    ///  1. Find the user's nearest stop across all live arrivals (by `distanceM`,
    ///     falling back to lat/lon distance or server-side `distance_m`).
    ///  2. Place arrivals at THAT stop first (sorted by smartETA).
    ///  3. Append arrivals at other stops after (sorted by smartETA).
    ///  4. Deduplicate by vehicle key within each partition.
    ///
    /// This guarantees chip #1 == home-row countdown when at least one arrival
    /// has coordinates, and degrades gracefully to "soonest globally" otherwise.
    private var nearestStopArrivals: [NearbyTransitResponse] {
        // Show ALL arrivals (live + scheduled) — chip status is determined
        // by `isLiveOnMap` (actual map marker presence), not the backend
        // status string.  This keeps chips in sync with what the user sees
        // on the route line.
        let raw = safeDirection.liveArrivals
        guard !raw.isEmpty else { return [] }

        // ── Pre-filter: remove vehicles that have passed the stop ──
        let (polyline, stopFraction) = directionPolylineAndStopFraction
        let live: [NearbyTransitResponse]
        if let sf = stopFraction {
            let filtered = raw.filter { !hasVehiclePassedStop($0, stopFraction: sf, polyline: polyline) }
            // Safety net: never drop ALL arrivals — if the polyline filter
            // removed everything, fall back to the unfiltered list so the
            // user never sees chips=0 when arrivals actually exist.
            live = filtered.isEmpty ? raw : filtered
        } else {
            live = raw
        }

        // Deduplicate helper (used in multiple branches below).
        // Partitions: live (isRealTime) first sorted by ETA, then
        // scheduled sorted by ETA.  This guarantees the chip strip
        // always reads left→right: approaching buses → future scheduled.
        func deduped(_ list: [NearbyTransitResponse]) -> [NearbyTransitResponse] {
            var seen = Set<String>()
            let unique = sortArrivalsByETA(list).filter { a in
                guard let k = a.vehicleId ?? a.tripId else { return true }
                return seen.insert(k).inserted
            }
            let live = unique.filter { $0.isRealTime }
            let sched = unique.filter { !$0.isRealTime }
            return live + sched
        }

        // ── USER-SELECTED STOP takes absolute priority ──────────────────
        // When the user taps a stop on the map or in the Stops list,
        // show arrivals at THAT stop — letting them explore upcoming
        // vehicles at any point along the route.
        if let userStop = inSheetSelectedStopId, !userStop.isEmpty {
            let atSelected = live.filter { arrivalMatchesStop($0, stopId: userStop) }
            if !atSelected.isEmpty {
                return deduped(atSelected)
            }
            // No arrivals matched the selected stop yet (vehicle sync
            // may not have run) — fall through to nearest-stop logic
            // so chips don't flash empty.
        }

        // ── Prefer the locked stop key if arrivals still exist there ────────
        // This prevents the nearest-stop from hopping between polls when a
        // backend re-sort changes distance ordering.
        // Use normalized comparison so the lock survives format differences
        // between the nearby API stop IDs and SIRI onward-call stop IDs
        // (e.g. "MTA_403530" vs "MTA NYCT_403530" vs "403530").
        var nearestStopKey: String?
        func stopKeyMatches(_ a: String?, _ b: String?) -> Bool {
            guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
            if a == b { return true }
            return stripMTAStopPrefix(a) == stripMTAStopPrefix(b)
        }
        if let lockedKey = lockedStopKeyPerDirection[selectedDirectionIndex] {
            let atLocked = live.filter { stopKeyMatches($0.stopId ?? $0.stopName, lockedKey) }
            if !atLocked.isEmpty {
                nearestStopKey = lockedKey
            }
        }

        // ── Fall back to distance-based nearest stop ───────────────────────
        if nearestStopKey == nil {
            let refLoc: CLLocation? = (currentLocation ?? searchCenter).map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
            }
            var nearestDist: CLLocationDistance = .greatestFiniteMagnitude

            for arrival in live {
                let dist: CLLocationDistance
                if let dm = arrival.distanceM {
                    dist = dm
                } else if let loc = refLoc, let lat = arrival.stopLat, let lon = arrival.stopLon {
                    dist = loc.distance(from: CLLocation(latitude: lat, longitude: lon))
                } else {
                    dist = .greatestFiniteMagnitude
                }
                if dist < nearestDist {
                    nearestDist = dist
                    nearestStopKey = arrival.stopId ?? arrival.stopName
                }
            }
        }

        // ── Partition: nearest-stop first, then the rest ─────────────────────
        var atNearest: [NearbyTransitResponse] = []
        var elsewhere: [NearbyTransitResponse] = []
        for arrival in live {
            let key = arrival.stopId ?? arrival.stopName
            if let nearest = nearestStopKey, stopKeyMatches(key, nearest) {
                atNearest.append(arrival)
            } else {
                elsewhere.append(arrival)
            }
        }

        // Show ONLY the nearest-stop arrivals (matches home-row chip #1 exactly).
        // No artificial cap — the chip section is a horizontal ScrollView that
        // handles any count.  Show everything the backend gives us.
        // Fallback: if no arrivals resolved to a nearest stop, show globally-soonest arrivals.
        let nearestChips = deduped(atNearest)
        if !nearestChips.isEmpty {
            return nearestChips
        }
        return deduped(elsewhere)
    }

    /// Mirrors `GroupedRouteRow.countdownArrival(for:)` exactly by delegating
    /// to the shared `ArrivalHelpers.countdownArrival` — single source of truth.
    private func rowComparableCountdownArrival(for direction: DirectionArrivalsResponse) -> NearbyTransitResponse? {
        let refCoord = currentLocation ?? searchCenter
        let refLoc = refCoord.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        return ArrivalHelpers.countdownArrival(for: direction, userLocation: refLoc, provider: smartETA)
    }

    // MARK: - Arrival diff logging

    /// Logs a rich diff of arrivals every time `group` changes.
    /// Each arrival line shows:
    ///   • minutes away + clock time  (so you can cross-check against Transit app)
    ///   • LIVE or ★SCHED             (live = confirmed SIRI real-time, sched = GTFS-static)
    ///   • vehicle/trip id
    ///   • GPS coordinates of the map marker (LIVE only) — proves the bus is physically on route
    private func logArrivalDiff(
        old: [NearbyTransitResponse],
        new: [NearbyTransitResponse],
        label: String
    ) {
        #if DEBUG
        let ts = String(format: "%.1f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10000))
        let route = group.routeId
        let dir = safeDirection.direction
        let lockInfo = lockedNearestStopKey.map { "lock:\($0)" } ?? "lock:none"

        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        // Build a rich one-liner per arrival
        func describe(_ arr: [NearbyTransitResponse]) -> [String] {
            arr.map { a in
                let vid = a.vehicleId ?? a.tripId ?? "?"
                let tag = a.isScheduledOnly ? "★SCHED" : "●LIVE "

                // Clock time: prefer arrival_ts, fall back to now + minutesAway
                let clockTime: String = {
                    if let ts = a.arrivalTs {
                        return fmt.string(from: Date(timeIntervalSince1970: Double(ts)))
                    }
                    let approx = Date().addingTimeInterval(Double(a.minutesAway) * 60)
                    return "~" + fmt.string(from: approx)
                }()

                // GPS coordinates: look up the matching vehicle in the busVehicles binding
                let coords: String = {
                    guard !a.isScheduledOnly else { return "" }
                    if let vid = a.vehicleId,
                       let bus = busVehicles.first(where: { $0.vehicleId == vid }) {
                        return String(format: " 📍%.5f,%.5f", bus.lat, bus.lon)
                    }
                    return " (no GPS match)"
                }()

                return "  \(tag) \(a.minutesAway)m @ \(clockTime)  id=\(vid)  stop=\(a.stopName)\(coords)"
            }
        }

        let oldKeys = Set(old.map { $0.tripId ?? $0.vehicleId ?? $0.id })
        let newKeys = Set(new.map { $0.tripId ?? $0.vehicleId ?? $0.id })
        let appeared  = newKeys.subtracting(oldKeys)
        let vanished  = oldKeys.subtracting(newKeys)

        let oldLines = old.isEmpty ? ["  <empty>"] : describe(old)
        let newLines = new.isEmpty ? ["  <empty>"] : describe(new)

        var out = """
        ┌─ [ARRIVAL_DIFF] \(ts)s  route=\(route)  dir=\(dir)  \(lockInfo)  (\(label))
        │  ── OLD (\(old.count)) ──────────────────────────────────────
        """
        for l in oldLines { out += "\n│ \(l)" }
        out += "\n│  ── NEW (\(new.count)) ──────────────────────────────────────"
        for l in newLines { out += "\n│ \(l)" }
        out += "\n│  APPEARED (\(appeared.count)): \(appeared.isEmpty ? "none" : appeared.joined(separator: ", "))"
        out += "\n│  VANISHED (\(vanished.count)): \(vanished.isEmpty ? "none" : vanished.joined(separator: ", "))"
        out += "\n└─────────────────────────────────────────────────────────────────"
        print(out)
        #endif
    }

    /// Returns true when `new` differs enough from `stableNearestArrivals` to warrant
    /// a display refresh — i.e. the set of arrivals changed, or the count changed.
    ///
    /// NOTE: We no longer gate on a large ETA threshold because the TimelineView
    /// now re-sorts chips every tick.  `stableNearestArrivals` only controls WHICH
    /// arrivals are in the chip list; their ORDER is handled live.  So we refresh
    /// whenever the arrival set itself changes (different vehicle, count change,
    /// or a new stop key), which keeps the chip list fresh without causing visual
    /// flicker (the TimelineView sort handles smooth reordering).
    private func shouldRefreshStableArrivals(_ new: [NearbyTransitResponse]) -> Bool {
        // When fresh data is empty (e.g. SIRI feed dropped live tracking),
        // DON'T immediately clear the chips — the old live arrivals may still
        // be valid (bus hasn't passed the stop yet).  Hold them until they
        // naturally expire via isPastArrival.  This prevents the chips from
        // flashing to empty/grey during a 1-poll SIRI dropout.
        guard !new.isEmpty else {
            if stableNearestArrivals.isEmpty { return false }
            // Only clear when ALL old chips have expired
            let allPast = stableNearestArrivals.allSatisfy { smartETA(for: $0).isPastArrival }
            return allPast
        }
        guard !stableNearestArrivals.isEmpty else { return true }

        // ── Anti-flap: protect arrivals from SIRI feed dropouts ───────────
        // Compare by VEHICLE SET — not count.  Only block when vehicles
        // *vanished* (same vehicles minus some), which means the feed
        // temporarily dropped them.  If a vehicle legitimately departed
        // (new set has a different leading vehicle), allow the update.
        let oldKeys = Set(stableNearestArrivals.compactMap { $0.vehicleId ?? $0.tripId })
        let newKeys = Set(new.compactMap { $0.vehicleId ?? $0.tripId })
        let vanished = oldKeys.subtracting(newKeys)
        let appeared = newKeys.subtracting(oldKeys)

        // Vehicles vanished but none appeared → likely a SIRI feed dropout.
        // Block for 15s (1-2 polls) to let the feed recover.
        if !vanished.isEmpty && appeared.isEmpty {
            let elapsed = Date.now.timeIntervalSince(lastStableRefreshDate)
            if elapsed < 15 {
                #if DEBUG
                print("[STABLE_CHIPS] ⏳ ANTI-FLAP: blocking vanished=\(vanished) with no new arrivals, \(String(format: "%.0f", elapsed))s since last refresh")
                #endif
                return false
            }
        }

        // New vehicles appeared → always update immediately
        if !appeared.isEmpty { return true }

        // Count changed → refresh (arrival appeared or departed)
        if new.count != stableNearestArrivals.count { return true }

        // Different leading vehicle/trip → refresh
        let newKey = new[0].tripId ?? new[0].vehicleId
        let oldKey = stableNearestArrivals[0].tripId ?? stableNearestArrivals[0].vehicleId
        if newKey != oldKey { return true }

        // Different set of vehicles → refresh (reuse sets from anti-flap above)
        return newKeys != oldKeys
    }

    private func logETAParity(reason: String) {
        #if DEBUG
        let direction = safeDirection
        guard let rowArrival = rowComparableCountdownArrival(for: direction),
              let detailArrival = nearestStopArrivals.first
        else {
            AppLogger.shared.log(
                "ETA_PARITY",
                message: "reason=\(reason) route=\(group.routeId) dir=\(direction.direction) unavailable"
            )
            return
        }

        let rowETA = smartETA(for: rowArrival)
        let detailETA = smartETA(for: detailArrival)
        let deltaSeconds = Int(abs(rowETA.secondsRemaining - detailETA.secondsRemaining))

        AppLogger.shared.log(
            "ETA_PARITY",
            message:
                "reason=\(reason) route=\(group.routeId) dir=\(direction.direction) row=\(rowETA.minutesRemaining)m detail=\(detailETA.minutesRemaining)m delta=\(deltaSeconds)s rowStop=\(rowArrival.stopName) detailStop=\(detailArrival.stopName)"
        )

        // Log the full arrival lists from both sides so discrepancies are visible.
        // Row side: all live arrivals in the direction (same pool GroupedRouteRow uses)
        let rowLive = direction.liveArrivals
        let rowMins = rowLive.map { a -> String in
            let eta = smartETA(for: a)
            let vid = a.vehicleId ?? a.tripId ?? "?"
            let rtTag = a.isRealTime ? "LIVE" : "SCHED"
            return "\(eta.minutesRemaining)m(raw=\(a.minutesAway),\(rtTag),id=\(vid.suffix(6)),stop=\(a.stopName))"
        }
        // Detail side: the stable nearest-stop arrivals (what the user sees as chips)
        let detailChips = stableNearestArrivals
        let detailMins = detailChips.map { a -> String in
            let eta = smartETA(for: a)
            let vid = a.vehicleId ?? a.tripId ?? "?"
            let rtTag = a.isRealTime ? "LIVE" : "SCHED"
            return "\(eta.minutesRemaining)m(raw=\(a.minutesAway),\(rtTag),id=\(vid.suffix(6)),stop=\(a.stopName))"
        }
        print("[DETAIL_ARRIVALS] route=\(group.routeId)  row=[\(rowMins.joined(separator: ", "))]  detail=[\(detailMins.joined(separator: ", "))]")
        #endif
    }

    /// Checks if an arrival matches a stop ID, with fuzzy matching for
    /// different ID formats (e.g. "MTA_305423" vs "305423" vs "MTA NYCT_305423").
    /// Also handles subway N/S direction suffixes (e.g. "120N" vs "120S" both
    /// refer to the same physical station) and falls back to name-based matching.
    private func arrivalMatchesStop(_ arrival: NearbyTransitResponse, stopId: String) -> Bool {
        guard let arrivalStopId = arrival.stopId, !arrivalStopId.isEmpty else {
            // No stopId on arrival — try name-based match as last resort
            return matchesByName(arrivalStopName: arrival.stopName, shapeStopId: stopId)
        }
        // Exact match
        if arrivalStopId == stopId { return true }
        // Strip common MTA prefixes for fuzzy matching
        let stripped1 = stripMTAStopPrefix(arrivalStopId)
        let stripped2 = stripMTAStopPrefix(stopId)
        if stripped1 == stripped2 { return true }
        // One might be a suffix of the other (e.g. "305423" vs "MTA_305423")
        if stripped1.hasSuffix(stripped2) || stripped2.hasSuffix(stripped1) { return true }
        // Subway parent station match: "120N" and "120S" share parent "120".
        // Uses shared normalizeStopId which strips prefix + N/S suffix.
        let parent1 = normalizeStopId(arrivalStopId)
        let parent2 = normalizeStopId(stopId)
        if parent1 == parent2 && !parent1.isEmpty { return true }
        // Name-based fallback: lookup what name the route shape gives this stopId
        return matchesByName(arrivalStopName: arrival.stopName, shapeStopId: stopId)
    }

    /// Checks if an arrival's stop name matches the name of a route shape stop by ID.
    private func matchesByName(arrivalStopName: String, shapeStopId: String) -> Bool {
        guard let shape = routeShape else { return false }
        let allStops = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
        // Try exact ID match first, then parent station ID match
        let shapeStop = allStops.first(where: { $0.id == shapeStopId })
            ?? allStops.first(where: { normalizeStopId($0.id) == normalizeStopId(shapeStopId) })
        guard let shapeStop else { return false }
        // Compare names case-insensitively, allowing partial matches
        let a = arrivalStopName.lowercased().trimmingCharacters(in: .whitespaces)
        let b = shapeStop.name.lowercased().trimmingCharacters(in: .whitespaces)
        return a == b || a.contains(b) || b.contains(a)
    }

    /// Calculates distance from a user location to an arrival's stop.
    /// Uses stop lat/lon from the arrival, or tries to look up from route shape.
    private func arrivalDistance(_ arrival: NearbyTransitResponse, from userLoc: CLLocation) -> CLLocationDistance {
        // Use arrival's own coordinates if available
        if let lat = arrival.stopLat, let lon = arrival.stopLon {
            return userLoc.distance(from: CLLocation(latitude: lat, longitude: lon))
        }
        // Try to look up coordinates from route shape stops
        if let stopId = arrival.stopId, let shape = routeShape {
            let allStops = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
            if let stop = allStops.first(where: { $0.id == stopId }) {
                return userLoc.distance(from: CLLocation(latitude: stop.lat, longitude: stop.lon))
            }
            // Fuzzy match on normalized IDs (MTA prefix + N/S suffix stripped)
            let normalized = normalizeStopId(stopId)
            if let stop = allStops.first(where: { normalizeStopId($0.id) == normalized }) {
                return userLoc.distance(from: CLLocation(latitude: stop.lat, longitude: stop.lon))
            }
        }
        // Try name-based lookup
        if let shape = routeShape {
            let allStops = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
            if let stop = allStops.first(where: { $0.name.lowercased() == arrival.stopName.lowercased() }) {
                return userLoc.distance(from: CLLocation(latitude: stop.lat, longitude: stop.lon))
            }
        }
        return .greatestFiniteMagnitude
    }

    /// Sorts arrivals by smart ETA so chips and rows use the same ordering.
    ///
    /// Pre-computes ALL ETAs into a dictionary first so sorting only triggers
    /// O(N) smartETA calls instead of O(N log N) — critical because smartETA
    /// hits ArrivalETAEngine on the main thread on every comparison.
    private func sortArrivalsByETA(_ arrivals: [NearbyTransitResponse]) -> [NearbyTransitResponse] {
        ArrivalHelpers.sortedByETA(arrivals, provider: smartETA)
    }

    // MARK: - Smart ETA

    /// Computes a smart ETA for an arrival using live vehicle position + polyline.
    /// Uses the data already available on the sheet (busVehicles, routeShape).
    private func smartETA(for arrival: NearbyTransitResponse) -> SmartETA {
        if let shared = smartETAProvider {
            return shared(arrival)
        }

        // Find the vehicle's live coordinate from busVehicles binding
        let vehicleCoord: CLLocationCoordinate2D? = {
            if arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty,
               let bus = busVehicles.first(where: { $0.vehicleId == vid }) {
                return CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
            }
            // For trains, check isLiveOnMap callback — if true, vehicle is on the map
            // but we don't have direct access to trainVehicles here.
            // The engine will fall back to arrivalTs in that case.
            return nil
        }()

        let stopCoord: CLLocationCoordinate2D? = {
            if let lat = arrival.stopLat, let lon = arrival.stopLon {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            // Try route shape lookup
            if let sid = arrival.stopId, let shape = routeShape {
                let stops = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
                if let s = stops.first(where: { $0.id == sid }) {
                    return CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
                }
                // Fuzzy match on normalized IDs (MTA prefix + N/S suffix stripped)
                let normalized = normalizeStopId(sid)
                if let s = stops.first(where: { normalizeStopId($0.id) == normalized }) {
                    return CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
                }
            }
            return nil
        }()

        let polyline: [CLLocationCoordinate2D]? = {
            guard let shape = routeShape else { return nil }
            let decoded = shape.polylinesForDirection(
                index: selectedDirectionIndex, name: selectedDirectionName
            ).flatMap { $0 }
            return decoded.count >= 2 ? decoded : nil
        }()

        return ArrivalETAEngine.computeETA(
            vehicleCoord: vehicleCoord,
            vehicleKey: arrival.vehicleId ?? arrival.tripId,
            stopCoord: stopCoord,
            polyline: polyline,
            arrivalTs: arrival.arrivalTs,
            staticMinutes: arrival.minutesAway,
            mode: arrival.mode
        )
    }

    // MARK: - Arrival Card

    /// `eta` is pre-computed by the single sheet-level `TimelineView` in
    /// `countdownSection` — do NOT recompute it here.  This eliminates N
    /// separate per-chip timer callbacks (one per second each) and replaces
    /// them with one shared tick that computes all ETAs in a single pass.
    @ViewBuilder
    private func arrivalCard(arrival: NearbyTransitResponse, index: Int, eta: SmartETA) -> some View {
        let isFirst = index == 0
        let isCancelled = arrival.isCancelled
        let status = chipStatus(for: arrival)
        let isSched = !isCancelled && status == .scheduled

        // ── Tier colors ──────────────────────────────────────────────
        let tagColor: Color = isCancelled
            ? AppTheme.Colors.alertRed
            : isSched
                ? AppTheme.Colors.textSecondary.opacity(0.6)
                : arrival.isRealTime
                    ? AppTheme.Colors.successGreen
                    : AppTheme.Colors.textSecondary.opacity(0.6)
        let tagBg: Color = isCancelled
            ? AppTheme.Colors.alertRed.opacity(0.14)
            : isSched
                ? AppTheme.Colors.textSecondary.opacity(0.10)
                : arrival.isRealTime
                    ? AppTheme.Colors.successGreen.opacity(0.14)
                    : AppTheme.Colors.textSecondary.opacity(0.10)
        let tagLabel = isCancelled ? "Cancelled" : isSched ? "Scheduled" : arrival.isRealTime ? "Live" : "On Route"
        let tagIcon  = isCancelled ? "xmark.circle.fill" : isSched ? "clock" : "circle.fill"

        VStack(spacing: 0) {
            // ── Status tag ────────────────────────────────────────────────
            HStack(spacing: 4) {
                if isCancelled || isSched {
                    Image(systemName: tagIcon)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(tagColor)
                } else {
                    Circle()
                        .fill(tagColor)
                        .frame(width: 5, height: 5)
                }
                Text(tagLabel)
                    .font(.custom("Helvetica-Bold", size: 8.5))
                    .foregroundColor(tagColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tagBg))
            .padding(.top, 13)

            Spacer(minLength: 6)

            // ── ETA counter ───────────────────────────────────────────────
            let mins  = eta.minutesRemaining
            let isNow = !isSched && !isCancelled && (eta.isAtStop || eta.secondsRemaining <= 30)
            arrivalETA(mins: mins, isNow: isNow, isSched: isSched, isFirst: isFirst)

            Spacer(minLength: isFirst ? 8 : 6)

            // ── Clock time ────────────────────────────────────────────────
            // For scheduled arrivals, the clock time is the primary info
            // (the bus/train isn't on route yet, so the exact departure
            // time matters more than the countdown).
            if let ts = arrival.arrivalTs {
                Text(Date(timeIntervalSince1970: Double(ts)), style: .time)
                    .font(.custom("Helvetica-Bold", size: isSched ? 13 : 10))
                    .foregroundColor(
                        isSched
                        ? AppTheme.Colors.textSecondary.opacity(0.55)
                        : AppTheme.Colors.textSecondary.opacity(0.70)
                    )
            } else if isSched {
                // Scheduled arrival without a timestamp — compute from minutesAway.
                let departTime = Date().addingTimeInterval(Double(mins) * 60)
                Text(departTime, style: .time)
                    .font(.custom("Helvetica-Bold", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.55))
            }

            Spacer(minLength: 14)
        }
        .frame(width: isFirst ? 92 : 76)
        .frame(minHeight: isFirst ? 130 : 116)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    isSched
                    ? AppTheme.Colors.cardBackground.opacity(0.55)
                    : AppTheme.Colors.cardBackground
                )
                .shadow(
                    color: isSched ? .clear : .black.opacity(isFirst ? 0.09 : 0.05),
                    radius: isFirst ? 8 : 5, x: 0, y: 2
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    selectedChipId == arrival.id
                        ? routeColor.opacity(0.7)
                        : isSched
                            ? AppTheme.Colors.textSecondary.opacity(0.12)
                            : (isFirst ? routeColor.opacity(0.35) : Color.clear),
                    lineWidth: selectedChipId == arrival.id ? 2.0 : 1.2
                )
        )
        // Tap card to highlight vehicle on map + scale chip.
        // Tapping the same chip again deselects (back to default view).
        // Does NOT start Live Activity — that's reserved for the track button.
        .scaleEffect(selectedChipId == arrival.id ? 1.08 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selectedChipId)
        .onTapGesture {
            guard !isSched else { return }
            let vehicleKey = arrival.vehicleId ?? arrival.tripId
            if selectedChipId == arrival.id {
                // Deselect — clear highlight
                selectedChipId = nil
                onFocusVehicle?(nil)
            } else {
                // Select — highlight + zoom to vehicle marker
                selectedChipId = arrival.id
                if let key = vehicleKey {
                    onFocusVehicle?(key)
                }
            }
            HapticManager.impact(.light)
        }
    }

    @ViewBuilder
    private func arrivalETA(mins: Int, isNow: Bool, isSched: Bool, isFirst: Bool) -> some View {
        VStack(spacing: 1) {
            if isNow {
                Text("Now")
                    .font(.custom("Helvetica-Bold", size: isFirst ? 30 : 24))
                    .foregroundColor(AppTheme.Colors.countdown(0))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: mins)
            } else {
                Text("\(mins)")
                    .font(.custom("Helvetica-Bold", size: isFirst ? 40 : 32))
                    .foregroundColor(
                        isSched
                        ? AppTheme.Colors.textSecondary.opacity(0.45)
                        : AppTheme.Colors.countdown(mins)
                    )
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: mins)
                Text("min")
                    .font(.custom("Helvetica-Bold", size: 11))
                    .foregroundColor(
                        isSched
                        ? AppTheme.Colors.textSecondary.opacity(0.35)
                        : AppTheme.Colors.textSecondary
                    )
            }
        }
        .monospacedDigit()
    }

    private var countdownSection: some View {
        // Use the debounced stable snapshot to prevent ETA flickering during
        // the open cascade (initial → vehicles → shape).
        // Falls back to nearestStopArrivals if stable is empty (first render).
        let source = stableNearestArrivals.isEmpty ? nearestStopArrivals : stableNearestArrivals
        let nextArrivals = source
        let isUserSelected = inSheetSelectedStopId != nil
        // Resolve the stop name for the header
        let displayStopName: String? = {
            // 1) User-selected stop — resolve name from shape or arrivals
            if let userStop = inSheetSelectedStopId, !userStop.isEmpty {
                if let shape = routeShape {
                    let stops = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
                    let parentId = normalizeStopId(userStop)
                    if let name = stops.first(where: { $0.id == userStop })?.name
                        ?? stops.first(where: { normalizeStopId($0.id) == parentId })?.name {
                        return name
                    }
                }
                return source.first?.stopName
            }
            // 2) Auto-nearest stop (selectedStopId from ViewModel)
            if let stopId = selectedStopId, !stopId.isEmpty {
                if let name = source.first?.stopName { return name }
                if let shape = routeShape {
                    let stops = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
                    let parentId = normalizeStopId(stopId)
                    return stops.first(where: { $0.id == stopId })?.name
                        ?? stops.first(where: { normalizeStopId($0.id) == parentId })?.name
                }
            }
            return source.first?.stopName
        }()

        return VStack(alignment: .leading, spacing: 10) {
            // Show the stop name in the header when filtered to nearest stop
            HStack(spacing: 6) {
                Text("Next Arrivals")
                    .font(.custom("Helvetica-Bold", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                if let stopName = displayStopName {
                    if isUserSelected {
                        // User picked this stop — show as a dismissible filter pill
                        HStack(spacing: 4) {
                            Image(systemName: "mappin")
                                .font(.system(size: 8, weight: .bold))
                            Text(stopName)
                                .font(.custom("Helvetica-Bold", size: 11))
                                .lineLimit(1)
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    inSheetSelectedStopId = nil
                                    onStopSelected?(nil)
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                            }
                        }
                        .foregroundColor(routeColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(routeColor.opacity(0.12))
                        .clipShape(Capsule())
                    } else {
                        Text("at \(stopName)")
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(routeColor)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            if nextArrivals.isEmpty {
                // Still fetching first batch → show skeleton chips
                if isLoadingArrivals {
                    CountdownChipSkeleton(count: 3)
                } else if liveVehicleCount > 0 {
                    // Vehicles are on the map but no arrival data for this stop/direction yet.
                    // Clarify that vehicles exist on the route but aren't predicted for
                    // the user's stop to avoid confusion with the "Sched" indicator on
                    // GroupedRouteRow.
                    VStack(spacing: 8) {
                        Image(systemName: group.isBus ? "bus.fill" : "tram.fill")
                            .font(.system(size: 28))
                            .foregroundColor(routeColor.opacity(0.6))
                        Text("\(liveVehicleCount) vehicle\(liveVehicleCount == 1 ? "" : "s") en route")
                            .font(.custom("Helvetica-Bold", size: 14))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                        Text("No predicted arrivals at your stop yet")
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else if !scheduledDeparturesForCurrentDirection.isEmpty {
                    scheduledDeparturesView
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.system(size: 28))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                        Text("No upcoming arrivals")
                            .font(.subheadline)
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                // ONE TimelineView drives all chips — replacing the previous N
                // per-chip TimelineViews that each fired 1×/s on the main thread.
                //
                // CRITICAL: compute fresh ETAs, sort, and filter INSIDE the
                // TimelineView closure each tick.  `stableNearestArrivals`
                // determines WHICH arrivals appear; this tick-level sort ensures
                // the ORDER always matches the DISPLAYED values.  Without this,
                // chips that were sorted at "2 min" can later display "NOW" while
                // sitting to the right of an "8 min" chip — exactly the bug the
                // user reported.
                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    let allChips: [(arrival: NearbyTransitResponse, eta: SmartETA)] = nextArrivals.compactMap { arrival in
                        let eta = smartETA(for: arrival)
                        // Drop arrivals whose timestamp is >90 s in the past — bus already left.
                        guard !eta.isPastArrival else { return nil }
                        return (arrival, eta)
                    }

                    // Partition: live (isRealTime) first by ETA, then scheduled by ETA.
                    // This mirrors the home-row ordering: approaching buses first,
                    // future scheduled after.
                    let liveChips = allChips
                        .filter { $0.arrival.isRealTime }
                        .sorted { $0.eta.secondsRemaining < $1.eta.secondsRemaining }
                    let schedChips = allChips
                        .filter { !$0.arrival.isRealTime }
                        .sorted { $0.eta.secondsRemaining < $1.eta.secondsRemaining }
                    let orderedChips = liveChips + schedChips

                    if orderedChips.isEmpty {
                        // All stable chips expired — clear stableNearestArrivals
                        // so the NEXT SwiftUI layout pass enters the proper
                        // empty-state branch (skeleton / scheduled / "no arrivals").
                        // Using Color.clear as a zero-size placeholder ensures
                        // this tick renders something valid.
                        Color.clear
                            .frame(height: 0)
                            .onAppear {
                                // Guard avoids repeated no-op mutations on
                                // subsequent timeline ticks once already cleared.
                                guard !stableNearestArrivals.isEmpty else { return }
                                stableNearestArrivals = []
                                lastStableRefreshDate = .now
                            }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(Array(orderedChips.enumerated()), id: \.element.arrival.id) { index, pair in
                                    arrivalCard(arrival: pair.arrival, index: index, eta: pair.eta)
                                }
                            }
                            .padding(.horizontal, AppTheme.Layout.margin)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Scheduled Departures (Unified: Bus + Train)

    /// Scheduled departures matching the currently selected direction.
    /// Combines bus schedule data and train GTFS data into a unified list.
    /// Filters to future departures only and sorts by time.
    private var scheduledDeparturesForCurrentDirection: [ScheduledItem] {
        let direction = safeDirection

        // --- Bus schedule ---
        if group.isBus, let schedule = busSchedule {
            let dirLower = direction.direction.lowercased()
            let matched =
                schedule.directions.first { schedDir in
                    schedDir.direction.lowercased() == dirLower
                        || schedDir.headsign.lowercased().contains(dirLower)
                        || dirLower.contains(schedDir.headsign.lowercased())
                }
                ?? schedule.directions.first { schedDir in
                    schedule.directions.firstIndex(where: { $0.direction == schedDir.direction })
                        == selectedDirectionIndex
                }

            guard let matched else { return [] }
            return matched.departures
                .filter { $0.minutesAway >= 0 }
                .sorted { $0.departureTime < $1.departureTime }
                .map { ScheduledItem.from($0) }
        }

        // --- Train (subway / LIRR / MNR) schedule from cached GTFS arrivals ---
        if !group.isBus && !cachedTrainArrivals.isEmpty {
            let dirLower = direction.direction.lowercased()

            let matching = cachedTrainArrivals.filter { arrival in
                let arrDir = arrival.direction.lowercased()
                let arrDest = arrival.destination?.lowercased() ?? ""
                return arrDir == dirLower
                    || arrDest == dirLower
                    || dirLower.contains(arrDir)
                    || dirLower.contains(arrDest)
                    || arrDest.contains(dirLower)
            }
            .filter { $0.estimatedTime > Date().addingTimeInterval(-30) }
            .sorted { $0.estimatedTime < $1.estimatedTime }

            return matching.map { ScheduledItem.from($0) }
        }

        return []
    }

    /// View showing upcoming scheduled departures when no live vehicles are running.
    /// Greyed-out chips with the scheduled departure time underneath.
    @ViewBuilder
    private var scheduledDeparturesView: some View {
        let departures = scheduledDeparturesForCurrentDirection
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                Text("Scheduled Departures")
                    .font(.custom("Helvetica-Bold", size: 11))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(departures) { departure in
                        VStack(spacing: 6) {
                            Text("\(departure.minutesAway)")
                                .font(.custom("Helvetica-Bold", size: 30))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))

                            Text("min")
                                .font(.custom("Helvetica-Bold", size: 12))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))

                            // Show the actual clock time
                            Text(departure.formattedTime)
                                .font(.custom("Helvetica-Bold", size: 10))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(AppTheme.Colors.textSecondary.opacity(0.08))
                                .clipShape(Capsule())
                        }
                        .frame(width: 80)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(AppTheme.Colors.cardBackground.opacity(0.6))
                                .shadow(color: .black.opacity(0.02), radius: 4, x: 0, y: 2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(
                                    AppTheme.Colors.textSecondary.opacity(0.1), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.vertical, 2)
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
                    // Reorder pills so the selected direction is always first —
                    // gives a nice visual bump when the user taps a pill, and
                    // keeps the active direction front-and-center without scrolling.
                    let orderedDirs: [(index: Int, dir: DirectionArrivalsResponse)] = {
                        let all = group.directions.enumerated().map { (index: $0.offset, dir: $0.element) }
                        guard selectedDirectionIndex >= 0,
                              selectedDirectionIndex < group.directions.count else {
                            return all
                        }
                        var result = all
                        if let pos = result.firstIndex(where: { $0.index == selectedDirectionIndex }) {
                            let selected = result.remove(at: pos)
                            result.insert(selected, at: 0)
                        }
                        return result
                    }()

                    ForEach(orderedDirs, id: \.dir.id) { index, dir in
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selectedDirectionIndex = index
                                lockedDirectionHeadsign = dir.direction
                            }
                        } label: {
                            // Use the shared direction label resolver —
                            // always shows the terminal/last stop name,
                            // consistent with the header subtitle.
                            let matchedDir = routeShape?.matchedDirection(
                                index: index,
                                name: dir.direction
                            )
                            let dirServiceType = matchedDir?.serviceType
                            let rawLabel = resolvedDirectionLabel(for: dir, at: index)
                            // Truncate long labels to keep pills compact
                            let label =
                                rawLabel.count > 24 ? String(rawLabel.prefix(22)) + "…" : rawLabel
                            let isActive = selectedDirectionIndex == index

                            HStack(spacing: 6) {
                                // Direction arrow icon
                                Image(
                                    systemName: directionIcon(
                                        for: index, total: group.directions.count)
                                )
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(isActive ? .white : routeColor)

                                // Direction label
                                Text(label)
                                    .font(.custom("Helvetica-Bold", size: 13))
                                    .foregroundColor(
                                        isActive ? .white : AppTheme.Colors.textPrimary
                                    )
                                    .lineLimit(1)

                                // Express / Local badge per direction
                                if let sType = dirServiceType, !sType.isEmpty {
                                    let badgeLabel = sType.lowercased() == "express" ? "Exp"
                                        : sType.lowercased() == "local" ? "Lcl"
                                        : sType.lowercased() == "mixed" ? "Exp/Lcl"
                                        : sType.prefix(3).capitalized
                                    let badgeColor: Color = sType.lowercased() == "express"
                                        ? AppTheme.Colors.successGreen
                                        : sType.lowercased() == "mixed"
                                            ? AppTheme.Colors.warningYellow
                                            : AppTheme.Colors.textSecondary
                                    Text(badgeLabel)
                                        .font(.custom("Helvetica-Bold", size: 9))
                                        .foregroundColor(isActive ? badgeColor : badgeColor)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(
                                            isActive
                                                ? Color.white.opacity(0.85)
                                                : badgeColor.opacity(0.12)
                                        )
                                        .clipShape(Capsule())
                                }

                                // Vehicle count badge
                                // Show unique vehicle count (not per-stop arrival count)
                                // so the badge reflects how many distinct buses/trains
                                // are running in this direction — matching what the user
                                // sees on the map.
                                // Uses cached count to avoid recomputing on every body
                                // evaluation (1 Hz interpolation tick).
                                let vehicleCount = directionBadgeCounts[dir.id] ?? 0
                                if vehicleCount > 0 {
                                    Text("\(vehicleCount)")
                                        .font(.custom("Helvetica-Bold", size: 11))
                                        .foregroundColor(isActive ? routeColor : .white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            isActive ? Color.white.opacity(0.9) : routeColor
                                        )
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
                                    .stroke(
                                        isActive ? Color.clear : routeColor.opacity(0.2),
                                        lineWidth: 1)
                            )
                            .shadow(
                                color: isActive ? routeColor.opacity(0.3) : .clear, radius: 4, x: 0,
                                y: 2)
                        }
                        .accessibilityLabel(
                            "\(resolvedDirectionLabel(for: dir, at: index)), \(directionBadgeCounts[dir.id] ?? 0) vehicles"
                        )
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
    }

    /// Refreshes the cached badge counts for all direction pills.
    /// Called on appear and whenever `group` changes from a backend poll.
    private func refreshDirectionBadgeCounts() {
        var counts: [String: Int] = [:]
        for dir in group.directions {
            counts[dir.id] = dir.uniqueVehicleCount
        }
        directionBadgeCounts = counts
    }

    /// Rebuilds the per-stop arrival lookup used by the Stops tab.
    /// Called on appear, group change, and direction change.
    private func refreshArrivalByStopCache() {
        let allArrivals = safeDirection.liveArrivals
        var lookup: [String: NearbyTransitResponse] = [:]
        for a in allArrivals {
            if let sid = a.stopId, !sid.isEmpty {
                let key = normalizeStopId(sid)
                if lookup[key] == nil { lookup[key] = a }
                if lookup[sid] == nil { lookup[sid] = a }
            }
            let nameKey = a.stopName.lowercased().trimmingCharacters(in: .whitespaces)
            if lookup[nameKey] == nil { lookup[nameKey] = a }
        }
        cachedArrivalByStop = lookup
        // Also update the departure badge count while we have fresh data.
        cachedDepartureCount = prioritizedArrivals.count
    }

    /// Returns an appropriate SF Symbol arrow for the direction index.
    /// Supports up to 16 unique icons; wraps safely for any number of directions.
    private func directionIcon(for index: Int, total: Int) -> String {
        if total <= 2 {
            return index == 0 ? "arrow.up" : "arrow.down"
        }
        // For 3+ directions, cycle through a large set of directional icons.
        // 16 unique icons covers most realistic scenarios; wraps for even more.
        let icons = [
            "arrow.up", "arrow.down", "arrow.left", "arrow.right",
            "arrow.up.right", "arrow.down.left", "arrow.up.left", "arrow.down.right",
            "arrow.turn.up.right", "arrow.turn.down.left",
            "arrow.turn.up.left", "arrow.turn.down.right",
            "arrow.uturn.up", "arrow.uturn.down",
            "arrow.uturn.left", "arrow.uturn.right",
        ]
        return icons[index % icons.count]
    }

    /// Reusable service-type badge (Express / Local / Mixed) for the header.
    @ViewBuilder
    private func serviceTypeBadge(_ serviceType: String) -> some View {
        let (label, icon, color): (String, String, Color) = {
            switch serviceType.lowercased() {
            case "express":
                return ("Express", "bolt.fill", AppTheme.Colors.successGreen)
            case "local":
                return ("Local", "circle.fill", AppTheme.Colors.textSecondary)
            case "mixed":
                return ("Express/Local", "bolt.horizontal.fill", AppTheme.Colors.warningYellow)
            default:
                return (serviceType.capitalized, "tram.fill", AppTheme.Colors.textSecondary)
            }
        }()
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 7, weight: .bold))
            Text(label)
                .font(.custom("Helvetica-Bold", size: 10))
                .textCase(.uppercase)
                .tracking(0.8)
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }

    // MARK: - Departures Board

    private var arrivalsList: some View {
        // When a stop was tapped in the stops list, filter to that stop only.
        // Otherwise fall back to prioritizedArrivals (nearest stop).
        let allArrivals = safeDirection.liveArrivals
        let baseArrivals: [NearbyTransitResponse] = {
            if let sid = inSheetSelectedStopId, !sid.isEmpty {
                let filtered = allArrivals.filter {
                    ($0.stopId == sid) || ($0.stopName == sid)
                }
                return filtered.isEmpty ? allArrivals : filtered
            }
            return prioritizedArrivals
        }()

        // Reorder so the tapped vehicle appears first
        let sortedArrivals: [NearbyTransitResponse] = {
            guard let tapped = tappedVehicleId, !tapped.isEmpty else { return baseArrivals }
            var arr = baseArrivals
            if let idx = arr.firstIndex(where: { $0.vehicleId == tapped || $0.tripId == tapped }) {
                arr.insert(arr.remove(at: idx), at: 0)
            }
            return arr
        }()

        // Resolve stop name label for filter chip
        let selectedStopName: String? = {
            guard let sid = inSheetSelectedStopId else { return nil }
            return baseArrivals.first?.stopName ?? sid
        }()

        // ── DEBUG: log every render of the departures list ──
        #if DEBUG
        let _debugArrivals = sortedArrivals
        let _debugMode = group.isBus ? "BUS" : group.isLIRR ? "LIRR" : group.isMNR ? "MNR" : "SUBWAY"
        let _debugDir = safeDirection.directionLabel ?? safeDirection.direction
        let _debugLines = _debugArrivals.enumerated().map { (i, a) -> String in
            let vid = a.vehicleId ?? a.tripId ?? "?"
            let status = a.isScheduledOnly ? "SCHED" : "LIVE"
            let stop = a.stopName
            return "  #\(i+1) \(a.minutesAway)min  \(status)  id=\(vid.suffix(8))  stop=\(stop)"
        }
        let _ = {
            print("[ROUTE_DETAIL] \(_debugMode) \(group.displayName) → \(_debugDir)  (\(_debugArrivals.count) arrivals)")
            for line in _debugLines { print(line) }
            if _debugArrivals.isEmpty { print("  <no arrivals>") }
        }()
        #endif

        return VStack(alignment: .leading, spacing: 10) {
            // ── Header ───────────────────────────────────────────────────────
            HStack(spacing: 8) {
                Text("Departures")
                    .font(.custom("Helvetica-Bold", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                // Active stop filter pill with clear button
                if let name = selectedStopName {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin")
                            .font(.system(size: 9, weight: .bold))
                        Text(name)
                            .font(.custom("Helvetica-Bold", size: 10))
                            .lineLimit(1)
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                inSheetSelectedStopId = nil
                                onStopSelected?(nil)
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .foregroundColor(routeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(routeColor.opacity(0.12))
                    .clipShape(Capsule())
                }

                Spacer()

                if !sortedArrivals.isEmpty {
                    Text("\(sortedArrivals.count) upcoming")
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            if sortedArrivals.isEmpty {
                // Still fetching → show skeleton rows so sheet isn't blank
                if isLoadingArrivals {
                    ArrivalRowSkeleton(count: 4)
                } else if liveVehicleCount > 0 {
                    // Vehicles are on the map for this route, just no arrival data at this stop
                    VStack(spacing: 8) {
                        Image(systemName: group.isBus ? "bus.fill" : "tram.fill")
                            .font(.system(size: 32, weight: .light))
                            .foregroundColor(routeColor.opacity(0.5))
                        Text("\(liveVehicleCount) vehicle\(liveVehicleCount == 1 ? "" : "s") en route")
                            .font(.custom("Helvetica-Bold", size: 14))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                        Text("No predicted arrivals at your stop yet")
                            .font(.custom("Helvetica", size: 13))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .background(AppTheme.Colors.cardBackground)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
                    .padding(.horizontal, AppTheme.Layout.margin)
                } else if !scheduledDeparturesForCurrentDirection.isEmpty {
                    scheduledDeparturesView
                } else {
                    // Empty state — matches HomeView's emptyStateView pattern
                    VStack(spacing: 10) {
                        Image(
                            systemName: group.isCommuterRail
                                ? "train.side.front.car" : group.isBus ? "bus.fill" : "tram.fill"
                        )
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
                }
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 8) {
                        ForEach(Array(sortedArrivals.enumerated()), id: \.element.id) {
                            index, arrival in
                            arrivalRowView(arrival: arrival, index: index, in: sortedArrivals)
                        }

                        // ── Upcoming scheduled departures after live rows ────
                        // So the user always sees a full departure board, not
                        // just the 2-3 buses currently in the SIRI feed.
                        if !scheduledDeparturesForCurrentDirection.isEmpty {
                            scheduledDeparturesView
                                .padding(.top, 8)
                        }
                    }
                    .onChange(of: tappedVehicleId) { _, newValue in
                        guard let newValue, !newValue.isEmpty else { return }
                        // Find the matching arrival and scroll to it
                        if let match = sortedArrivals.first(where: {
                            $0.vehicleId == newValue || $0.tripId == newValue
                        }) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                expandedArrivalID = match.id
                                proxy.scrollTo(match.id, anchor: .top)
                            }
                        }
                    }
                    // Clear the expanded row whenever the direction tab changes —
                    // guards against stale IDs matching rows in the new direction.
                    .onChange(of: selectedDirectionIndex) { _, _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            expandedArrivalID = nil
                        }
                    }
                    // Auto-clear the stop-origin highlight after 1.5 s
                    .task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.easeOut(duration: 0.4)) {
                            stopHighlightActive = false
                        }
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
                            selectedDirectionIndex = min(
                                selectedDirectionIndex + 1,
                                group.directions.count - 1)
                        } else if value.translation.width > 0 {
                            selectedDirectionIndex = max(selectedDirectionIndex - 1, 0)
                        }
                    }
                }
        )
        .accessibilityHint(
            group.directions.count > 1 ? "Swipe left or right to switch direction" : "")
    }

    @ViewBuilder
    private func arrivalRowView(
        arrival: NearbyTransitResponse,
        index: Int,
        in sortedArrivals: [NearbyTransitResponse]
    ) -> some View {
        let isFirstAtStop = stopHighlightActive
            && selectedStopId != nil
            && arrival.stopId == selectedStopId
            && !sortedArrivals.prefix(index).contains(where: { $0.stopId == selectedStopId })

        let thisIsTracking = isTracking?(arrival) ?? false

        NearbyTransitRow(
            arrival: arrival,
            isTracking: thisIsTracking,
            isTrackingAnother: !thisIsTracking && isTrackingAny,
            isSelected: isFirstAtStop,
            isLiveOnMap: isLiveOnMap?(arrival) ?? false,
            tappedVehicleId: tappedVehicleId,
            onTrack: {
                onTrack?(arrival)
            },
            onSelectRoute: nil,
            onClearHighlight: {
                onClearHighlight?()
            },
            onFocusVehicle: { key in
                onFocusVehicle?(key)
            },
            userLocation: currentLocation.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
            },
            smartETAProvider: { smartETA(for: $0) },
            isExpanded: expandedArrivalID == arrival.id,
            onExpand: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    if expandedArrivalID == arrival.id {
                        expandedArrivalID = nil
                        // Collapse -> clear map highlight
                        onFocusVehicle?(nil)
                    } else {
                        expandedArrivalID = arrival.id
                        // Expand -> focus map if live
                        if isLiveOnMap?(arrival) ?? false {
                            onFocusVehicle?(arrival.vehicleId ?? arrival.tripId)
                        }
                    }
                }
            }
        )
        .id(arrival.id)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(arrivalAccessibilityLabel(for: arrival))
    }

    private func arrivalAccessibilityLabel(for arrival: NearbyTransitResponse) -> String {
        let eta = smartETA(for: arrival)
        let etaText = (eta.isAtStop || eta.secondsRemaining <= 30)
            ? "Now" : "\(eta.minutesRemaining) minutes"
        return "\(arrival.stopName), \(etaText), \(arrival.status)"
    }

    // MARK: - Content Tab Picker

    /// Horizontal pill-style picker for Stops / Departures / Alerts tabs.
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
                                    .background(
                                        isActive
                                            ? Color.white.opacity(0.9)
                                            : AppTheme.Colors.warningYellow
                                    )
                                    .clipShape(Capsule())
                            }

                            // Badge: stop count on Stops tab
                            if tab == .stops {
                                let stopCount = routeShape?.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName).count ?? 0
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

                            // Badge: departure count on Departures tab
                            // Uses cached count to avoid calling expensive
                            // `prioritizedArrivals` on every body evaluation.
                            if tab == .departures {
                                let depCount = cachedDepartureCount
                                if depCount > 0 {
                                    let label = depCount > 99 ? "99+" : "\(depCount)"
                                    Text(label)
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
                                .stroke(
                                    isActive ? Color.clear : routeColor.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(
                            color: isActive ? routeColor.opacity(0.3) : .clear, radius: 4, x: 0,
                            y: 2)
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
        case .stops: return "mappin.and.ellipse"
        case .departures: return "arrow.up.right.circle.fill"
        case .alerts: return "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Stops List

    /// Index of the "current" stop in the direction's stop list.
    /// Priority: 1) selectedStopId match  2) nearest stop to currentLocation/searchCenter  3) nil
    private func currentStopIndex(in dirStops: [BusStop]) -> Int? {
        // 1. Explicit stop selection from map tap
        if let sid = selectedStopId, !sid.isEmpty {
            let normalized = normalizeStopId(sid)
            if let idx = dirStops.firstIndex(where: {
                normalizeStopId($0.id) == normalized
            }) { return idx }
        }
        // 2. Nearest stop to the reference coordinate
        let refCoord = currentLocation ?? searchCenter
        guard let ref = refCoord else { return nil }
        let refLoc = CLLocation(latitude: ref.latitude, longitude: ref.longitude)
        var bestIdx: Int? = nil
        var bestDist: CLLocationDistance = .greatestFiniteMagnitude
        for (i, stop) in dirStops.enumerated() {
            let d = refLoc.distance(from: CLLocation(latitude: stop.lat, longitude: stop.lon))
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return bestIdx
    }

    /// List of all stops for the current direction.
    /// Tapping a stop sets `inSheetSelectedStopId` and switches to the Departures tab.
    private var stopsListSection: some View {
        let dirStops: [BusStop] = routeShape?.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName) ?? []
        let currentIdx = currentStopIndex(in: dirStops)

        // Use the cached per-stop arrival lookup (rebuilt on group/direction change)
        // to avoid recomputing `liveArrivals` on every 1 Hz interpolation tick.
        let arrivalByStop = cachedArrivalByStop

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
                if routeShape == nil {
                    StopsListSkeleton()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "mappin.slash")
                            .font(.system(size: 32, weight: .light))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                        Text("No stops for this direction")
                            .font(.custom("Helvetica", size: 15))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(AppTheme.Colors.cardBackground)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
                    .padding(.horizontal, AppTheme.Layout.margin)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(dirStops.enumerated()), id: \.element.id) { index, stop in
                            let isPassed = currentIdx.map { index < $0 } ?? false
                            let isCurrent = currentIdx == index
                            let isSelected = inSheetSelectedStopId == stop.id

                            // Resolve the next arriving bus for this specific stop
                            let normId = normalizeStopId(stop.id)
                            let nextArrival: NearbyTransitResponse? =
                                arrivalByStop[normId]
                                ?? arrivalByStop[stop.id]
                                ?? arrivalByStop[stop.name.lowercased().trimmingCharacters(in: .whitespaces)]

                                stopRow(stop, index: index, total: dirStops.count,
                                    isCurrent: isCurrent, isPassed: isPassed,
                                    isSelected: isSelected, nextArrival: nextArrival)
                                .opacity(isPassed ? 0.38 : 1.0)
                                // Tap: filter Departures to this stop
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        if inSheetSelectedStopId == stop.id {
                                            inSheetSelectedStopId = nil
                                            onStopSelected?(nil)
                                        } else {
                                            inSheetSelectedStopId = stop.id
                                            selectedTab = .departures
                                            // Update the map's behind/ahead polyline split
                                            // to anchor at this stop's location.
                                            onStopSelected?(CLLocationCoordinate2D(
                                                latitude: stop.lat, longitude: stop.lon))
                                        }
                                    }
                                    HapticManager.impact(.light)
                                }

                        if index < dirStops.count - 1 {
                            HStack(spacing: 0) {
                                Spacer().frame(width: 27)
                                Rectangle()
                                    .fill((isPassed ? AppTheme.Colors.textSecondary : routeColor)
                                        .opacity(isPassed ? 0.12 : 0.25))
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
                .onChange(of: selectedDirectionIndex) { _, _ in
                    // Clear stop filter when direction changes
                    inSheetSelectedStopId = nil
                    onStopSelected?(nil)
                }
            }
        }
    }

    /// A single stop row with transfer line badges and accessibility warnings.
    private func stopRow(_ stop: BusStop, index: Int, total: Int,
                         isCurrent: Bool = false, isPassed: Bool = false,
                         isSelected: Bool = false,
                         nextArrival: NearbyTransitResponse? = nil) -> some View {
        let transfers = transferRoutes(for: stop)
        let outages = accessibilityOutages(at: stop)
        let isFirst = index == 0
        let isLast = index == total - 1
        let dotColor = isCurrent ? routeColor : (isPassed ? AppTheme.Colors.textSecondary.opacity(0.4) : routeColor)

        return HStack(alignment: .center, spacing: 12) {
            // Stop dot
            ZStack {
                if isCurrent {
                    // Pulsing outer ring for the current stop
                    Circle()
                        .fill(routeColor.opacity(0.2))
                        .frame(width: 22, height: 22)
                }
                Circle()
                    .fill(dotColor)
                    .frame(
                        width: (isCurrent || isFirst || isLast) ? 14 : 10,
                        height: (isCurrent || isFirst || isLast) ? 14 : 10)
                if isCurrent || isFirst || isLast {
                    Circle()
                        .fill(isCurrent ? Color.white : Color.white)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(stop.name)
                        .font(.custom(isCurrent ? "Helvetica-Bold" : "Helvetica-Bold", size: 14))
                        .foregroundColor(isCurrent ? routeColor : AppTheme.Colors.textPrimary)
                        .lineLimit(1)

                    if isCurrent {
                        Text("HERE")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(routeColor)
                            .clipShape(Capsule())
                    }

                    // Elevator/escalator outage warning
                    if !outages.isEmpty {
                        let isElevator = outages.contains { $0.equipmentType.lowercased().contains("elevator") }
                        Image(systemName: isElevator ? "arrow.up.arrow.down.circle.fill" : "stairs")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.alertRed)
                            .help(outages.first?.description ?? "Accessibility outage")
                    }
                }

                // Transfer badges — subway + bus
                if !transfers.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.swap")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.textSecondary)

                            ForEach(transfers, id: \.self) { route in
                                RouteBadge(
                                    routeID: route,
                                    size: .custom(20, 10))
                            }
                        }
                    }
                }
            }

            Spacer()

            // ── Arrival time column ───────────────────────────────────────
            if let arrival = nextArrival, !arrival.isPlaceholder {
                VStack(alignment: .trailing, spacing: 2) {
                    if arrival.minutesAway <= 0 {
                        Text("Now")
                            .font(.custom("Helvetica-Bold", size: 13))
                            .foregroundColor(AppTheme.Colors.successGreen)
                    } else {
                        HStack(spacing: 3) {
                            if !arrival.isScheduledOnly {
                                Circle()
                                    .fill(AppTheme.Colors.successGreen)
                                    .frame(width: 5, height: 5)
                            }
                            Text("\(arrival.minutesAway)m")
                                .font(.custom("Helvetica-Bold", size: 13))
                                .foregroundColor(
                                    isPassed
                                    ? AppTheme.Colors.textSecondary.opacity(0.35)
                                    : (arrival.isScheduledOnly
                                       ? AppTheme.Colors.textSecondary
                                       : routeColor)
                                )
                        }
                        if let ts = arrival.arrivalTs {
                            Text(Date(timeIntervalSince1970: Double(ts)), style: .time)
                                .font(.custom("Helvetica", size: 10))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(isPassed ? 0.3 : 0.55))
                        }
                    }
                }
            } else {
                Text("\(index + 1)")
                    .font(.custom("Helvetica", size: 11))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(isPassed ? 0.25 : 0.5))
            }
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 8)
        // Show subtle route-colored highlight when this stop is the active Departures filter
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? routeColor.opacity(0.09) : Color.clear)
                .padding(.horizontal, 4)
        )
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    /// Finds transfer routes at a given stop.
    ///
    /// Two sources:
    /// 1. **Subway stations** — matched by name/proximity from `cachedStations`.
    /// 2. **Bus routes** — pulled directly from `stop.routeIds` (set by the backend
    ///    for stops fetched from /bus/nearby; often nil for shape-derived stops).
    ///
    /// Returns a deduplicated, sorted list of route display names (badges).
    private func transferRoutes(for stop: BusStop) -> [String] {
        let currentRoute = group.displayName
        var routes = Set<String>()

        // ── 1. Subway station matches ──
        if !cachedStations.isEmpty {
            let stopName = stop.name.lowercased().trimmingCharacters(in: .whitespaces)

            // Exact name match
            if let match = cachedStations.first(where: {
                $0.name.lowercased().trimmingCharacters(in: .whitespaces) == stopName
            }) {
                for r in match.routes where r != currentRoute { routes.insert(r) }
            } else {
                // Proximity match (~100 m)
                let stopCoord = CLLocation(latitude: stop.lat, longitude: stop.lon)
                let nearbyStations = cachedStations.filter { station in
                    let loc = CLLocation(
                        latitude: station.coordinate.latitude,
                        longitude: station.coordinate.longitude)
                    return stopCoord.distance(from: loc) <= 100
                }
                for station in nearbyStations {
                    for r in station.routes where r != currentRoute { routes.insert(r) }
                }
            }
        }

        // ── 2. Bus route IDs served at this stop (from shape/nearby data) ──
        if let routeIds = stop.routeIds {
            for rawId in routeIds {
                let display = BranchNames.resolveDisplayName(routeId: rawId, mode: "bus")
                if display != currentRoute && !display.isEmpty {
                    routes.insert(display)
                }
            }
        }

        // ── 3. Fallback: nearby/name-matched shape stops (captures bus transfers
        // when the current stop row itself has nil routeIds) ──
        if let shape = routeShape {
            let here = CLLocation(latitude: stop.lat, longitude: stop.lon)
            let stopNameKey = stop.name.lowercased().trimmingCharacters(in: .whitespaces)
            for direction in shape.directions {
                for candidate in direction.stops {
                    guard let candidateRouteIds = candidate.routeIds, !candidateRouteIds.isEmpty else {
                        continue
                    }
                    let candidateLoc = CLLocation(latitude: candidate.lat, longitude: candidate.lon)
                    let isNearby = here.distance(from: candidateLoc) <= 80
                    let isSameName = candidate.name.lowercased().trimmingCharacters(in: .whitespaces) == stopNameKey
                    guard isNearby || isSameName else { continue }

                    for rawId in candidateRouteIds {
                        let display = BranchNames.resolveDisplayName(routeId: rawId, mode: "bus")
                        if display != currentRoute && !display.isEmpty {
                            routes.insert(display)
                        }
                    }
                }
            }
        }

        return routes.sorted()
    }

    /// Returns true when this stop has an active elevator or escalator outage.
    private func hasAccessibilityOutage(at stop: BusStop) -> Bool {
        guard !elevatorOutages.isEmpty else { return false }
        let name = stop.name.lowercased()
        return elevatorOutages.contains { outage in
            let station = outage.station.lowercased()
            return name == station || name.contains(station) || station.contains(name)
        }
    }

    /// Returns the outage descriptions for a stop, for tooltip/accessibility label.
    private func accessibilityOutages(at stop: BusStop) -> [ElevatorStatus] {
        guard !elevatorOutages.isEmpty else { return [] }
        let name = stop.name.lowercased()
        return elevatorOutages.filter { outage in
            let station = outage.station.lowercased()
            return name == station || name.contains(station) || station.contains(name)
        }
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

    /// Lightweight alert banner built from the backend's inline `InlineAlertResponse`.
    /// Used as a fallback when the full `serviceAlerts` array hasn't loaded yet
    /// but the grouped response already includes alert data.
    private func inlineAlertBanner(_ alert: InlineAlertResponse) -> some View {
        let isSevere = alert.severity == "severe"
        let bannerColor = isSevere ? AppTheme.Colors.alertRed : AppTheme.Colors.warningYellow

        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)

            Text(alert.title)
                .font(.custom("Helvetica-Bold", size: 12))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            if group.alerts.count > 1 {
                Text("+\(group.alerts.count - 1)")
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

    // MARK: - Route Alerts Section

    // MARK: - Loading Skeletons

    /// Shimmer placeholder for the alert banner while arrivals are in-flight.
    private var alertBannerSkeleton: some View {
        HStack(spacing: 10) {
            SkeletonBar(width: 14, height: 14, opacity: 0.12)
            SkeletonBar(width: 200, height: 14, opacity: 0.10)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        )
        .padding(.horizontal, AppTheme.Layout.margin)
        .shimmer()
    }

    /// Shimmer placeholder for direction pills while shape / arrivals load.
    private var directionPickerSkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonBar(width: 70, height: 12, opacity: 0.08)
                .padding(.horizontal, AppTheme.Layout.margin)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Two pill placeholders
                    ForEach([CGFloat(110), 90], id: \.self) { width in
                        SkeletonBar(width: width, height: 40, opacity: 0.10)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
        .shimmer()
    }

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
        let shape = routeShape
        let hasStops = shape?.stops.isEmpty == false
        let hasVehicles = liveVehicleCount > 0
        let isShapeLoading = shape == nil

        if isShapeLoading {
            // Shape still loading — show shimmer placeholders
            return AnyView(RouteInfoFooterSkeleton())
        } else if hasStops || hasVehicles {
            return AnyView(
                HStack(spacing: 16) {
                    if let shape, hasStops {
                        let dirStops = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
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
                                Text(
                                    Date(timeIntervalSince1970: TimeInterval(ts)), style: .relative)
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
                            stopLat: 40.72, stopLon: -74.0,
                            arrivalTs: Int(Date().timeIntervalSince1970 + 180),
                            vehicleId: "V123", tripId: "T456", stopId: "A32"
                        ),
                        NearbyTransitResponse(
                            routeId: "A", stopName: "14 St", direction: "N",
                            destination: "Inwood-207 St",
                            minutesAway: 8, status: "On Time", mode: "subway",
                            stopLat: 40.74, stopLon: -74.0,
                            arrivalTs: Int(Date().timeIntervalSince1970 + 480),
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
                            stopLat: 40.71, stopLon: -74.01,
                            arrivalTs: Int(Date().timeIntervalSince1970 + 300),
                            vehicleId: "V125", tripId: "T458", stopId: "A34"
                        )
                    ]
                ),
            ]
        ),
        busVehicles: .constant([]),
        routeShape: .constant(nil),
        selectedDirectionIndex: .constant(0)
    )
}
