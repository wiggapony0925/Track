// Route detail view presented when tapping a grouped route card.
// Uses the same AppTheme design system, RouteBadge, and card layout
// patterns as the rest of the app. No separate map — the MAIN map
// behind this sheet draws the route polylines and live vehicles.

import CoreLocation
import SwiftUI

struct RouteDetailSheet: View {
    let group: GroupedNearbyTransitResponse
    /// Closure that returns the live coordinate for a vehicle ID, if available.
    /// Replaces the old `@Binding var busVehicles` to avoid 1 Hz full-body
    /// re-evaluations from bus interpolation ticks.
    var vehicleCoordinateLookup: ((String) -> CLLocationCoordinate2D?)?
    /// O(1) lookup for backend-owned live vehicle metadata keyed by an arrival.
    var liveVehicleDetailLookup: ((NearbyTransitResponse) -> LiveVehicleDetailResponse?)?
    var trainVehicles: [TrainVehicle] = []
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
    /// Called when the user taps the center button — HomeView provides
    /// the route-fitting camera that shows both user + nearest stop.
    var onRecenter: (() -> Void)?
    /// Called when the user taps again on an already-selected stop to open
    /// the full stop-detail sheet for that stop.
    var onStopDetailRequested: ((StopDetailSelection) -> Void)? = nil

    // Map controls (shown in header when sheet is expanded)
    var isSheetExpanded: Bool = false
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

    /// Current weather snapshot for the weather chip in the header.
    /// Provided by `WeatherService.shared` via the ViewModel.
    var weatherSnapshot: WeatherSnapshot? = nil

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

    /// Bound to viewModel so map and stops list grey out local-only stops
    /// when the currently-displayed arrival is express.
    @Binding var isSelectedArrivalExpress: Bool

    /// Which content tab is active: arrivals, departures, or alerts.
    @State private var selectedTab: RouteDetailTab = .stops

    /// Optional external tab-selection trigger.  HomeView writes a
    /// non-nil value when the map's route-banner alert pill is
    /// tapped; the sheet observes the change, switches `selectedTab`,
    /// then clears the binding so subsequent taps still fire.
    @Binding var tabRequest: RouteDetailTab?

    /// Current panel drag offset, expressed as how far the panel is
    /// pushed DOWN from its fully-expanded position.
    ///   0          → fully expanded
    ///   expandRange → collapsed (resting / default)
    /// Initialized to a large positive sentinel so the very first
    /// layout pass clamps it to `range` (collapsed) once `range` is
    /// resolved by the GeometryReader — we don't know `range` here.
    @State private var panelDragOffset: CGFloat = .greatestFiniteMagnitude

    /// Remembered offset from the last completed drag so the
    /// panel stays wherever the user left it.  Same units as
    /// `panelDragOffset` (positive-down).
    @State private var panelRestingOffset: CGFloat = .greatestFiniteMagnitude

    /// Whether the scroll view is at the very top.
    /// When true and user drags down, the panel collapses.
    @State private var scrollAtTop: Bool = true

    /// True while the user is actively pulling the panel down from scroll-top.
    @State private var isDraggingPanel: Bool = false

    /// Once the first meaningful drag movement occurs, we lock in
    /// whether this gesture moves the panel or scrolls content.
    /// Prevents per-frame re-evaluation that caused jitter.
    @State private var gestureDecided: Bool = false

    /// Cached expand range so drag closure doesn't rely on GeometryReader.
    @State private var cachedExpandRange: CGFloat = 400

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
    @State private var showLostAndFound = false
    @ObservedObject private var supabase = SupabaseManager.shared
    @ObservedObject private var favoritesManager = FavoritesManager.shared

    /// True while the first arrivals batch is still in-flight.
    /// Drives skeleton placeholders so the sheet never looks empty on open.
    @State private var isLoadingArrivals: Bool = true
    /// Set after first-frame route-detail cache warmup finishes. Until then,
    /// the sheet renders light skeletons instead of synchronously deriving
    /// polyline snaps, nearest-stop chips, and stop-arrival lookup tables.
    @State private var didWarmInitialContent: Bool = false

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

    /// Cached decoded direction polyline.
    /// Rebuilt only when `routeShape` or `selectedDirectionIndex` changes — avoids
    /// re-decoding all Google-encoded polyline strings on every body evaluation.
    @State private var cachedDirectionPolyline: [CLLocationCoordinate2D] = []

    /// ID of the chip the user tapped to highlight on the map.
    /// Tapping the same chip again deselects it.  Only live (non-scheduled)
    /// chips can be selected — this zooms the map to the vehicle marker
    /// and scales the chip up slightly.
    @State private var selectedChipId: String?

    /// The raw route ID of the currently selected chip (e.g. "7X").
    /// Used to dynamically switch the header badge to diamond for express.
    @State private var selectedChipRouteId: String?

    /// Per-stop predicted arrival timestamps for the chip's underlying
    /// GTFS trip — populated when the user taps a live chip and consumed
    /// by `buildStopRowData` so the Stops list renders ETAs from the
    /// selected vehicle's perspective.  Keys are stop IDs in both their
    /// suffixed (`123N`) and base (`123`) forms.  Cleared when the chip
    /// is deselected or the direction changes.
    @State private var selectedTripStopETAs: [String: Int] = [:]

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
    /// Guard against double-fire of `handleDirectionChange` when `selectedDirectionIndex`
    /// is written twice in rapid succession (e.g. initial snap + DIR_PREF restore at open).
    @State private var _lastHandledDirectionIndex: Int = -1
    /// Headsign of the user's selected direction — locked so that backend
    /// re-sorts of `group.directions` never flip the sheet to a different dir.
    @State private var lockedDirectionHeadsign: String?

    /// Stable copies of schedule data for use in event handlers.
    /// The prop-passed `busSchedule` / `cachedTrainArrivals` vars may not
    /// reflect the latest ViewModel state when `.onChange` handlers fire
    /// (SwiftUI evaluates view struct THEN fires onChange).  These @State
    /// snapshots are updated in `handleScheduleChange` and read by handlers
    /// that need schedule data (e.g. direction changes, chip rebuilds).
    @State private var stableBusSchedule: BusScheduleResponse?
    @State private var stableTrainArrivals: [TrainArrival] = []

    /// Convenience: locked stop key for the currently-displayed direction.
    private var lockedNearestStopKey: String? { lockedStopKeyPerDirection[selectedDirectionIndex] }

    /// Three-tier chip status for clarity:
    ///  • `.live`      – vehicle has a visible GPS marker on the map (tappable)
    ///  • `.tracked`   – real-time feed is tracking this trip, but no GPS
    ///                   marker is on the map yet (not tappable for zoom)
    ///  • `.scheduled` – static GTFS schedule only, no live data
    private enum ChipStatus {
        case live, tracked, scheduled
    }

    /// Derives chip status by combining the backend `isRealTime` flag with
    /// actual map-marker presence.  This prevents the confusing scenario
    /// where a chip says "Live" but tapping it reveals no bus on the map.
    private func chipStatus(for arrival: NearbyTransitResponse) -> ChipStatus {
        // Vehicle has a visible marker on the map → full Live
        if isLiveOnMap?(arrival) == true { return .live }
        if let detail = liveVehicleDetailLookup?(arrival), !detail.isStale {
            return detail.isRealtime ? .tracked : .scheduled
        }
        // Backend says real-time (SIRI/GTFS-RT tracking) but no marker → Tracked
        if arrival.isRealTime { return .tracked }
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
        vehicleCoordinateLookup: ((String) -> CLLocationCoordinate2D?)? = nil,
        liveVehicleDetailLookup: ((NearbyTransitResponse) -> LiveVehicleDetailResponse?)? = nil,
        trainVehicles: [TrainVehicle] = [],
        routeShape: Binding<RouteShapeResponse?>,
        selectedDirectionIndex: Binding<Int>,
        isSelectedArrivalExpress: Binding<Bool> = .constant(false),
        serviceAlerts: [TransitAlert] = [],
        busSchedule: BusScheduleResponse? = nil,
        cachedTrainArrivals: [TrainArrival] = [],
        cachedStations: [HomeViewModel.CachedSubwayStation] = [],
        smartETAProvider: ((NearbyTransitResponse) -> SmartETA)? = nil,
        liveVehicleCount: Int = 0,
        elevatorOutages: [ElevatorStatus] = [],
        weatherSnapshot: WeatherSnapshot? = nil,
        initialTab: RouteDetailTab? = nil,
        tabRequest: Binding<RouteDetailTab?> = .constant(nil),
        isSheetExpanded: Bool = false,
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
        onStopSelected: ((CLLocationCoordinate2D?) -> Void)? = nil,
        onRecenter: (() -> Void)? = nil,
        onStopDetailRequested: ((StopDetailSelection) -> Void)? = nil
    ) {
        self.group = group
        self.vehicleCoordinateLookup = vehicleCoordinateLookup
        self.liveVehicleDetailLookup = liveVehicleDetailLookup
        self.trainVehicles = trainVehicles
        self._routeShape = routeShape
        self._selectedDirectionIndex = selectedDirectionIndex
        self._isSelectedArrivalExpress = isSelectedArrivalExpress
        self.serviceAlerts = serviceAlerts
        self.busSchedule = busSchedule
        self.cachedTrainArrivals = cachedTrainArrivals
        self.cachedStations = cachedStations
        self.smartETAProvider = smartETAProvider
        self.liveVehicleCount = liveVehicleCount
        self.elevatorOutages = elevatorOutages
        self.weatherSnapshot = weatherSnapshot
        self._selectedTab = State(initialValue: initialTab ?? .stops)
        self._tabRequest = tabRequest
        self.onTrack = onTrack
        self.isTracking = isTracking
        self.isTrackingAny = isTrackingAny
        self.isLiveOnMap = isLiveOnMap
        self.onClearHighlight = onClearHighlight
        self.onFocusVehicle = onFocusVehicle
        self.tappedVehicleId = tappedVehicleId
        self.onDismiss = onDismiss
        self.onStopSelected = onStopSelected
        self.onRecenter = onRecenter
        self.onStopDetailRequested = onStopDetailRequested
        self.isSheetExpanded = isSheetExpanded
        self._cameraPosition = cameraPosition
        self.currentLocation = currentLocation
        self.searchCenter = searchCenter
        self.selectedStopId = selectedStopId
        self.isStopManuallySelected = isStopManuallySelected
    }

    /// Route color from the group data or the theme palette.
    /// For buses with a missing `busServiceType`, infer from displayName
    /// so we don't flash localBlue while the parent re-emits the group
    /// with the resolved service type a moment later.
    private var routeColor: Color {
        if group.isBus {
            let resolved = group.busServiceType
                ?? Self.inferBusServiceType(from: group.displayName)
            return AppTheme.BusColors.color(forServiceType: resolved)
        }
        if let hex = group.colorHex {
            return Color(hex: hex)
        }
        if group.isLIRR { return AppTheme.CommuterRailColors.lirrBlue }
        if group.isMNR { return AppTheme.CommuterRailColors.mnrBlue }
        return AppTheme.SubwayColors.color(for: group.displayName)
    }

    /// Heuristic fallback when `group.busServiceType` is nil — derives the
    /// service type from common name patterns so the route color is
    /// stable from the very first render.
    private static func inferBusServiceType(from name: String) -> String? {
        let upper = name.uppercased()
        if upper.contains("+SBS") || upper.contains("SBS") { return "select bus service" }
        if upper.contains("-LTD") || upper.contains(" LTD") || upper.hasSuffix("LTD") {
            return "limited"
        }
        // Express bus prefixes: BxM, BM, QM, X (e.g. X1, X27).
        if upper.hasPrefix("BXM") || upper.hasPrefix("BM")
            || upper.hasPrefix("QM") || upper.hasPrefix("X") {
            return "express"
        }
        return nil
    }

    private static func isGenericShapeHeadsign(_ headsign: String?) -> Bool {
        guard let headsign, !headsign.isEmpty else { return true }
        return DirectionConstants.isFallbackDirection(headsign)
    }

    /// The name of the currently selected direction, used to match headsigns in RouteShape.
    private var selectedDirectionName: String? {
        guard selectedDirectionIndex >= 0,
            selectedDirectionIndex < group.directions.count
        else { return nil }
        return group.directions[selectedDirectionIndex].direction
    }

    private var selectedShapeDirectionId: Int? {
        guard group.isBus,
              group.directions.indices.contains(selectedDirectionIndex),
              let rawId = group.directions[selectedDirectionIndex].directionId
        else { return nil }
        return Int(rawId)
    }

