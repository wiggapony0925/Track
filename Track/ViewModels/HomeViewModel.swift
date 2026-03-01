//
//  HomeViewModel.swift
//  Track
//
//  ViewModel for the HomeView. Fetches nearby transit arrivals
//  (both subway and bus) from the TrackAPI backend based on the
//  user's current location or a draggable search pin.
//  Shows a unified live transit feed with bus tracking on the map.
//

import CoreLocation
import Foundation
import MapKit
import SwiftData
import SwiftUI
import WidgetKit

@Observable
@MainActor
final class HomeViewModel {
    var nearbyStations: [(stationID: String, name: String, lat: Double, lon: Double, routeIDs: [String])] =
        []
    var upcomingArrivals: [TrainArrival] = []
    var isLoading = false
    /// True after the first successful data load. Prevents skeleton placeholders
    /// from appearing on subsequent refreshes (e.g. return from background).
    var hasLoadedOnce = false
    var errorMessage: String?

    /// True when `errorMessage` indicates a network/connectivity failure rather
    /// than a server-side or data issue.
    var isNetworkError: Bool {
        guard let msg = errorMessage?.lowercased() else { return false }
        return msg.contains("network") || msg.contains("offline")
            || msg.contains("internet") || msg.contains("connection")
            || msg.contains("timed out") || msg.contains("not connected")
    }

    /// Timestamp of the last successful data refresh.
    /// Used to skip redundant fetches when the user returns from background
    /// within a short window (e.g. < 15 seconds).
    private(set) var lastRefreshDate: Date?
    /// Per-mode refresh timestamps so `canSkipRefresh` doesn't let a
    /// recent "Nearby" fetch prevent a first-time "Bus" fetch.
    private var lastRefreshDateByMode: [TransportMode: Date] = [:]
    /// Location where the last refresh was performed.
    /// Compared against the current position to decide whether the user
    /// has moved far enough to warrant re-discovering nearby routes.
    var lastRefreshLocation: CLLocation?
    /// Tracks which modes have had their dedicated data arrays populated
    /// via a mode-specific API call.  Prevents tab switches from relying
    /// solely on `groupedTransit` fallback data that can later vanish.
    var modesEverRefreshed: Set<TransportMode> = []

    /// Cached bus schedule for the currently selected bus route.
    var busSchedule: BusScheduleResponse?
    /// Cached train arrivals for interpolation between refresh cycles.
    var cachedTrainArrivals: [TrainArrival] = []

    /// The currently tracked route for the widget, loaded from UserDefaults.
    var currentTrackedRoute: TrackedRoute? = nil

    /// When `true`, the app should navigate to the currently tracked route's
    /// detail page once grouped transit data has loaded. Set by deep-link
    /// handling (e.g. tapping a Live Activity).
    var pendingDeepLink = false

    // MARK: - Search

    /// User-entered search text for filtering transit results.
    var searchText = ""

    /// Distance from the user to the closest stop in this grouped route.
    ///
    /// Uses the same algorithm as the walking polyline on the map: iterate
    /// every stop coordinate in the group and return the minimum distance
    /// to the reference location — no separate data source, no race.
    func displayDistanceMeters(for group: GroupedNearbyTransitResponse, from location: CLLocation?) -> CLLocationDistance? {
        guard let location else { return nil }

        #if DEBUG
        let centerLabel = isSearchPinActive
            ? "📍 PIN (\(String(format: "%.5f", location.coordinate.latitude)), \(String(format: "%.5f", location.coordinate.longitude)))"
            : "🔵 GPS (\(String(format: "%.5f", location.coordinate.latitude)), \(String(format: "%.5f", location.coordinate.longitude)))"
        #endif

        // Resolve the result into a local variable so we can emit one
        // [DASHBOARD DIST] comparison log before every return.
        let result: CLLocationDistance?

        if group.isBus {
            let target = normalizeMTARouteToken(group.routeId)
            let matchingStops = nearbyBusStops.filter { stop in
                guard let routeIds = stop.routeIds, !routeIds.isEmpty else { return false }
                return routeIds.contains { normalizeMTARouteToken($0) == target }
            }
            #if DEBUG
            if matchingStops.isEmpty {
                print("[DIST] \(group.routeId) bus  center=\(centerLabel)  ⚠️ NO matching stops (token=\(target), nearbyBusStops=\(nearbyBusStops.count)) → fallback groupMinDistance")
            } else {
                for stop in matchingStops {
                    let d = location.distance(from: CLLocation(latitude: stop.lat, longitude: stop.lon))
                    print("[DIST] \(group.routeId) bus  center=\(centerLabel)  stop=\(stop.name)  (\(String(format: "%.5f", stop.lat)),\(String(format: "%.5f", stop.lon)))  d=\(Int(d))m / \(String(format: "%.2f", d * 3.28084 / 5280))mi")
                }
            }
            #endif
            // Always take the min of nearbyBusStops distance AND the group's
            // own arrival-coordinate distance, so a stop inside the group that
            // wasn't captured by the separate /bus/nearby fetch (different
            // fetch radius / route-ID format) never gets silently ignored.
            let groupDist = groupMinDistance(for: group, from: location)
            if !matchingStops.isEmpty {
                let nearbyDist = matchingStops.reduce(Double.greatestFiniteMagnitude) { best, stop in
                    min(best, location.distance(from: CLLocation(latitude: stop.lat, longitude: stop.lon)))
                }
                let best = min(nearbyDist, groupDist)
                result = best.isFinite ? best : nil
            } else {
                result = groupDist.isFinite ? groupDist : nil
            }
        } else {
            let target = normalizeMTARouteToken(group.routeId)
            let groupMode = group.mode  // "subway" | "lirr" | "mnr"
            let matchingStations = nearbyStations.filter { station in
                station.routeIDs.contains { rawID in
                    // Guard mode-compatibility BEFORE normalizing so that
                    // LIRR_2/3/4/5 don't match subway station routeIDs "2"/"3"/"4"/"5".
                    let lower = rawID.lowercased()
                    switch groupMode {
                    case "lirr":
                        guard lower.hasPrefix("lirr_") else { return false }
                    case "mnr":
                        guard lower.hasPrefix("mnr_") || lower.hasPrefix("mta mnr_") else { return false }
                    default: // subway
                        guard !lower.hasPrefix("lirr_") && !lower.hasPrefix("mnr_") && !lower.hasPrefix("mta mnr_") else { return false }
                    }
                    return normalizeMTARouteToken(rawID) == target
                }
            }
            #if DEBUG
            if matchingStations.isEmpty {
                print("[DIST] \(group.routeId) \(group.mode)  center=\(centerLabel)  ⚠️ NO matching stations (token=\(target), nearbyStations=\(nearbyStations.count)) → fallback groupMinDistance")
            } else {
                for st in matchingStations {
                    let d = location.distance(from: CLLocation(latitude: st.lat, longitude: st.lon))
                    print("[DIST] \(group.routeId) \(group.mode)  center=\(centerLabel)  station=\(st.name)  (\(String(format: "%.5f", st.lat)),\(String(format: "%.5f", st.lon)))  d=\(Int(d))m / \(String(format: "%.2f", d * 3.28084 / 5280))mi")
                }
            }
            #endif
            let groupDist = groupMinDistance(for: group, from: location)
            if !matchingStations.isEmpty {
                let nearbyDist = matchingStations.reduce(Double.greatestFiniteMagnitude) { best, station in
                    min(best, location.distance(from: CLLocation(latitude: station.lat, longitude: station.lon)))
                }
                let best = min(nearbyDist, groupDist)
                result = best.isFinite ? best : nil
            } else {
                #if DEBUG
                print("[DIST] \(group.routeId) \(group.mode)  center=\(centerLabel)  ⛔ using groupMinDistance=\(Int(groupDist))m / \(String(format: "%.2f", groupDist * 3.28084 / 5280))mi")
                #endif
                result = groupDist.isFinite ? groupDist : nil
            }
        }

        #if DEBUG
        if let r = result {
            print("[DASHBOARD DIST] \(group.routeId) (\(group.mode))  center=\(centerLabel)  → \(Int(r))m / \(String(format: "%.2f", r / 1609.34))mi  ← this is what the row badge shows")
        } else {
            print("[DASHBOARD DIST] \(group.routeId) (\(group.mode))  center=\(centerLabel)  → nil (hidden)")
        }
        #endif
        return result
    }

    /// Groups and sorts routes for dashboard display using the same distance source
    /// as row badges (`displayDistanceMeters`) so category placement and row distance
    /// stay consistent.
    func groupedDisplayBuckets(
        from groups: [GroupedNearbyTransitResponse],
        referenceLocation: CLLocation?
    ) -> (
        nearYou: [GroupedNearbyTransitResponse],
        fartherAway: [GroupedNearbyTransitResponse],
        muchFarther: [GroupedNearbyTransitResponse]
    ) {
        #if DEBUG
        if let referenceLocation {
            let src = isSearchPinActive ? "PIN" : "GPS"
            print("[BUCKETS] center=\(src) (\(String(format: "%.5f", referenceLocation.coordinate.latitude)), \(String(format: "%.5f", referenceLocation.coordinate.longitude)))  groups=\(groups.count)  nearbyBusStops=\(nearbyBusStops.count)  nearbyStations=\(nearbyStations.count)  lastKnownGPS=\(lastKnownUserLocation.map { "(\(String(format: "%.5f", $0.coordinate.latitude)),\(String(format: "%.5f", $0.coordinate.longitude)))" } ?? "nil")")
        } else {
            print("[BUCKETS] ⚠️ referenceLocation=nil — sorting without distance  lastKnownGPS=\(lastKnownUserLocation.map { "(\(String(format: "%.5f", $0.coordinate.latitude)),\(String(format: "%.5f", $0.coordinate.longitude)))" } ?? "nil")")
        }
        #endif
        guard let referenceLocation else {
            let sorted = sortGroupedByDistance(groups: groups, from: nil)
            return (sorted, [], [])
        }

        let r1 = AppSettings.shared.nearYouRadiusMeters
        let r2 = max(AppSettings.shared.fartherAwayRadiusMeters, r1)

        // Pre-compute distances once per group so bucketing and sorting both
        // use the same value without re-invoking displayDistanceMeters O(n log n)
        // times (which also eliminates the duplicate [DIST] log spam).
        var distanceCache: [String: CLLocationDistance] = [:]
        distanceCache.reserveCapacity(groups.count)
        for group in groups {
            let key = "\(group.routeId)|\(group.mode)"
            distanceCache[key] = displayDistanceMeters(for: group, from: referenceLocation)
        }

        var nearYou: [GroupedNearbyTransitResponse] = []
        var fartherAway: [GroupedNearbyTransitResponse] = []
        var muchFarther: [GroupedNearbyTransitResponse] = []

        for group in groups {
            let key = "\(group.routeId)|\(group.mode)"
            guard let distance = distanceCache[key] else {
                // Keep route rows visible during short feed/coordinate gaps.
                muchFarther.append(group)
                continue
            }
            if distance <= r1 {
                nearYou.append(group)
            } else if distance <= r2 {
                fartherAway.append(group)
            } else {
                // Include everything beyond r2 in the "much farther" bucket
                // instead of silently dropping routes beyond r3.  This keeps
                // routes visible during radius-setting transitions (old data
                // bucketed with new, tighter thresholds) instead of causing
                // a flash where rows vanish before the new API data arrives.
                muchFarther.append(group)
            }
        }

        let epsilon: CLLocationDistance = 0.5
        let sorter: (GroupedNearbyTransitResponse, GroupedNearbyTransitResponse) -> Bool = { lhs, rhs in
            let leftDistance = distanceCache["\(lhs.routeId)|\(lhs.mode)"] ?? .greatestFiniteMagnitude
            let rightDistance = distanceCache["\(rhs.routeId)|\(rhs.mode)"] ?? .greatestFiniteMagnitude
            if abs(leftDistance - rightDistance) > epsilon { return leftDistance < rightDistance }
            if lhs.soonestMinutes != rhs.soonestMinutes { return lhs.soonestMinutes < rhs.soonestMinutes }
            let leftName = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if leftName != .orderedSame { return leftName == .orderedAscending }
            return lhs.routeId.localizedCaseInsensitiveCompare(rhs.routeId) == .orderedAscending
        }

        nearYou.sort(by: sorter)
        fartherAway.sort(by: sorter)
        muchFarther.sort(by: sorter)

        return (nearYou, fartherAway, muchFarther)
    }

