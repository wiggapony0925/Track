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

    /// Selected direction index - bound to viewModel so map can filter polylines
    @Binding var selectedDirectionIndex: Int

    /// Which content tab is active: arrivals, stops, or alerts.
    @State private var selectedTab: RouteDetailTab = .arrivals

    /// Track expanded row ID locally in the sheet
    @State private var expandedArrivalID: String?

    /// Controls the brief stop-origin highlight on first open.
    /// Auto-clears after 1.5 s so only the first arrival at the tapped
    /// stop flashes blue momentarily — not every arrival at that stop.
    @State private var stopHighlightActive: Bool = true

    /// Favorites manager for heart button
    @State private var isFavorited = false

    /// Available tabs for this route.
    enum RouteDetailTab: String, CaseIterable {
        case arrivals = "Arrivals"
        case stops = "Stops"
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
        liveVehicleCount: Int = 0,
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
        self.liveVehicleCount = liveVehicleCount
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

    /// Live arrivals filtered to the user's nearest stop ONLY.
    /// No other stops are shown — the user only cares about when the next
    /// vehicle arrives at THEIR stop.
    ///
    /// Reference priority for "nearest stop":
    /// 1. `selectedStopId` (explicitly tapped stop on the map)
    /// 2. GPS location (`currentLocation`)
    /// 3. Drag-search center pin (`searchCenter`) — used when GPS is unavailable
    /// 4. Soonest arrivals deduplicated by trip (last resort)
    private var prioritizedArrivals: [NearbyTransitResponse] {
        let direction = safeDirection
        let liveOnly = direction.liveArrivals

        guard !liveOnly.isEmpty else { return [] }

        // ── 1. Filter to explicitly selected stop ──
        if let stopId = selectedStopId, !stopId.isEmpty {
            let atNearestStop = liveOnly.filter { arrivalMatchesStop($0, stopId: stopId) }
            if !atNearestStop.isEmpty {
                return atNearestStop.sorted { $0.minutesAway < $1.minutesAway }
            }
        }

        // ── 2 & 3. Find the closest stop from the reference coordinate.
        // Use GPS if available; fall back to the drag-search pin coordinate.
        let refCoord: CLLocationCoordinate2D? = currentLocation ?? searchCenter
        if let refCoordUnwrapped = refCoord {
            let refLoc = CLLocation(
                latitude: refCoordUnwrapped.latitude,
                longitude: refCoordUnwrapped.longitude)

            // Find which stop key is closest to the reference coordinate
            var closestStopKey: String?
            var minDist: CLLocationDistance = .greatestFiniteMagnitude
            for arrival in liveOnly {
                let dist = arrivalDistance(arrival, from: refLoc)
                if dist < minDist {
                    minDist = dist
                    closestStopKey = arrival.stopId ?? arrival.stopName
                }
            }

            if let key = closestStopKey {
                let atClosest = liveOnly.filter { ($0.stopId ?? $0.stopName) == key }
                if !atClosest.isEmpty {
                    return atClosest.sorted { $0.minutesAway < $1.minutesAway }
                }
            }
        }

        // ── 4. Last resort: soonest arrivals deduplicated by trip ──
        // Avoids showing the same vehicle at multiple stops along the route.
        var seenTrips = Set<String>()
        return liveOnly
            .sorted { $0.minutesAway < $1.minutesAway }
            .filter { arrival in
                let key = arrival.tripId ?? arrival.vehicleId ?? arrival.id
                return seenTrips.insert(key).inserted
            }
            .prefix(3)
            .map { $0 }
    }

    /// Arrivals at the user's nearest stop only — used for countdown chips.
    /// Strictly filters to one stop. Falls back to closest stop by distance.
    private var nearestStopArrivals: [NearbyTransitResponse] {
        // Reuse prioritizedArrivals which already filters to nearest stop
        return prioritizedArrivals
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
    private func stripMTAPrefix(_ id: String) -> String {
        id.replacingOccurrences(of: "MTA NYCT_", with: "")
            .replacingOccurrences(of: "MTA_", with: "")
            .replacingOccurrences(of: "MTABC_", with: "")
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

    // MARK: - Smart ETA

    /// Computes a smart ETA for an arrival using live vehicle position + polyline.
    /// Uses the data already available on the sheet (busVehicles, routeShape).
    private func smartETA(for arrival: NearbyTransitResponse) -> SmartETA {
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

    private var countdownSection: some View {
        // Show countdown for arrivals at the user's nearest stop ONLY
        let nextArrivals = Array(
            nearestStopArrivals.prefix(AppSettings.shared.maxRouteDetailArrivals))
        // Resolve the stop name for the header
        let nearestStopName: String? = {
            if let stopId = selectedStopId, !stopId.isEmpty {
                // Try from the arrivals first (freshest data)
                if let name = nearestStopArrivals.first?.stopName { return name }
                // Fall back to route shape stops (with parent station fallback)
                if let shape = routeShape {
                    let stops = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
                    let parentId = stripDirectionSuffix(stripMTAPrefix(stopId))
                    return stops.first(where: { $0.id == stopId })?.name
                        ?? stops.first(where: { stripDirectionSuffix(stripMTAPrefix($0.id)) == parentId })?.name
                }
            }
            // Fall back to whatever the first arrival says
            return nearestStopArrivals.first?.stopName
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
                // When no live arrivals, show vehicle count awareness, scheduled departures, or empty state
                if liveVehicleCount > 0 {
                    // Vehicles are on the map but no arrival data for this direction yet
                    VStack(spacing: 8) {
                        Image(systemName: group.isBus ? "bus.fill" : "tram.fill")
                            .font(.system(size: 28))
                            .foregroundColor(routeColor.opacity(0.6))
                        Text("\(liveVehicleCount) vehicle\(liveVehicleCount == 1 ? "" : "s") on route")
                            .font(.custom("Helvetica-Bold", size: 14))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                        Text("No arrival times for this direction yet")
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
                    HStack(spacing: 12) {
                        ForEach(Array(nextArrivals.enumerated()), id: \.element.id) {
                            index, arrival in
                            VStack(spacing: 6) {
                                // Smart countdown: uses vehicle position + polyline when
                                // available, falls back to arrivalTs → static minutesAway.
                                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                                    let eta = smartETA(for: arrival)
                                    let mins = eta.minutesRemaining
                                    let isNow = eta.isAtStop || eta.secondsRemaining <= 30

                                    if isNow {
                                        Text("Now")
                                            .font(.custom("Helvetica-Bold", size: index == 0 ? 32 : 24))
                                            .foregroundColor(AppTheme.Colors.countdown(0))
                                    } else {
                                        Text("\(mins)")
                                            .font(.custom("Helvetica-Bold", size: index == 0 ? 40 : 30))
                                            .foregroundColor(AppTheme.Colors.countdown(mins))
                                    }

                                    if !isNow {
                                        Text("min")
                                            .font(.custom("Helvetica-Bold", size: 12))
                                            .foregroundColor(AppTheme.Colors.textSecondary)
                                    }
                                }

                                // Show the actual clock time so users know
                                // exactly when the train/bus is expected
                                if let ts = arrival.arrivalTs {
                                    Text(Date(timeIntervalSince1970: Double(ts)), style: .time)
                                        .font(.custom("Helvetica-Bold", size: 10))
                                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                                }

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
                                    .shadow(
                                        color: .black.opacity(index == 0 ? 0.08 : 0.04),
                                        radius: index == 0 ? 8 : 4, x: 0, y: 2)
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
                    .padding(.vertical, 2)  // Extra space for shadow to render
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

    // MARK: - Arrivals List (same card pattern as HomeView)

    private var arrivalsList: some View {
        // Use prioritized arrivals (nearest stop first) for the list
        let liveOnly = prioritizedArrivals

        // Reorder arrivals so the tapped vehicle's row appears first
        let sortedArrivals: [NearbyTransitResponse] = {
            guard let tapped = tappedVehicleId, !tapped.isEmpty else {
                return liveOnly
            }
            var arr = liveOnly
            if let idx = arr.firstIndex(where: { $0.vehicleId == tapped || $0.tripId == tapped }) {
                let matched = arr.remove(at: idx)
                arr.insert(matched, at: 0)
            }
            return arr
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Arrivals")
                    .font(.custom("Helvetica-Bold", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer()

                if !sortedArrivals.isEmpty {
                    Text("\(sortedArrivals.count) upcoming")
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            if sortedArrivals.isEmpty {
                // Priority: live vehicle awareness > scheduled departures > empty state
                if liveVehicleCount > 0 {
                    // Vehicles are on the map for this route, just no arrival data here
                    VStack(spacing: 8) {
                        Image(systemName: group.isBus ? "bus.fill" : "tram.fill")
                            .font(.system(size: 32, weight: .light))
                            .foregroundColor(routeColor.opacity(0.5))
                        Text("\(liveVehicleCount) vehicle\(liveVehicleCount == 1 ? "" : "s") on route")
                            .font(.custom("Helvetica-Bold", size: 14))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                        Text("Arrival times not available for this direction")
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
                            // Only highlight the *first* arrival at the origin stop,
                            // and only while stopHighlightActive is true.
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
                            .accessibilityLabel(
                                "\(arrival.stopName), \(arrival.minutesAway) minutes, \(arrival.status)"
                            )
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
                                    .background(
                                        isActive
                                            ? Color.white.opacity(0.9)
                                            : AppTheme.Colors.warningYellow
                                    )
                                    .clipShape(Capsule())
                            }

                            // Badge: show stop count on Stops tab (or loading dot)
                            if tab == .stops {
                                if let shape = routeShape {
                                    let stopCount = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
                                        .count
                                    if stopCount > 0 {
                                        Text("\(stopCount)")
                                            .font(.custom("Helvetica-Bold", size: 11))
                                            .foregroundColor(isActive ? routeColor : .white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                isActive ? Color.white.opacity(0.9) : routeColor
                                            )
                                            .clipShape(Capsule())
                                    }
                                } else {
                                    // Shape loading — tiny pulsing dot
                                    SkeletonCircle(size: 8, opacity: 0.3)
                                        .shimmer()
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
        case .arrivals: return "clock.fill"
        case .stops: return "mappin.and.ellipse"
        case .alerts: return "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Stops List

    /// List of all stops for the current direction, with transfer indicators.
    private var stopsListSection: some View {
        let dirStops: [BusStop] = routeShape?.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName) ?? []

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
                    // Route shape still loading — show animated skeleton
                    StopsListSkeleton()
                } else {
                    // Shape loaded but this direction has no stops
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
                    .frame(
                        width: (isFirst || isLast) ? 14 : 10,
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
                                RouteBadge(
                                    routeID: route,
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
        let nearbyThreshold: CLLocationDistance = 100  // meters

        let nearbyStations = cachedStations.filter { station in
            let stationLoc = CLLocation(
                latitude: station.coordinate.latitude,
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