    /// Resolves the best display label for a direction.
    ///
    /// Priority:
    /// 1. Route shape headsign (GTFS terminal name — most reliable, e.g. "Far Rockaway-Mott Av")
    /// 2. Last stop name in the route shape's stop list for that direction
    /// 3. First unique destination from live arrivals
    /// 4. Compass fallback ("↑ North")
    ///
    /// **Subway** routes skip the backend `directionLabel` because it
    /// concatenates ALL branch destinations ("Southbound → Far Rockaway /
    /// Lefferts Blvd") — too verbose for a pill.
    /// **Bus** routes use the backend label as a reliable fallback: it's
    /// already a clean terminal name ("Midtown West Columbus Circle") and
    /// avoids falling through to the raw ALL-CAPS SIRI DestinationName
    /// when the shape hasn't finished loading yet.
    private func resolvedDirectionLabel(
        for dir: DirectionArrivalsResponse,
        at index: Int
    ) -> String {
        let matchedDir = routeShape?.matchedDirection(
            index: index, name: dir.direction
        )
        let useShapeTerminal = !Self.isGenericShapeHeadsign(matchedDir?.headsign)
        // Skip backend label only for subway — bus labels are already clean.
        let skipBackend = !group.isBus
        return ArrivalHelpers.resolveDirectionLabel(
            for: dir,
            shapeHeadsign: useShapeTerminal ? matchedDir?.headsign : nil,
            shapeLastStopName: useShapeTerminal ? matchedDir?.stops.last?.name : nil,
            skipBackendLabel: skipBackend,
            skipArrivalDestinations: !group.isBus,
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

    // MARK: - Body Sub-Views (broken out for type-checker)

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
        if !didWarmInitialContent {
            routeDetailWarmupPlaceholder
        } else {
            switch selectedTab {
            case .stops:
                stopsListSection
                lostAndFoundPrompt
            case .departures:
                arrivalsList
            case .alerts:
                alertsList
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
                Text(
                    "Create a free account to save"
                    + " your favorite routes and access"
                    + " them across all your devices."
                )
            }
            .sheet(isPresented: $showLostAndFound) {
                LostAndFoundSheet(tripContext: TripContext(
                    routeName: group.displayName,
                    mode: group.mode,
                    direction: selectedDirectionName,
                    vehicleId: stableNearestArrivals.first?.vehicleId,
                    nearestStop: stableNearestArrivals.first?.stopName
                ))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
                .presentationBackgroundInteraction(.disabled)
                .presentationCornerRadius(24)
            }
    }

    private var bodyWithObservers: some View {
        bodyWithLifecycle
            .onChange(of: busSchedule) { _, _ in handleScheduleChange() }
            .onChange(of: cachedTrainArrivals) { _, _ in handleScheduleChange() }
            .onChange(of: favoritesManager.favorites) { _, _ in handleFavoritesChange() }
            .onChange(of: selectedStopId) { _, newId in handleSelectedStopIdChange(newId) }
            .onChange(of: inSheetSelectedStopId) { _, _ in handleStopSelectionChange() }
            .onChange(of: selectedDirectionIndex) { _, _ in handleDirectionChange() }
            .onChange(of: selectedChipId) { _, newId in handleChipSelectionChange(newId) }
            .onChange(of: routeShape?.routeId) { _, _ in rebuildCachedPolyline() }
    }

    private var bodyWithLifecycle: some View {
        bodyContent
            .onAppear(perform: handleOnAppear)
            .onChange(of: group) { _, _ in handleGroupChange() }
            .onChange(of: stableNearestArrivals) { _, _ in
                // When no chip is manually selected, derive express state
                // from the nearest (first) arrival so stop greying follows.
                if selectedChipRouteId == nil {
                    syncExpressState()
                }
            }
            .task(id: group.id) { await handleLoadingTimeout() }
    }

    // MARK: - Body Content

    /// Whether the panel is fully expanded (scroll content enabled).
    /// Only updated on drag-end to avoid mid-gesture layout thrashing.
    @State private var panelScrollEnabled: Bool = false

    private var bodyContent: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let totalHeight = proxy.size.height + safeTop
            let minPanelHeight = totalHeight * 0.45
            let maxPanelHeight = totalHeight
            let range = maxPanelHeight - minPanelHeight
            // Drag offset is NEGATIVE when pulled up.
            // panelTranslation: how far the (maxPanelHeight-tall) panel is
            // pushed DOWN from the fully-expanded position.  0 = fully open,
            // `range` = resting / collapsed.  We translate instead of
            // resizing the panel so children never relayout during the drag
            // — that's what was causing the shake / lag (ScrollView, chip
            // TimelineView, frosted material, and gradients all relaying
            // out 60×/sec when the height was changing per frame).
            // panelDragOffset is positive-down: 0 = fully expanded,
            // `range` = collapsed (default resting position).
            let panelTranslation = min(max(panelDragOffset, 0), range)
            // How far expanded: 0 = resting, 1 = fully open
            let expandProgress = 1 - panelTranslation / max(range, 1)

            ZStack(alignment: .top) {
                // NOTE: The close X has moved to MapControlsOverlay's route
                // banner (top-right corner), so we no longer render one
                // here — having two visible X buttons stacked vertically
                // was redundant.  The recenter button stays put.

                // ── Center button — fades smoothly as panel expands ──
                if isSheetExpanded {
                    HStack {
                        Spacer()
                        recenterRouteButton
                    }
                    .padding(.top, 94)
                    .padding(.horizontal, AppTheme.Layout.margin)
                    .opacity(max(1.0 - expandProgress * 2.5, 0))
                    .allowsHitTesting(expandProgress < 0.3)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                // ── Bottom floating panel ──
                // Fixed at maxPanelHeight; we slide it via .offset() so the
                // gesture is a pure GPU transform — no layout work per frame.
                panelContent(
                    safeBottom: proxy.safeAreaInsets.bottom,
                    expandRange: range
                )
                .frame(height: maxPanelHeight, alignment: .top)
                .background {
                    panelBackground
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .offset(y: panelTranslation)
                .ignoresSafeArea(edges: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                cachedExpandRange = range
                // Seed default to COLLAPSED on first appear (offset = range).
                // The sentinel `.greatestFiniteMagnitude` initializer means
                // we only run this once, before any user drag.
                if panelRestingOffset > range {
                    panelRestingOffset = range
                    panelDragOffset = range
                }
            }
            .onChange(of: range) { _, newRange in
                cachedExpandRange = newRange
                // Keep current state proportionally valid when geometry changes.
                if panelRestingOffset > newRange { panelRestingOffset = newRange }
                if panelDragOffset > newRange { panelDragOffset = newRange }
            }
            .onChange(of: tabRequest) { _, newValue in
                // External tab switch (e.g. tapping the alert pill on the
                // map banner).  Apply, then clear so subsequent taps fire
                // even if the requested tab matches the current one.
                guard let requested = newValue else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    selectedTab = requested
                }
                DispatchQueue.main.async { tabRequest = nil }
            }
        }
    }

    /// Panel background — frosted glass + route-color gradient + base fill.
    /// Extracted so it's not rebuilt during drag and so we drop the inner
    /// GeometryReaders that were re-evaluating every frame.  All gradients
    /// are static; the panel's fixed `maxPanelHeight` frame means none of
    /// these layers resize during a swipe.
    private var panelBackground: some View {
        ZStack(alignment: .bottom) {
            // Frosted glass — the very tip of the panel is transparent so
            // the map bleeds through, then material density ramps up
            // quickly around the direction picker.
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.10), location: 0.024),
                            .init(color: .white.opacity(0.45), location: 0.066),
                            .init(color: .white.opacity(0.75), location: 0.114),
                            .init(color: .white.opacity(0.92), location: 0.156),
                            .init(color: .white, location: 0.195),
                            .init(color: .white, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Route-color gradient — transparent at the top so the map
            // bleeds through, builds intensity toward the bottom so the
            // panel base carries the line's identity color.
            LinearGradient(
                stops: [
                    .init(color: routeColor.opacity(0), location: 0),
                    .init(color: routeColor.opacity(0.03), location: 0.10),
                    .init(color: routeColor.opacity(0.06), location: 0.20),
                    .init(color: routeColor.opacity(0.10), location: 0.30),
                    .init(color: routeColor.opacity(0.16), location: 0.42),
                    .init(color: routeColor.opacity(0.22), location: 0.55),
                    .init(color: routeColor.opacity(0.28), location: 0.68),
                    .init(color: routeColor.opacity(0.32), location: 0.80),
                    .init(color: routeColor.opacity(0.36), location: 0.92),
                    .init(color: routeColor.opacity(0.38), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Base fill — gentle gradient that keeps the upper portion
            // clean and lets the route color own the lower half.
            LinearGradient(
                stops: [
                    .init(color: AppTheme.Colors.cardBackground.opacity(0), location: 0),
                    .init(color: AppTheme.Colors.cardBackground.opacity(0), location: 0.25),
                    .init(color: AppTheme.Colors.cardBackground.opacity(0.12), location: 0.40),
                    .init(color: AppTheme.Colors.cardBackground.opacity(0.30), location: 0.55),
                    .init(color: AppTheme.Colors.cardBackground.opacity(0.50), location: 0.70),
                    .init(color: AppTheme.Colors.cardBackground.opacity(0.65), location: 0.85),
                    .init(color: AppTheme.Colors.cardBackground.opacity(0.75), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // NOTE: mapFloatingHeader, unifiedRouteHeroCard, routeTerminals removed —
    // the route identity is now shown by the MapControlsOverlay's selectedRouteBanner.

    /// Interior content of the floating bottom panel — direction, countdowns, tabs, content.
    /// Mirrors the dashboard sheet's structure exactly:
    ///   • A fixed header region (direction picker, chips, countdown, tabs)
    ///     that doubles as the drag handle — pulling it freeforms the panel.
    ///   • A ScrollView below it that ALWAYS scrolls so rows are usable
    ///     at every panel position.
    private func panelContent(
        safeBottom: CGFloat,
        expandRange: CGFloat
    ) -> some View {
        // One single ScrollView for the WHOLE sheet — header chips, tabs,
        // and rows are all part of one continuous scroll. No inner box,
        // no fixed-header / scrolling-body split.
        //
        // While the panel is collapsed/partial, scrolling is disabled so
        // any swipe is captured by `panelDragGesture` and grows the panel.
        // Once the user has fully expanded the sheet, the ScrollView takes
        // over and lets them keep scrolling through stops / departures.
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // NOTE: `directionPickerContent` wraps `DirectionPickerView`
                // which already applies its own
                // `.padding(.horizontal, AppTheme.Layout.margin)` inside the
                // inner horizontal ScrollView. Don't wrap it again or the
                // pill ends up double-indented and looks misaligned with
                // the chips / tabs below.
                directionPickerContent
                    .padding(.top, 14)

                supplementalHeaderChips
                    .padding(.horizontal, AppTheme.Layout.margin)
                    .padding(.top, 10)

                countdownSection
                    .padding(.top, 14)

                contentTabPicker
                    .padding(.top, 10)

                contentDeckDivider
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 18) {
                    tabContent
                    if selectedTab != .stops {
                        routeInfoFooter
                    }
                }
                .padding(.top, 14)
                // Bottom slack: enough to let the user scroll the LAST
                // content row well past the foggy top region (~20% of
                // the panel height).  Without this you hit the natural
                // end-of-scroll while the bottom row is still sitting
                // behind the fog and looks "cut off".
                .padding(.bottom, safeBottom + 240)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Collapsed / partial: any swipe expands the panel via the drag
        // gesture below. Fully expanded: the ScrollView takes over.
        .scrollDisabled(panelDragOffset > 0.5)
        // Track whether the ScrollView is at its top edge so we only
        // arm the collapse-drag when the user can no longer scroll up.
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y <= geo.contentInsets.top + 1
        } action: { _, atTop in
            scrollAtTop = atTop
        }
        // Background touches that DON'T hit a row still drag the panel
        // up/down via simultaneousGesture, mirroring the main sheet.
        // BUT: only enable while the panel is collapsed/partial OR the
        // ScrollView is already at its top. Otherwise this gesture would
        // grab downward swipes from inside the scroll content and tear
        // the header out of view by partially collapsing the panel mid-
        // scroll.
        .contentShape(Rectangle())
        .simultaneousGesture(
            panelDragGesture,
            including: (panelDragOffset > 0.5 || scrollAtTop) ? .all : .subviews
        )
    }

    /// Continuous drag gesture for the route detail panel.  Same shape
    /// as the dashboard navbar gesture — `.global` coords, freeform
    /// offset, momentum-projected snap on release.
    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                // Drag DOWN  (dy > 0) → increase offset → collapse.
                // Drag UP    (dy < 0) → decrease offset → expand.
                let proposed = panelRestingOffset + value.translation.height
                let clamped = min(max(proposed, 0), cachedExpandRange)
                panelDragOffset = clamped
            }
            .onEnded { value in
                // Freeform release — match the main sheet's behavior:
                // wherever the user lets go is where the panel stays.
                // No snap to extremes; the resting offset becomes the
                // final clamped offset so subsequent drags continue from
                // here.
                let proposed = panelRestingOffset + value.translation.height
                let clamped = min(max(proposed, 0), cachedExpandRange)
                panelRestingOffset = clamped
                panelDragOffset = clamped
            }
    }

    private var contentDeckDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        .clear,
                        routeColor.opacity(0.10),
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
            .padding(.horizontal, AppTheme.Layout.margin)
    }

    /// Elegant gradient separator between hero zone and content.
    private var heroSeparator: some View {
        HStack(spacing: 0) {
            // Leading accent dot
            Circle()
                .fill(
                    RadialGradient(
                        colors: [routeColor.opacity(0.6), routeColor.opacity(0.15)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 4
                    )
                )
                .frame(width: 4, height: 4)
            // Fading gradient line
            LinearGradient(
                stops: [
                    .init(color: routeColor.opacity(0.3), location: 0),
                    .init(color: routeColor.opacity(0.05), location: 0.6),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.5)
        }
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    // MARK: - Lifecycle Handlers

    /// Rebuilds the cached decoded direction polyline from the current `routeShape`
    /// and `selectedDirectionIndex`.  Called when shape or direction changes — NOT
    /// on every body evaluation.  This avoids re-decoding Google-encoded polylines
    /// (O(total_encoded_chars)) on every 1 Hz tick.
    private func rebuildCachedPolyline() {
        guard let shape = routeShape else {
            cachedDirectionPolyline = []
            return
        }
        let directionStops = shape.stopsForDirection(
            index: selectedDirectionIndex,
            name: selectedDirectionName,
            shapeDirectionId: selectedShapeDirectionId,
            fallbackToCombined: false
        )
        let rawSegments = shape.polylinesForDirection(
            index: selectedDirectionIndex,
            name: selectedDirectionName,
            shapeDirectionId: selectedShapeDirectionId,
            fallbackToCombined: false
        )
        let segments = HomeViewModel.filterPolylinesToDirectionStops(
            rawSegments,
            stops: directionStops,
            isBus: group.isBus
        )
        // Bus routes can have loops/branches — keep segments merged but
        // don't force-consolidate into a single line.  Trains benefit
        // from consolidation for seamless vehicle interpolation.
        if group.isBus {
            let merged = mergeOrderedPolylines(segments)
            cachedDirectionPolyline = merged.flatMap { $0 }
        } else if segments.count > 1 {
            cachedDirectionPolyline = bestRailSegment(
                from: segments,
                directionStops: directionStops
            ) ?? segments.max(by: { $0.count < $1.count }) ?? []
        } else {
            cachedDirectionPolyline = segments.flatMap { $0 }
        }
    }

    private func bestRailSegment(
        from segments: [[CLLocationCoordinate2D]],
        directionStops: [BusStop]
    ) -> [CLLocationCoordinate2D]? {
        guard segments.count > 1,
              let anchor = selectedRailSegmentAnchor(in: directionStops)
        else { return nil }

        return segments.min { lhs, rhs in
            let lhsDistance = VehicleInterpolator
                .snap(coordinate: anchor, to: lhs)?.distanceFromPolyline ?? .greatestFiniteMagnitude
            let rhsDistance = VehicleInterpolator
                .snap(coordinate: anchor, to: rhs)?.distanceFromPolyline ?? .greatestFiniteMagnitude
            return lhsDistance < rhsDistance
        }
    }

    private func selectedRailSegmentAnchor(in directionStops: [BusStop]) -> CLLocationCoordinate2D? {
        let candidateKeys = [
            inSheetSelectedStopId,
            selectedStopId,
            stableNearestArrivals.first?.stopId,
            stableNearestArrivals.first?.stopName,
            nearestStopArrivals.first?.stopId,
            nearestStopArrivals.first?.stopName,
        ].compactMap { key -> String? in
            guard let key, !key.isEmpty else { return nil }
            return key
        }

        for key in candidateKeys {
            let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let stop = directionStops.first(where: { stop in
                stop.id == key
                    || normalizeStopId(stop.id) == normalizeStopId(key)
                    || stop.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedKey
            }) {
                return CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
            }
        }
        return nil
    }

    /// Updates the bound `isSelectedArrivalExpress` from the currently
    /// active arrival: user-selected chip → that chip's express flag,
    /// otherwise the nearest (first) arrival's express flag.
    private func syncExpressState() {
        if let selId = selectedChipRouteId {
            isSelectedArrivalExpress = stableNearestArrivals
                .first { $0.routeId == selId }?.isExpress ?? false
        } else {
            isSelectedArrivalExpress = stableNearestArrivals
                .first?.isExpress ?? false
        }
    }

    private func handleOnAppear() {
        // Prime the direction-change guard so the first real direction change
        // (e.g. from a DIR_PREF restore) is handled, not spurious double-fires.
        _lastHandledDirectionIndex = selectedDirectionIndex
        isFavorited = favoritesManager.isFavorite(routeId: group.routeId, mode: group.mode)
        isLoadingArrivals = true
        // Initialize stable schedule snapshots from props
        if busSchedule != nil { stableBusSchedule = busSchedule }
        if !cachedTrainArrivals.isEmpty { stableTrainArrivals = cachedTrainArrivals }
        lastStableRefreshDate = .distantPast
        if lockedDirectionHeadsign == nil {
            lockedDirectionHeadsign = safeDirection.direction
        }
        didWarmInitialContent = false
        Task { @MainActor in
            await Task.yield()
            warmInitialRouteDetailContent()
        }
        #if DEBUG
        AppLogger.shared.log(
            "ROUTE_DETAIL",
            message:
                "VIEW_OPEN route=\(group.routeId)"
                + " dir=\(safeDirection.direction)"
                + " live=\(safeDirection.liveArrivals.count)"
        )
        #endif
    }

    private func warmInitialRouteDetailContent() {
        rebuildCachedPolyline()
        isLoadingArrivals = safeDirection.arrivals.isEmpty
        stableNearestArrivals = nearestStopArrivals
        // Sync express state so map + stops list start with correct skip state.
        syncExpressState()
        refreshDirectionBadgeCounts()
        refreshArrivalByStopCache()
        if lockedStopKeyPerDirection[selectedDirectionIndex] == nil,
           let selectedStopId, !selectedStopId.isEmpty {
            lockedStopKeyPerDirection[selectedDirectionIndex] = selectedStopId
        } else if lockedStopKeyPerDirection[selectedDirectionIndex] == nil,
                  let first = stableNearestArrivals.first {
            lockedStopKeyPerDirection[selectedDirectionIndex] = first.stopId ?? first.stopName
        }
        didWarmInitialContent = true
    }

    private func handleGroupChange() {
        if !didWarmInitialContent {
            warmInitialRouteDetailContent()
            return
        }
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
        if let selectedStopId, !selectedStopId.isEmpty {
            lockedStopKeyPerDirection[selectedDirectionIndex] = selectedStopId
        } else if lockedStopKeyPerDirection[selectedDirectionIndex] == nil,
                  let first = fresh.first {
            lockedStopKeyPerDirection[selectedDirectionIndex] = first.stopId ?? first.stopName
        }

        // ── Freeze chips while a chip is selected ──────────────────────
        // When the user is interacting with a chip (highlighted vehicle
        // on the map), defer chip-list updates so the strip doesn't
        // visually shift underneath them.  We catch up as soon as the
        // chip is deselected (see handleChipSelectionChange).
        // TIME LIMIT: If the chip has been selected for >20s, allow the
        // refresh anyway — the user needs fresh data even while interacting.
        // This prevents the sheet from going stale if the user stares at
        // a selected chip while the bus is stuck in traffic for minutes.
        if selectedChipId != nil {
            let timeSinceLastRefresh = Date.now.timeIntervalSince(lastStableRefreshDate)
            if timeSinceLastRefresh < 20 {
                chipRefreshDeferred = true
                #if DEBUG
                print("[STABLE_CHIPS] ⏸ DEFERRED — chip selected, skipping refresh")
                #endif
                return
            }
            #if DEBUG
            print("[STABLE_CHIPS] ⏰ CHIP TIMEOUT — refreshing despite chip selection (\(String(format: "%.0f", timeSinceLastRefresh))s)")
            #endif
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
                print(
                    "[STABLE_CHIPS] ♻️ FORCE-REFRESH:"
                    + " all \(stableNearestArrivals.count)"
                    + " stable arrivals are past due"
                )
                #endif
            }
        }
    }

    private func handleStopSelectionChange() {
        selectedChipId = nil
        selectedChipRouteId = nil
        onFocusVehicle?(nil)
        let fresh = nearestStopArrivals
        stableNearestArrivals = fresh
        lastStableRefreshDate = .now
        #if DEBUG
        if let sid = inSheetSelectedStopId {
            let stopName = routeShape?
                .stopsForDirection(
                    index: selectedDirectionIndex,
                    name: selectedDirectionName
                )
                .first(where: { $0.id == sid })?
                .name ?? sid
            let etas = fresh.map {
                "\($0.minutesAway)m"
                + "(\($0.isRealTime ? "LIVE" : "SCHED"))"
            }.joined(separator: ",")
            print(
                "[STOP_SELECT]"
                + " route=\(group.routeId)"
                + " stop='\(stopName)'"
                + " id=\(sid)"
                + " chips=\(fresh.count)"
                + " etas=[\(etas)]"
            )
        } else {
            print(
                "[STOP_SELECT]"
                + " route=\(group.routeId)"
                + " CLEARED → chips=\(fresh.count)"
            )
        }
        #endif
    }

    private func handleSelectedStopIdChange(_ newId: String?) {
        // Manual stop taps are mirrored into `inSheetSelectedStopId`; keep
        // that existing path so the user-selected pill and clear button work.
        guard !isStopManuallySelected else {
            handleMapStopTap(newId)
            return
        }

        // Auto-nearest GPS / drag-search updates should refresh the departure
        // board and route split anchor, but they should not be treated like a
        // user tap.  In particular, live chip auto-selection must never move
        // the walking route to a far prediction stop.
        if let newId, !newId.isEmpty {
            lockedStopKeyPerDirection[selectedDirectionIndex] = newId
        } else {
            lockedStopKeyPerDirection[selectedDirectionIndex] = nil
        }

        selectedChipId = nil
        selectedChipRouteId = nil
        onFocusVehicle?(nil)

        let fresh = nearestStopArrivals
        stableNearestArrivals = fresh
        lastStableRefreshDate = .now
        syncExpressState()
    }

    private func handleDirectionChange() {
        // Guard: skip duplicate fires that occur when selectedDirectionIndex is
        // written twice in rapid succession (initial open + DIR_PREF restore).
        guard selectedDirectionIndex != _lastHandledDirectionIndex else {
            #if DEBUG
            print("[DIR_CHANGE] ⏭ SKIP duplicate fire for idx=\(selectedDirectionIndex)")
            #endif
            return
        }
        _lastHandledDirectionIndex = selectedDirectionIndex

        inSheetSelectedStopId = nil
        selectedChipId = nil
        selectedChipRouteId = nil
        onFocusVehicle?(nil)
        onStopSelected?(nil)

        // Keep the locked headsign in sync with the new direction so that
        // safeDirection doesn't return an empty shell (arrivals: []).
        // The direction-picker button already sets this, but the swipe
        // DragGesture only mutates selectedDirectionIndex — this covers both.
        if selectedDirectionIndex < group.directions.count {
            lockedDirectionHeadsign = group.directions[selectedDirectionIndex].direction
        }

        // Clear the locked stop for the new direction so it re-resolves fresh.
        // The old lock may carry a platform stop ID from the opposite direction
        // (e.g. 726N for southbound) that won't match any arrivals in this direction,
        // causing the chip list to show only expiring SCHED entries instead of live.
        lockedStopKeyPerDirection[selectedDirectionIndex] = nil

        rebuildCachedPolyline()
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
                "DIR_CHANGE"
                + " route=\(group.routeId)"
                + " mode=\(group.mode)"
                + " selectedDirIdx=\(selectedDirectionIndex)"
                + " dir=\(direction.direction)"
                + " all=\(direction.arrivals.count)"
                + " live=\(direction.liveArrivals.count)"
        )
        #endif
        logETAParity(reason: "dir_change")
    }

    private func handleScheduleChange() {
        // Snapshot schedule data into @State so it survives across SwiftUI
        // render cycles.  The prop-passed `busSchedule`/`cachedTrainArrivals`
        // may be stale when event handlers (e.g. direction change) read them
        // because SwiftUI fires onChange AFTER props are captured.
        if busSchedule != nil {
            stableBusSchedule = busSchedule
        }
        if !cachedTrainArrivals.isEmpty {
            stableTrainArrivals = cachedTrainArrivals
        }

        // Don't disrupt chips while user has a chip selected
        guard selectedChipId == nil else {
            chipRefreshDeferred = true
            return
        }
        stableNearestArrivals = nearestStopArrivals
    }

    /// Called when `selectedChipId` changes.  When the user deselects a
    /// chip (value → nil), catch up with any deferred chip refreshes so
    /// the strip shows the latest data.  When the user *selects* a chip,
    /// kick off a fetch for that trip's per-stop predictions so the Stops
    /// list can re-render ETAs from the selected vehicle's perspective.
    private func handleChipSelectionChange(_ newId: String?) {
        guard let newId else {
            // Deselect → drop trip-specific overrides + run any deferred refresh.
            selectedTripStopETAs = [:]
            guard chipRefreshDeferred else { return }
            chipRefreshDeferred = false
            let fresh = nearestStopArrivals
            if shouldRefreshStableArrivals(fresh) {
                stableNearestArrivals = fresh
                lastStableRefreshDate = .now
            }
            return
        }
        // Selection → look up the chip's trip ID and fetch its stop times.
        // Only subway trips have stable trip_ids in the GTFS-RT cache, so
        // skip the fetch for buses (their per-stop predictions come from
        // SIRI and aren't trip-keyed).
        guard group.mode == "subway",
              let arrival = stableNearestArrivals.first(where: { $0.id == newId }),
              let tripId = arrival.tripId, !tripId.isEmpty
        else {
            selectedTripStopETAs = [:]
            return
        }
        Task { @MainActor in
            do {
                let etas = try await TripStopTimesService.shared.stopETAs(for: tripId)
                // Guard against the user deselecting/changing chip mid-flight.
                guard selectedChipId == newId else { return }
                selectedTripStopETAs = etas
            } catch {
                // Network failure → silently fall back to existing per-stop
                // arrivals.  No UI surface needed; the Stops list keeps its
                // pre-selection ETAs.
                selectedTripStopETAs = [:]
            }
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

    /// Walking distance to the nearest stop on this route, in meters.
    private var nearestStopWalkingDistance: Double? {
        guard let loc = currentLocation ?? searchCenter else { return nil }
        let refLoc = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
        let allArrivals = group.directions.flatMap(\.arrivals)
        var best = Double.greatestFiniteMagnitude
        for a in allArrivals {
            if let lat = a.stopLat, let lon = a.stopLon {
                let d = refLoc.distance(from: CLLocation(latitude: lat, longitude: lon))
                if d < best { best = d }
            } else if let dm = a.distanceM, dm < best {
                best = dm
            }
        }
        return best < .greatestFiniteMagnitude ? best : nil
    }

    private var routeModeLabel: String {
        if group.isCommuterRail {
            return group.isLIRR ? "LIRR" : "Metro-North"
        }
        return group.isBus ? "Bus" : "Subway"
    }

    private var headerDisplayRouteID: String {
        let preferredRoute = selectedChipRouteId
            ?? stableNearestArrivals.first?.displayName
            ?? (!group.displayName.isEmpty ? group.displayName : group.routeId)
        return BranchNames.resolveDisplayName(routeId: preferredRoute, mode: group.mode)
    }

    private var headerBadgeIsExpress: Bool {
        if let selId = selectedChipRouteId {
            return stableNearestArrivals.first(where: { $0.routeId == selId })?.isExpress ?? false
        }
        return stableNearestArrivals.first?.isExpress ?? false
    }

    // NOTE: routeHeader, routeIdentityPill, liveStatusPill, currentDirectionLabel,
    // headerTitleFontSize removed — replaced by `unifiedRouteHeroCard`.

    @ViewBuilder
    private var supplementalHeaderChips: some View {
            HStack(spacing: 8) {
                // Favorite heart
                Button {
                    guard supabase.isAuthenticated else {
                        showSignInPrompt = true
                        return
                    }
                    Task {
                        let nowFav = await FavoritesManager.shared.toggleFavorite(
                            routeId: group.routeId,
                            routeDisplayName: group.displayName,
                            mode: group.mode
                        )
                        withAnimation(.spring(response: 0.3)) {
                            isFavorited = nowFav
                        }
                        HapticManager.notification(isFavorited ? .success : .warning)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isFavorited ? "heart.fill" : "heart")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(isFavorited ? AppTheme.Colors.favoriteTint : AppTheme.Colors.textSecondary)
                            .symbolEffect(.bounce, value: isFavorited)
                        if isFavorited {
                            Text("Saved")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(AppTheme.Colors.favoriteTint)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .trackOverlayGlass(
                        tint: isFavorited ? AppTheme.Colors.favoriteTint : routeColor,
                        cornerRadius: 999,
                        tintOpacity: isFavorited ? 0.08 : 0.05
                    )
                }
                .accessibilityLabel(isFavorited ? "Remove from favorites" : "Add to favorites")

                // Lost something?
                Button {
                    showLostAndFound = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bag.fill.badge.questionmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Lost something?")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(AppTheme.Colors.lostItemTint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .trackOverlayGlass(
                        tint: AppTheme.Colors.lostItemTint,
                        cornerRadius: 999,
                        tintOpacity: 0.06
                    )
                }

                Spacer()

                // Weather — pushed to trailing edge
                if let weather = weatherSnapshot {
                    WeatherChipView(snapshot: weather, style: .standard)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: weatherSnapshot != nil)
    }

    // NOTE: `routeHeaderActionRail` and `closeRouteButton` were removed —
    // the close X now lives on the MapControlsOverlay route banner so we
    // never have two X buttons on screen.  `recenterRouteButton` is still
    // rendered directly by the panel's ZStack (see body).

    private var recenterRouteButton: some View {
        Button {
            onRecenter?()
        } label: {
            actionCircle(
                icon: "location.fill",
                iconColor: AppTheme.Colors.mtaBlue,
                fill: AnyShapeStyle(AppTheme.Gradients.accentSurface),
                borderColor: AppTheme.Colors.borderAccent.opacity(0.35),
                glowColor: AppTheme.Colors.mtaBlue.opacity(0.08),
                size: 42
            )
        }
        .accessibilityLabel("Recenter on my location")
    }

    private var favoriteRouteButton: some View {
        Button {
            guard supabase.isAuthenticated else {
                showSignInPrompt = true
                return
            }
            Task {
                let nowFav = await FavoritesManager.shared.toggleFavorite(
                    routeId: group.routeId,
                    routeDisplayName: group.displayName,
                    mode: group.mode
                )
                withAnimation(.spring(response: 0.3)) {
                    isFavorited = nowFav
                }
                HapticManager.notification(isFavorited ? .success : .warning)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        isFavorited
                            ? AnyShapeStyle(
                                RadialGradient(
                                    colors: [
                                        .red.opacity(0.18),
                                        .red.opacity(0.06),
                                        .clear,
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 20
                                )
                              )
                            : AnyShapeStyle(AppTheme.Gradients.controlSurface)
                    )
                    .overlay {
                        Circle().strokeBorder(
                            isFavorited
                                ? Color.red.opacity(0.25)
                                : AppTheme.Colors.borderSubtle,
                            lineWidth: 0.5
                        )
                    }
                Image(systemName: isFavorited ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(isFavorited ? .red : AppTheme.Colors.textSecondary)
                    .symbolEffect(.bounce, value: isFavorited)
            }
            .frame(width: 42, height: 42)
            .shadow(
                color: isFavorited
                    ? .red.opacity(0.15)
                    : AppTheme.Colors.shadow.opacity(0.1),
                radius: 6,
                y: 2
            )
        }
        .accessibilityLabel(isFavorited ? "Remove from favorites" : "Add to favorites")
    }

    // NOTE: `closeRouteButton` removed — the close X is now provided by
    // MapControlsOverlay's route banner (top-right) so we don't render
    // two X buttons.

    // MARK: - Action Circle Button

    /// Reusable glass-style circular action button used in the header.
    private func actionCircle(
        icon: String,
        iconColor: Color,
        fill: AnyShapeStyle,
        borderColor: Color,
        glowColor: Color = .clear,
        size: CGFloat = 34
    ) -> some View {
        ZStack {
            Circle()
                .fill(fill)
                .overlay(
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.12), location: 0),
                                    .init(color: borderColor, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
            Image(systemName: icon)
                .font(.system(size: max(14.0, size * 0.38), weight: .bold))
                .foregroundColor(iconColor)
        }
        .frame(width: size, height: size)
        .shadow(color: glowColor, radius: 8, y: 2)
        .shadow(color: AppTheme.Colors.shadow.opacity(0.1), radius: 4, y: 2)
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
        // Backend says the vehicle is arriving NOW — never filter it out.
        // This prevents chips=0 when the bus is physically at the stop but
        // its polyline fraction is slightly past the stop marker.
        if arrival.minutesAway <= 0 { return false }
        // Only check vehicles that are actually on the map
        guard isLiveOnMap?(arrival) ?? false else { return false }

        let vehicleCoord: CLLocationCoordinate2D? = vehicleCoordinate(for: arrival)
        guard let vc = vehicleCoord else { return false }

        // Polyline path: high-confidence past-stop check using fraction along.
        if polyline.count >= 2,
           let snap = VehicleInterpolator.snap(coordinate: vc, to: polyline),
           snap.distanceFromPolyline < 500 {
            // How far past the stop (in meters) the vehicle is
            // Use totalPolylineLength from snap result — avoids redundant O(N) pass
            let pastDistance =
                (snap.fractionAlongPolyline - stopFraction)
                * snap.totalPolylineLength
            // Vehicle is past the stop by more than the grace buffer → gone
            return pastDistance > 150
        }

        // Geographic fallback (Wave 9) — when the polyline isn't usable
        // (off-route bus, missing shape, or vehicle snapped > 500 m from
        // the line), guard against past-stop chips by comparing vehicle
        // GPS to the stop GPS directly.  We only filter when the bus is
        // both physically far from the stop AND the backend's predicted
        // arrival is suspiciously soon (<= 1 min) — a strong signal the
        // RT prediction is stale and the bus has already left.
        if let stopLat = arrival.stopLat,
           let stopLon = arrival.stopLon {
            let stopLoc = CLLocation(latitude: stopLat, longitude: stopLon)
            let vehLoc = CLLocation(latitude: vc.latitude, longitude: vc.longitude)
            let metersFromStop = vehLoc.distance(from: stopLoc)
            if metersFromStop > 600 && arrival.minutesAway <= 1 {
                return true
            }
        }
        return false
    }

    /// Builds the direction polyline and stop fraction used by the passed-stop
    /// filter and polyline-distance sort.  Uses `cachedDirectionPolyline` to
    /// avoid re-decoding Google-encoded polylines on every body evaluation.
    private var directionPolylineAndStopFraction: (
        polyline: [CLLocationCoordinate2D],
        stopFraction: Double?
    ) {
        let polyline: [CLLocationCoordinate2D] = cachedDirectionPolyline

        let liveOnly = safeDirection.liveArrivals

        let nearestStopKey: String? = {
            if let userStop = inSheetSelectedStopId, !userStop.isEmpty { return userStop }
            if let vmStop = selectedStopId, !vmStop.isEmpty { return vmStop }
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
                if let loc = refLoc, let lat = arrival.stopLat, let lon = arrival.stopLon {
                    dist = loc.distance(from: CLLocation(latitude: lat, longitude: lon))
                } else if let loc = refLoc {
                    dist = arrivalDistance(arrival, from: loc)
                } else if let dm = arrival.distanceM {
                    dist = dm
                } else {
                    dist = .greatestFiniteMagnitude
                }
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
                        let stops = shape.stopsForDirection(
                            index: selectedDirectionIndex,
                            name: selectedDirectionName
                        )
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
            reachable = liveOnly.filter {
                !hasVehiclePassedStop(
                    $0,
                    stopFraction: sf,
                    polyline: polyline
                )
            }
        } else {
            reachable = liveOnly
        }
        guard !reachable.isEmpty else { return [] }

        // ── Helper: get vehicle's distance-to-stop along polyline ──
        func vehicleDistanceToStop(_ arrival: NearbyTransitResponse) -> Double? {
            guard let sf = stopFraction, polyline.count >= 2 else { return nil }
            let vehicleCoord = vehicleCoordinate(for: arrival)
            guard let vc = vehicleCoord,
                  let snap = VehicleInterpolator.snap(coordinate: vc, to: polyline),
                  snap.distanceFromPolyline < 500
            else { return nil }
            // Use totalPolylineLength from snap result — avoids redundant O(N) pass
            return abs(snap.fractionAlongPolyline - sf) * snap.totalPolylineLength
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

        // When the backend returns no arrivals at all, still try to show
        // scheduled departures from the bus schedule / GTFS data.
        // This fills the chip scroller for untracked late-night or
        // infrequent service where zero live vehicles exist.
        guard !raw.isEmpty else {
            return appendScheduledDepartures(to: [], direction: safeDirection)
        }

        // ── Pre-filter: remove vehicles that have passed the stop ──
        let (polyline, stopFraction) = directionPolylineAndStopFraction
        let live: [NearbyTransitResponse]
        if let sf = stopFraction {
            let filtered = raw.filter {
                !hasVehiclePassedStop(
                    $0,
                    stopFraction: sf,
                    polyline: polyline
                )
            }
            // Safety net: never drop ALL arrivals — if the polyline filter
            // removed everything, fall back to the unfiltered list so the
            // user never sees chips=0 when arrivals actually exist.
            live = filtered.isEmpty ? raw : filtered
        } else {
            live = raw
        }

        // Deduplicate helper (used in multiple branches below).
        // Sorts by ETA and deduplicates by vehicle/trip key.
        // Final display order is determined by buildOrderedChips which
        // sorts all chips chronologically (live + scheduled interleaved).
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
            let stopName = routeShape?
                .stopsForDirection(
                    index: selectedDirectionIndex,
                    name: selectedDirectionName
                )
                .first(where: { $0.id == userStop })?
                .name ?? userStop
            let etas = atSelected.map { "\($0.minutesAway)m" }.joined(separator: ",")
            let stopTapKey = "\(group.routeId)_\(userStop)_\(atSelected.count)_\(etas)"
            if stopTapKey != Self._lastStopTapLog {
                Self._lastStopTapLog = stopTapKey
                print(
                    "[STOP_TAP]"
                    + " route=\(group.routeId)"
                    + " stop=\(stopName)"
                    + " id=\(userStop)"
                    + " liveHits=\(atSelected.count)"
                    + " etas=[\(etas)]"
                )
            }
            #endif

            // Even when no live arrivals match, append scheduled departures
            // so the user still sees upcoming service at the selected stop.
            return appendScheduledDepartures(to: atSelected, direction: safeDirection)
        }

        // ── Prefer ViewModel's selectedStopId (GPS/drag nearest shape stop) ─
        // This is the route-detail boarding stop.  Do not let a live chip's
        // prediction stop override it; buses report many future onward-call
        // stops and the first live vehicle may be far from the rider.
        if let vmStop = selectedStopId, !vmStop.isEmpty {
            let atVM = deduped(live.filter {
                arrivalMatchesStop($0, stopId: vmStop)
            })
            return appendScheduledDepartures(to: atVM, direction: safeDirection)
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
        // Resolve from `raw` (unfiltered) so the nearest-stop key matches
        // `ArrivalHelpers.countdownArrival` used by the home row.  The
        // polyline pass-filter (`live`) may have removed vehicles at the
        // closest stop, causing a different stop to win the distance race
        // and producing an ETA_PARITY mismatch.
        if nearestStopKey == nil {
            let refLoc: CLLocation? = (currentLocation ?? searchCenter).map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
            }
            var nearestDist: CLLocationDistance = .greatestFiniteMagnitude

            for arrival in raw {
                let dist: CLLocationDistance
                if let loc = refLoc, let lat = arrival.stopLat, let lon = arrival.stopLon {
                    dist = loc.distance(from: CLLocation(latitude: lat, longitude: lon))
                } else if let loc = refLoc {
                    dist = arrivalDistance(arrival, from: loc)
                } else if let dm = arrival.distanceM {
                    dist = dm
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
            let effectiveBusSchedule = stableBusSchedule ?? busSchedule
            let effectiveTrainArrivals =
                stableTrainArrivals.isEmpty
                ? cachedTrainArrivals
                : stableTrainArrivals
            let schedLogKey = "\(group.routeId)"
                + "_\(direction.direction.prefix(30))"
                + "_\(allSchedItems.count)"
                + "_\(schedItems.count)"
                + "_\(effectiveBusSchedule != nil)"
            if schedLogKey != Self._lastChipsSchedLog {
                Self._lastChipsSchedLog = schedLogKey
                if allSchedItems.isEmpty {
                    print(
                        "[CHIPS_SCHED]"
                        + " route=\(group.routeId)"
                        + " dir=\(direction.direction.prefix(30))"
                        + " scheduledDeparturesForCurrentDirection"
                        + " is EMPTY"
                        + " — busSchedule=\(effectiveBusSchedule != nil ? "loaded" : "nil")"
                        + " stableSched=\(stableBusSchedule != nil)"
                        + " cachedTrainArrivals=\(effectiveTrainArrivals.count)"
                        + " stableTrains=\(stableTrainArrivals.count)"
                    )
                }
            }
        }
        #endif

        // ── Nearest-stop anchor ─────────────────────────────────────────
        // Bus schedules return departures from every stop on the route.  When
        // live arrivals are present we know which stop the user is at, so we
        // discard schedule chips from any other stop.  Without this guard,
        // upstream stops (e.g. "130 PL/BERGEN RD") produce phantom chips that
        // appear earlier than the user's real next bus.
        // When *no* live arrivals exist there is no anchor and all schedule
        // chips pass through (so the departure board still fills for untracked
        // service).
        let anchorStopName: String? =
            baseChips.first(where: { $0.isRealTime })?.stopName
            ?? baseChips.first?.stopName
            ?? autoNearestShapeStopName()

        func schedItemMatchesAnchor(_ itemStop: String) -> Bool {
            guard let anchor = anchorStopName else { return true }
            let a = anchor.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let b = itemStop.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Normalize common punctuation differences ("130 ST /135 AV"
            // vs "130 ST/135 AV") before comparing.
            let aNorm = a.replacingOccurrences(of: " /", with: "/")
                         .replacingOccurrences(of: "/ ", with: "/")
            let bNorm = b.replacingOccurrences(of: " /", with: "/")
                         .replacingOccurrences(of: "/ ", with: "/")
            return aNorm == bNorm
                || aNorm.contains(bNorm) || bNorm.contains(aNorm)
        }

        var schedChips: [NearbyTransitResponse] = []
        for item in schedItems {
            let ts = Int(item.departureDate.timeIntervalSince1970)
            if existingTripIds.contains(item.id) { continue }
            // GTFS static trip IDs (e.g. "AFA25GEN-7064-Weekday-00_058350_7..S35R") don't
            // exact-match SIRI trip IDs (e.g. "058350_7..S").  Check if the GTFS ID contains
            // any existing SIRI ID as a substring (min 8 chars to avoid false positives).
            let gtfsLower = item.id.lowercased()
            if existingTripIds.contains(where: { k in k.count >= 8 && gtfsLower.contains(k.lowercased()) }) {
                continue
            }
            // Don't filter by timestamp exact match too aggressively, just trip IDs.
            // But if we have no trip ID, timestamp collision check is useful.
            if existingTimestamps.contains(ts) { continue }
            // Drop schedule chips from a different stop than the user's nearest stop.
            if !schedItemMatchesAnchor(item.stopName) { continue }

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
                isCancelled: false,
                colorHex: group.colorHex,
                busServiceType: group.busServiceType
            ))
        }

        #if DEBUG
        let liveCount = baseChips.filter(\.isRealTime).count
        let apiSchedCount = baseChips.filter { !$0.isRealTime }.count
        let appendedCount = schedChips.count
        let totalSched = scheduledDeparturesForCurrentDirection.count
        if !baseChips.isEmpty || !schedChips.isEmpty {
            let chipsKey = "\(group.routeId)"
                + "_\(liveCount)"
                + "_\(apiSchedCount)"
                + "_\(appendedCount)"
                + "_\(totalSched)"
                + "_\((baseChips + schedChips).map { $0.minutesAway }.description)"
            if chipsKey != Self._lastChipsLog {
                Self._lastChipsLog = chipsKey
                let chipDesc = (baseChips + schedChips).map { a -> String in
                    let tag = a.isRealTime ? "LIVE" : "SCHED"
                    let vid = a.vehicleId ?? a.tripId ?? "?"
                    return "\(a.minutesAway)m"
                        + "(\(tag),\(vid.suffix(12)))"
                }
                print(
                    "[CHIPS]"
                    + " route=\(group.routeId)"
                    + " dir=\(direction.direction.prefix(30))"
                    + "  live=\(liveCount)"
                    + " apiSched=\(apiSchedCount)"
                    + " appendedSched=\(appendedCount)"
                    + " (of \(totalSched) available)"
                    + "  chips=[\(chipDesc.joined(separator: ", "))]"
                )
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
    private func rowComparableCountdownArrival(
        for direction: DirectionArrivalsResponse
    ) -> NearbyTransitResponse? {
        let refCoord = currentLocation ?? searchCenter
        let refLoc = refCoord.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
        }
        return ArrivalHelpers.countdownArrival(
            for: direction,
            userLocation: refLoc,
            provider: smartETA
        )
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
        let ts = String(
            format: "%.1f",
            Date().timeIntervalSince1970
                .truncatingRemainder(dividingBy: 10000)
        )
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

                // GPS coordinates: look up the matching vehicle
                let coords: String = {
                    guard !a.isScheduledOnly else { return "" }
                    if let coord = vehicleCoordinate(for: a) {
                        return String(format: " 📍%.5f,%.5f", coord.latitude, coord.longitude)
                    }
                    return " (no GPS match)"
                }()

                return "  \(tag) \(a.minutesAway)m"
                    + " @ \(clockTime)"
                    + "  id=\(vid)"
                    + "  stop=\(a.stopName)\(coords)"
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
        out += "\n│  APPEARED (\(appeared.count)): "
            + "\(appeared.isEmpty ? "none" : appeared.joined(separator: ", "))"
        out += "\n│  VANISHED (\(vanished.count)): "
            + "\(vanished.isEmpty ? "none" : vanished.joined(separator: ", "))"
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

        let elapsed = Date.now.timeIntervalSince(lastStableRefreshDate)

        // ── Anti-flap: protect against dramatic count drops ───────────
        // When count drops by >50%, it's likely a data source switch or
        // backend returning sparse data — not real departures.
        // Block the drop temporarily to prevent jarring chip count changes.
        let oldCount = stableNearestArrivals.count
        let newCount = new.count
        if newCount < oldCount / 2 && oldCount >= 4 {
            if elapsed < 45 {
                #if DEBUG
                print(
                    "[STABLE_CHIPS] ⏳ ANTI-FLAP:"
                    + " blocking count drop"
                    + " \(oldCount)→\(newCount),"
                    + " \(String(format: "%.0f", elapsed))s"
                    + " since last refresh"
                )
                #endif
                return false
            }
        }

        // ── Anti-flap: protect arrivals from SIRI feed dropouts ───────────
        // Compare by VEHICLE SET — not count.  Only block when vehicles
        // *vanished* (same vehicles minus some), which means the feed
        // temporarily dropped them.  If a vehicle legitimately departed
        // (new set has a different leading vehicle), allow the update.
        let oldKeys = Set(stableNearestArrivals.compactMap { $0.vehicleId ?? $0.tripId })
        let newKeys = Set(new.compactMap { $0.vehicleId ?? $0.tripId })
        let vanished = oldKeys.subtracting(newKeys)
        let appeared = newKeys.subtracting(oldKeys)

        // Vehicles vanished but none appeared → likely a SIRI feed dropout
        // or the nearby API replaced the enriched vehicle-sync data with
        // its sparse 2-arrival response.  Block for 45s (4-5 poll cycles)
        // to let the feed recover.  Extended from 25s to handle congested
        // corridors (e.g. Jamaica) where SIRI drops are frequent.
        if !vanished.isEmpty && appeared.isEmpty {
            if elapsed < 45 {
                #if DEBUG
                print(
                    "[STABLE_CHIPS] ⏳ ANTI-FLAP:"
                    + " blocking vanished=\(vanished)"
                    + " with no new arrivals,"
                    + " \(String(format: "%.0f", elapsed))s"
                    + " since last refresh"
                )
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
                message:
                    "reason=\(reason)"
                    + " route=\(group.routeId)"
                    + " dir=\(direction.direction)"
                    + " unavailable"
            )
            return
        }

        let rowETA = smartETA(for: rowArrival)
        let detailETA = smartETA(for: detailArrival)
        let deltaSeconds = Int(abs(rowETA.secondsRemaining - detailETA.secondsRemaining))

        AppLogger.shared.log(
            "ETA_PARITY",
            message:
                "reason=\(reason)"
                    + " route=\(group.routeId)"
                    + " dir=\(direction.direction)"
                    + " row=\(rowETA.minutesRemaining)m"
                    + " detail=\(detailETA.minutesRemaining)m"
                    + " delta=\(deltaSeconds)s"
                    + " rowStop=\(rowArrival.stopName)"
                    + " detailStop=\(detailArrival.stopName)"
        )

        // Log the full arrival lists from both sides so discrepancies are visible.
        // Row side: all live arrivals in the direction (same pool GroupedRouteRow uses)
        let rowLive = direction.liveArrivals
        let rowMins = rowLive.map { a -> String in
            let eta = smartETA(for: a)
            let vid = a.vehicleId ?? a.tripId ?? "?"
            let rtTag = a.isRealTime ? "LIVE" : "SCHED"
            return "\(eta.minutesRemaining)m"
                + "(raw=\(a.minutesAway)"
                + ",\(rtTag)"
                + ",id=\(vid.suffix(6))"
                + ",stop=\(a.stopName))"
        }
        // Detail side: the stable nearest-stop arrivals
        // (what the user sees as chips)
        let detailChips = stableNearestArrivals
        let detailMins = detailChips.map { a -> String in
            let eta = smartETA(for: a)
            let vid = a.vehicleId ?? a.tripId ?? "?"
            let rtTag = a.isRealTime ? "LIVE" : "SCHED"
            return "\(eta.minutesRemaining)m"
                + "(raw=\(a.minutesAway)"
                + ",\(rtTag)"
                + ",id=\(vid.suffix(6))"
                + ",stop=\(a.stopName))"
        }
        print(
            "[DETAIL_ARRIVALS]"
            + " route=\(group.routeId)"
            + "  row=[\(rowMins.joined(separator: ", "))]"
            + "  detail=[\(detailMins.joined(separator: ", "))]"
        )
        #endif
    }

    private func autoNearestShapeStopName() -> String? {
        let stopId = inSheetSelectedStopId ?? selectedStopId
        guard let stopId, !stopId.isEmpty, let shape = routeShape else { return nil }
        let stops = shape.stopsForDirection(
            index: selectedDirectionIndex,
            name: selectedDirectionName
        )
        let normalized = normalizeStopId(stopId)
        return stops.first(where: { $0.id == stopId })?.name
            ?? stops.first(where: { normalizeStopId($0.id) == normalized })?.name
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
        let allStops = shape.stopsForDirection(
            index: selectedDirectionIndex,
            name: selectedDirectionName
        )
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
    private func arrivalDistance(
        _ arrival: NearbyTransitResponse,
        from userLoc: CLLocation
    ) -> CLLocationDistance {
        // Use arrival's own coordinates if available
        if let lat = arrival.stopLat, let lon = arrival.stopLon {
            return userLoc.distance(from: CLLocation(latitude: lat, longitude: lon))
        }
        // Try to look up coordinates from route shape stops
        if let stopId = arrival.stopId, let shape = routeShape {
            let allStops = shape.stopsForDirection(
                index: selectedDirectionIndex,
                name: selectedDirectionName
            )
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
            let allStops = shape.stopsForDirection(
                index: selectedDirectionIndex,
                name: selectedDirectionName
            )
            if let stop = allStops.first(where: {
                $0.name.lowercased() == arrival.stopName.lowercased()
            }) {
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

    // MARK: - Vehicle Coordinate Lookup

    /// Unified vehicle coordinate lookup — uses vehicleCoordinateLookup closure for buses,
    /// trainVehicles for subway/LIRR/MNR. Returns nil for scheduled-only arrivals.
    private func vehicleCoordinate(for arrival: NearbyTransitResponse) -> CLLocationCoordinate2D? {
        if let detail = liveVehicleDetailLookup?(arrival),
           !detail.isStale,
           detail.positionConfidence >= 0.5 {
            return CLLocationCoordinate2D(latitude: detail.lat, longitude: detail.lon)
        }

        let vid = arrival.vehicleId ?? arrival.tripId
        guard let vid, !vid.isEmpty else { return nil }
        if arrival.isBus {
            return vehicleCoordinateLookup?(vid)
        } else {
            // Match train by vehicleId or tripId
            if let train = trainVehicles.first(where: { $0.id == vid || $0.tripId == vid }) {
                return CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
            }
        }
        return nil
    }

    // MARK: - Smart ETA

    /// Computes a smart ETA for an arrival using live vehicle position + polyline.
    /// Uses the data already available on the sheet (busVehicles, routeShape).
    private func smartETA(for arrival: NearbyTransitResponse) -> SmartETA {
        if let shared = smartETAProvider {
            return shared(arrival)
        }

        // Find the vehicle's live coordinate
        let vehicleCoord = arrival.isRealTime ? vehicleCoordinate(for: arrival) : nil

        let stopCoord: CLLocationCoordinate2D? = {
            if let lat = arrival.stopLat, let lon = arrival.stopLon {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            // Try route shape lookup
            if let sid = arrival.stopId, let shape = routeShape {
                let stops = shape.stopsForDirection(
                    index: selectedDirectionIndex,
                    name: selectedDirectionName
                )
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
            let cached = cachedDirectionPolyline
            return cached.count >= 2 ? cached : nil
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
        let isTrackedOnly = !arrival.isCancelled && status == .tracked
        let hasMarker = isLiveOnMap?(arrival) ?? false
        let liveDetail = liveVehicleDetailLookup?(arrival)
        return ArrivalChipData(
            id: arrival.id,
            minutesRemaining: eta.minutesRemaining,
            secondsRemaining: eta.secondsRemaining,
            isAtStop: eta.isAtStop,
            isRealTime: arrival.isRealTime,
            isCancelled: arrival.isCancelled,
            isScheduled: isSched,
            isTrackedOnly: isTrackedOnly,
            hasMapMarker: hasMarker,
            etaSource: eta.source,
            arrivalTimestamp: arrival.arrivalTs,
            vehicleId: arrival.vehicleId,
            tripId: arrival.tripId,
            routeId: arrival.routeId,
            isExpressFromServer: arrival.isExpress,
            serviceVariant: arrival.serviceVariant,
            variantLabel: arrival.variantLabel,
            stopId: arrival.stopId,
            mode: arrival.mode,
            delaySeconds: arrival.delaySeconds,
            isStalled: arrival.isStalled,
            arrivalProximityText: arrival.arrivalProximityText,
            livePositionSource: liveDetail?.positionSource,
            livePositionAgeSeconds: liveDetail?.positionAgeSeconds,
            livePositionConfidence: liveDetail?.positionConfidence,
            nextStopName: liveDetail?.nextStopName,
            downstreamStopCount: liveDetail?.downstreamStopCount ?? 0
        )
    }

    private func arrivalCard(
        arrival: NearbyTransitResponse,
        index: Int,
        eta: SmartETA
    ) -> some View {
        let chip = makeChipData(arrival: arrival, eta: eta)
        // Tappable for any non-disabled chip: live or tracked-only.
        // Scheduled and cancelled chips remain informational.
        let isChipTappable = !chip.isScheduled && !chip.isCancelled
        // Always pass the route's theme color — `ArrivalChipView` greys out
        // tracked-only / scheduled chips internally, and promotes the color
        // back when the user selects a tracked chip.
        let chipAccent: Color = chip.isCancelled
            ? AppTheme.Colors.alertRed
            : chip.isScheduled ? AppTheme.Colors.textSecondary : routeColor
        return ArrivalChipView(
            chip: chip,
            index: index,
            accentColor: chipAccent,
            isSelected: selectedChipId == arrival.id
        ) {
            // Scheduled and cancelled chips are informational — not tappable.
            guard isChipTappable else { return }
            let vehicleKey = arrival.vehicleId ?? arrival.tripId
            if selectedChipId == arrival.id {
                selectedChipId = nil
                selectedChipRouteId = nil
                isSelectedArrivalExpress = stableNearestArrivals.first?.isExpress ?? false
                onFocusVehicle?(nil)
            } else {
                selectedChipId = arrival.id
                selectedChipRouteId = arrival.routeId
                isSelectedArrivalExpress = arrival.isExpress
                if let key = vehicleKey {
                    onFocusVehicle?(key)
                }
            }
            // Selection-style haptic: Transit-grade snappy click instead
            // of a heavier impact thud.  Matches the chip's instantaneous
            // visual response (scale → 1.06 spring).
            HapticManager.selection()
        }
    }

    // MARK: - Countdown Section Helpers

    /// Resolve the display stop name for the countdown header.
    private func resolveDisplayStopName(source: [NearbyTransitResponse]) -> String? {
        // 1) User-selected stop — resolve name from shape or arrivals
        if let userStop = inSheetSelectedStopId, !userStop.isEmpty {
            if let shape = routeShape {
                let stops = shape.stopsForDirection(
                    index: selectedDirectionIndex,
                    name: selectedDirectionName
                )
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
                let stops = shape.stopsForDirection(
                    index: selectedDirectionIndex,
                    name: selectedDirectionName
                )
                let parentId = normalizeStopId(stopId)
                return stops.first(where: { $0.id == stopId })?.name
                    ?? stops.first(where: { normalizeStopId($0.id) == parentId })?.name
            }
        }
        return source.first?.stopName
    }

    /// Build ordered chips array from arrivals, partitioned live-first then scheduled.
    private func buildOrderedChips(
        from arrivals: [NearbyTransitResponse]
    ) -> [(arrival: NearbyTransitResponse, eta: SmartETA)] {
        // Partition into live and scheduled buckets, then sort each by ETA.
        // Live chips appear first (left) — matching Transit app behavior —
        // then scheduled chips follow, each group sorted by time.
        var live: [(arrival: NearbyTransitResponse, eta: SmartETA)] = []
        var sched: [(arrival: NearbyTransitResponse, eta: SmartETA)] = []
        for arrival in arrivals {
            let eta = smartETA(for: arrival)
            guard !eta.isPastArrival else { continue }
            // Partition by data-stable signal: is this a real-time
            // arrival (GTFS-RT or SIRI), not a pure schedule entry?
            // Using `isLiveOnMap` here would race against vehicle-feed
            // updates and momentarily drop a Live arrival into the
            // Sched bucket, letting a 5-min SCHED chip leap ahead of
            // an 8-min Live chip on every refresh.
            let isLiveData = arrival.isRealTime && !arrival.isScheduledOnly && !arrival.isPlaceholder
            if isLiveData {
                live.append((arrival, eta))
            } else {
                sched.append((arrival, eta))
            }
        }
        // Sort by feed arrivalTs (canonical order) when available.
        // SmartETA's vehicle-position blending can reorder far-out trains
        // (e.g. trip A inflated 10 min, trip B deflated 6 min → swapped),
        // but the feed's relative arrival order at a given stop is reliable.
        // Tiebreaker: stable `id` prevents flicker when two chips share an
        // identical timestamp — without it the TimelineView re-sort can swap
        // their order every second.
        live.sort { a, b in
            if let tsA = a.arrival.arrivalTs, let tsB = b.arrival.arrivalTs,
               tsA > 0, tsB > 0, tsA != tsB {
                return tsA < tsB
            }
            if a.eta.secondsRemaining != b.eta.secondsRemaining {
                return a.eta.secondsRemaining < b.eta.secondsRemaining
            }
            return a.arrival.id < b.arrival.id
        }
        sched.sort { a, b in
            if let tsA = a.arrival.arrivalTs, let tsB = b.arrival.arrivalTs,
               tsA > 0, tsB > 0, tsA != tsB {
                return tsA < tsB
            }
            if a.eta.secondsRemaining != b.eta.secondsRemaining {
                return a.eta.secondsRemaining < b.eta.secondsRemaining
            }
            return a.arrival.id < b.arrival.id
        }

        // Safety cap: if more than `maxNowChipsVisible` live chips show "NOW"
        // simultaneously, only keep the first N.  The GTFS-RT feed occasionally
        // publishes duplicate trip entries for the same physical train with
        // slightly different trip IDs — this prevents 4-6 ghost NOWs.
        let maxNows = ArrivalChipLogic.maxNowChipsVisible
        let nowCount = live.prefix(4).filter { pair in
            makeChipData(arrival: pair.arrival, eta: pair.eta).isNow
        }.count
        if nowCount > maxNows {
            // Keep first N true NOW chips, skip the rest that are also NOW.
            // Use the same contract as the renderer, not feed seconds alone.
            var keptNows = 0
            live = live.filter { pair in
                if makeChipData(arrival: pair.arrival, eta: pair.eta).isNow {
                    keptNows += 1
                    return keptNows <= maxNows
                }
                return true
            }
        }

        var result = live + sched

        // ── Guarantee minimum 6 chips ─────────────────────────────────────
        // If the pipeline produced fewer than 6 (backend returned few arrivals,
        // or isPastArrival removed some), pad with additional scheduled
        // departures from scheduledDeparturesForCurrentDirection, bypassing
        // the anchor-stop filter that may have been too strict upstream.
        if result.count < 6 {
            let existingTripIds = Set(result.compactMap(\.arrival.tripId))
            let existingTs     = Set(result.compactMap(\.arrival.arrivalTs))
            let allSched = scheduledDeparturesForCurrentDirection
            let nowTs    = Date().timeIntervalSince1970

            for item in allSched {
                guard result.count < 6 else { break }
                let ts = Int(item.departureDate.timeIntervalSince1970)
                guard ts > Int(nowTs - 60) else { continue }  // skip clearly past
                guard !existingTripIds.contains(item.id) else { continue }
                // GTFS/SIRI partial dedup (same as appendScheduledDepartures)
                let gtfsLow = item.id.lowercased()
                if existingTripIds.contains(where: { k in k.count >= 8 && gtfsLow.contains(k.lowercased()) }) { continue }
                guard !existingTs.contains(ts) else { continue }

                let synthetic = NearbyTransitResponse(
                    routeId: group.routeId,
                    stopName: item.stopName,
                    direction: safeDirection.direction,
                    destination: item.headsign,
                    minutesAway: item.minutesAway,
                    status: "Scheduled",
                    mode: group.mode,
                    stopLat: nil, stopLon: nil,
                    arrivalTs: ts,
                    vehicleId: nil,
                    tripId: item.id,
                    stopId: nil,
                    isRealTime: false,
                    isCancelled: false,
                    colorHex: group.colorHex,
                    busServiceType: group.busServiceType
                )
                let eta = smartETA(for: synthetic)
                guard !eta.isPastArrival else { continue }
                result.append((synthetic, eta))
            }

            // Re-sort after padding so times remain chronological.
            result.sort { a, b in
                if let tsA = a.arrival.arrivalTs, let tsB = b.arrival.arrivalTs,
                   tsA > 0, tsB > 0 { return tsA < tsB }
                return a.eta.secondsRemaining < b.eta.secondsRemaining
            }
        }

        return result
    }

    /// Stop-name pill shown when user has manually selected a stop.
    @ViewBuilder
    private func userSelectedStopPill(stopName: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(stopName)
                .font(.custom("Helvetica-Bold", fixedSize: 11))
                .lineLimit(1)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    inSheetSelectedStopId = nil
                    onStopSelected?(nil)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundColor(routeColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(routeColor.opacity(0.1))
                .overlay(
                    Capsule()
                        .strokeBorder(routeColor.opacity(0.2), lineWidth: 0.5)
                )
        )
    }

    /// Header row for the countdown section with "Next Arrivals" title and optional stop name.
    @ViewBuilder
    private func countdownHeader(displayStopName: String?, isUserSelected: Bool) -> some View {
        HStack(spacing: 8) {
            // Left accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(routeColor)
                .frame(width: 3, height: 18)

            Text("Next Arrivals")
                .font(.custom("Helvetica-Bold", fixedSize: 14))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .textCase(.uppercase)
                .tracking(0.8)

            if let stopName = displayStopName {
                if isUserSelected {
                    userSelectedStopPill(stopName: stopName)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(stopName)
                            .font(.custom("Helvetica-Bold", fixedSize: 11))
                            .lineLimit(1)
                    }
                    .foregroundColor(routeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(routeColor.opacity(0.08))
                    .clipShape(Capsule())
                }
            }

            Spacer()
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
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(routeColor.opacity(0.08))
                    .frame(width: 52, height: 52)
                Image(systemName: group.isBus ? "bus.fill" : "tram.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(routeColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("\(liveVehicleCount) vehicle\(liveVehicleCount == 1 ? "" : "s") en route")
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text("No predicted arrivals at your stop yet")
                    .font(.custom("Helvetica", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }

            Spacer()
        }
        .padding(16)
        .trackTintedCard(tint: routeColor, borderOpacity: 0.1, borderWidth: 0.5)
        .shadow(color: AppTheme.Colors.shadow.opacity(0.04), radius: 8, x: 0, y: 3)
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    /// Generic "No upcoming arrivals" state.
    private var countdownNoArrivalsState: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.10))
                    .frame(width: 48, height: 48)
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.indigo.opacity(0.55))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("No upcoming arrivals")
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                Text("Service may have ended for today")
                    .font(.custom("Helvetica", size: 12))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
            }

            Spacer()
        }
        .padding(16)
        .trackGlassCard(borderOpacity: 1.0, hasHighlight: false)
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
    /// Shows the first 6 chips, then a Transit-style "More departures" chip
    /// whenever the Departures tab can show *anything* — even a single
    /// scheduled trip later today, or the full GTFS timetable for the rest
    /// of the service week.  We never hide it just because fewer than 7 chips
    /// rendered: there is almost always more schedule depth available, and
    /// the chip is the user's only signal that the full timetable exists.
    private func countdownChipRow(
        chips: [(arrival: NearbyTransitResponse, eta: SmartETA)]
    ) -> some View {
        let visibleChips = Array(chips.prefix(6))
        // "More" total = anything in the schedule beyond the chips we just rendered.
        // Transit shows the chip whenever the Departures board is reachable —
        // we mirror that by checking the cached departure count (populated by
        // `refreshArrivalByStopCache`) plus the raw schedule depth as a fallback.
        let totalSchedDepth = max(
            cachedDepartureCount,
            scheduledDeparturesForCurrentDirection.count
        )
        let extraBeyondChips = max(0, totalSchedDepth - visibleChips.count)
        // Always render the "More departures" chip — the Departures tab is
        // the user's gateway to the full GTFS timetable for the rest of the
        // service week, so it must never disappear, even on a quiet route
        // where only a handful of chips are visible right now.
        let hasMore = true
        // When chips overflow but the schedule depth is unknown, fall back
        // to the chip overflow count for the badge.
        let badgeCount = max(extraBeyondChips, chips.count - visibleChips.count)

        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(Array(visibleChips.enumerated()), id: \.element.arrival.id) { index, pair in
                    arrivalCard(arrival: pair.arrival, index: index, eta: pair.eta)
                        // Wave 10: smooth in/out so newly-arrived chips
                        // and stops dropping off don't pop the strip.
                        .transition(
                            .asymmetric(
                                insertion: .opacity
                                    .combined(with: .scale(scale: 0.92))
                                    .combined(with: .move(edge: .trailing)),
                                removal: .opacity
                                    .combined(with: .scale(scale: 0.92))
                            )
                        )
                }

                if hasMore {
                    SeeMoreChip(routeColor: routeColor, remainingCount: badgeCount) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selectedTab = .departures
                        }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 8)
            .padding(.bottom, 0)
            // Wave 10: animate chip-strip changes (insert / remove / reorder)
            // by binding the animation to the ordered ID list so SwiftUI's
            // diffing engine has a stable signal to drive the transition.
            .animation(
                .spring(response: 0.4, dampingFraction: 0.88),
                value: visibleChips.map(\.arrival.id)
            )
            .onAppear {
                logChips(chips)
                autoSelectFirstChipIfNeeded(visible: visibleChips)
            }
            // Use a Set keyed on stable arrival.id so reorders or ETA
            // ticks don't trigger the auto-select cascade.  Only true
            // membership changes (a chip joins or leaves the strip)
            // re-fire this handler.
            .onChange(of: Set(chips.map(\.arrival.id))) { _, _ in
                logChips(chips)
                autoSelectFirstChipIfNeeded(visible: visibleChips)
            }
        }
    }

    /// Wave 5: when no chip is currently selected and the strip just
    /// rendered (or the chip identities changed enough that the prior
    /// selection is gone), auto-select the first *live* chip.  This
    /// makes the map open already focused on the next vehicle and
    /// matches the user's mental model that "the leftmost chip is the
    /// one you're tracking".
    private func autoSelectFirstChipIfNeeded(
        visible: [(arrival: NearbyTransitResponse, eta: SmartETA)]
    ) {
        // Honor an existing selection so taps stay sticky.
        if let sid = selectedChipId, visible.contains(where: { $0.arrival.id == sid }) {
            return
        }
        // Find the first chip that is genuinely live (has a marker) so
        // tapping focuses something the user can see on the map.
        guard let firstLive = visible.first(where: { pair in
            !pair.arrival.isCancelled
                && !pair.arrival.isPlaceholder
                && (isLiveOnMap?(pair.arrival) ?? false)
        }) else {
            // No live chip available — leave selection nil rather than
            // selecting a grey chip that has no marker to focus.
            if selectedChipId != nil { selectedChipId = nil }
            return
        }
        selectedChipId = firstLive.arrival.id
        selectedChipRouteId = firstLive.arrival.routeId
        isSelectedArrivalExpress = firstLive.arrival.isExpress
    }

    /// Resolve a stop_id to its `CLLocationCoordinate2D` using the route
    /// shape's stops for the currently-selected direction. Returns nil if
    /// the shape is not loaded or the stop is unknown.
    private func coordinateForStopId(_ stopId: String) -> CLLocationCoordinate2D? {
        guard let shape = routeShape else { return nil }
        let stops = shape.stopsForDirection(
            index: selectedDirectionIndex,
            name: selectedDirectionName
        )
        let parentId = normalizeStopId(stopId)
        guard let s = stops.first(where: { $0.id == stopId })
            ?? stops.first(where: { normalizeStopId($0.id) == parentId })
        else { return nil }
        return CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
    }

    /// A trailing chip in the horizontal scroller that switches to the
    /// Departures tab so the user can browse the full schedule board.
    /// Implementation lives in `Track/Views/Components/Chips/SeeMoreChip.swift`.

    /// Logs every visible chip for debugging — compare against raw endpoint data.
    private func logChips(_ chips: [(arrival: NearbyTransitResponse, eta: SmartETA)]) {
        #if DEBUG
        let dir = safeDirection.direction
        let stopName = chips.first?.arrival.stopName ?? "?"
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[CHIPS] \(group.routeId) → \(dir) | stop: \(stopName) | \(chips.count) chip(s)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        // Cap log to first 8 entries — schedule-heavy directions can produce
        // 100+ chips and blow out the console (one Q10 dump = 120 lines).
        let logCap = 8
        let toLog = chips.prefix(logCap)
        for (i, pair) in toLog.enumerated() {
            let a = pair.arrival
            let eta = pair.eta
            let type = a.isScheduledOnly ? "SCHED" : (a.isRealTime ? "LIVE" : "OTHER")
            let vid = a.vehicleId ?? "nil"
            let tid = a.tripId ?? "nil"
            let sid = a.stopId ?? "nil"
            let dest = a.destination ?? "nil"
            let mins = eta.minutesRemaining
            let secs = Int(eta.secondsRemaining)
            let status = a.status
            let ts = a.arrivalTs.map { String($0) } ?? "nil"
            let dist = a.distanceM.map { String(Int($0)) + "m" } ?? "nil"
            let isNow = a.isRealTime
                && eta.source == .vehiclePosition
                && eta.isAtStop
                && (isLiveOnMap?(a) ?? false)
            print(
                "  [\(i)] \(type)"
                + " | \(isNow ? "NOW" : "\(mins)min")"
                + " (\(secs)s)"
                + " | vid=\(vid) tid=\(tid)"
                + " | stop=\(a.stopName) sid=\(sid)"
                + " | dest=\(dest)"
                + " | status=\(status)"
                + " | arrTs=\(ts)"
                + " | dist=\(dist)"
            )
        }
        if chips.count > logCap {
            print("  … +\(chips.count - logCap) more chip(s) suppressed")
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
        #endif
    }

    private var countdownSection: some View {
        let source = didWarmInitialContent
            ? (stableNearestArrivals.isEmpty ? nearestStopArrivals : stableNearestArrivals)
            : []
        let isUserSelected = inSheetSelectedStopId != nil
        let displayStopName = resolveDisplayStopName(source: source)

        return VStack(alignment: .leading, spacing: 10) {
            countdownHeader(displayStopName: displayStopName, isUserSelected: isUserSelected)

            if let tip = catchThisOneTip(source: source) {
                catchThisOneBanner(tip)
            }

            if source.isEmpty {
                countdownEmptyState
            } else {
                countdownChipScroller(arrivals: source)
            }
        }
    }

    private var routeDetailWarmupPlaceholder: some View {
        VStack(spacing: 10) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.Colors.textTertiary.opacity(0.08))
                    .frame(height: 54)
                    .padding(.horizontal, AppTheme.Layout.margin)
            }
        }
        .redacted(reason: .placeholder)
    }

    /// Computes a "walk now to catch the next one" hint when the user is
    /// close enough that a brisk walk could realistically intercept the
    /// next live arrival.  Returns nil when the math doesn't work out
    /// (too far, plenty of time, no live arrivals, etc.).
    private func catchThisOneTip(
        source: [NearbyTransitResponse]
    ) -> (mins: Int, walkMins: Int, routeId: String)? {
        // Only show when the user is at the auto-nearest stop \u2014 if they've
        // explicitly selected a different stop, the walking math is wrong.
        guard inSheetSelectedStopId == nil,
              let distance = nearestStopWalkingDistance,
              distance >= 50, distance <= 600 else { return nil }
        // Brisk walking pace ~1.4 m/s = 84 m/min; ceil to be conservative.
        let walkMins = max(1, Int(ceil(distance / 84.0)))
        // Look at the soonest LIVE arrival (chip-relevant, not pure schedule).
        let firstLive = source.first {
            $0.isRealTime && !$0.isScheduledOnly && !$0.isPlaceholder
        }
        guard let arrival = firstLive else { return nil }
        let eta = smartETA(for: arrival)
        guard !eta.isPastArrival else { return nil }
        let mins = eta.minutesRemaining
        // Sweet spot: arrival is reachable on foot but not trivial.
        // Need at least 1 min slack, no more than 4 min over walking time.
        guard mins >= walkMins + 1, mins <= walkMins + 4 else { return nil }
        return (mins, walkMins, arrival.displayName)
    }

    private func catchThisOneText(tip: (mins: Int, walkMins: Int, routeId: String)) -> Text {
        let secondary = AppTheme.Colors.textSecondary
        let primary = AppTheme.Colors.textPrimary
        let route = Text(tip.routeId).foregroundStyle(routeColor).fontWeight(.bold)
        let walk = Text("\(tip.walkMins) min walk").foregroundStyle(primary).fontWeight(.semibold)
        let mins = Text("\(tip.mins) min").foregroundStyle(primary).fontWeight(.semibold)
        return Text("\(Text("Catch the ").foregroundStyle(secondary))\(route)\(Text(" — ").foregroundStyle(secondary))\(walk)\(Text(" for a ").foregroundStyle(secondary))\(mins)\(Text(" arrival").foregroundStyle(secondary))")
    }

    @ViewBuilder
    private func catchThisOneBanner(
        _ tip: (mins: Int, walkMins: Int, routeId: String)
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(routeColor)
            catchThisOneText(tip: tip)
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(routeColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(routeColor.opacity(0.18), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, AppTheme.Layout.margin)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Scheduled Departures (Unified: Bus + Train)

    /// Scheduled departures matching the currently selected direction.
    /// Combines bus schedule data and train GTFS data into a unified list.
    /// Filters to future departures only and sorts by time.
    private var scheduledDeparturesForCurrentDirection: [ScheduledItem] {
        let direction = safeDirection

        // Prefer stable @State snapshots over prop-passed values.
        // Props may be stale when called from event handlers (onChange fires
        // after props are captured).  Fall back to props for the initial
        // render before handleScheduleChange() populates the @State.
        let effectiveBusSchedule = stableBusSchedule ?? busSchedule
        let effectiveTrainArrivals =
            stableTrainArrivals.isEmpty
            ? cachedTrainArrivals
            : stableTrainArrivals

        // --- Bus schedule ---
        if group.isBus, let schedule = effectiveBusSchedule {
            return busScheduledDepartures(schedule: schedule, direction: direction)
        }

        // --- Train (subway / LIRR / MNR) schedule from cached GTFS arrivals ---
        if !group.isBus && !effectiveTrainArrivals.isEmpty {
            let dirLower = direction.direction.lowercased()

            // Route filter — cachedTrainArrivals may contain sister lines
            // from the same GTFS feed (e.g. A/C/E).  Only show *this*
            // route's schedules.
            let routeUpper = group.routeId.uppercased()
            let displayUpper = group.displayName.uppercased()

            // ── Resolve the user's nearest stop so we only show scheduled
            //    arrivals AT that stop (not at every stop on the line). ──
            let nearestStopName: String? = {
                // Use the ViewModel's resolved stop first
                if let sid = selectedStopId, !sid.isEmpty { return sid }
                // Fallback: find nearest from route shape
                if let shape = routeShape {
                    let refLoc = (currentLocation ?? searchCenter).map {
                        CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    }
                    if let refLoc {
                        let shapeDir = shape.matchedDirection(
                            index: selectedDirectionIndex,
                            name: direction.direction
                        )
                        let stops = shapeDir?.stops
                            ?? shape.stops
                        return stops.min(by: {
                            refLoc.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon))
                            < refLoc.distance(from: CLLocation(latitude: $1.lat, longitude: $1.lon))
                        })?.id
                    }
                }
                return nil
            }()

            let matching = cachedTrainArrivals.filter { arrival in
                // ── Route gate ──
                let arrRoute = arrival.routeID.uppercased()
                guard arrRoute == routeUpper
                        || arrRoute == displayUpper
                        || routeUpper.hasSuffix("_\(arrRoute)")
                else { return false }

                // ── Direction gate ──
                // Use destination matching — the direction field is just
                // "N"/"S" which false-matches via .contains() on almost
                // any direction name ("hudso*n* yards" contains "n").
                let arrDir = arrival.direction.lowercased()
                let arrDest = arrival.destination?.lowercased() ?? ""

                let dirMatch: Bool = {
                    // Exact matches are always safe
                    if arrDir == dirLower || arrDest == dirLower { return true }
                    // Only allow substring matching for strings >= 3 chars
                    // to avoid single-char compass codes ("n","s") false-matching
                    if arrDir.count >= 3
                        && (dirLower.contains(arrDir)
                            || arrDir.contains(dirLower)) {
                        return true
                    }
                    if arrDest.count >= 3
                        && (dirLower.contains(arrDest)
                            || arrDest.contains(dirLower)) {
                        return true
                    }
                    return false
                }()
                guard dirMatch else { return false }

                // ── Stop gate — only show the user's nearest stop ──
                if let nearest = nearestStopName {
                    let sid = arrival.stationID.lowercased()
                    let sname = arrival.stationName.lowercased()
                    let nLower = nearest.lowercased()
                    return sid == nLower || sname == nLower
                        || sid.contains(nLower) || nLower.contains(sid)
                        || sname.contains(nLower) || nLower.contains(sname)
                }
                return true
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

    /// Match a bus schedule direction to the currently-selected direction.
    /// Extracted from `scheduledDeparturesForCurrentDirection` to reduce
    /// type-checker pressure on the computed property.
    private func busScheduledDepartures(
        schedule: BusScheduleResponse,
        direction: DirectionArrivalsResponse
    ) -> [ScheduledItem] {
        let dirLower: String = direction.direction.lowercased()
        let stopWords: Set<String> = ["via", "to", "and", "the"]
        let dirTokens: Set<String> = Set(
            dirLower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        ).subtracting(stopWords)

        // Primary: flexible text match
        let matched: BusScheduleDirection? =
            schedule.directions.first { (schedDir: BusScheduleDirection) -> Bool in
                let schedDirLower: String = schedDir.direction.lowercased()
                let hsLower: String = schedDir.headsign.lowercased()
                if schedDirLower == dirLower { return true }
                if !hsLower.isEmpty
                    && (hsLower.contains(dirLower)
                        || dirLower.contains(hsLower)) {
                    return true
                }
                if !hsLower.isEmpty {
                    let hsTokens: Set<String> = Set(
                        hsLower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                            .map(String.init)
                    ).subtracting(stopWords)
                    let overlap: Set<String> = dirTokens.intersection(hsTokens)
                    if !hsTokens.isEmpty
                        && overlap.count >= max(1, hsTokens.count - 1) {
                        return true
                    }
                }
                return false
            }
            // Bridge via route shape: the live direction name (e.g. "133 ST-BROADWAY")
            // often doesn't match the OBA schedule headsign (e.g. "RIVERBANK 145 ST via 10 AV").
            // Use the route shape to find which direction_id the current direction maps to,
            // then match the schedule direction that corresponds to the same direction_id.
            ?? {
                guard let shape = routeShape, !shape.directions.isEmpty else { return nil }
                let shapeDir = shape.matchedDirection(
                    index: selectedDirectionIndex,
                    name: direction.direction
                )
                guard let shapeDirId = shapeDir?.directionId
                else { return nil }
                // Schedule directions are ordered by direction_id (0 first, 1 second).
                // Match by positional alignment: schedule dir at index N = direction_id N.
                let schedIdx = min(shapeDirId, schedule.directions.count - 1)
                guard schedIdx >= 0 && schedIdx < schedule.directions.count else { return nil }
                return schedule.directions[schedIdx]
            }()
            // Fallback: positional index match (last resort — may not align if
            // group has more directions than the schedule)
            ?? schedule.directions.first { (schedDir: BusScheduleDirection) -> Bool in
                let idx: Int? = schedule.directions.firstIndex(
                    where: { $0.direction == schedDir.direction }
                )
                return idx == selectedDirectionIndex
            }

        #if DEBUG
        do {
            let depCount: Int = matched?.departures.count ?? -1
            let matchKey: String =
                "\(group.routeId)_\(dirLower)"
                + "_\(matched?.direction ?? "nil")"
                + "_\(depCount)"
            if matchKey != Self._lastSchedMatchLog {
                Self._lastSchedMatchLog = matchKey
                if matched == nil {
                    let availDirs: [String] = schedule.directions.map {
                        "dir='\($0.direction)' hs='\($0.headsign)' deps=\($0.departures.count)"
                    }
                    print(
                        "[SCHED_MATCH] FAILED"
                        + " route=\(group.routeId)"
                        + " looking for '\(dirLower)'"
                        + " in [\(availDirs.joined(separator: ", "))]"
                    )
                } else if let m = matched {
                    print(
                        "[SCHED_MATCH] OK"
                        + " route=\(group.routeId)"
                        + " dir='\(dirLower)'"
                        + " \u{2192} sched dir='\(m.direction)'"
                        + " hs='\(m.headsign)'"
                        + " deps=\(m.departures.count)"
                    )
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

    // MARK: - Direction Picker

    /// Builds `DirectionPillData` array for the reusable `DirectionPickerView`.
    private func buildDirectionPills() -> [DirectionPillData] {
        // Safety filter: hide generic placeholder directions (e.g. "Outbound"
        // with no real arrivals) during the window before enrichGroupWithShapeDirections
        // fires.  If at least one other direction already has real arrivals we
        // know real terminal names are available, so suppress the placeholder tab.
        let hasRealDirection = group.directions.contains { dir in
            let key = dir.direction.lowercased()
            let isGenericKey = key == "outbound" || key == "inbound"
                || key == "northbound" || key == "southbound"
                || key == "eastbound" || key == "westbound"
            let hasRealArrivals = dir.arrivals.contains { !$0.isPlaceholder }
            return hasRealArrivals && !isGenericKey
        }

        let filtered = group.directions.enumerated().filter { (offset, dir) in
            guard hasRealDirection else { return true }  // nothing real yet → show all (loading state)
            let key = dir.direction.lowercased()
            let isGenericPlaceholder = (key == "outbound" || key == "inbound")
                && !dir.arrivals.contains { !$0.isPlaceholder }
            return !isGenericPlaceholder
        }

        // Reorder so the selected direction is first
        let all = filtered.map { (index: $0.offset, dir: $0.element) }
        var ordered = all
        if selectedDirectionIndex >= 0, selectedDirectionIndex < group.directions.count,
           let pos = ordered.firstIndex(where: { $0.index == selectedDirectionIndex }) {
            let selected = ordered.remove(at: pos)
            ordered.insert(selected, at: 0)
        }

        let pills = ordered.map { index, dir in
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
        return deduplicatedDirectionPills(pills)
    }

    /// Collapses identical rendered direction labels so backend/shape enrichment
    /// can't surface duplicate-looking tags like "Downtown" / "Downtown".
    /// If the selected direction is one of the duplicates, its pill wins so the
    /// map and selected polyline remain in sync with the user's current choice.
    private func deduplicatedDirectionPills(_ pills: [DirectionPillData]) -> [DirectionPillData] {
        var ordered: [DirectionPillData] = []
        var indexByLabel: [String: Int] = [:]

        for pill in pills {
            let key = normalizedDirectionPillLabel(pill.label)
            guard let existingIndex = indexByLabel[key] else {
                indexByLabel[key] = ordered.count
                ordered.append(pill)
                continue
            }

            let existing = ordered[existingIndex]
            let winner: DirectionPillData
            if pill.isActive || (!existing.isActive && pill.vehicleCount > existing.vehicleCount) {
                winner = DirectionPillData(
                    id: existing.id + "|" + pill.id,
                    index: pill.index,
                    label: pill.label,
                    serviceType: pill.serviceType ?? existing.serviceType,
                    vehicleCount: max(existing.vehicleCount, pill.vehicleCount),
                    isActive: existing.isActive || pill.isActive
                )
            } else {
                winner = DirectionPillData(
                    id: existing.id + "|" + pill.id,
                    index: existing.index,
                    label: existing.label,
                    serviceType: existing.serviceType ?? pill.serviceType,
                    vehicleCount: max(existing.vehicleCount, pill.vehicleCount),
                    isActive: existing.isActive || pill.isActive
                )
            }
            ordered[existingIndex] = winner
        }

        return ordered
    }

    private func normalizedDirectionPillLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "→", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
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
                hasScheduleData: busSchedule != nil || !cachedTrainArrivals.isEmpty,
                showsHeader: false
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
        .trackCardBackground(cornerRadius: 16)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(arrivalAccessibilityLabel(for: arrival))
    }

    private func arrivalAccessibilityLabel(for arrival: NearbyTransitResponse) -> String {
        let eta = smartETA(for: arrival)
        let etaText = (arrival.isRealTime
            && eta.source == .vehiclePosition
            && eta.isAtStop
            && (isLiveOnMap?(arrival) ?? false))
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
                    return routeShape?.stopsForDirection(
                        index: selectedDirectionIndex,
                        name: selectedDirectionName
                    ).count ?? 0
                case .departures:
                    return cachedDepartureCount
                case .alerts:
                    return routeServiceAlerts.count
                }
            }()
            return PillTab(
                id: tab.rawValue,
                label: tab.rawValue,
                icon: tabIcon(for: tab),
                badgeCount: badge
            )
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

    // MARK: - Alerts List

    /// Active service alerts that affect this route, deduped.  Reuses
    /// the same matching logic the map banner uses (`routeId` + display
    /// name on `.matching(routeId:mode:)`) so what's summarized in the
    /// banner matches exactly what's listed here.
    private var routeServiceAlerts: [TransitAlert] {
        let byId = serviceAlerts.matching(routeId: group.routeId, mode: group.mode)
        let byName = serviceAlerts.matching(routeId: group.displayName, mode: group.mode)
        var seen = Set<String>()
        return (byId + byName).filter { seen.insert($0.id).inserted }
    }

    /// Renders the Alerts tab content — either the full
    /// `RouteAlertsSection` (with expandable rows + inline route
    /// badges via `AlertRichText`) or an All-Clear empty state.
    @ViewBuilder
    private var alertsList: some View {
        let alerts = routeServiceAlerts
        if alerts.isEmpty {
            NoAlertsEmptyState(routeDisplayName: group.displayName)
        } else {
            RouteAlertsSection(alerts: alerts)
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

        // Express skip: grey out stops that only appear on local shapes.
        let localOnlyIds: Set<String> = {
            guard isSelectedArrivalExpress else { return [] }
            let ids = routeShape?.matchedDirection(
                index: selectedDirectionIndex,
                name: selectedDirectionName
            )?.localOnlyStopIds ?? []
            return Set(ids)
        }()

        // ── Anchor time for interpolation ──
        // Use the soonest live arrival's timestamp as the departure time
        // from that stop, then estimate subsequent stops using average
        // inter-stop travel time (~2 min for subway, ~3 min for bus).
        let anchorArrival = stableNearestArrivals.first(where: {
            !$0.isPlaceholder && $0.arrivalTs != nil
        })
        let anchorTs: Int? = anchorArrival?.arrivalTs
        let anchorStopId: String? = anchorArrival?.stopId.map { normalizeStopId($0) }
            ?? anchorArrival?.stopId
        let anchorStopName: String? = anchorArrival?.stopName
            .lowercased().trimmingCharacters(in: .whitespaces)

        // Find which index in dirStops the anchor corresponds to
        let anchorIndex: Int? = {
            guard anchorTs != nil else { return nil }
            for (i, s) in dirStops.enumerated() {
                let normId = normalizeStopId(s.id)
                if let aid = anchorStopId, (normId == aid || s.id == aid) { return i }
                let nameKey = s.name.lowercased().trimmingCharacters(in: .whitespaces)
                if let aName = anchorStopName, nameKey == aName { return i }
            }
            // Fallback: use first non-passed stop
            return currentIdx ?? 0
        }()

        let intervalSec: Int = group.isBus ? 180 : 120  // 3 min bus, 2 min subway

        let rows = dirStops.enumerated().map { index, stop -> StopRowData in
            let isPassed = currentIdx.map { index < $0 } ?? false
            let isCurrent = currentIdx == index
            let normId = normalizeStopId(stop.id)
            let nextArrival: NearbyTransitResponse? =
                arrivalByStop[normId]
                ?? arrivalByStop[stop.id]
                ?? arrivalByStop[stop.name.lowercased().trimmingCharacters(in: .whitespaces)]
            let transfers = transferRoutes(for: stop)
            let outages = accessibilityOutages(at: stop)

            // Per-trip override: when the user has tapped a chip, prefer
            // that specific vehicle's predicted arrival time at this stop
            // over the generic per-stop arrival.  Falls back to nil — and
            // therefore to the existing `nextArrival` path — when the
            // selected trip doesn't visit this stop.
            let tripOverrideTs: Int? = {
                guard !selectedTripStopETAs.isEmpty else { return nil }
                return selectedTripStopETAs[normId] ?? selectedTripStopETAs[stop.id]
            }()

            // Estimate arrival time if no live data for this stop
            let estimatedTs: Int? = {
                guard nextArrival == nil || nextArrival?.isPlaceholder == true,
                      let aTs = anchorTs, let aIdx = anchorIndex else { return nil }
                let stopsAway = index - aIdx
                guard stopsAway >= 0 else { return nil }  // don't estimate for passed stops
                return aTs + (stopsAway * intervalSec)
            }()

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
                hasElevatorOutage: outages.contains {
                    $0.equipmentType.lowercased()
                        .contains("elevator")
                },
                nextArrivalMinutes: {
                    if let ts = tripOverrideTs {
                        return max(0, Int((Double(ts) - Date().timeIntervalSince1970) / 60))
                    }
                    return nextArrival.flatMap { a -> Int? in
                        guard !a.isPlaceholder else { return nil }
                        return smartETA(for: a).minutesRemaining
                    }
                }(),
                nextArrivalIsScheduled: tripOverrideTs != nil
                    ? false
                    : (nextArrival?.isScheduledOnly ?? true),
                nextArrivalIsAtStop: tripOverrideTs != nil
                    ? false
                    : (nextArrival.map { arrival in
                        let eta = smartETA(for: arrival)
                        return arrival.isRealTime
                            && eta.source == .vehiclePosition
                            && eta.isAtStop
                            && (isLiveOnMap?(arrival) ?? false)
                    } ?? false),
                nextArrivalTimestamp: tripOverrideTs ?? nextArrival?.arrivalTs,
                estimatedTimestamp: estimatedTs,
                isFirst: index == 0,
                isLast: index == dirStops.count - 1,
                isSkipped: localOnlyIds.contains(stop.id),
                vehicleId: nextArrival?.vehicleId
            )
        }

        return rows
    }

    private var stopsListSection: some View {
        StopsListView(
            stops: buildStopRowData(),
            routeColor: routeColor,
            isLoading: routeShape == nil,
            selectedStopId: inSheetSelectedStopId,
            currentRouteID: group.displayName,
            currentRouteMode: group.mode,
            userLocation: currentLocation,
            showsHeader: false,
            usesEmbeddedSurface: true
        ) { stop in
            // Single tap → navigate to full stop detail sheet
            let dirStops = routeShape?.stopsForDirection(
                index: selectedDirectionIndex,
                name: selectedDirectionName
            ) ?? []
            if let busStop = dirStops.first(where: { $0.id == stop.id }) {
                let selection = StopDetailSelection.routeStop(
                    busStop, mode: group.mode,
                    fallbackRouteID: group.displayName
                )
                onStopDetailRequested?(selection)
            }
            HapticManager.impact(.light)
        }
        .onChange(of: selectedDirectionIndex) { _, _ in
            inSheetSelectedStopId = nil
            onStopSelected?(nil)
        }
    }

    /// "Leave something behind?" prompt shown below the stops list.
    private var lostAndFoundPrompt: some View {
        Button {
            showLostAndFound = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bag.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(AppTheme.Colors.mtaBlue.opacity(0.08))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Leave something behind?")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("Learn how to recover lost items on the MTA")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppTheme.Colors.cardFloating.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 16)
    }

    /// Finds transfer routes at a given stop.
    ///
    /// The backend's `enrich_stops_with_transfers` runs before every subway /
    /// commuter-rail shape response and writes the correct transfer route IDs
    /// into `stop.routeIds` using authoritative GTFS coordinates.  We simply
    /// read those here — no client-side station lookup needed.
    ///
    /// Two sources, combined additively:
    /// 1. **Backend-enriched route IDs** — `stop.routeIds` populated by the
    ///    backend's transfer-enrichment pipeline (subway + commuter rail stops).
    /// 2. **Fallback shape stops** — nearby/name-matched stops in the current
    ///    routeShape that carry routeIds (catches bus-to-bus transfers where
    ///    the current stop row itself has nil routeIds).
    ///
    /// Returns a deduplicated, sorted list of route display names (badges).
    private func transferRoutes(for stop: BusStop) -> [String] {
        let currentRoute = group.displayName
        var routes = Set<String>()

        // ── 1. Backend-enriched route IDs (authoritative source) ──
        if let routeIds = stop.routeIds {
            for rawId in routeIds {
                let display = BranchNames.resolveDisplayName(routeId: rawId, mode: "bus")
                if display != currentRoute && !display.isEmpty {
                    routes.insert(display)
                }
            }
        }

        // ── 2. Fallback: nearby/name-matched shape stops (captures bus transfers
        // when the current stop row itself has nil routeIds) ──
        if let shape = routeShape {
            let here = CLLocation(latitude: stop.lat, longitude: stop.lon)
            let stopNameKey = stop.name.lowercased().trimmingCharacters(in: .whitespaces)
            for direction in shape.directions {
                for candidate in direction.stops {
                    guard let candidateRouteIds = candidate.routeIds,
                          !candidateRouteIds.isEmpty
                    else {
                        continue
                    }
                    let candidateLoc = CLLocation(latitude: candidate.lat, longitude: candidate.lon)
                    let isNearby = here.distance(from: candidateLoc) <= 80
                    let isSameName = candidate.name.lowercased()
                        .trimmingCharacters(in: .whitespaces)
                        == stopNameKey
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

        // Filter out express variants that duplicate a base line the user
        // already sees (e.g. "6X" when "6" is present, "7X" when "7" is present,
        // "FX" when "F" is present).  These are the same physical line.
        let expressVariants: [String: String] = ["6X": "6", "7X": "7", "FX": "F"]
        for (express, base) in expressVariants {
            if routes.contains(express) && routes.contains(base) {
                routes.remove(express)
            }
        }

        // Sort: subway lines first (numeric then alpha), then buses
        let subwayIDs: Set<String> = [
            "1", "2", "3", "4", "5", "6", "6X",
            "7", "7X", "A", "C", "E", "B", "D",
            "F", "FX", "M", "G", "J", "Z", "L",
            "N", "Q", "R", "W", "GS", "FS", "SI",
        ]
        return routes.sorted { a, b in
            let aIsSubway = subwayIDs.contains(a.uppercased())
            let bIsSubway = subwayIDs.contains(b.uppercased())
            if aIsSubway != bIsSubway { return aIsSubway }
            // Both subway: numeric before alpha, then string compare
            if aIsSubway && bIsSubway {
                let aNum = Int(a)
                let bNum = Int(b)
                if let an = aNum, let bn = bNum { return an < bn }
                if aNum != nil { return true }
                if bNum != nil { return false }
            }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
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

    // MARK: - Loading Skeletons

    private var directionPickerSkeleton: some View {
        DirectionPickerSkeleton()
    }

    // MARK: - Route Info Footer

    /// Animating pulse state for the live indicator dot
    @State private var liveDotPulse = false

    /// Derive live vehicle count from the current direction's real-time arrivals.
    /// This is more accurate than the ViewModel's `filteredBusVehicles.count`
    /// which uses destination-matching heuristics and includes grace-buffered
    /// vehicles that may have already left the route.
    private var directionLiveVehicleCount: Int {
        let arrivals = safeDirection.arrivals
        let uniqueVehicles = Set(arrivals.filter(\.isRealTime).compactMap(\.vehicleId))
        // Prefer the direction-scoped count derived from real arrivals.
        // Fall back to the total route vehicle count only when the
        // direction has no arrival data at all (avoids showing "0 live buses"
        // when vehicles are clearly running but haven't been assigned to a
        // direction yet during the initial load window).
        return uniqueVehicles.isEmpty ? liveVehicleCount : uniqueVehicles.count
    }

    @ViewBuilder
    private var routeInfoFooter: some View {
        let shape = routeShape
        let hasStops = shape?.stops.isEmpty == false
        let hasVehicles = directionLiveVehicleCount > 0
        let isShapeLoading = shape == nil

        if isShapeLoading {
            RouteInfoFooterSkeleton()
        } else if hasStops || hasVehicles {
            HStack(spacing: 10) {
                if let shape, hasStops {
                    let dirStops = shape.stopsForDirection(
                        index: selectedDirectionIndex,
                        name: selectedDirectionName
                    )
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(routeColor)
                        Text("\(dirStops.count) stops")
                            .font(.custom("Helvetica-Bold", size: 12))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(routeColor.opacity(0.06))
                            .overlay(
                                Capsule()
                                    .strokeBorder(routeColor.opacity(0.1), lineWidth: 0.5)
                            )
                    )
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
                                withAnimation(
                                    .easeInOut(duration: 1.2)
                                        .repeatForever(autoreverses: false)
                                ) {
                                    liveDotPulse = true
                                }
                            }
                        let label = group.isBus ? "buses" : "trains"
                        Text("\(directionLiveVehicleCount) live \(label)")
                            .font(.custom("Helvetica-Bold", size: 12))
                            .foregroundColor(AppTheme.Colors.successGreen)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(AppTheme.Colors.successGreen.opacity(0.06))
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        AppTheme.Colors.successGreen
                                            .opacity(0.12),
                                        lineWidth: 0.5
                                    )
                                )
                    )
                }

                Spacer()
            }
            .padding(.horizontal, AppTheme.Layout.margin + 2)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(routeColor.opacity(0.06), lineWidth: 0.5)
                    )
            )
            .shadow(color: routeColor.opacity(0.03), radius: 8, x: 0, y: 3)
            .padding(.horizontal, AppTheme.Layout.margin)
        }
    }
}