    /// Nearby stations filtered by search text.
    var filteredNearbyStations:
        [(stationID: String, name: String, lat: Double, lon: Double, routeIDs: [String])]
    {
        guard !searchText.isEmpty else { return nearbyStations }
        let query = searchText.lowercased()
        return nearbyStations.filter { station in
            station.name.lowercased().contains(query)
                || station.routeIDs.contains { $0.lowercased().contains(query) }
        }
    }

    // MARK: - Grouped Arrivals for Unified Navigation

    /// Groups subway arrivals into `GroupedNearbyTransitResponse` for the unified
    /// tap-to-detail navigation flow (same as Nearby tab).
    var groupedSubwayArrivals: [GroupedNearbyTransitResponse] {
        groupTrainArrivals(filteredSubwayArrivals, mode: "subway")
    }

    /// Groups LIRR arrivals into `GroupedNearbyTransitResponse` for the unified
    /// tap-to-detail navigation flow.
    var groupedLIRRArrivals: [GroupedNearbyTransitResponse] {
        groupTrainArrivals(filteredLIRRArrivals, mode: "lirr")
    }

    /// Groups Metro-North arrivals into `GroupedNearbyTransitResponse` for the unified
    /// tap-to-detail navigation flow.
    var groupedMNRArrivals: [GroupedNearbyTransitResponse] {
        groupTrainArrivals(filteredMNRArrivals, mode: "mnr")
    }

    /// Helper: Groups `TrainArrival` arrays into `GroupedNearbyTransitResponse`.
    /// Works for subway, LIRR, and Metro-North.
    func groupTrainArrivals(_ arrivals: [TrainArrival], mode: String)
        -> [GroupedNearbyTransitResponse]
    {
        // Filter out stale arrivals (minutesAway == 0 with past timestamps)
        let liveArrivals = arrivals.filter { $0.minutesAway > 0 || $0.estimatedTime > Date() }

        // Group by route_id — for LIRR/MNR prefix the raw numeric ID
        var byRoute: [String: [TrainArrival]] = [:]
        for arrival in liveArrivals {
            let key: String
            switch mode {
            case "lirr":
                key =
                    arrival.routeID.hasPrefix("LIRR_") ? arrival.routeID : "LIRR_\(arrival.routeID)"
            case "mnr":
                key = arrival.routeID.hasPrefix("MNR_") ? arrival.routeID : "MNR_\(arrival.routeID)"
            default:
                key = arrival.routeID
            }
            byRoute[key, default: []].append(arrival)
        }

        return byRoute.map { routeId, routeArrivals in
            // Sub-group by direction
            var byDirection: [String: [TrainArrival]] = [:]
            for arrival in routeArrivals {
                let dirLabel = arrival.destination ?? arrival.direction
                byDirection[dirLabel, default: []].append(arrival)
            }

            let directions = byDirection.map {
                direction, dirArrivals -> DirectionArrivalsResponse in
                let nearbyArrivals =
                    dirArrivals
                    .sorted { $0.minutesAway < $1.minutesAway }
                    .map { train -> NearbyTransitResponse in
                        var dist: Double? = nil
                        if let sLat = train.stopLat, let sLon = train.stopLon, let ref = self.lastRefreshLocation {
                            dist = ref.distance(from: CLLocation(latitude: sLat, longitude: sLon))
                        }
                        return NearbyTransitResponse(
                            routeId: train.routeID,
                            stopName: train.stationName,
                            direction: train.direction,
                            destination: train.destination,
                            minutesAway: train.minutesAway,
                            status: train.status,
                            mode: mode,
                            stopLat: train.stopLat,
                            stopLon: train.stopLon,
                            arrivalTs: Int(train.estimatedTime.timeIntervalSince1970),
                            vehicleId: nil,
                            tripId: train.tripId,
                            stopId: train.stationID,
                            distanceM: dist
                        )
                    }
                return DirectionArrivalsResponse(direction: direction, arrivals: nearbyArrivals)
            }.sorted { $0.direction < $1.direction }

            let colorHex: String? = mode == "subway" ? nil : nil

            // Resolve display name: use branch name lookup for commuter rail
            let displayName = BranchNames.resolveDisplayName(routeId: routeId, mode: mode)

            return GroupedNearbyTransitResponse(
                routeId: routeId,
                displayName: displayName,
                mode: mode,
                colorHex: colorHex,
                directions: directions
            )
        }.sorted { $0.soonestMinutes < $1.soonestMinutes }
    }

    // Bus mode
    var selectedMode: TransportMode = .nearby
    var nearbyBusStops: [BusStop] = []
    var busArrivals: [BusArrival] = []
    var selectedBusStop: BusStop?

    // Grouped bus arrivals fetched from the nearby/grouped API (bus-only)
    var nearbyGroupedBusArrivals: [GroupedNearbyTransitResponse] = []

    // Grouped subway arrivals fetched from the nearby/grouped API (subway-only)
    var nearbyGroupedSubwayArrivals: [GroupedNearbyTransitResponse] = []

    // Grouped LIRR arrivals fetched from the nearby/grouped API (lirr-only)
    var nearbyGroupedLIRRArrivals: [GroupedNearbyTransitResponse] = []

    // Grouped MNR arrivals fetched from the nearby/grouped API (mnr-only)
    var nearbyGroupedMNRArrivals: [GroupedNearbyTransitResponse] = []

    // Bus routes (browse all routes)
    var allBusRoutes: [BusRoute] = []

    // Nearby transit (unified)
    var nearbyTransit: [NearbyTransitResponse] = []

    // Grouped nearby transit (one card per route)
    var groupedTransit: [GroupedNearbyTransitResponse] = []

    /// Remembers the user's last selected direction per grouped route card.
    /// Keyed by "mode:routeId" so bus/subway routes with similar IDs don't collide.
    /// Stores both a stable direction key and the last known index fallback.
    private var preferredDirectionByRoute: [String: DirectionPreference] = [:]

    private struct DirectionPreference {
        let index: Int
        let directionKey: String?
    }

    /// Tracks how many consecutive refresh cycles each route has been
    /// absent from the API response, keyed by data source ("nearby",
    /// "bus", "subway", "lirr", "mnr"). Routes are retained while
    /// the location context is stable, and counters are cleared when
    /// the context changes (search-pin set/clear, significant movement).
    var graceMissCountBySource: [String: [String: Int]] = [:]

    // MARK: - Direction Preference Persistence

    private func directionPreferenceKey(for group: GroupedNearbyTransitResponse) -> String {
        "\(group.mode):\(group.routeId)"
    }

    /// Stable, normalized identity for a direction entry.
    /// Uses direction text + optional label so reordered arrays still resolve correctly.
    private func normalizedDirectionKey(_ direction: DirectionArrivalsResponse) -> String {
        let base = direction.direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let label = direction.directionLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return label.isEmpty ? base : "\(base)|\(label)"
    }

    /// Returns the remembered direction index for a grouped route, clamped to
    /// the group's current direction count.
    func preferredDirectionIndex(for group: GroupedNearbyTransitResponse) -> Int {
        guard !group.directions.isEmpty else { return 0 }

        let key = directionPreferenceKey(for: group)
        guard let stored = preferredDirectionByRoute[key] else { return 0 }

        if let storedDirectionKey = stored.directionKey,
           let resolvedIndex = group.directions.firstIndex(where: {
               normalizedDirectionKey($0) == storedDirectionKey
           }) {
            return resolvedIndex
        }

        return max(0, min(stored.index, group.directions.count - 1))
    }

    /// Stores the user's currently selected direction for a grouped route.
    func setPreferredDirectionIndex(_ index: Int, for group: GroupedNearbyTransitResponse) {
        guard !group.directions.isEmpty else { return }

        let clampedIndex = max(0, min(index, group.directions.count - 1))
        let directionKey = normalizedDirectionKey(group.directions[clampedIndex])
        let key = directionPreferenceKey(for: group)
        preferredDirectionByRoute[key] = DirectionPreference(
            index: clampedIndex,
            directionKey: directionKey
        )

        #if DEBUG
        AppLogger.shared.log(
            "DIR_PREF",
            message:
                "STORE route=\(group.routeId) mode=\(group.mode) idx=\(clampedIndex) dir=\(group.directions[clampedIndex].direction) key=\(directionKey)"
        )
        #endif
    }

    // Nearest metro recommendation (shown when no nearby transit)
    var nearestTransit: NearbyTransitResponse?
    /// Distance in meters from the user to the nearest transit stop.
    var nearestTransitDistance: Double?

    // LIRR mode
    var lirrArrivals: [TrainArrival] = []

    // Metro-North mode
    var mnrArrivals: [TrainArrival] = []

    // Service alerts & accessibility
    var serviceAlerts: [TransitAlert] = []
    var alertsLastUpdated: Date?
    var elevatorOutages: [ElevatorStatus] = []
    /// Timestamp of the last global-feeds (alerts + accessibility) fetch.
    /// Used to debounce the per-mode calls — these feeds are location-
    /// independent and cached server-side, so re-fetching within 30 s
    /// just wastes bandwidth and MainActor render cycles.
    private var lastGlobalFeedsDate: Date?

    /// Fetches alerts and accessibility once per 30 s. Mode-specific
    /// refreshes all call this; the guard prevents redundant network hits.
    func refreshGlobalFeedsIfNeeded() async {
        if let last = lastGlobalFeedsDate,
           Date().timeIntervalSince(last) < 30 { return }
        lastGlobalFeedsDate = Date()
        async let alertsTask: Void = refreshAlerts()
        async let accessTask: [ElevatorStatus]? = { try? await TrackAPI.fetchAccessibility() }()
        _ = await alertsTask
        if let outages = await accessTask { elevatorOutages = outages }
    }

