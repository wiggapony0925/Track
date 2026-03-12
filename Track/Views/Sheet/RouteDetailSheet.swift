//
//  RouteDetailSheet.swift
//  Track
//
//  Route detail view presented when tapping a grouped route card.
//  Uses the same AppTheme design system, RouteBadge, and card layout
//  patterns as the rest of the app. No separate map — the MAIN map
//  behind this sheet draws the route polylines and live vehicles.
//

import CoreLocation
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
    @Binding var cameraPosition: TrackCameraPosition
    var currentLocation: CLLocationCoordinate2D?
    /// When the user has dragged the search pin, this is the pin's coordinate.
    /// Used as the reference point for nearest-stop filtering when GPS is unavailable.
    var searchCenter: CLLocationCoordinate2D?
    var selectedStopId: String?
    /// True when the user explicitly tapped a stop (map dot or stops list).
    /// When false, `selectedStopId` changes come from auto-nearest GPS
    /// and should NOT override chip filtering.
    var isStopManuallySelected: Bool = false

    /// Number of live vehicles (buses or trains) filtered by the current direction.
    /// Provided by the ViewModel's `filteredBusVehicles` / `filteredTrainVehicles`
    /// to avoid duplicating direction-filtering logic here.
    var liveVehicleCount: Int = 0
    /// Active elevator/escalator outages — used to badge stops with accessibility warnings.
    var elevatorOutages: [ElevatorStatus] = []

    // MARK: - Debug log dedup keys (prevent computed-property spam)
    // Computed properties like `nearestStopArrivals` re-evaluate on every
    // SwiftUI body pass (~60 Hz).  These static keys ensure each diagnostic
    // print fires only when the actual content changes.
    #if DEBUG
    nonisolated(unsafe) private static var _lastStopTapLog = ""
    nonisolated(unsafe) private static var _lastChipsLog = ""
    nonisolated(unsafe) private static var _lastSchedMatchLog = ""
    nonisolated(unsafe) private static var _lastChipsSchedLog = ""
    #endif

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

    /// True when an API poll arrived while a chip was selected and we
    /// deferred the `stableNearestArrivals` refresh to avoid visual
    /// disruption.  Cleared when the chip is deselected.
    @State private var chipRefreshDeferred = false

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
        cameraPosition: Binding<TrackCameraPosition> = .constant(.automatic),
        currentLocation: CLLocationCoordinate2D? = nil,
        searchCenter: CLLocationCoordinate2D? = nil,
        selectedStopId: String? = nil,
        isStopManuallySelected: Bool = false,
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
        self.isStopManuallySelected = isStopManuallySelected
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

    // MARK: - Body Sub-Views (broken out for type-checker)

    @ViewBuilder
    private var alertBannerContent: some View {
        if let topAlert = routeAlerts.first {
            routeAlertBanner(topAlert)
        } else if let inlineAlert = group.alerts.first {
            inlineAlertBanner(inlineAlert)
        } else if isLoadingArrivals {
            alertBannerSkeleton
        }
    }

    @ViewBuilder
    private var directionPickerContent: some View {
        if group.directions.count > 1 {
            directionPicker
        } else if isLoadingArrivals {
            directionPickerSkeleton
        }
    }

    @ViewBuilder
    private var tabContent: some View {
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
    }

    var body: some View {
        bodyWithAlert
    }

    private var bodyWithAlert: some View {
        bodyWithObservers
            .alert("Sign In to Save Favorites", isPresented: $showSignInPrompt) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Create a free account to save your favorite routes and access them across all your devices.")
            }
    }

    private var bodyWithObservers: some View {
        bodyWithLifecycle
            .onChange(of: busSchedule) { _, _ in handleScheduleChange() }
            .onChange(of: cachedTrainArrivals) { _, _ in handleScheduleChange() }
            .onChange(of: favoritesManager.favorites) { _, _ in handleFavoritesChange() }
            .onChange(of: selectedStopId) { _, newId in handleMapStopTap(newId) }
            .onChange(of: inSheetSelectedStopId) { _, _ in handleStopSelectionChange() }
            .onChange(of: selectedDirectionIndex) { _, _ in handleDirectionChange() }
            .onChange(of: selectedChipId) { _, newId in handleChipSelectionChange(newId) }
    }

    private var bodyWithLifecycle: some View {
        bodyContent
            .background(AppTheme.Colors.background)
            .onAppear(perform: handleOnAppear)
            .onChange(of: group) { _, _ in handleGroupChange() }
            .task(id: group.id) { await handleLoadingTimeout() }
    }

    // MARK: - Body Content

    private var bodyContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // ── Hero section: header + alert + countdown ──
                routeHeader
                    .padding(.bottom, 12)

                alertBannerContent
                    .padding(.bottom, 14)

                countdownSection
                    .padding(.bottom, 6)

                directionPickerContent
                    .padding(.bottom, 20)

                // ── Thin separator between hero and tab content ──
                Divider()
                    .overlay(routeColor.opacity(0.15))
                    .padding(.horizontal, AppTheme.Layout.margin)
                    .padding(.bottom, 16)

                // ── Tab navigation & content ──
                contentTabPicker
                    .padding(.bottom, 16)

                tabContent
                    .padding(.bottom, 20)

                // ── Footer metadata ──
                routeInfoFooter
                
                Spacer().frame(height: 40)
            }
            .padding(.top, AppTheme.Layout.margin)
        }
    }

    // MARK: - Lifecycle Handlers

    private func handleOnAppear() {
        isFavorited = favoritesManager.isFavorite(routeId: group.routeId, mode: group.mode)
        isLoadingArrivals = safeDirection.arrivals.isEmpty
        stableNearestArrivals = nearestStopArrivals
        lastStableRefreshDate = .distantPast
        refreshDirectionBadgeCounts()
        refreshArrivalByStopCache()
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

    private func handleGroupChange() {
        refreshDirectionBadgeCounts()
        refreshArrivalByStopCache()
        if let locked = lockedDirectionHeadsign,
           !group.directions.contains(where: { $0.direction == locked }) {
            #if DEBUG
            print("[ARRIVAL_DIFF] ⏭ SKIP — locked dir '\(locked)' absent from poll")
            #endif
            return
        }
        if !safeDirection.arrivals.isEmpty {
            withAnimation(.easeOut(duration: 0.3)) {
                isLoadingArrivals = false
            }
        }

        let fresh = nearestStopArrivals
        if lockedStopKeyPerDirection[selectedDirectionIndex] == nil, let first = fresh.first {
            lockedStopKeyPerDirection[selectedDirectionIndex] = first.stopId ?? first.stopName
        }

        // ── Freeze chips while a chip is selected ──────────────────────
        // When the user is interacting with a chip (highlighted vehicle
        // on the map), defer chip-list updates so the strip doesn't
        // visually shift underneath them.  We catch up as soon as the
        // chip is deselected (see handleChipSelectionChange).
        if selectedChipId != nil {
            chipRefreshDeferred = true
            #if DEBUG
            print("[STABLE_CHIPS] ⏸ DEFERRED — chip selected, skipping refresh")
            #endif
            return
        }

        if shouldRefreshStableArrivals(fresh) {
            stableNearestArrivals = fresh
            lastStableRefreshDate = .now
        }

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

    private func handleStopSelectionChange() {
        selectedChipId = nil
        onFocusVehicle?(nil)
        let fresh = nearestStopArrivals
        stableNearestArrivals = fresh
        lastStableRefreshDate = .now
        #if DEBUG
        if let sid = inSheetSelectedStopId {
            let stopName = routeShape?.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
                .first(where: { $0.id == sid })?.name ?? sid
            let etas = fresh.map { "\($0.minutesAway)m(\($0.isRealTime ? "LIVE" : "SCHED"))" }.joined(separator: ",")
            print("[STOP_SELECT] route=\(group.routeId) stop='\(stopName)' id=\(sid) chips=\(fresh.count) etas=[\(etas)]")
        } else {
            print("[STOP_SELECT] route=\(group.routeId) CLEARED → chips=\(fresh.count)")
        }
        #endif
    }

    private func handleDirectionChange() {
        inSheetSelectedStopId = nil
        selectedChipId = nil
        onFocusVehicle?(nil)
        onStopSelected?(nil)
        let freshArrivals = nearestStopArrivals
        stableNearestArrivals = freshArrivals
        lastStableRefreshDate = .distantPast
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

    private func handleScheduleChange() {
        // Don't disrupt chips while user has a chip selected
        guard selectedChipId == nil else {
            chipRefreshDeferred = true
            return
        }
        stableNearestArrivals = nearestStopArrivals
    }

    /// Called when `selectedChipId` changes.  When the user deselects a
    /// chip (value → nil), catch up with any deferred chip refreshes so
    /// the strip shows the latest data.
    private func handleChipSelectionChange(_ newId: String?) {
        guard newId == nil, chipRefreshDeferred else { return }
        chipRefreshDeferred = false
        let fresh = nearestStopArrivals
        if shouldRefreshStableArrivals(fresh) {
            stableNearestArrivals = fresh
            lastStableRefreshDate = .now
        }
    }

    private func handleLoadingTimeout() async {
        try? await Task.sleep(for: .seconds(6))
        withAnimation(.easeOut(duration: 0.3)) {
            isLoadingArrivals = false
        }
    }

    private func handleFavoritesChange() {
        isFavorited = favoritesManager.isFavorite(routeId: group.routeId, mode: group.mode)
    }

    private func handleMapStopTap(_ newId: String?) {
        // Only treat this as a user stop selection when the user explicitly
        // tapped a stop on the map or stops list.  Auto-nearest GPS updates
        // (isStopManuallySelected == false) should NOT override chip filtering
        // — they would force chips to show only arrivals at the nearest shape
        // stop, which for express buses often has NO SIRI predictions, causing
        // a jarring switch from live chips to schedule-only.
        guard isStopManuallySelected else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if let sid = newId, !sid.isEmpty {
                inSheetSelectedStopId = sid
            } else {
                inSheetSelectedStopId = nil
            }
        }
    }

    // MARK: - Header

    private var routeHeader: some View {
        HStack(spacing: 14) {
            // Unified badge with mode-specific styling
            RouteBadge(
                routeID: group.displayName, size: .large, hexColor: group.colorHex, mode: group.mode
            )
            .shadow(color: routeColor.opacity(0.35), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(group.displayName)
                    .font(AppTheme.Typography.sheetTitle)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if group.directions.indices.contains(selectedDirectionIndex) {
                    let dir = group.directions[selectedDirectionIndex]
                    let subtitle = "→ \(resolvedDirectionLabel(for: dir, at: selectedDirectionIndex))"
                    Text(subtitle)
                        .font(AppTheme.Typography.cardSubtitle)
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
                    .background(routeColor.opacity(0.12))
                    .clipShape(Capsule())

                    // Express / Local / Mixed service type (route-level, from GTFS)
                    if let serviceType = routeShape?.serviceType, !serviceType.isEmpty {
                        ServiceTypeBadge(serviceType: serviceType)
                    } else if routeShape == nil && !group.isBus {
                        // Shape loading — show shimmer placeholder for service type
                        SkeletonBar(width: 52, height: 20, opacity: 0.08)
                            .clipShape(Capsule())
                            .shimmer()
                    }
                }
            }

            Spacer()

            // Favorite + Close buttons — frosted circle style
            HStack(spacing: 10) {
                // Map controls (shown when sheet is expanded)
                if isSheetExpanded {
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
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(AppTheme.Colors.cardBackground)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
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
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                            .frame(width: 34, height: 34)
                            .background(AppTheme.Colors.cardBackground)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                    }
                    .accessibilityLabel("Recenter on my location")
                }

                // Heart button
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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isFavorited ? .red : AppTheme.Colors.textSecondary)
                        .symbolEffect(.bounce, value: isFavorited)
                        .frame(width: 34, height: 34)
                        .background(isFavorited ? Color.red.opacity(0.1) : AppTheme.Colors.cardBackground)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                }
                .accessibilityLabel(isFavorited ? "Remove from favorites" : "Add to favorites")

                // Close button
                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(AppTheme.Colors.cardBackground)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
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
        // IMPORTANT: Never fall through to nearest-stop logic when a
        // user explicitly selected a stop.  Showing arrivals from a
        // different stop with the selected stop's name pill is confusing.
        // If no live arrivals match, the empty-state ("No predicted
        // arrivals at your stop yet") is shown, which is correct —
        // and scheduled departures are still appended below.
        if let userStop = inSheetSelectedStopId, !userStop.isEmpty {
            let atSelected = deduped(live.filter { arrivalMatchesStop($0, stopId: userStop) })

            #if DEBUG
            let stopName = routeShape?.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
                .first(where: { $0.id == userStop })?.name ?? userStop
            let etas = atSelected.map { "\($0.minutesAway)m" }.joined(separator: ",")
            let stopTapKey = "\(group.routeId)_\(userStop)_\(atSelected.count)_\(etas)"
            if stopTapKey != Self._lastStopTapLog {
                Self._lastStopTapLog = stopTapKey
                print("[STOP_TAP] route=\(group.routeId) stop=\(stopName) id=\(userStop) liveHits=\(atSelected.count) etas=[\(etas)]")
            }
            #endif

            // Even when no live arrivals match, append scheduled departures
            // so the user still sees upcoming service at the selected stop.
            return appendScheduledDepartures(to: atSelected, direction: safeDirection)
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
        let baseChips = nearestChips.isEmpty ? deduped(elsewhere) : nearestChips

        return appendScheduledDepartures(to: baseChips, direction: safeDirection)
    }

    /// Appends scheduled departures after the given live/base chips.
    /// Shared between user-selected-stop and nearest-stop code paths.
    private func appendScheduledDepartures(
        to baseChips: [NearbyTransitResponse],
        direction: DirectionArrivalsResponse
    ) -> [NearbyTransitResponse] {
        // ── Merge scheduled departures with live arrivals ─────────────
        // Mix live positions with scheduled ones to fill gaps (e.g. untracked buses).
        // Filter out scheduled trips that match known live ones.

        let existingTripIds = Set(baseChips.compactMap(\.tripId))
        let existingTimestamps = Set(baseChips.compactMap(\.arrivalTs))

        let allSchedItems = scheduledDeparturesForCurrentDirection
        
        // Only ignore scheduled items that are significantly in the past (-2 mins),
        // but ALLOW them even if they are before the latest live bus.
        // This fixes "missing" ghost buses that are scheduled but not tracking.
        let nowTs = Date().timeIntervalSince1970
        let schedItems = allSchedItems
            .filter { $0.departureDate.timeIntervalSince1970 > (nowTs - 120) }

        #if DEBUG
        do {
            let schedLogKey = "\(group.routeId)_\(direction.direction.prefix(30))_\(allSchedItems.count)_\(schedItems.count)_\(busSchedule != nil)"
            if schedLogKey != Self._lastChipsSchedLog {
                Self._lastChipsSchedLog = schedLogKey
                if allSchedItems.isEmpty {
                    print("[CHIPS_SCHED] route=\(group.routeId) dir=\(direction.direction.prefix(30))  scheduledDeparturesForCurrentDirection is EMPTY — busSchedule=\(busSchedule != nil ? "loaded" : "nil") cachedTrainArrivals=\(cachedTrainArrivals.count)")
                }
            }
        }
        #endif

        var schedChips: [NearbyTransitResponse] = []
        for item in schedItems {
            let ts = Int(item.departureDate.timeIntervalSince1970)
            if existingTripIds.contains(item.id) { continue }
            // Don't filter by timestamp exact match too aggressively, just trip IDs.
            // But if we have no trip ID, timestamp collision check is useful.
            if existingTimestamps.contains(ts) { continue }
            
            schedChips.append(NearbyTransitResponse(
                routeId: group.routeId,
                stopName: item.stopName,
                direction: direction.direction,
                destination: item.headsign,
                minutesAway: item.minutesAway,
                status: "Scheduled",
                mode: group.mode,
                stopLat: nil,
                stopLon: nil,
                arrivalTs: ts,
                vehicleId: nil,
                tripId: item.id,
                stopId: nil,
                isRealTime: false,
                isCancelled: false
            ))
        }

        #if DEBUG
        let liveCount = baseChips.filter(\.isRealTime).count
        let apiSchedCount = baseChips.filter { !$0.isRealTime }.count
        let appendedCount = schedChips.count
        let totalSched = scheduledDeparturesForCurrentDirection.count
        if !baseChips.isEmpty || !schedChips.isEmpty {
            let chipsKey = "\(group.routeId)_\(liveCount)_\(apiSchedCount)_\(appendedCount)_\(totalSched)_\((baseChips + schedChips).map { $0.minutesAway }.description)"
            if chipsKey != Self._lastChipsLog {
                Self._lastChipsLog = chipsKey
                let chipDesc = (baseChips + schedChips).map { a -> String in
                    let tag = a.isRealTime ? "LIVE" : "SCHED"
                    let vid = a.vehicleId ?? a.tripId ?? "?"
                    return "\(a.minutesAway)m(\(tag),\(vid.suffix(12)))"
                }
                print("[CHIPS] route=\(group.routeId) dir=\(direction.direction.prefix(30))  live=\(liveCount) apiSched=\(apiSchedCount) appendedSched=\(appendedCount) (of \(totalSched) available)  chips=[\(chipDesc.joined(separator: ", "))]")
            }
        }
        #endif

        // Combine and sort by time so they interleave correctly
        return (baseChips + schedChips).sorted { a, b in
            let tsA = Double(a.arrivalTs ?? 0)
            let tsB = Double(b.arrivalTs ?? 0)
            if tsA > 0 && tsB > 0 { return tsA < tsB }
            return a.minutesAway < b.minutesAway
        }
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
    /// Converts a `NearbyTransitResponse` + `SmartETA` into an `ArrivalChipData`
    /// value bag that the reusable `ArrivalChipView` component understands.
    private func makeChipData(arrival: NearbyTransitResponse, eta: SmartETA) -> ArrivalChipData {
        let status = chipStatus(for: arrival)
        let isSched = !arrival.isCancelled && status == .scheduled
        return ArrivalChipData(
            id: arrival.id,
            minutesRemaining: eta.minutesRemaining,
            secondsRemaining: eta.secondsRemaining,
            isAtStop: eta.isAtStop,
            isRealTime: arrival.isRealTime,
            isCancelled: arrival.isCancelled,
            isScheduled: isSched,
            arrivalTimestamp: arrival.arrivalTs,
            vehicleId: arrival.vehicleId,
            tripId: arrival.tripId
        )
    }

    private func arrivalCard(arrival: NearbyTransitResponse, index: Int, eta: SmartETA) -> some View {
        let chip = makeChipData(arrival: arrival, eta: eta)
        let isSched = chip.isScheduled
        let accent: Color = chip.isCancelled
            ? AppTheme.Colors.alertRed
            : isSched ? AppTheme.Colors.textSecondary : routeColor

        return ArrivalChipView(
            chip: chip,
            index: index,
            accentColor: accent,
            isSelected: selectedChipId == arrival.id
        ) {
            guard !isSched else { return }
            let vehicleKey = arrival.vehicleId ?? arrival.tripId
            if selectedChipId == arrival.id {
                selectedChipId = nil
                onFocusVehicle?(nil)
            } else {
                selectedChipId = arrival.id
                if let key = vehicleKey {
                    onFocusVehicle?(key)
                }
            }
            HapticManager.impact(.light)
        }
    }

    // MARK: - Countdown Section Helpers

    /// Resolve the display stop name for the countdown header.
    private func resolveDisplayStopName(source: [NearbyTransitResponse]) -> String? {
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
    }

    /// Build ordered chips array from arrivals, partitioned live-first then scheduled.
    private func buildOrderedChips(from arrivals: [NearbyTransitResponse]) -> [(arrival: NearbyTransitResponse, eta: SmartETA)] {
        var live: [(arrival: NearbyTransitResponse, eta: SmartETA)] = []
        var sched: [(arrival: NearbyTransitResponse, eta: SmartETA)] = []
        for arrival in arrivals {
            let eta = smartETA(for: arrival)
            guard !eta.isPastArrival else { continue }
            if arrival.isRealTime {
                live.append((arrival, eta))
            } else {
                sched.append((arrival, eta))
            }
        }
        live.sort { $0.eta.secondsRemaining < $1.eta.secondsRemaining }
        sched.sort { $0.eta.secondsRemaining < $1.eta.secondsRemaining }
        return live + sched
    }

    /// Stop-name pill shown when user has manually selected a stop.
    @ViewBuilder
    private func userSelectedStopPill(stopName: String) -> some View {
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
    }

    /// Header row for the countdown section with "Next Arrivals" title and optional stop name.
    @ViewBuilder
    private func countdownHeader(displayStopName: String?, isUserSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text("Next Arrivals")
                .font(.custom("Helvetica-Bold", size: 13))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)

            if let stopName = displayStopName {
                if isUserSelected {
                    userSelectedStopPill(stopName: stopName)
                } else {
                    Text("at \(stopName)")
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(routeColor)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    /// Empty-state when there are no arrivals yet.
    @ViewBuilder
    private var countdownEmptyState: some View {
        if isLoadingArrivals {
            CountdownChipSkeleton(count: 3)
        } else if !scheduledDeparturesForCurrentDirection.isEmpty {
            // Always prefer showing scheduled departures over the generic
            // "vehicles en route" placeholder — actual departure times are
            // more useful than a vehicle count.
            scheduledDeparturesView
        } else if liveVehicleCount > 0 {
            countdownVehiclesEnRouteState
        } else {
            countdownNoArrivalsState
        }
    }

    /// "X vehicles en route" placeholder.
    private var countdownVehiclesEnRouteState: some View {
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
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    /// Generic "No upcoming arrivals" state.
    private var countdownNoArrivalsState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 28))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
            Text("No upcoming arrivals")
                .font(.custom("Helvetica", size: 14))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    /// The horizontal chip scroller driven by a single TimelineView.
    @ViewBuilder
    private func countdownChipScroller(arrivals: [NearbyTransitResponse]) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
            let orderedChips = buildOrderedChips(from: arrivals)
            if orderedChips.isEmpty {
                Color.clear
                    .frame(height: 0)
                    .onAppear {
                        guard !stableNearestArrivals.isEmpty else { return }
                        stableNearestArrivals = []
                        lastStableRefreshDate = .now
                    }
            } else {
                countdownChipRow(chips: orderedChips)
            }
        }
    }

    /// Single horizontal row of arrival chips.
    private func countdownChipRow(chips: [(arrival: NearbyTransitResponse, eta: SmartETA)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(chips.enumerated()), id: \.element.arrival.id) { index, pair in
                    arrivalCard(arrival: pair.arrival, index: index, eta: pair.eta)
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.vertical, 8)
        }
    }

    private var countdownSection: some View {
        let source = stableNearestArrivals.isEmpty ? nearestStopArrivals : stableNearestArrivals
        let isUserSelected = inSheetSelectedStopId != nil
        let displayStopName = resolveDisplayStopName(source: source)

        return VStack(alignment: .leading, spacing: 10) {
            countdownHeader(displayStopName: displayStopName, isUserSelected: isUserSelected)

            if source.isEmpty {
                countdownEmptyState
            } else {
                countdownChipScroller(arrivals: source)
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
            // Tokenize the direction for flexible matching:
            // direction="CYPRESS HILLS via ROCKAWAY BL" → tokens=["cypress","hills",...]
            // headsign="CYPRESS HILLS"                   → tokens=["cypress","hills"]
            let dirTokens = Set(dirLower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
                .subtracting(["via", "to", "and", "the"])

            let matched =
                schedule.directions.first { schedDir in
                    let schedDirLower = schedDir.direction.lowercased()
                    let hsLower = schedDir.headsign.lowercased()
                    // Exact direction match
                    if schedDirLower == dirLower { return true }
                    // Substring containment (either way)
                    if !hsLower.isEmpty && (hsLower.contains(dirLower) || dirLower.contains(hsLower)) { return true }
                    // Token overlap: if the headsign shares most tokens with the direction
                    if !hsLower.isEmpty {
                        let hsTokens = Set(hsLower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
                            .subtracting(["via", "to", "and", "the"])
                        let overlap = dirTokens.intersection(hsTokens)
                        if !hsTokens.isEmpty && overlap.count >= max(1, hsTokens.count - 1) { return true }
                    }
                    return false
                }
                ?? schedule.directions.first { schedDir in
                    schedule.directions.firstIndex(where: { $0.direction == schedDir.direction })
                        == selectedDirectionIndex
                }

            #if DEBUG
            do {
                let matchKey = "\(group.routeId)_\(dirLower)_\(matched?.direction ?? "nil")_\(matched?.departures.count ?? -1)"
                if matchKey != Self._lastSchedMatchLog {
                    Self._lastSchedMatchLog = matchKey
                    if matched == nil {
                        let availDirs = schedule.directions.map { "dir='\($0.direction)' hs='\($0.headsign)' deps=\($0.departures.count)" }
                        print("[SCHED_MATCH] FAILED route=\(group.routeId) looking for '\(dirLower)' in [\(availDirs.joined(separator: ", "))]")
                    } else if let m = matched {
                        print("[SCHED_MATCH] OK route=\(group.routeId) dir='\(dirLower)' → sched dir='\(m.direction)' hs='\(m.headsign)' deps=\(m.departures.count)")
                    }
                }
            }
            #endif

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
    private var scheduledDeparturesView: some View {
        ScheduledChipStrip(departures: scheduledDeparturesForCurrentDirection)
    }

    // MARK: - Direction Picker

    /// Builds `DirectionPillData` array for the reusable `DirectionPickerView`.
    private func buildDirectionPills() -> [DirectionPillData] {
        // Reorder so the selected direction is first
        let all = group.directions.enumerated().map { (index: $0.offset, dir: $0.element) }
        var ordered = all
        if selectedDirectionIndex >= 0, selectedDirectionIndex < group.directions.count,
           let pos = ordered.firstIndex(where: { $0.index == selectedDirectionIndex }) {
            let selected = ordered.remove(at: pos)
            ordered.insert(selected, at: 0)
        }

        return ordered.map { index, dir in
            let matchedDir = routeShape?.matchedDirection(index: index, name: dir.direction)
            return DirectionPillData(
                id: dir.id,
                index: index,
                label: resolvedDirectionLabel(for: dir, at: index),
                serviceType: matchedDir?.serviceType,
                vehicleCount: directionBadgeCounts[dir.id] ?? 0,
                isActive: selectedDirectionIndex == index
            )
        }
    }

    private var directionPicker: some View {
        DirectionPickerView(
            directions: buildDirectionPills(),
            routeColor: routeColor
        ) { index in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedDirectionIndex = index
                lockedDirectionHeadsign = group.directions[index].direction
            }
        }
    }

    /// Refreshes the cached badge counts for all direction pills.
    private func refreshDirectionBadgeCounts() {
        var counts: [String: Int] = [:]
        for dir in group.directions {
            counts[dir.id] = dir.uniqueVehicleCount
        }
        directionBadgeCounts = counts
    }

    /// Rebuilds the per-stop arrival lookup used by the Stops tab.
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
        cachedDepartureCount = scheduledOnlyDepartures.count
    }

    // MARK: - Departures Board

    /// Scheduled departures that are NOT already live-tracked.
    /// These are "ghost" buses/trains in the timetable with no active GPS position.
    private var scheduledOnlyDepartures: [ScheduledItem] {
        let allSched = scheduledDeparturesForCurrentDirection
        guard !allSched.isEmpty else { return [] }

        // Collect trip IDs and approximate timestamps from all live arrivals
        // in the current direction so we can exclude them.
        let liveArrivals = safeDirection.liveArrivals
        let liveTripIds = Set(liveArrivals.compactMap(\.tripId))
        let liveTimestamps = Set(liveArrivals.compactMap(\.arrivalTs))

        return allSched.filter { item in
            // Skip if this trip is already live-tracked
            if liveTripIds.contains(item.id) { return false }
            // Skip if the timestamp matches a live arrival exactly
            let ts = Int(item.departureDate.timeIntervalSince1970)
            if liveTimestamps.contains(ts) { return false }
            return true
        }
    }

    private var arrivalsList: some View {
        let departures = scheduledOnlyDepartures

        return VStack(alignment: .leading, spacing: 10) {
            DeparturesBoardView(
                departures: departures,
                routeColor: routeColor,
                isLoading: isLoadingArrivals,
                hasScheduleData: busSchedule != nil || !cachedTrainArrivals.isEmpty
            )
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

    // MARK: - Departures Sub-Views (broken out for type-checker)

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
        let tabs = RouteDetailTab.allCases.map { tab -> PillTab in
            let badge: Int = {
                switch tab {
                case .stops:
                    return routeShape?.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName).count ?? 0
                case .departures:
                    return cachedDepartureCount
                case .alerts:
                    return routeAlerts.count
                }
            }()
            return PillTab(id: tab.rawValue, label: tab.rawValue, icon: tabIcon(for: tab), badgeCount: badge)
        }

        return PillTabPicker(
            tabs: tabs,
            selectedId: Binding(
                get: { selectedTab.rawValue },
                set: { if let t = RouteDetailTab(rawValue: $0) { selectedTab = t } }
            ),
            accentColor: routeColor
        )
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
    private func currentStopIndex(in dirStops: [BusStop]) -> Int? {
        if let sid = selectedStopId, !sid.isEmpty {
            let normalized = normalizeStopId(sid)
            if let idx = dirStops.firstIndex(where: {
                normalizeStopId($0.id) == normalized
            }) { return idx }
        }
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

    /// Builds `StopRowData` array from raw `BusStop` list for the reusable `StopsListView`.
    private func buildStopRowData() -> [StopRowData] {
        let dirStops: [BusStop] = routeShape?.stopsForDirection(
            index: selectedDirectionIndex, name: selectedDirectionName) ?? []
        let currentIdx = currentStopIndex(in: dirStops)
        let arrivalByStop = cachedArrivalByStop

        return dirStops.enumerated().map { index, stop in
            let isPassed = currentIdx.map { index < $0 } ?? false
            let isCurrent = currentIdx == index
            let normId = normalizeStopId(stop.id)
            let nextArrival: NearbyTransitResponse? =
                arrivalByStop[normId]
                ?? arrivalByStop[stop.id]
                ?? arrivalByStop[stop.name.lowercased().trimmingCharacters(in: .whitespaces)]
            let transfers = transferRoutes(for: stop)
            let outages = accessibilityOutages(at: stop)

            return StopRowData(
                id: stop.id,
                name: stop.name,
                lat: stop.lat,
                lon: stop.lon,
                isCurrent: isCurrent,
                isPassed: isPassed,
                isSelected: inSheetSelectedStopId == stop.id,
                transfers: transfers,
                accessibilityOutages: outages.map(\.description),
                hasElevatorOutage: outages.contains { $0.equipmentType.lowercased().contains("elevator") },
                nextArrivalMinutes: (nextArrival != nil && !(nextArrival!.isPlaceholder)) ? nextArrival!.minutesAway : nil,
                nextArrivalIsScheduled: nextArrival?.isScheduledOnly ?? true,
                nextArrivalIsAtStop: (nextArrival?.minutesAway ?? 1) <= 0,
                nextArrivalTimestamp: nextArrival?.arrivalTs,
                isFirst: index == 0,
                isLast: index == dirStops.count - 1
            )
        }
    }

    private var stopsListSection: some View {
        StopsListView(
            stops: buildStopRowData(),
            routeColor: routeColor,
            isLoading: routeShape == nil,
            selectedStopId: inSheetSelectedStopId
        ) { stop in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if inSheetSelectedStopId == stop.id {
                    inSheetSelectedStopId = nil
                    onStopSelected?(nil)
                } else {
                    inSheetSelectedStopId = stop.id
                    selectedTab = .departures
                    onStopSelected?(CLLocationCoordinate2D(
                        latitude: stop.lat, longitude: stop.lon))
                }
            }
            HapticManager.impact(.light)
        }
        .onChange(of: selectedDirectionIndex) { _, _ in
            inSheetSelectedStopId = nil
            onStopSelected?(nil)
        }
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
        NoAlertsEmptyState(routeDisplayName: group.displayName)
    }

    // MARK: - Alert Banner (top of sheet)
    // MARK: - Alert Banner Adapters

    private func routeAlertBanner(_ alert: TransitAlert) -> some View {
        RouteAlertBanner(alert: alert, totalAlertCount: routeAlerts.count)
    }

    private func inlineAlertBanner(_ alert: InlineAlertResponse) -> some View {
        InlineAlertBannerView(alert: alert, totalAlertCount: group.alerts.count)
    }

    // MARK: - Route Alerts Section

    // MARK: - Loading Skeletons

    private var alertBannerSkeleton: some View {
        AlertBannerSkeleton()
    }

    private var directionPickerSkeleton: some View {
        DirectionPickerSkeleton()
    }

    private var routeAlertsSection: some View {
        RouteAlertsSection(alerts: routeAlerts)
    }

    // MARK: - Route Info Footer

    /// Animating pulse state for the live indicator dot
    @State private var liveDotPulse = false

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
                VStack(spacing: 12) {
                    // Thin separator above footer
                    Divider()
                        .overlay(AppTheme.Colors.textSecondary.opacity(0.1))
                        .padding(.horizontal, AppTheme.Layout.margin)

                    HStack(spacing: 12) {
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
                                // Pulsing live dot
                                Circle()
                                    .fill(AppTheme.Colors.successGreen)
                                    .frame(width: 7, height: 7)
                                    .overlay(
                                        Circle()
                                            .fill(AppTheme.Colors.successGreen.opacity(0.35))
                                            .frame(width: 14, height: 14)
                                            .scaleEffect(liveDotPulse ? 1.4 : 0.8)
                                            .opacity(liveDotPulse ? 0 : 0.6)
                                    )
                                    .onAppear {
                                        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                                            liveDotPulse = true
                                        }
                                    }
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
                }
            )
        } else {
            return AnyView(EmptyView())
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
