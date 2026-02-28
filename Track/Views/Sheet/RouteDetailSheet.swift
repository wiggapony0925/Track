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
    /// Only refreshes when the leading trip changes OR ETA shifts > 60 s —
    /// prevents the chips from flickering 3× during the open-sheet data cascade
    /// (initial load → vehicles refresh → shape refresh).
    @State private var stableNearestArrivals: [NearbyTransitResponse] = []

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

    /// One-way latch: once a trip has been observed as "live" (non-scheduled),
    /// we never downgrade it back to "Scheduled" even if the backend flips
    /// (e.g. SIRI GPS spooking toggles `Monitored` between polls).
    @State private var knownLiveTripKeys: Set<String> = []

    /// Convenience: locked stop key for the currently-displayed direction.
    private var lockedNearestStopKey: String? { lockedStopKeyPerDirection[selectedDirectionIndex] }

    /// Returns `true` only if this arrival has *never* been observed as live.
    /// Prevents the "On Route" ↔ "Scheduled" flicker caused by MTA SIRI
    /// GPS spooking (the `Monitored` flag toggles between consecutive polls).
    private func isEffectivelyScheduled(_ arrival: NearbyTransitResponse) -> Bool {
        guard arrival.isScheduledOnly else { return false }  // currently live → not scheduled
        let key = arrival.tripId ?? arrival.vehicleId ?? ""
        guard !key.isEmpty else { return true }  // unknown trip → trust backend
        return !knownLiveTripKeys.contains(key)   // seen live before → still live
    }

    /// Record all currently-live trips so we never downgrade them to scheduled.
    private func recordLiveTrips(_ arrivals: [NearbyTransitResponse]) {
        for a in arrivals where !a.isScheduledOnly {
            if let key = a.tripId ?? a.vehicleId, !key.isEmpty {
                knownLiveTripKeys.insert(key)
            }
        }
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
        isLiveOnMap: ((NearbyTransitResponse) -> Bool)? = nil,
        onClearHighlight: (() -> Void)? = nil,
        onFocusVehicle: ((String?) -> Void)? = nil,
        tappedVehicleId: String? = nil,
        onDismiss: (() -> Void)? = nil
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
        self.isLiveOnMap = isLiveOnMap
        self.onClearHighlight = onClearHighlight
        self.onFocusVehicle = onFocusVehicle
        self.tappedVehicleId = tappedVehicleId
        self.onDismiss = onDismiss
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

        // 1. GTFS headsign — this IS the terminal/last-stop name
        if let hs = matchedDir?.headsign, !hs.isEmpty {
            return hs
        }

        // 2. Last stop in route shape's stops for this direction
        if let stops = matchedDir?.stops, let lastStop = stops.last {
            return lastStop.name
        }

        // 3. First live arrival's destination (single destination, not concatenated)
        if let dest = dir.liveArrivals.first?.destination ?? dir.arrivals.first?.destination,
           !dest.isEmpty {
            return dest
        }

        // 4. Compass fallback
        return shortDirectionLabel(dir.direction)
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
            // Seed stable arrivals on first appear
            stableNearestArrivals = nearestStopArrivals
            // Lock the nearest stop key for this direction so subsequent refreshes don't hop stops
            if lockedDirectionHeadsign == nil {
                lockedDirectionHeadsign = safeDirection.direction
            }
            if lockedStopKeyPerDirection[selectedDirectionIndex] == nil,
               let first = stableNearestArrivals.first {
                lockedStopKeyPerDirection[selectedDirectionIndex] = first.stopId ?? first.stopName
            }
            // Latch live trip keys so we never downgrade them to "Scheduled"
            recordLiveTrips(safeDirection.liveArrivals)
            #if DEBUG
            AppLogger.shared.log(
                "ROUTE_DETAIL",
                message:
                    "VIEW_OPEN route=\(group.routeId) dir=\(safeDirection.direction) live=\(safeDirection.liveArrivals.count) latchedLive=\(knownLiveTripKeys.count)"
            )
            #endif
        }
        .onChange(of: group) { _, _ in
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

            // Latch any newly-live trips so their status never regresses.
            recordLiveTrips(safeDirection.liveArrivals)

            // Update the stable countdown only when it meaningfully changes:
            // different leading vehicle/trip, or ETA shifts > 60 s.
            let fresh = nearestStopArrivals
            // Lock the nearest stop key for this direction on first resolution
            if lockedStopKeyPerDirection[selectedDirectionIndex] == nil, let first = fresh.first {
                lockedStopKeyPerDirection[selectedDirectionIndex] = first.stopId ?? first.stopName
            }

            if shouldRefreshStableArrivals(fresh) {
                stableNearestArrivals = fresh
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
        .onChange(of: selectedDirectionIndex) { _, _ in
            // Reset stable countdown chips immediately when the user switches direction
            // so they see the new direction's nearest-stop times right away rather than
            // waiting for the next group poll cycle to trigger shouldRefreshStableArrivals.
            let freshArrivals = nearestStopArrivals
            if !freshArrivals.isEmpty {
                stableNearestArrivals = freshArrivals
            }
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
                                cameraPosition = .camera(
                                    MapCamera(
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
                            cameraPosition = .camera(
                                MapCamera(
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

    // MARK: - Countdown Chips

    /// Primary arrivals source for Route Details display.
    ///
    /// Important UX rule:
    /// - Route Details should show the full direction feed by default (not just
    ///   a nearest-stop subset), so users can see all upcoming vehicles.
    /// - Stop-specific filtering is applied only when the user explicitly taps a
    ///   stop row in the Stops tab (`inSheetSelectedStopId`).
    private var prioritizedArrivals: [NearbyTransitResponse] {
        let direction = safeDirection
        let liveOnly = direction.liveArrivals

        guard !liveOnly.isEmpty else { return [] }

        // Sort first, then deduplicate by vehicle/trip key.
        // The backend already deduplicates, but this is a client-side safety net:
        // same vehicle can still appear with different stop coordinates after
        // shape enrichment re-processes the flat list.
        let sorted = sortArrivalsByETA(liveOnly)
        var seen = Set<String>()
        return sorted.filter { arrival in
            guard let key = arrival.vehicleId ?? arrival.tripId else {
                return true  // no key → scheduled placeholder, always keep
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
    /// Arrivals for the countdown chips.
    ///
    /// The backend now returns exactly ONE prediction per unique vehicle — the
    /// one at the stop CLOSEST to the user (smallest `distance_m`).  So we no
    /// longer filter by nearest stop here; doing so was the root cause of chips
    /// disappearing (the user's nearest stop ≠ the stop the backend kept after
    /// dedup, producing zero matches).
    ///
    /// We simply return all live arrivals sorted by smart ETA, deduplicated by
    /// vehicle key as a client-side safety net.
    private var nearestStopArrivals: [NearbyTransitResponse] {
        let live = safeDirection.liveArrivals
        guard !live.isEmpty else { return [] }
        let sorted = sortArrivalsByETA(live)
        var seen = Set<String>()
        return sorted.filter { arrival in
            guard let key = arrival.vehicleId ?? arrival.tripId else { return true }
            return seen.insert(key).inserted
        }
    }

    /// Mirrors `GroupedRouteRow.countdownArrival(for:)` as closely as possible,
    /// so we can compare Home-row countdown ETA against Route Detail countdown ETA.
    private func rowComparableCountdownArrival(for direction: DirectionArrivalsResponse) -> NearbyTransitResponse? {
        let live = direction.liveArrivals
        guard !live.isEmpty else { return nil }

        let refCoord = currentLocation ?? searchCenter
        if let refCoord {
            let refLoc = CLLocation(latitude: refCoord.latitude, longitude: refCoord.longitude)
            var nearestStopKey: String?
            var nearestDistance: CLLocationDistance = .greatestFiniteMagnitude

            for arrival in live {
                let distance = arrivalDistance(arrival, from: refLoc)
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestStopKey = arrival.stopId ?? arrival.stopName
                }
            }

            if let key = nearestStopKey {
                let atNearestStop = live.filter { ($0.stopId ?? $0.stopName) == key }
                if let first = sortArrivalsByETA(atNearestStop).first {
                    return first
                }
            }
        }

        return sortArrivalsByETA(live).first
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
    /// a display refresh — i.e. the leading trip changed, or the ETA shifted > 60 s.
    ///
    /// Uses ``smartETA`` (not the raw ``minutesAway`` integer) so changes that
    /// result from live vehicle movement — not just backend poll boundary integers —
    /// also trigger a refresh.
    private func shouldRefreshStableArrivals(_ new: [NearbyTransitResponse]) -> Bool {
        guard !new.isEmpty else { return false }
        guard !stableNearestArrivals.isEmpty else { return true }

        let newFirst = new[0]
        let oldFirst = stableNearestArrivals[0]

        // Different vehicle / trip → always refresh
        let newKey = newFirst.tripId ?? newFirst.vehicleId
        let oldKey = oldFirst.tripId ?? oldFirst.vehicleId
        if newKey != oldKey { return true }

        // Same vehicle: compare using smartETA so live GPS refinements are captured
        let newSecs = smartETA(for: newFirst).secondsRemaining
        let oldSecs = smartETA(for: oldFirst).secondsRemaining
        return abs(newSecs - oldSecs) > 60
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
        let stripped1 = stripMTAPrefix(arrivalStopId)
        let stripped2 = stripMTAPrefix(stopId)
        if stripped1 == stripped2 { return true }
        // One might be a suffix of the other (e.g. "305423" vs "MTA_305423")
        if stripped1.hasSuffix(stripped2) || stripped2.hasSuffix(stripped1) { return true }
        // Subway parent station match: "120N" and "120S" share parent "120".
        // Since safeDirection already restricts arrivals to one direction,
        // matching by parent station is safe (no cross-direction leakage).
        let parent1 = stripDirectionSuffix(stripped1)
        let parent2 = stripDirectionSuffix(stripped2)
        if parent1 == parent2 && !parent1.isEmpty { return true }
        // Name-based fallback: lookup what name the route shape gives this stopId
        return matchesByName(arrivalStopName: arrival.stopName, shapeStopId: stopId)
    }

    /// Strips MTA agency prefixes from a stop ID for comparison.
    /// Uses the shared prefix table in `MTAPrefixes.swift`.
    private func stripMTAPrefix(_ id: String) -> String {
        stripMTAStopPrefix(id)
    }

    /// Strips trailing N/S direction suffix from a subway stop ID.
    /// e.g. "120N" → "120", "A31S" → "A31", "H11N" → "H11".
    /// Leaves bus/commuter rail IDs unchanged (they don't use this convention).
    private func stripDirectionSuffix(_ id: String) -> String {
        guard id.count > 1, let last = id.last, last == "N" || last == "S" else { return id }
        // Only strip if the character before the suffix is a digit or lowercase letter
        // (avoids stripping from IDs like "GS" — Grand Central Shuttle)
        let penultimate = id[id.index(before: id.index(before: id.endIndex))]
        if penultimate.isNumber || penultimate.isLowercase {
            return String(id.dropLast())
        }
        return id
    }

    /// Checks if an arrival's stop name matches the name of a route shape stop by ID.
    private func matchesByName(arrivalStopName: String, shapeStopId: String) -> Bool {
        guard let shape = routeShape else { return false }
        let allStops = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
        // Try exact ID match first, then parent station ID match
        let shapeStop = allStops.first(where: { $0.id == shapeStopId })
            ?? allStops.first(where: { stripDirectionSuffix(stripMTAPrefix($0.id)) == stripDirectionSuffix(stripMTAPrefix(shapeStopId)) })
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
            // Fuzzy match on stripped IDs (MTA prefix + N/S suffix)
            let stripped = stripMTAPrefix(stopId)
            if let stop = allStops.first(where: { stripMTAPrefix($0.id) == stripped }) {
                return userLoc.distance(from: CLLocation(latitude: stop.lat, longitude: stop.lon))
            }
            // Parent station match (strip N/S)
            let parent = stripDirectionSuffix(stripped)
            if let stop = allStops.first(where: { stripDirectionSuffix(stripMTAPrefix($0.id)) == parent }) {
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
    private func sortArrivalsByETA(_ arrivals: [NearbyTransitResponse]) -> [NearbyTransitResponse] {
        arrivals.sorted { lhs, rhs in
            let left = smartETA(for: lhs).secondsRemaining
            let right = smartETA(for: rhs).secondsRemaining
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
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
                let stripped = stripMTAPrefix(sid)
                if let s = stops.first(where: { stripMTAPrefix($0.id) == stripped }) {
                    return CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
                }
                // Parent station match (strip N/S suffix)
                let parent = stripDirectionSuffix(stripped)
                if let s = stops.first(where: { stripDirectionSuffix(stripMTAPrefix($0.id)) == parent }) {
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

    @ViewBuilder
    private func arrivalCard(arrival: NearbyTransitResponse, index: Int) -> some View {
        let isFirst = index == 0
        let isSched = isEffectivelyScheduled(arrival)

        VStack(spacing: 0) {
            // ── Status tag ────────────────────────────────────────────────
            HStack(spacing: 4) {
                if isSched {
                    Image(systemName: "clock")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                    Text("Scheduled")
                        .font(.custom("Helvetica-Bold", size: 8.5))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                } else {
                    Circle()
                        .fill(AppTheme.Colors.successGreen)
                        .frame(width: 5, height: 5)
                    Text("On Route")
                        .font(.custom("Helvetica-Bold", size: 8.5))
                        .foregroundColor(AppTheme.Colors.successGreen)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(
                        isSched
                        ? AppTheme.Colors.textSecondary.opacity(0.10)
                        : AppTheme.Colors.successGreen.opacity(0.14)
                    )
            )
            .padding(.top, 13)

            Spacer(minLength: 6)

            // ── ETA counter ───────────────────────────────────────────────
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                let eta = smartETA(for: arrival)
                let mins = eta.minutesRemaining
                let isNow = !isSched && (eta.isAtStop || eta.secondsRemaining <= 30)
                arrivalETA(mins: mins, isNow: isNow, isSched: isSched, isFirst: isFirst)
            }

            Spacer(minLength: isFirst ? 8 : 6)

            // ── Clock time ────────────────────────────────────────────────
            if let ts = arrival.arrivalTs {
                Text(Date(timeIntervalSince1970: Double(ts)), style: .time)
                    .font(.custom("Helvetica-Bold", size: 10))
                    .foregroundColor(
                        isSched
                        ? AppTheme.Colors.textSecondary.opacity(0.35)
                        : AppTheme.Colors.textSecondary.opacity(0.70)
                    )
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
                    isSched
                    ? AppTheme.Colors.textSecondary.opacity(0.12)
                    : (isFirst ? routeColor.opacity(0.35) : Color.clear),
                    lineWidth: 1.2
                )
        )
        // Tap card to start Live Activity tracking for this arrival
        .onTapGesture {
            guard !isSched else { return }
            onTrack?(arrival)
            HapticManager.impact(.medium)
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
        // Resolve the stop name for the header
        let nearestStopName: String? = {
            if let stopId = selectedStopId, !stopId.isEmpty {
                // Try from the arrivals first (freshest data)
                if let name = source.first?.stopName { return name }
                // Fall back to route shape stops (with parent station fallback)
                if let shape = routeShape {
                    let stops = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
                    let parentId = stripDirectionSuffix(stripMTAPrefix(stopId))
                    return stops.first(where: { $0.id == stopId })?.name
                        ?? stops.first(where: { stripDirectionSuffix(stripMTAPrefix($0.id)) == parentId })?.name
                }
            }
            // Fall back to whatever the first arrival says
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

                if let stopName = nearestStopName {
                    Text("at \(stopName)")
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(routeColor)
                        .lineLimit(1)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(nextArrivals.enumerated()), id: \.element.id) { index, arrival in
                            arrivalCard(arrival: arrival, index: index)
                        }
                    }
                    .padding(.horizontal, AppTheme.Layout.margin)
                    .padding(.vertical, 4)
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
                .prefix(6)
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

            return Array(matching.prefix(6)).map { ScheduledItem.from($0) }
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
                    ForEach(Array(group.directions.enumerated()), id: \.element.id) { index, dir in
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

                                // Arrival count
                                // Show live arrival count (exclude placeholders)
                                let liveCount = dir.liveArrivals.count
                                if liveCount > 0 {
                                    Text("\(liveCount)")
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
                            "\(resolvedDirectionLabel(for: dir, at: index)), \(dir.liveArrivals.count) arrivals"
                        )
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
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

        NearbyTransitRow(
            arrival: arrival,
            isTracking: isTracking?(arrival) ?? false,
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
                            if tab == .departures {
                                let depCount = safeDirection.liveArrivals.count
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
            let stripped = stripMTAPrefix(sid)
            let parent = stripDirectionSuffix(stripped)
            if let idx = dirStops.firstIndex(where: {
                let s = stripMTAPrefix($0.id)
                return s == stripped || stripDirectionSuffix(s) == parent
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

        // Build a lookup: normalised stop-id → nearest arriving bus at that stop.
        // Keys use the same strip logic used elsewhere for stop-id matching.
        let allArrivals = safeDirection.liveArrivals
        var arrivalByStop: [String: NearbyTransitResponse] = [:]
        for a in allArrivals {
            // Key 1: normalised stop-id
            if let sid = a.stopId, !sid.isEmpty {
                let key = stripDirectionSuffix(stripMTAPrefix(sid))
                if arrivalByStop[key] == nil { arrivalByStop[key] = a }
                // also store raw
                if arrivalByStop[sid] == nil { arrivalByStop[sid] = a }
            }
            // Key 2: stopName (lowercase, trimmed) as fallback
            let nameKey = a.stopName.lowercased().trimmingCharacters(in: .whitespaces)
            if arrivalByStop[nameKey] == nil { arrivalByStop[nameKey] = a }
        }

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
                            let normId = stripDirectionSuffix(stripMTAPrefix(stop.id))
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
                                        } else {
                                            inSheetSelectedStopId = stop.id
                                            selectedTab = .departures
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
                            if !isEffectivelyScheduled(arrival) {
                                Circle()
                                    .fill(AppTheme.Colors.successGreen)
                                    .frame(width: 5, height: 5)
                            }
                            Text("\(arrival.minutesAway)m")
                                .font(.custom("Helvetica-Bold", size: 13))
                                .foregroundColor(
                                    isPassed
                                    ? AppTheme.Colors.textSecondary.opacity(0.35)
                                    : (isEffectivelyScheduled(arrival)
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
        let hasStops = shape != nil && !shape!.stops.isEmpty
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