    /// Fetch alerts from the API and deliver local notifications for new ones.
    func refreshAlerts() async {
        do {
            serviceAlerts = try await TrackAPI.fetchAlerts()
            alertsLastUpdated = Date()
            AlertNotificationManager.shared.processAlerts(serviceAlerts)
        } catch {}
    }

    // Route detail sheet
    var selectedGroupedRoute: GroupedNearbyTransitResponse?
    /// Cancelable task for polyline rebuild — cancelled when the user switches
    /// directions rapidly so only the final selection triggers a full rebuild.
    private var _polylineRebuildTask: Task<Void, Never>?
    var selectedDirectionIndex: Int = 0 {
        didSet {
            // Cancel any in-flight rebuild from a previous tap so rapid direction
            // switching doesn't cascade into multiple simultaneous MapPolyline
            // teardown/rebuild cycles on MapKit's render thread.
            _polylineRebuildTask?.cancel()
            _polylineRebuildTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.rebuildCachedPolylines()
                guard !Task.isCancelled else { return }
                self.rebuildDirectionalSplit()
            }
        }
    }
    var selectedDirectionName: String? {
        guard let group = selectedGroupedRoute, selectedDirectionIndex >= 0, selectedDirectionIndex < group.directions.count else { return nil }
        return group.directions[selectedDirectionIndex].direction
    }
    var isRouteDetailPresented = false

    // Draggable search pin
    var searchPinCoordinate: CLLocationCoordinate2D?
    var isSearchPinActive = false

    /// Last raw GPS location passed into `refresh()`.  Used by `referenceLocation`
    /// so the ViewModel can resolve pin-vs-GPS without requiring a parameter.
    var lastKnownUserLocation: CLLocation?

    // Walking route to the nearest station (forwarded from goMode)
    /// Cancelable task for directional split rebuild — debounces rapid GPS
    /// updates so the O(n×m) point-search only runs when location settles.
    private var _splitRebuildTask: Task<Void, Never>?
    var nearestStopCoordinate: CLLocationCoordinate2D? {
        didSet {
            _splitRebuildTask?.cancel()
            _splitRebuildTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.rebuildDirectionalSplit()
            }
        }
    }
    var selectedStopId: String?

    // Live bus/train tracking on map
    var selectedRouteId: String?
    var highlightedVehicleId: String?
    /// Coordinate of the tracked vehicle/arrival for map zoom-to-center.
    /// Set by `trackNearbyArrival` so the View can animate the camera.
    var trackedVehicleCoordinate: CLLocationCoordinate2D?
    /// Vehicle/trip ID tapped on the map — used to highlight and expand the
    /// matching arrival row in the RouteDetailSheet.
    /// The ID of the currently expanded arrival row in the flat list.
    /// Used to enforce single-row expansion.
    var selectedExpandedArrivalID: String? = nil

    /// Validates the vehicle ID currently selected on the map.
    var tappedVehicleId: String? {
        didSet {
            // When map selection changes, auto-expand the corresponding row
            guard let id = tappedVehicleId else { return }

            // Find the best matching arrival to expand
            // prioritize exact vehicle ID match
            if let match = nearbyTransit.first(where: { $0.vehicleId == id || $0.tripId == id }) {
                // Only change if not already selected to avoid animation glitches
                if selectedExpandedArrivalID != match.id {
                    withAnimation {
                        selectedExpandedArrivalID = match.id
                    }
                }
            }
        }
    }

    /// Toggles the expansion state for a given arrival ID.
    func toggleArrivalExpansion(_ id: String) {
        withAnimation {
            if selectedExpandedArrivalID == id {
                selectedExpandedArrivalID = nil
            } else {
                selectedExpandedArrivalID = id
            }
        }
    }
    var busVehicles: [BusVehicleResponse] = [] {
        didSet { _busVehicleIndex = Dictionary(busVehicles.map { ($0.vehicleId, $0) }, uniquingKeysWith: { $1 }) }
    }
    /// O(1) lookup by vehicleId — rebuilt automatically when busVehicles is set.
    private var _busVehicleIndex: [String: BusVehicleResponse] = [:]

    var trainVehicles: [TrainVehicle] = [] {
        didSet {
            _trainVehicleByTrip = Dictionary(trainVehicles.compactMap { v in v.tripId.map { ($0, v) } }, uniquingKeysWith: { $1 })
            _trainVehicleById = Dictionary(trainVehicles.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        }
    }
    /// O(1) lookup by tripId — rebuilt automatically when trainVehicles is set.
    private var _trainVehicleByTrip: [String: TrainVehicle] = [:]
    /// O(1) lookup by id — rebuilt automatically when trainVehicles is set.
    private var _trainVehicleById: [String: TrainVehicle] = [:]

    // Smooth bus interpolation state — stores the previous GPS snapshot
    // so we can glide between updates along the route polyline.
    /// Previous GPS positions keyed by vehicle ID for smooth interpolation.
    var previousBusPositions: [String: BusSnapshot] = [:]
    /// When the last bus GPS batch arrived (for elapsed-time calculation).
    var lastBusUpdateTime: Date = .distantPast
    /// Target GPS positions from the latest API response. The simulation
    /// interpolates `busVehicles` display positions toward these targets
    /// each tick, eliminating the snap-forward → jump-back flicker.
    var _targetBusGPS: [String: BusVehicleResponse] = [:]

    /// Previous train display positions for smooth cross-tick interpolation.
    /// Keyed by trip ID (same as TrainVehicle.id).
    var _previousTrainPositions: [String: CLLocationCoordinate2D] = [:]
    /// Train vehicles that disappeared in the latest poll. Kept for a grace
    /// period (1 poll cycle) to avoid markers vanishing on a single GTFS-RT dropout.
    var _trainGraceBuffer: [String: (vehicle: TrainVehicle, missedAt: Date)] = [:]

    var routeShape: RouteShapeResponse? {
        didSet {
            rebuildCachedPolylines()
            rebuildDirectionalSplit()
        }
    }

    /// Pre-decoded polylines for the currently selected route direction.
    /// Invalidated and rebuilt when `routeShape` or `selectedDirectionIndex` changes
    /// so the map never decodes encoded strings during render.
    private(set) var cachedRoutePolylines: [[CLLocationCoordinate2D]] = []

    /// Pre-decoded polylines for all NON-selected directions.
    /// Rendered at low opacity on the map so users can see branching routes,
    /// short-turn variants, and alternate paths while knowing which direction
    /// is active. Works for subway branches, bus short-turns, LIRR/MNR splits.
    private(set) var cachedInactivePolylines: [[CLLocationCoordinate2D]] = []

    /// Single combined polyline for vehicle interpolation (bus simulation / train positions).
    /// Invalidated and rebuilt alongside `cachedRoutePolylines`.
    private(set) var cachedInterpolationPolyline: [CLLocationCoordinate2D] = []

    /// Rebuilds the cached decoded polylines from the current route shape and direction.
    private func rebuildCachedPolylines() {
        guard let shape = routeShape else {
            cachedRoutePolylines = []
            cachedInactivePolylines = []
            cachedInterpolationPolyline = []
            return
        }
        let groupDirCount = selectedGroupedRoute?.directions.count ?? 0
        let shouldFilter = !shape.directions.isEmpty && groupDirCount > 1
        let isBus = selectedGroupedRoute?.isBus == true

        // Simplify active-direction segments to ~8 m tolerance using RDP.
        // Reduces MapKit coordinate count by 60–80% with zero visible difference
        // at normal map zoom, dramatically cutting per-frame polyline render cost.
        let activeRaw =
            shouldFilter
            ? shape.polylinesForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
            : shape.decodedPolylines
        cachedRoutePolylines = activeRaw.map { simplifyPolyline($0, tolerance: 0.00007) }

        // Build inactive polylines from all OTHER directions.
        // Bus routes: skip entirely — the opposite direction runs 15–30 m across
        // the same street. At 0.15 opacity it looks like a ghost duplicate and
        // doubles MapKit polyline objects for zero navigational benefit.
        // Subway/rail: keep it — branches can run on physically distinct tracks.
        if shouldFilter && shape.directions.count > 1 && !isBus {
            // Collect the active direction's polyline encoded strings for dedup
            let activeDir = shape.matchedDirection(index: selectedDirectionIndex, name: selectedDirectionName)
            let activePolylineSet = Set(activeDir?.polylines ?? [])

            // Track all encoded strings we've already decoded to avoid
            // rendering the same segment twice when multiple inactive
            // directions share trunk/branch polylines (common with 3+ dirs).
            var seenEncodedPolylines = activePolylineSet
            var inactive: [[CLLocationCoordinate2D]] = []
            for dir in shape.directions {
                // Skip the active direction entirely
                if let active = activeDir, dir.directionId == active.directionId,
                   dir.headsign == active.headsign {
                    continue
                }
                for encodedPoly in dir.polylines {
                    // Skip polylines already seen (active direction OR
                    // another inactive direction sharing the same segment)
                    if seenEncodedPolylines.contains(encodedPoly) { continue }
                    seenEncodedPolylines.insert(encodedPoly)
                    // Simplify inactive segments at ~20 m tolerance — they
                    // render at 0.15 opacity so reduced point density is
                    // imperceptible while halving MapKit's overlay load.
                    let decoded = simplifyPolyline(decodePolyline(encodedPoly), tolerance: 0.00018)
                    if decoded.count >= 2 {
                        inactive.append(decoded)
                    }
                }
            }
            cachedInactivePolylines = inactive
        } else {
            cachedInactivePolylines = []
        }

        // Build a single continuous polyline for interpolation.
        // Prefer direction-filtered segments; fall back to all polylines
        // when the filtered set has too few points (e.g. single-direction routes).
        let combined = cachedRoutePolylines.flatMap { $0 }
        if combined.count >= 2 {
            cachedInterpolationPolyline = combined
        } else {
            let all = shape.decodedPolylines.flatMap { $0 }
            cachedInterpolationPolyline = all.count >= 2 ? all : []
        }
    }

    /// Cached polyline split at the nearest stop: `ahead` keeps full color, `behind` fades.
    /// Each array contains multiple polyline segments so separate route portions
    /// (branches, trunks) are never joined into one continuous line — preventing
    /// straight-line artifacts that cut across the map.
    private(set) var directionalSplit:
        (ahead: [[CLLocationCoordinate2D]], behind: [[CLLocationCoordinate2D]])?

    /// Rebuilds the cached directional split from current state.
    /// Called when `routeShape`, `nearestStopCoordinate`, or `selectedDirectionIndex` changes.
    ///
    /// Strategy: find which polyline segment contains the point closest to the
    /// nearest stop, split only that segment, and classify all other segments
    /// as fully "ahead" or fully "behind" based on their order.
    private func rebuildDirectionalSplit() {
        guard let nearestCoord = nearestStopCoordinate,
            !cachedRoutePolylines.isEmpty,
            let shape = routeShape
        else {
            directionalSplit = nil
            return
        }

        let segments = cachedRoutePolylines
        let nearestLoc = CLLocation(
            latitude: nearestCoord.latitude, longitude: nearestCoord.longitude)

        // Find the segment and index within that segment closest to the nearest stop
        var bestSegIdx = 0
        var bestPtIdx = 0
        var minDist: CLLocationDistance = .greatestFiniteMagnitude
        for (segIdx, seg) in segments.enumerated() {
            for (ptIdx, coord) in seg.enumerated() {
                let d = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    .distance(from: nearestLoc)
                if d < minDist {
                    minDist = d
                    bestSegIdx = segIdx
                    bestPtIdx = ptIdx
                }
            }
        }

        let directionStops = shape.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
        guard !directionStops.isEmpty else {
            directionalSplit = nil
            return
        }

        // Determine polyline flow direction relative to stop ordering.
        // Use the first segment's start/end vs. the first stop.
        let firstStopLoc = CLLocation(latitude: directionStops[0].lat, longitude: directionStops[0].lon)
        let firstPoly = segments[0]
        guard let firstPolyStart = firstPoly.first, let lastSeg = segments.last, let lastPolyEnd = lastSeg.last else {
            directionalSplit = nil
            return
        }
        let firstPolyLoc = CLLocation(latitude: firstPolyStart.latitude, longitude: firstPolyStart.longitude)
        let lastPolyLoc = CLLocation(latitude: lastPolyEnd.latitude, longitude: lastPolyEnd.longitude)
        let polyFlowsWithStops =
            firstPolyLoc.distance(from: firstStopLoc)
            <= lastPolyLoc.distance(from: firstStopLoc)

        // Split the best segment at the split point
        let splitSeg = segments[bestSegIdx]
        let clampedIdx = max(0, min(bestPtIdx, splitSeg.count - 1))
        let beforePart = Array(splitSeg[0...clampedIdx])
        let afterPart = Array(splitSeg[clampedIdx...])

        // Classify: segments before bestSegIdx are fully "before",
        // the split segment is divided, segments after are fully "after".
        var beforeSegments: [[CLLocationCoordinate2D]] = []
        var afterSegments: [[CLLocationCoordinate2D]] = []

        for i in 0..<bestSegIdx {
            if segments[i].count >= 2 { beforeSegments.append(segments[i]) }
        }
        if beforePart.count >= 2 { beforeSegments.append(beforePart) }
        if afterPart.count >= 2 { afterSegments.append(afterPart) }
        for i in (bestSegIdx + 1)..<segments.count {
            if segments[i].count >= 2 { afterSegments.append(segments[i]) }
        }

        if polyFlowsWithStops {
            directionalSplit = (ahead: afterSegments, behind: beforeSegments)
        } else {
            directionalSplit = (ahead: beforeSegments, behind: afterSegments)
        }
    }

    // MARK: - Direction-Filtered Vehicles

    /// Bus vehicles filtered to the currently selected direction.
    /// GTFS only defines `directionRef` 0/1, which breaks for routes with 3+ directions
    /// (branches, short-turns). Strategy:
    ///   1. Match by destination name against the selected direction's headsign/arrivals.
    ///   2. Fall back to `directionRef` == `selectedDirectionIndex` for simple 2-dir routes.
    ///   3. Show all vehicles if nothing matches (missing backend data).
    var filteredBusVehicles: [BusVehicleResponse] {
        guard let group = selectedGroupedRoute,
            group.directions.count > 1
        else {
            return busVehicles  // single direction → show all
        }
        let safeIdx = min(selectedDirectionIndex, group.directions.count - 1)
        let selectedDir = group.directions[safeIdx]

        // Build a set of destination names from the selected direction's arrivals
        var validDestinations = Set<String>()
        validDestinations.insert(selectedDir.direction.uppercased())
        for arrival in selectedDir.arrivals {
            if let dest = arrival.destination {
                validDestinations.insert(dest.uppercased())
            }
        }
        // Also include the route shape headsign for this direction
        if let shape = routeShape {
            let matched = shape.matchedDirection(index: selectedDirectionIndex, name: selectedDirectionName)
            if let hs = matched?.headsign.uppercased(), !hs.isEmpty {
                validDestinations.insert(hs)
            }
        }

        // 1) Try matching by destination name (works for any number of directions)
        let byDest = busVehicles.filter { vehicle in
            guard let dest = vehicle.onwardCalls?.first?.destinationName?.uppercased()
                ?? vehicle.statusText?.uppercased() else {
                return false
            }
            return validDestinations.contains(where: { dest.contains($0) || $0.contains(dest) })
        }
        if !byDest.isEmpty { return byDest }

        // 2) Fallback: match by directionRef for simple 2-direction routes
        if group.directions.count <= 2 {
            let byRef = busVehicles.filter { $0.directionRef == selectedDirectionIndex }
            if !byRef.isEmpty { return byRef }
        }

        // 3) If no vehicles matched (data missing), show all
        return busVehicles
    }

    /// Train vehicles filtered to the currently selected direction.
    /// Subway directions use "N"/"S" (or destination names); we match by
    /// checking the direction string of the arrivals in the selected group,
    /// and also map compass codes to ensure GTFS-RT "N"/"S" values match.
    var filteredTrainVehicles: [TrainVehicle] {
        guard let group = selectedGroupedRoute,
            group.directions.count > 1
        else {
            return trainVehicles  // single direction → show all
        }
        let safeIdx = min(selectedDirectionIndex, group.directions.count - 1)
        let selectedDir = group.directions[safeIdx]

        // Collect all direction strings that belong to this direction tab
        // (the direction field, plus any arrival directions/destinations)
        var validDirs = Set<String>()
        validDirs.insert(selectedDir.direction.uppercased())
        for arrival in selectedDir.arrivals {
            validDirs.insert(arrival.direction.uppercased())
            if let dest = arrival.destination {
                validDirs.insert(dest.uppercased())
            }
        }

        // Map compass codes ↔ directional labels so GTFS-RT "N"/"S" values
        // match grouped API labels like "Northbound", "Uptown", etc.
        let compassExpansions: [String: [String]] = [
            "N": ["NORTHBOUND", "UPTOWN"],
            "S": ["SOUTHBOUND", "DOWNTOWN"],
            "E": ["EASTBOUND"],
            "W": ["WESTBOUND"],
            "NE": ["NORTHBOUND", "EASTBOUND"],
            "NW": ["NORTHBOUND", "WESTBOUND"],
            "SE": ["SOUTHBOUND", "EASTBOUND"],
            "SW": ["SOUTHBOUND", "WESTBOUND"],
        ]
        let reverseCompass: [String: String] = [
            "NORTHBOUND": "N", "UPTOWN": "N",
            "SOUTHBOUND": "S", "DOWNTOWN": "S",
            "EASTBOUND": "E", "WESTBOUND": "W",
        ]
        // Expand existing compass codes and add reverse mappings
        for dir in Array(validDirs) {
            if let expansions = compassExpansions[dir] {
                for e in expansions { validDirs.insert(e) }
            }
            if let code = reverseCompass[dir] {
                validDirs.insert(code)
            }
        }

        // Bridge grouped API destination names with GTFS compass codes.
        // The grouped API uses destination names (e.g. "Flushing-Main St")
        // while GTFS-RT vehicles use compass codes ("N"/"S"). When validDirs
        // only contains destination names, the compass expansion above has
        // nothing to work with. Use the route shape's direction data to find
        // which GTFS direction_id corresponds to the selected tab, then map
        // direction_id to the standard GTFS compass convention.
        //
        // For branching routes with 3+ directions, direction_id alone is
        // unreliable (multiple branches share 0 or 1). In that case we skip
        // the compass bridge and rely on destination/trip matching below.
        let hasCompassCode =
            validDirs.contains("N") || validDirs.contains("S")
            || validDirs.contains("E") || validDirs.contains("W")
        if !hasCompassCode, let shape = routeShape, !shape.directions.isEmpty {
            // Only apply the compass bridge for simple 2-direction routes.
            // For 3+ directions the 0→S / 1→N assumption is wrong.
            if shape.directions.count <= 2 {
                // Try matching the selected direction's name against shape headsigns
                let selectedName = selectedDir.direction.uppercased()
                if let matchedShape = shape.directions.first(where: {
                    $0.headsign.uppercased() == selectedName
                        || selectedName.contains($0.headsign.uppercased())
                        || $0.headsign.uppercased().contains(selectedName)
                }) {
                    // GTFS convention: direction_id 0 = southbound, 1 = northbound
                    let compassCode = matchedShape.directionId == 0 ? "S" : "N"
                    validDirs.insert(compassCode)
                    if let expansions = compassExpansions[compassCode] {
                        for e in expansions { validDirs.insert(e) }
                    }
                } else {
                    // No headsign match — fall back to positional mapping.
                    let shapeIdx = min(safeIdx, shape.directions.count - 1)
                    let dirId = shape.directions[shapeIdx].directionId
                    let compassCode = dirId == 0 ? "S" : "N"
                    validDirs.insert(compassCode)
                    if let expansions = compassExpansions[compassCode] {
                        for e in expansions { validDirs.insert(e) }
                    }
                }
            }
        }

        // Primary filter: match by direction/destination strings
        let filtered = trainVehicles.filter { vehicle in
            validDirs.contains(vehicle.direction.uppercased())
        }

        // For 3+ directions where compass matching fails, try trip-based matching.
        // Each arrival has a tripId — if a vehicle's tripId matches an arrival in
        // the selected direction, it belongs here.
        if filtered.isEmpty && group.directions.count > 2 {
            let tripIds = Set(selectedDir.arrivals.compactMap { $0.tripId?.uppercased() })
            let vehicleIds = Set(selectedDir.arrivals.compactMap { $0.vehicleId?.uppercased() })
            if !tripIds.isEmpty || !vehicleIds.isEmpty {
                let byTrip = trainVehicles.filter { vehicle in
                    if let trip = vehicle.tripId?.uppercased(), tripIds.contains(trip) { return true }
                    if vehicleIds.contains(vehicle.id.uppercased()) { return true }
                    return false
                }
                if !byTrip.isEmpty { return byTrip }
            }
            // Last resort for many-direction routes: show all
            return trainVehicles
        }

        return filtered
    }

    // MARK: - Sub-ViewModels

    /// System map data (subway/LIRR/MNR polylines and stations).
    /// Loaded once at startup; the View reads directly from this sub-ViewModel.
    let mapSystem = MapSystemViewModel()

    /// GO Mode (live transit tracking) state and logic.
    let goMode = GoModeViewModel()

    // MARK: - Type Aliases (backward compatibility)

    typealias CachedSubwayStation = MapSystemViewModel.CachedSubwayStation
    typealias FlattenedMapPolyline = MapSystemViewModel.FlattenedMapPolyline
    typealias CachedTransitLine = MapSystemViewModel.CachedTransitLine

    // MARK: - System Map Forwarding (backward compatibility)

    /// Forwarding properties so existing views can still use `viewModel.flattenedSubwayPolylines`, etc.
    var flattenedSubwayPolylines: [MapSystemViewModel.FlattenedMapPolyline] {
        mapSystem.flattenedSubwayPolylines
    }
    var flattenedCommuterRailPolylines: [MapSystemViewModel.FlattenedMapPolyline] {
        mapSystem.flattenedCommuterRailPolylines
    }
    var cachedStations: [MapSystemViewModel.CachedSubwayStation] {
        mapSystem.cachedStations
    }

    // MARK: - Offline Support

    /// Whether we're currently using cached data due to network issues
    var isUsingCachedData: Bool {
        OfflineCacheManager.shared.isUsingCachedData
    }

    /// Whether the device is currently online
    var isOnline: Bool {
        OfflineCacheManager.shared.isOnline
    }

    /// Age of cached data (e.g., "5 min ago")
    var cacheAge: String? {
        OfflineCacheManager.shared.getCacheAge()
    }

    init() {
        syncTrackedRoute()
        // System map and stations are now loaded by MapSystemViewModel
    }

    /// Syncs the local tracking state with the persisted TrackedRoute in UserDefaults.
    func syncTrackedRoute() {
        currentTrackedRoute = TrackedRoute.load()
    }

    // MARK: - Tracking Helpers

    /// Checks if a nearby arrival matches the currently tracked route.
    func isTracking(_ arrival: NearbyTransitResponse) -> Bool {
        guard let tracked = currentTrackedRoute else { return false }
        return tracked.routeId == arrival.routeId && tracked.stopName == arrival.stopName
            && tracked.direction == arrival.direction
    }

    /// Checks if a subway arrival matches the currently tracked route.
    func isTracking(_ arrival: TrainArrival) -> Bool {
        guard let tracked = currentTrackedRoute else { return false }
        return tracked.routeId == arrival.routeID && tracked.stopName == arrival.stationID
            && tracked.direction == arrival.direction
    }

    /// Checks if a bus arrival matches the currently tracked route.
    func isTracking(_ arrival: BusArrival) -> Bool {
        guard let tracked = currentTrackedRoute else { return false }
        // For bus arrivals, we strip the prefix for display/matching
        let cleanRouteId = stripMTAPrefix(arrival.routeId)
        let trackedCleanId = stripMTAPrefix(tracked.routeId)
        return cleanRouteId == trackedCleanId && tracked.stopName == arrival.stopId
    }

    /// Returns the map-marker key for an arrival — the same identifier
    /// the map uses for `tappedVehicleId`. Bus vehicles use `vehicleId`;
    /// trains use `tripId` (falling back to `vehicleId`).
    /// Returns nil when the arrival has no live vehicle on the map IN THE
    /// CURRENTLY SELECTED DIRECTION.
    ///
    /// Uses `filteredBusVehicles` / `filteredTrainVehicles` (direction-scoped)
    /// rather than the raw collections so that a vehicle going the other
    /// direction never returns a key — it wouldn't have a marker on the map.
    func vehicleKeyForArrival(_ arrival: NearbyTransitResponse) -> String? {
        if arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty,
            filteredBusVehicles.contains(where: { $0.vehicleId == vid })
        {
            return vid
        }
        if !arrival.isBus {
            if let tid = arrival.tripId, !tid.isEmpty,
                filteredTrainVehicles.contains(where: { $0.tripId == tid })
            {
                return tid
            }
            if let vid = arrival.vehicleId, !vid.isEmpty,
                filteredTrainVehicles.contains(where: { $0.id == vid })
            {
                return vid
            }
        }
        return nil
    }

    /// Returns the coordinate of a tapped vehicle marker (bus or train) by its ID.
    /// Used by HomeView to zoom/center the map on the tapped marker.
    func coordinateForTappedVehicle(_ vehicleId: String) -> CLLocationCoordinate2D? {
        // Check bus vehicles — O(1)
        if let bus = _busVehicleIndex[vehicleId] {
            return CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
        }
        // Check train vehicles — O(1)
        if let train = _trainVehicleByTrip[vehicleId] ?? _trainVehicleById[vehicleId] {
            return CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
        }
        return nil
    }

    /// Finds the map coordinate for a tracked arrival.
    /// Looks up the live vehicle position first (bus by vehicleId, train by tripId);
    /// falls back to the arrival's stop lat/lon if no live vehicle is found.
    /// Works for all modes: subway, bus, LIRR, Metro-North.
    func coordinateForTrackedArrival(_ arrival: NearbyTransitResponse) -> CLLocationCoordinate2D? {
        // 1. Try to find a live bus vehicle by vehicleId — O(1)
        if arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty,
           let vehicle = _busVehicleIndex[vid] {
            return CLLocationCoordinate2D(latitude: vehicle.lat, longitude: vehicle.lon)
        }

        // 2. Try to find a live train vehicle by tripId — O(1)
        if !arrival.isBus, let tripId = arrival.tripId, !tripId.isEmpty,
           let train = _trainVehicleByTrip[tripId] {
            return CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
        }

        // 3. Try to find a train vehicle by vehicleId — O(1)
        if !arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty,
           let train = _trainVehicleById[vid] {
            return CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
        }

        // 4. Fall back to the stop's coordinates
        if let lat = arrival.stopLat, let lon = arrival.stopLon {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }

        return nil
    }

    /// Returns true if the arrival has a live vehicle currently visible on
    /// the map FOR THE CURRENTLY SELECTED DIRECTION.
    ///
    /// Uses `filteredBusVehicles` / `filteredTrainVehicles` (direction-scoped)
    /// so the indicator never lights up for a vehicle going in the OPPOSITE
    /// direction (which would have a marker on the map but for a different
    /// direction tab than the user is viewing).
    ///
    /// Note: We use the O(1) dictionaries when possible but still need to
    /// check against filtered vehicles for direction scoping.
    func isVehicleLiveOnMap(_ arrival: NearbyTransitResponse) -> Bool {
        if arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty {
            // O(1) check: is this vehicle in our full index at all?
            guard _busVehicleIndex[vid] != nil else { return false }
            // Then confirm it's in the direction-filtered set.
            return filteredBusVehicles.contains(where: { $0.vehicleId == vid })
        }
        if !arrival.isBus {
            if let tripId = arrival.tripId, !tripId.isEmpty {
                if _trainVehicleByTrip[tripId] != nil,
                   filteredTrainVehicles.contains(where: { $0.tripId == tripId }) { return true }
            }
            if let vid = arrival.vehicleId, !vid.isEmpty {
                if _trainVehicleById[vid] != nil,
                   filteredTrainVehicles.contains(where: { $0.id == vid }) { return true }
            }
        }
        return false
    }

    // MARK: - Smart ETA

    /// Computes a smart ETA for an arrival using live vehicle position,
    /// route polyline distance, and speed estimation. Falls back gracefully
    /// to arrivalTs → static minutesAway when vehicle data is unavailable.
    func smartETA(for arrival: NearbyTransitResponse) -> SmartETA {
        // 1. Find the vehicle's live coordinate
        let vehicleCoord = coordinateForTrackedArrival(arrival).flatMap { coord in
            // coordinateForTrackedArrival falls back to stop coords when
            // no vehicle is found — we only want actual vehicle positions here.
            // Check if this coord came from a real vehicle vs. the stop fallback.
            let isVehicle = isVehicleLiveOnMap(arrival)
            return isVehicle ? coord : nil
        }

        // 2. Build stop coordinate
        let stopCoord: CLLocationCoordinate2D? = {
            if let lat = arrival.stopLat, let lon = arrival.stopLon {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            return nil
        }()

        // 3. Vehicle key for speed history
        let vehicleKey = arrival.vehicleId ?? arrival.tripId

        return ArrivalETAEngine.computeETA(
            vehicleCoord: vehicleCoord,
            vehicleKey: vehicleKey,
            stopCoord: stopCoord,
            polyline: cachedInterpolationPolyline.count >= 2 ? cachedInterpolationPolyline : nil,
            arrivalTs: arrival.arrivalTs,
            staticMinutes: arrival.minutesAway,
            mode: arrival.mode,
            delayFactor: ArrivalETAEngine.cachedDelayFactor(routeId: arrival.routeId, mode: arrival.mode)
        )
    }

    // MARK: - GO Mode Forwarding (backward compatibility)

    var isGoModeActive: Bool { goMode.isGoModeActive }
    var goModeRouteName: String? { goMode.goModeRouteName }
    var goModeRouteColor: Color? { goMode.goModeRouteColor }
    var passedStopIds: Set<String> { goMode.passedStopIds }
    var transitEtaMinutes: Int? { goMode.transitEtaMinutes }
    var walkingRoute: MKRoute? { goMode.walkingRoute }

    let repository = TransitRepository()

    /// Single source of truth for "which location to measure distances from".
    /// Returns the search-pin coordinate when the pin is active, otherwise the last
    /// known GPS fix (falling back to Midtown if outside the service area).
    /// SwiftUI re-evaluates this automatically whenever `isSearchPinActive` or
    /// `searchPinCoordinate` changes because both are `@Observable` stored properties.
    var referenceLocation: CLLocation? {
        effectiveLocation(userLocation: lastKnownUserLocation)
    }

    /// The effective location for data fetching — either the search pin or user location.
    /// If the GPS fix is outside the NYC service area, falls back to Midtown Manhattan
    /// so the app always shows MTA transit data.
    func effectiveLocation(userLocation: CLLocation?) -> CLLocation? {
        if isSearchPinActive, let pin = searchPinCoordinate {
            return CLLocation(latitude: pin.latitude, longitude: pin.longitude)
        }
        guard let location = userLocation else { return nil }
        if AppTheme.MapConfig.isInServiceArea(location.coordinate) {
            return location
        }
        // Outside NYC — fall back to Midtown Manhattan
        AppLogger.shared.log(
            "LOCATION",
            message:
                "GPS outside service area (\(location.coordinate.latitude), \(location.coordinate.longitude)) — using NYC fallback"
        )
        let nyc = AppTheme.MapConfig.nycCenter
        return CLLocation(latitude: nyc.latitude, longitude: nyc.longitude)
    }

    // MARK: - Staleness / Distance Guards

    /// Returns `true` when recent data is fresh enough AND the user
    /// hasn't moved significantly, so we can safely skip a full refresh.
    ///
    /// Uses per-mode timestamps so switching from "Nearby" to "Bus"
    /// won't skip the bus fetch just because "Nearby" ran recently.
    func canSkipRefresh(for location: CLLocation?) -> Bool {
        // Use the mode-specific timestamp when available; fall back to
        // the global one for backwards-compatibility (first load, etc.).
        let modeDate = lastRefreshDateByMode[selectedMode]
        guard hasLoadedOnce,
              let lastDate = modeDate ?? lastRefreshDate else {
            AppLogger.shared.log("REFRESH", message: "canSkipRefresh → NO (first load or no last date for \(selectedMode))")
            return false
        }
        let elapsed = Date().timeIntervalSince(lastDate)
        let cooldown = TimeInterval(AppSettings.shared.refreshCooldownSeconds)
        guard elapsed < cooldown else {
            AppLogger.shared.log("REFRESH", message: "canSkipRefresh → NO (elapsed \(Int(elapsed))s ≥ cooldown \(Int(cooldown))s, mode=\(selectedMode))")
            return false
        }
        // If we have a previous fetch location, require meaningful movement
        if let lastLoc = lastRefreshLocation, let newLoc = location {
            let dist = newLoc.distance(from: lastLoc)
            let threshold = AppSettings.shared.significantMovementMeters
            let skip = dist < threshold
            AppLogger.shared.log("REFRESH", message: "canSkipRefresh → \(skip ? "YES" : "NO") (moved \(Int(dist))m, threshold \(Int(threshold))m, \(Int(elapsed))s ago, mode=\(selectedMode))")
            return skip
        }
        // No location to compare — trust the time guard alone
        AppLogger.shared.log("REFRESH", message: "canSkipRefresh → YES (time guard only, \(Int(elapsed))s ago, mode=\(selectedMode))")
        return true
    }

    /// Refreshes the view based on current location and transport mode.
    /// Uses a "stale-while-revalidate" pattern: if data already exists,
    /// the refresh happens silently in the background so the user keeps
    /// seeing the previous results instead of skeleton placeholders.
    ///
    /// - Returns: `true` when a network fetch actually ran; `false` when
    ///   the request was skipped by the staleness guard.
    @discardableResult
    func refresh(location: CLLocation?, force: Bool = false) async -> Bool {
        // Keep the raw GPS location up-to-date so `referenceLocation` can
        // resolve pin vs GPS without needing a parameter at call sites.
        if let location { lastKnownUserLocation = location }
        let loc = effectiveLocation(userLocation: location)

        // Skip if data is still fresh and user hasn't moved far.
        // force=true bypasses this (used by pull-to-refresh / mode switch).
        if !force && canSkipRefresh(for: loc) {
            AppLogger.shared.log("REFRESH", message: "⏭️ Skipped — data still fresh")
            return false
        }

        AppLogger.shared.log(
            "REFRESH",
            message: "🔄 Running \(force ? "(forced)" : "") mode=\(selectedMode)"
        )

        // If the user has moved significantly since the last fetch,
        // clear the grace period so stale routes from the old position
        // don't linger in the new location's results.
        if let loc, let lastLoc = lastRefreshLocation {
            let moved = loc.distance(from: lastLoc)
            if moved >= AppSettings.shared.significantMovementMeters {
                graceMissCountBySource.removeAll()
            }
        }

        // Only show the loading spinner on the very first fetch.
        // Subsequent refreshes (e.g. return from background) keep
        // showing the previous data and silently swap in new results.
        let isSilentRefresh = hasLoadedOnce
        if !isSilentRefresh {
            isLoading = true
        }
        errorMessage = nil

        // During drag-to-search the search pin is active — skip global
        // feeds (alerts, accessibility) since they're location-independent
        // and were already loaded on the initial refresh.  Saves ~2 network
        // calls per pan gesture.
        let skipGlobal = isSearchPinActive

        switch selectedMode {
        case .nearby:
            await refreshNearbyTransit(location: loc, skipGlobalFeeds: skipGlobal, silent: isSilentRefresh)
        case .subway:
            await refreshSubway(location: loc)
        case .bus:
            await refreshBus(location: loc)
        case .lirr:
            await refreshLIRR(location: loc)
        case .mnr:
            await refreshMNR(location: loc)
        }

        syncTrackedRoute()
        updateLiveActivityFromRefresh()
        let now = Date()
        lastRefreshDate = now
        lastRefreshDateByMode[selectedMode] = now
        modesEverRefreshed.insert(selectedMode)
        lastRefreshLocation = loc
        hasLoadedOnce = true
        isLoading = false
        return true
    }

    /// Updates the running Live Activity with fresh data from the latest refresh.
    /// This ensures the 'Other upcoming arrivals' and progress stay accurate.
    func updateLiveActivityFromRefresh() {
        if currentTrackedRoute == nil { return }

        // Find matching arrival and its siblings across all possible data sources.
        var found: (secondsRemaining: Double, siblings: [Int])?

        // 1. Check Nearby Transit (Unified)
        if let match = nearbyTransit.first(where: { isTracking($0) }) {
            let now = Date()
            let currentETA = smartETA(for: match)
            let currentSecs = currentETA.secondsRemaining
            let currentArrival = now.addingTimeInterval(currentSecs)
            let siblingTimes = nearbyTransit
                .filter {
                    $0.routeId == match.routeId
                        && $0.direction == match.direction
                        && $0.id != match.id
                }
                .map { now.addingTimeInterval(smartETA(for: $0).secondsRemaining) }

            let siblingMinutes = TrackingTimeSync.nextArrivalMinutes(
                arrivalTimes: siblingTimes,
                after: currentArrival,
                now: now
            )
            found = (secondsRemaining: currentSecs, siblings: siblingMinutes)
        }
        // 2. Check Subway Dedicated
        else if let match = upcomingArrivals.first(where: { isTracking($0) }) {
            let now = Date()
            let currentArrival = match.estimatedTime
            let siblingTimes = upcomingArrivals
                .filter {
                    $0.direction == match.direction
                        && $0.stationID == match.stationID
                        && $0.id != match.id
                }
                .map(\ .estimatedTime)

            let siblingMinutes = TrackingTimeSync.nextArrivalMinutes(
                arrivalTimes: siblingTimes,
                after: currentArrival,
                now: now
            )
            let currentSecs = TrackingTimeSync.remainingSeconds(until: currentArrival, now: now)
            found = (secondsRemaining: currentSecs, siblings: siblingMinutes)
        }
        // 3. Check Bus Dedicated
        else if let match = busArrivals.first(where: { isTracking($0) }) {
            let now = Date()
            let currentArrival = match.expectedArrival ?? now
            let siblingTimes = busArrivals
                .filter { $0.routeId == match.routeId && $0.stopId == match.stopId && $0.id != match.id }
                .compactMap(\ .expectedArrival)

            let siblingMinutes = TrackingTimeSync.nextArrivalMinutes(
                arrivalTimes: siblingTimes,
                after: currentArrival,
                now: now
            )
            let currentSecs = TrackingTimeSync.remainingSeconds(until: currentArrival, now: now)
            found = (secondsRemaining: currentSecs, siblings: siblingMinutes)
        }

        if let current = found {
            let eta = Date().addingTimeInterval(current.secondsRemaining)
            let mins = TrackingTimeSync.remainingMinutes(until: eta)
            let progress = TrackingTimeSync.progress(until: eta)

            LiveActivityManager.shared.updateActivity(
                statusText: TrackingTimeSync.statusText(until: eta),
                arrivalTime: eta,
                progress: progress,
                minutesAway: mins,
                nextArrivals: Array(current.siblings.prefix(2))
            )
        } else {
            // Fallback: If no arrival is found (e.g. train just left and next one not yet in feed),
            // keep the widget alive and indicate we're waiting for the next one.
            // Do NOT end the activity; let the next refresh pick up the new train.
            LiveActivityManager.shared.updateActivity(
                statusText: "Waiting for next train...",
                arrivalTime: Date().addingTimeInterval(300),  // 5 min buffer to keep widget alive
                progress: 0.0,
                minutesAway: nil,
                nextArrivals: []
            )
        }
    }

    // MARK: - Search Pin

    /// Activates the search pin and refreshes data for that location.
    /// The `userLocation` parameter is only used as a fallback — once
    /// `isSearchPinActive` is set, `effectiveLocation` will always
    /// return the pin coordinate for all subsequent operations.
    ///
    /// Uses the standard mode-aware `refresh()` so that drag-search
    /// works correctly on every tab (Nearby, Subway, Bus, etc.).
    func setSearchPin(_ coordinate: CLLocationCoordinate2D, userLocation: CLLocation?) async {
        if let userLocation { lastKnownUserLocation = userLocation }
        searchPinCoordinate = coordinate
        isSearchPinActive = true
        // New location context — clear grace so stale routes from the
        // previous location don't persist.
        graceMissCountBySource.removeAll()
        // Use the full mode-aware refresh so bus/subway/LIRR/MNR tabs
        // all get correct data at the drag-search location.
        let loc = effectiveLocation(userLocation: userLocation)
        await refresh(location: loc)
    }

    /// Deactivates the search pin and returns to user location.
    /// Resets pin state so that the next `refresh()` call uses the real GPS.
    /// Does NOT clear transit arrays here — the subsequent refresh replaces
    /// them atomically with fresh data. This avoids a visible empty-state
    /// flash and ensures rows never disappear if the refresh fails.
    func clearSearchPin(userLocation: CLLocation?) async {
        if let userLocation { lastKnownUserLocation = userLocation }
        isSearchPinActive = false
        searchPinCoordinate = nil
        graceMissCountBySource.removeAll()
        goMode.walkingRoute = nil
        nearestStopCoordinate = nil
        nearestTransit = nil
        nearestTransitDistance = nil
    }

    // MARK: - Route Detail

    /// Opens the route detail sheet for a grouped route and loads its
    /// Convenience alias used by the UI layer to select a grouped route.
    func handleRouteSelection(
        _ group: GroupedNearbyTransitResponse, directionIndex: Int = 0, userLocation: CLLocation?
    ) async {
        await selectGroupedRoute(group, directionIndex: directionIndex, userLocation: userLocation)
    }

    /// route shape / vehicle positions on the map.
    /// Also centers the map on the nearest station and calculates walking directions.
    func selectGroupedRoute(
        _ group: GroupedNearbyTransitResponse, directionIndex: Int = 0, userLocation: CLLocation?
    ) async {
        selectedGroupedRoute = group
        selectedDirectionIndex = directionIndex
        isRouteDetailPresented = true

        #if DEBUG
        AppLogger.shared.log(
            "ROUTE_DETAIL",
            message:
                "OPEN route=\(group.routeId) mode=\(group.mode) selectedDirIdx=\(directionIndex) dirs=\(group.directions.count) snapshot=\(debugDirectionSnapshot(group))"
        )
        #endif

        // Log route interaction to Supabase for analytics
        Task {
            await SupabaseManager.shared.logRouteInteraction(
                routeId: group.routeId,
                mode: group.mode,
                type: "click"
            )
        }

        // Reset previous route data
        goMode.walkingRoute = nil
        nearestStopCoordinate = nil
        busVehicles = []
        trainVehicles = []
        cachedTrainArrivals = []
        routeShape = nil

        selectedRouteId = group.routeId

        if group.isBus {
            // Load route shape + vehicles for bus routes
            async let vehiclesTask = TrackAPI.fetchBusVehicles(routeID: group.routeId)
            async let shapeTask = TrackAPI.fetchRouteShape(routeID: group.routeId)

            do {
                let vehicles = try await vehiclesTask
                busVehicles = vehicles
                // Seed interpolation state so the first updateBusSimulation()
                // ticks have correct data (no movement until refreshBusVehicles
                // provides a second GPS reading, but the bookkeeping is ready).
                _targetBusGPS = Dictionary(
                    vehicles.map { ($0.vehicleId, $0) },
                    uniquingKeysWith: { $1 }
                )
                for v in vehicles {
                    previousBusPositions[v.vehicleId] = BusSnapshot(
                        lat: v.lat, lon: v.lon, timestamp: Date()
                    )
                }
                lastBusUpdateTime = Date()
            } catch {
                AppLogger.shared.logError("fetchBusVehicles(\(group.routeId))", error: error)
            }
            // Polling handled by HomeView.onChange(of: selectedRouteId)

            do {
                routeShape = try await shapeTask
                if let shape = routeShape {
                    // Log decoded polyline details for debugging
                    let decoded = shape.decodedPolylines
                    let totalPoints = decoded.reduce(0) { $0 + $1.count }
                    AppLogger.shared.log(
                        "BUS_SHAPE",
                        message:
                            "Loaded shape for \(group.routeId): \(shape.polylines.count) polylines (\(totalPoints) total points), \(shape.stops.count) stops"
                    )

                    // Enrich the grouped route with any missing directions from the shape.
                    // The nearby API only returns directions for stops near the user,
                    // but the route shape knows ALL directions (e.g. both inbound & outbound).
                    enrichGroupWithShapeDirections(shape)
                } else {
                    AppLogger.shared.log(
                        "BUS_SHAPE", message: "No shape returned for \(group.routeId)")
                }
            } catch {
                AppLogger.shared.logError("fetchRouteShape(\(group.routeId))", error: error)
            }
        } else if group.isLIRR {
            // LIRR: fetch the branch-specific polyline + live arrivals
            do {
                async let shapeTask = TrackAPI.fetchLIRRShape(routeID: group.routeId)
                async let arrivalsTask = TrackAPI.fetchLIRRArrivals()

                routeShape = try await shapeTask
                populateStopsFromArrivals(group: group)
                AppLogger.shared.log(
                    "LIRR_SHAPE",
                    message: "Loaded shape for \(group.routeId) (\(group.displayName))")
                if let shape = routeShape { enrichGroupWithShapeDirections(shape) }

                // Filter arrivals to this specific branch and interpolate
                let allArrivals = try await arrivalsTask
                let routeArrivals = allArrivals.filter { arrival in
                    let id = arrival.routeID.lowercased()
                    let target = group.routeId.lowercased()
                    return id == target
                        || id == target.replacingOccurrences(of: "lirr_", with: "")
                        || "lirr_\(id)" == target
                }
                updateTrainPositions(arrivals: routeArrivals)
            } catch {
                AppLogger.shared.logError("fetchLIRRData(\(group.routeId))", error: error)
            }
        } else if group.isMNR {
            // Metro-North: fetch the line-specific polyline + live arrivals
            do {
                async let shapeTask = TrackAPI.fetchMNRShape(routeID: group.routeId)
                async let arrivalsTask = TrackAPI.fetchMNRArrivals()

                routeShape = try await shapeTask
                populateStopsFromArrivals(group: group)
                AppLogger.shared.log(
                    "MNR_SHAPE", message: "Loaded shape for \(group.routeId) (\(group.displayName))"
                )
                if let shape = routeShape { enrichGroupWithShapeDirections(shape) }

                // Filter arrivals to this specific line and interpolate
                let allArrivals = try await arrivalsTask
                let routeArrivals = allArrivals.filter { arrival in
                    let id = arrival.routeID.lowercased()
                    let target = group.routeId.lowercased()
                    return id == target
                        || id == target.replacingOccurrences(of: "mnr_", with: "")
                        || "mnr_\(id)" == target
                }
                updateTrainPositions(arrivals: routeArrivals)
            } catch {
                AppLogger.shared.logError("fetchMNRData(\(group.routeId))", error: error)
            }
        } else {
            // For subway: fetch the full line geometry AND live arrivals from the backend
            do {
                async let shapeTask = TrackAPI.fetchSubwayShape(routeID: group.displayName)
                async let arrivalsTask = TrackAPI.fetchSubwayArrivals(lineID: group.displayName)

                routeShape = try await shapeTask
                let arrivals = try await arrivalsTask
                updateTrainPositions(arrivals: arrivals)
                if let shape = routeShape { enrichGroupWithShapeDirections(shape) }

            } catch {
                AppLogger.shared.logError("fetchSubwayData(\(group.displayName))", error: error)
            }
        }

        // Find nearest stop and calculate walking route.
        // Use referenceLocation — single source of truth for pin vs GPS.
        let refLocation = referenceLocation
        let fallbackStops = routeShape?.stopsForDirection(index: selectedDirectionIndex) ?? []
        if !fallbackStops.isEmpty, let userLoc = refLocation {
            var closestStop: BusStop?
            var minDistance: CLLocationDistance = .greatestFiniteMagnitude

            for stop in fallbackStops {
                let stopLoc = CLLocation(latitude: stop.lat, longitude: stop.lon)
                let distance = userLoc.distance(from: stopLoc)
                if distance < minDistance {
                    minDistance = distance
                    closestStop = stop
                }
            }

            if let closest = closestStop {
                let closestCoord = CLLocationCoordinate2D(
                    latitude: closest.lat, longitude: closest.lon)
                nearestStopCoordinate = closestCoord
                // Highlight the nearest stop in the arrivals list
                selectedStopId = closest.id
                #if DEBUG
                print("[WALK DIST] \(group.routeId) (\(group.mode))  source=routeShape (\(fallbackStops.count) stops)  nearest stop='\(closest.name)' id=\(closest.id)  (\(String(format: "%.5f", closest.lat)),\(String(format: "%.5f", closest.lon)))  straight-line=\(Int(minDistance))m / \(String(format: "%.2f", minDistance / 1609.34))mi  ← polyline targets this stop")
                #endif

                // Fetch walking route in background
                let from = userLoc.coordinate
                Task { await fetchWalkingRoute(from: from, to: closestCoord) }
            }
        } else if fallbackStops.isEmpty {
            // Fallback: zoom to the first arrival's stop coordinates when
            // route shape data is unavailable (common for buses when the
            // OBA API is slow or returns empty data).
            if let first = group.directions.first?.arrivals.first,
                let lat = first.stopLat, let lon = first.stopLon
            {
                let fallbackCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                nearestStopCoordinate = fallbackCoord
                // Highlight the nearest stop in the arrivals list
                selectedStopId = first.stopId

                if let userLoc = refLocation {
                    #if DEBUG
                    let fallbackDist = userLoc.distance(from: CLLocation(latitude: lat, longitude: lon))
                    print("[WALK DIST] \(group.routeId) (\(group.mode))  source=arrivalFallback (no shape stops)  stop='\(first.stopName)'  (\(String(format: "%.5f", lat)),\(String(format: "%.5f", lon)))  straight-line=\(Int(fallbackDist))m / \(String(format: "%.2f", fallbackDist / 1609.34))mi  ← polyline targets this stop")
                    #endif
                    let from = userLoc.coordinate
                    Task { await fetchWalkingRoute(from: from, to: fallbackCoord) }
                }
            }
        }

        // After loading shape and vehicles, check if we need schedule data
        // for directions with no live buses
        if group.isBus {
            await fetchBusScheduleIfNeeded()
        }

        #if DEBUG
        if let selected = selectedGroupedRoute {
            AppLogger.shared.log(
                "ROUTE_DETAIL",
                message:
                    "READY route=\(selected.routeId) mode=\(selected.mode) selectedDirIdx=\(selectedDirectionIndex) snapshot=\(debugDirectionSnapshot(selected))"
            )
        }
        #endif
    }

    /// Populates the route shape's empty `stops` array from the group's arrival
    /// data. Commuter rail (LIRR/MNR) backends don't include stops in the shape
    /// response, but each arrival carries its stop coordinates. This synthesizes
    /// BusStop objects so the map can show stop markers and the camera zoom logic
    /// can find the nearest stop.
    private func populateStopsFromArrivals(group: GroupedNearbyTransitResponse) {
        guard var shape = routeShape, shape.stops.isEmpty else { return }

        var seenIds = Set<String>()
        var synthesized: [BusStop] = []

        for direction in group.directions {
            for arrival in direction.arrivals {
                guard let lat = arrival.stopLat, let lon = arrival.stopLon else { continue }
                // Use stopId when available; fall back to a composite key
                // of name + coordinates to avoid dedup collisions when
                // different physical stops share the same name.
                let stopId = arrival.stopId ?? "\(arrival.stopName)_\(lat)_\(lon)"
                guard !seenIds.contains(stopId) else { continue }
                seenIds.insert(stopId)
                synthesized.append(
                    BusStop(
                        id: stopId,
                        name: arrival.stopName,
                        lat: lat,
                        lon: lon,
                        direction: nil
                    ))
            }
        }

        if !synthesized.isEmpty {
            shape.stops = synthesized
            routeShape = shape
        }
    }

    /// Enriches the currently selected grouped route with any directions
    /// present in the route shape data but missing from the nearby API response.
    ///
    /// The `/nearby/grouped` endpoint only includes directions that have live
    /// arrivals at stops near the user. However, the route shape knows about
    /// ALL directions (e.g. both inbound and outbound). This method adds
    /// placeholder direction entries so the direction picker shows every
    /// direction the route serves — even if no arrivals are nearby right now.
    ///
    /// Works for all transit modes (bus, subway, LIRR, MNR).
    func enrichGroupWithShapeDirections(_ shape: RouteShapeResponse) {
        guard let group = selectedGroupedRoute, !shape.directions.isEmpty else { return }

        let existingCount = group.directions.count
        let previousSelectedDirectionKey: String? = {
            guard group.directions.indices.contains(selectedDirectionIndex) else { return nil }
            return normalizedDirectionKey(group.directions[selectedDirectionIndex])
        }()

        // Build a new directions array ordered by shape direction_id.
        // For each shape direction, either find the matching existing group
        // direction or create a placeholder. This guarantees group index N
        // maps to shape direction_id N.
        var orderedDirections: [DirectionArrivalsResponse] = []
        var usedExistingIndices = Set<Int>()

        for shapeDir in shape.directions.sorted(by: { $0.directionId < $1.directionId }) {
            let headsign = shapeDir.headsign.lowercased()

            // Try to find a matching existing group direction
            var matchedIndex: Int? = nil
            for (idx, existingDir) in group.directions.enumerated()
            where !usedExistingIndices.contains(idx) {
                let existingLower = existingDir.direction.lowercased()

                let exactMatch = !headsign.isEmpty && existingLower == headsign
                // Only allow loose substring matching when the existing direction
                // key is long enough (>= 3 chars). Short compass codes like "n"/"s"
                // false-match against nearly every headsign ("inwood-207 st"
                // contains "s"), which causes both "N" and "S" to match the same
                // shape direction.
                let partialMatch =
                    !headsign.isEmpty && existingLower.count >= 3
                    && (existingLower.contains(headsign) || headsign.contains(existingLower))
                let destMatch =
                    !headsign.isEmpty
                    && existingDir.arrivals.contains(where: { arrival in
                        guard let dest = arrival.destination?.lowercased() else { return false }
                        return dest.contains(headsign) || headsign.contains(dest)
                    })

                if exactMatch || partialMatch || destMatch {
                    matchedIndex = idx
                    break
                }
            }

            if let idx = matchedIndex {
                orderedDirections.append(group.directions[idx])
                usedExistingIndices.insert(idx)
            } else {
                // No headsign/destination match found. Before creating a brand-new
                // placeholder, check if there's an unmatched existing direction that
                // is itself a placeholder (e.g. "Opposite", a compass code like "S",
                // or an empty-arrivals backfill). Consuming it avoids inflating the
                // direction count from 2 → 3 for routes that only have live data in
                // one direction.
                let placeholderIdx = group.directions.indices.first { idx in
                    guard !usedExistingIndices.contains(idx) else { return false }
                    let dir = group.directions[idx]
                    // Consider it a placeholder if it has no real (non-placeholder) arrivals,
                    // or its direction key is a generic backfill label
                    let isGeneric = ["opposite", "n/a", "loop"].contains(dir.direction.lowercased())
                        || dir.direction.count <= 2  // compass codes like "N", "S", "SW"
                    return dir.liveArrivals.isEmpty || isGeneric
                }

                if let pidx = placeholderIdx {
                    // Replace the placeholder with a proper direction entry
                    // carrying the shape's headsign but keeping any arrivals
                    let existing = group.directions[pidx]
                    let directionString =
                        shapeDir.headsign.isEmpty
                        ? existing.direction
                        : shapeDir.headsign
                    orderedDirections.append(
                        DirectionArrivalsResponse(
                            direction: directionString,
                            directionLabel: shapeDir.headsign.isEmpty ? existing.directionLabel : "→ \(shapeDir.headsign)",
                            arrivals: existing.arrivals
                        ))
                    usedExistingIndices.insert(pidx)
                } else {
                    // Create a placeholder for this missing direction
                    let directionString =
                        shapeDir.headsign.isEmpty
                        ? "Direction \(shapeDir.directionId)"
                        : shapeDir.headsign
                    orderedDirections.append(
                        DirectionArrivalsResponse(
                            direction: directionString,
                            directionLabel: shapeDir.headsign.isEmpty ? nil : "→ \(shapeDir.headsign)",
                            arrivals: []
                        ))
                }
            }
        }

        // Append any existing directions that didn't match any shape direction
        // (e.g. backfilled compass directions from the nearby API)
        for (idx, dir) in group.directions.enumerated() where !usedExistingIndices.contains(idx) {
            orderedDirections.append(dir)
        }

        // Only update if we added directions or reordered them
        let changed =
            orderedDirections.count != existingCount
            || zip(orderedDirections, group.directions).contains(where: {
                $0.direction != $1.direction
            })

        if changed {
            let updatedGroup = GroupedNearbyTransitResponse(
                routeId: group.routeId,
                displayName: group.displayName,
                mode: group.mode,
                colorHex: group.colorHex,
                directions: orderedDirections
            )
            selectedGroupedRoute = updatedGroup

            // Preserve the user's selected direction when shape enrichment
            // reorders or backfills direction entries.
            if let key = previousSelectedDirectionKey,
               let resolvedIndex = updatedGroup.directions.firstIndex(where: {
                   normalizedDirectionKey($0) == key
               }) {
                let previousIndex = selectedDirectionIndex
                selectedDirectionIndex = resolvedIndex

                #if DEBUG
                AppLogger.shared.log(
                    "DIR_PREF",
                    message:
                        "RESTORE route=\(updatedGroup.routeId) mode=\(updatedGroup.mode) oldIdx=\(previousIndex) newIdx=\(resolvedIndex) oldKey=\(key) newDir=\(updatedGroup.directions[resolvedIndex].direction)"
                )
                #endif
            } else {
                let previousIndex = selectedDirectionIndex
                selectedDirectionIndex = max(
                    0,
                    min(selectedDirectionIndex, max(0, updatedGroup.directions.count - 1))
                )

                #if DEBUG
                AppLogger.shared.log(
                    "DIR_PREF",
                    message:
                        "RESTORE_FALLBACK route=\(updatedGroup.routeId) mode=\(updatedGroup.mode) oldIdx=\(previousIndex) newIdx=\(selectedDirectionIndex) reason=no-key-match"
                )
                #endif
            }

            AppLogger.shared.log(
                "ROUTE_DETAIL",
                message:
                    "Enriched \(group.displayName) from \(existingCount) → \(orderedDirections.count) directions (ordered by shape direction_id)"
            )
        }
    }

    /// Returns a camera position centered on the first arrival's stop.
    func cameraPositionForRoute(_ group: GroupedNearbyTransitResponse) -> MapCameraPosition {
        if let first = group.directions.first?.arrivals.first,
            let lat = first.stopLat, let lon = first.stopLon
        {
            return .camera(
                MapCamera(
                    centerCoordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    distance: 3000
                ))
        }
        return .automatic
    }

    /// Computes a camera position that fits the entire route shape on screen,
    /// including the user's location when available. Works for all modes:
    /// subway, bus, LIRR, and Metro-North.
    func cameraPositionFittingRoute(userLocation: CLLocation?, is3D: Bool) -> MapCameraPosition? {
        guard let shape = routeShape else { return nil }

        // Use the effective location (search pin when drag-to-search is active)
        // so the map fits the route relative to where the user is exploring.
        let refLocation = effectiveLocation(userLocation: userLocation)

        // Collect all coordinates: polyline points + stop locations
        var allCoords: [CLLocationCoordinate2D] = []

        // Use direction-specific polylines when a direction is selected
        let group = selectedGroupedRoute
        let hasDirections = (group?.directions.count ?? 0) > 1
        let polylines: [[CLLocationCoordinate2D]]
        if hasDirections, !shape.directions.isEmpty {
            polylines = shape.polylinesForDirection(index: selectedDirectionIndex)
        } else {
            polylines = shape.decodedPolylines
        }

        for coords in polylines {
            allCoords.append(contentsOf: coords)
        }

        // Also include stop coordinates as a fallback anchor
        let stops = hasDirections ? shape.stopsForDirection(index: selectedDirectionIndex) : shape.stops
        for stop in stops {
            allCoords.append(CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon))
        }

        guard !allCoords.isEmpty else { return nil }

        // Compute bounding box of route geometry ONLY (without user location)
        var minLat = allCoords[0].latitude
        var maxLat = allCoords[0].latitude
        var minLon = allCoords[0].longitude
        var maxLon = allCoords[0].longitude

        for coord in allCoords {
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }

        // Include effective location so the map shows both you (or your search center) and the route
        if let loc = refLocation?.coordinate {
            allCoords.append(loc)
        }

        // Recompute bounding box WITH user location
        var fullMinLat = allCoords[0].latitude
        var fullMaxLat = allCoords[0].latitude
        var fullMinLon = allCoords[0].longitude
        var fullMaxLon = allCoords[0].longitude

        for coord in allCoords {
            fullMinLat = min(fullMinLat, coord.latitude)
            fullMaxLat = max(fullMaxLat, coord.latitude)
            fullMinLon = min(fullMinLon, coord.longitude)
            fullMaxLon = max(fullMaxLon, coord.longitude)
        }

        // Check if including the user location pushes the span beyond max zoom.
        // If the full span (route + user) exceeds max altitude but the route-only
        // span is within limits, center on the nearest stop instead of trying
        // to fit both user and route endpoints across the city.
        let fullLatSpan = (fullMaxLat - fullMinLat) * 111_000
        let fullCenterLat = (fullMinLat + fullMaxLat) / 2
        let fullLonSpan = (fullMaxLon - fullMinLon) * 111_000 * cos(fullCenterLat * .pi / 180)
        let fullSpanMeters = max(fullLatSpan, fullLonSpan)
        let fullPadded = fullSpanMeters * AppSettings.shared.smartZoomPaddingMultiplier

        let routeLatSpan = (maxLat - minLat) * 111_000
        let routeCenterLat = (minLat + maxLat) / 2
        let routeLonSpan = (maxLon - minLon) * 111_000 * cos(routeCenterLat * .pi / 180)
        let routeSpanMeters = max(routeLatSpan, routeLonSpan)
        let routePadded = routeSpanMeters * AppSettings.shared.smartZoomPaddingMultiplier

        // If the route+user span exceeds max zoom, just fit the route itself.
        // If even the route alone exceeds max zoom (very long route like LIRR),
        // center on the nearest stop at max zoom.
        let useRouteOnly = fullPadded > AppSettings.shared.smartZoomMaxAltitude

        let center: CLLocationCoordinate2D
        let distance: Double

        if useRouteOnly && routePadded > AppSettings.shared.smartZoomMaxAltitude {
            // Route itself is too long (e.g. LIRR spanning Manhattan → Montauk).
            // Center on the nearest stop to the effective location (search pin
            // when drag-to-search is active, otherwise the user's GPS).
            if let refLoc = refLocation,
                let nearest = stops.min(by: {
                    let d1 = CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: refLoc)
                    let d2 = CLLocation(latitude: $1.lat, longitude: $1.lon).distance(from: refLoc)
                    return d1 < d2
                })
            {
                center = CLLocationCoordinate2D(latitude: nearest.lat, longitude: nearest.lon)
            } else if let refLoc = refLocation {
                // No stops available (e.g. commuter rail) — stay near the
                // user's current location instead of zooming to the geometric
                // center of a 100-mile route, which would be confusing.
                center = refLoc.coordinate
            } else {
                // No stops AND no user location — don't zoom at all.
                return nil
            }
            distance = AppSettings.shared.smartZoomMaxAltitude
        } else if useRouteOnly {
            // Route fits within max zoom but user location is too far away.
            // Just fit the route without the user location.
            center = CLLocationCoordinate2D(
                latitude: routeCenterLat, longitude: (minLon + maxLon) / 2)
            distance = max(
                AppSettings.shared.smartZoomMinAltitude,
                min(routePadded, AppSettings.shared.smartZoomMaxAltitude)
            )
        } else {
            // Everything fits — use the full bounding box including user location.
            center = CLLocationCoordinate2D(
                latitude: fullCenterLat, longitude: (fullMinLon + fullMaxLon) / 2)
            distance = max(
                AppSettings.shared.smartZoomMinAltitude,
                min(fullPadded, AppSettings.shared.smartZoomMaxAltitude)
            )
        }

        return .camera(
            MapCamera(
                centerCoordinate: center,
                distance: distance,
                heading: 0,
                pitch: is3D ? 60 : 0
            ))
    }
}
