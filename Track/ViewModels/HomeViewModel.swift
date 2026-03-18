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
    /// Dedup key for [BUCKETS] debug log — only prints when content changes.
    private static var _lastBucketsMessage: String?

    var nearbyStations: [(stationID: String, name: String, lat: Double, lon: Double, routeIDs: [String])] =
        []
    var upcomingArrivals: [TrainArrival] = []
    var isLoading = false
    /// True after the first successful data load. Prevents skeleton placeholders
    /// from appearing on subsequent refreshes (e.g. return from background).
    var hasLoadedOnce = false
    /// True while a background refresh is running after cached data has been
    /// displayed on cold launch.  The UI shows a subtle "Updating…" indicator
    /// instead of full skeleton placeholders.
    var isRefreshing = false
    /// True while `refresh()` is executing. Used to prevent the 20s timer from
    /// stacking duplicate refresh calls when the backend is slow (cold-start
    /// can take 30-60s, causing 1-3 extra timer fires before the first fetch
    /// returns). Without this, each tick spawns a new `refresh()` that passes
    /// the `canSkipRefresh` gate (hasLoadedOnce is still false), creating a
    /// retry storm.
    private var _refreshInFlight = false

    /// Tracks the single cold-start retry chain. When non-nil, a retry is
    /// already scheduled — new retry requests are ignored to prevent
    /// geometric growth (each failed fetch was scheduling a *new* 5s retry,
    /// and each of those failures scheduled another, creating O(2^n) fetches).
    var _coldStartRetryTask: Task<Void, Never>?
    /// Current attempt counter for exponential backoff (5s → 10s → 20s → 40s).
    var _coldStartRetryAttempt: Int = 0
    /// Maximum number of cold-start retry attempts before giving up and
    /// letting the normal 30s timer handle subsequent refreshes.
    static let maxColdStartRetries = 5
    var errorMessage: String?

    /// True when `errorMessage` indicates a network/connectivity failure rather
    /// than a server-side or data issue.
    var isNetworkError: Bool {
        guard let msg = errorMessage?.lowercased() else { return false }
        return msg.contains("network") || msg.contains("offline")
            || msg.contains("internet") || msg.contains("connection")
            || msg.contains("timed out") || msg.contains("not connected")
    }

    /// True when `errorMessage` indicates a backend/server problem (5xx, timeout)
    /// as opposed to a client-side network outage.
    var isBackendError: Bool {
        guard let msg = errorMessage?.lowercased() else { return false }
        return msg.contains("server error") || msg.contains("502")
            || msg.contains("503") || msg.contains("504")
            || msg.contains("500") || msg.contains("couldn't be completed")
    }

    /// True when the user's real GPS location is outside the NYC metro service area.
    /// The app still fetches data (using a Midtown fallback), but the UI can show
    /// an "unsupported region" message instead of the generic empty state.
    var isOutsideServiceArea: Bool {
        guard let loc = lastKnownUserLocation else { return false }
        return !AppTheme.MapConfig.isInServiceArea(loc.coordinate) && !isSearchPinActive
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
    /// Routes whose DIST warning has already been printed this session.
    /// Prevents the same warning from repeating on every SwiftUI render pass.
    private static var _loggedDistWarnings: Set<String> = []

    func displayDistanceMeters(for group: GroupedNearbyTransitResponse, from location: CLLocation?) -> CLLocationDistance? {
        guard let location else { return nil }

        let result: CLLocationDistance?

        if group.isBus {
            let target = normalizeMTARouteToken(group.routeId)
            let matchingStops = nearbyBusStops.filter { stop in
                guard let routeIds = stop.routeIds, !routeIds.isEmpty else { return false }
                return routeIds.contains { normalizeMTARouteToken($0) == target }
            }
            #if DEBUG
            do {
                let warnKey = "\(group.routeId)|bus"
                // Suppress the warning for graced routes — they're expected
                // to have no matching nearby stops because they've disappeared
                // from the fresh API response (e.g. express buses that left the radius).
                let isGraced = (graceMissCountBySource["bus"]?[group.routeId.uppercased()] ?? 0) > 0
                if matchingStops.isEmpty && !nearbyBusStops.isEmpty && !isGraced && Self._loggedDistWarnings.insert(warnKey).inserted {
                    print("[DIST] \(group.routeId) bus  ⚠️ NO matching stops (token=\(target), nearbyBusStops=\(nearbyBusStops.count))")
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
            do {
                let warnKey = "\(group.routeId)|\(group.mode)"
                // Suppress the warning for graced routes — they're expected
                // to have no matching stations because they've disappeared
                // from the fresh API response (e.g. routes that left the radius).
                let isGraced = (graceMissCountBySource["nearby"]?[group.routeId.uppercased()] ?? 0) > 0
                if matchingStations.isEmpty && !nearbyStations.isEmpty && !isGraced && Self._loggedDistWarnings.insert(warnKey).inserted {
                    print("[DIST] \(group.routeId) \(group.mode)  ⚠️ NO matching stations (token=\(target), nearbyStations=\(nearbyStations.count))")
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
                result = groupDist.isFinite ? groupDist : nil
            }
        }

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
        do {
            let bucketsMsg: String
            if let referenceLocation {
                let src = isSearchPinActive ? "PIN" : "GPS"
                bucketsMsg = "[BUCKETS] center=\(src) (\(String(format: "%.5f", referenceLocation.coordinate.latitude)), \(String(format: "%.5f", referenceLocation.coordinate.longitude)))  groups=\(groups.count)  nearbyBusStops=\(nearbyBusStops.count)  nearbyStations=\(nearbyStations.count)  lastKnownGPS=\(lastKnownUserLocation.map { "(\(String(format: "%.5f", $0.coordinate.latitude)),\(String(format: "%.5f", $0.coordinate.longitude)))" } ?? "nil")"
            } else {
                bucketsMsg = "[BUCKETS] ⚠️ referenceLocation=nil — sorting without distance  lastKnownGPS=\(lastKnownUserLocation.map { "(\(String(format: "%.5f", $0.coordinate.latitude)),\(String(format: "%.5f", $0.coordinate.longitude)))" } ?? "nil")"
            }
            if Self._lastBucketsMessage != bucketsMsg {
                Self._lastBucketsMessage = bucketsMsg
                print(bucketsMsg)
            }
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
            // Use backend's canonical MTA sorting key as tiebreaker
            if !lhs.sortingKey.isEmpty && !rhs.sortingKey.isEmpty && lhs.sortingKey != rhs.sortingKey {
                return lhs.sortingKey < rhs.sortingKey
            }
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
                            distanceM: dist,
                            isRealTime: !train.isCancelled && train.status != "Scheduled",
                            isCancelled: train.isCancelled
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
    /// the location context is stable, and counters are expired when
    /// the context changes (search-pin set/clear, significant movement).
    var graceMissCountBySource: [String: [String: Int]] = [:]

    /// Pre-seeds every currently-visible route at the eviction threshold
    /// so that routes not present at the new location are immediately dropped
    /// on the very next merge.  Routes that DO reappear have their count reset
    /// by the merge logic's "reappeared" check.
    private func expireAllGraceCounters() {
        let evictionThreshold = 3  // must match maxGraceCycles in mergeGroupedTransit()
        let sourceArrays: [(String, [GroupedNearbyTransitResponse])] = [
            ("nearby", groupedTransit),
            ("subway", nearbyGroupedSubwayArrivals),
            ("bus", nearbyGroupedBusArrivals),
            ("lirr", nearbyGroupedLIRRArrivals),
            ("mnr", nearbyGroupedMNRArrivals),
        ]
        for (source, groups) in sourceArrays {
            var counts = graceMissCountBySource[source] ?? [:]
            for g in groups {
                counts[g.routeId.uppercased()] = evictionThreshold
            }
            if !counts.isEmpty {
                graceMissCountBySource[source] = counts
            }
        }
    }

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

        // Don't store preferences for empty/placeholder directions (e.g.
        // compass stubs "E", "N" with 0 live arrivals).  This prevents
        // phantom prefs that flip the user to a blank tab next session.
        let targetDir = group.directions[clampedIndex]
        guard !targetDir.liveArrivals.isEmpty else { return }

        let directionKey = normalizedDirectionKey(targetDir)
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
    /// Also updates the map system's rerouted-route set so elevated
    /// polylines are demoted to subway-level during active reroutes.
    func refreshAlerts() async {
        do {
            serviceAlerts = try await TrackAPI.fetchAlerts()
            alertsLastUpdated = Date()
            AlertNotificationManager.shared.processAlerts(serviceAlerts)
            mapSystem.updateReroutedRoutes(from: serviceAlerts)
        } catch {}
    }

    // Route detail sheet
    var selectedGroupedRoute: GroupedNearbyTransitResponse? {
        didSet {
            _filteredBusVehiclesCache = nil
            _filteredTrainVehiclesCache = nil
        }
    }
    /// Cancelable task for polyline rebuild — cancelled when the user switches
    /// directions rapidly so only the final selection triggers a full rebuild.
    @ObservationIgnored private var _polylineRebuildTask: Task<Void, Never>?
    var selectedDirectionIndex: Int = 0 {
        didSet {
            // Invalidate vehicle filter caches when direction changes
            _filteredBusVehiclesCache = nil
            _filteredTrainVehiclesCache = nil
            // Cancel any in-flight rebuild from a previous tap so rapid direction
            // switching doesn't cascade into multiple simultaneous MapPolyline
            // teardown/rebuild cycles on MapKit's render thread.
            // Use the async path to avoid main-thread blocking.
            schedulePolylineRebuild()
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
    @ObservationIgnored private var _splitRebuildTask: Task<Void, Never>?
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

    /// True when the user manually tapped a stop in the stops list.
    /// Prevents `refreshWalkingState` from overwriting the selection
    /// back to the auto-nearest stop on the next GPS update.
    var isStopManuallySelected = false

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
            // When map selection changes, auto-expand the corresponding row.
            // Deferred to the next run-loop tick so the mutation doesn't nest
            // inside the @Observable registrar's `withMutation` for this property,
            // which would re-enter observation tracking and SIGABRT.
            guard let id = tappedVehicleId else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                // Find the best matching arrival to expand
                // prioritize exact vehicle ID match
                if let match = self.nearbyTransit.first(where: { $0.vehicleId == id || $0.tripId == id }) {
                    // Only change if not already selected to avoid animation glitches
                    if self.selectedExpandedArrivalID != match.id {
                        withAnimation {
                            self.selectedExpandedArrivalID = match.id
                        }
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
        didSet {
            _busVehicleIndex = Dictionary(busVehicles.map { ($0.vehicleId, $0) }, uniquingKeysWith: { $1 })
            // Only invalidate filter cache when vehicle IDs change (new vehicles
            // appeared or old ones disappeared), NOT on every position update.
            // The filter only depends on route/direction/destination — positions
            // don't affect which vehicles pass the filter.
            let newIds = Set(busVehicles.map(\.vehicleId))
            let oldIds = Set(oldValue.map(\.vehicleId))
            if newIds != oldIds {
                _filteredBusVehiclesCache = nil
            }
        }
    }
    /// O(1) lookup by vehicleId — rebuilt automatically when busVehicles is set.
    @ObservationIgnored private var _busVehicleIndex: [String: BusVehicleResponse] = [:]

    var trainVehicles: [TrainVehicle] = [] {
        didSet {
            _trainVehicleByTrip = Dictionary(trainVehicles.compactMap { v in v.tripId.map { ($0, v) } }, uniquingKeysWith: { $1 })
            _trainVehicleById = Dictionary(trainVehicles.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            // Only invalidate filter cache when vehicle set membership changes.
            let newIds = Set(trainVehicles.map(\.id))
            let oldIds = Set(oldValue.map(\.id))
            if newIds != oldIds {
                _filteredTrainVehiclesCache = nil
            }
        }
    }
    /// O(1) lookup by tripId — rebuilt automatically when trainVehicles is set.
    @ObservationIgnored private var _trainVehicleByTrip: [String: TrainVehicle] = [:]
    /// O(1) lookup by id — rebuilt automatically when trainVehicles is set.
    @ObservationIgnored private var _trainVehicleById: [String: TrainVehicle] = [:]

    // Smooth bus interpolation state — stores the previous GPS snapshot
    // so we can glide between updates along the route polyline.
    /// Previous GPS positions keyed by vehicle ID for smooth interpolation.
    @ObservationIgnored var previousBusPositions: [String: BusSnapshot] = [:]
    /// When the last bus GPS batch arrived (for elapsed-time calculation).
    @ObservationIgnored var lastBusUpdateTime: Date = .distantPast
    /// Target GPS positions from the latest API response. The simulation
    /// interpolates `busVehicles` display positions toward these targets
    /// each tick, eliminating the snap-forward → jump-back flicker.
    @ObservationIgnored var _targetBusGPS: [String: BusVehicleResponse] = [:]

    /// Previous train display positions for smooth cross-tick interpolation.
    /// Keyed by trip ID (same as TrainVehicle.id).
    @ObservationIgnored var _previousTrainPositions: [String: CLLocationCoordinate2D] = [:]
    /// Train vehicles that disappeared in the latest poll. Kept for a grace
    /// period (1 poll cycle) to avoid markers vanishing on a single GTFS-RT dropout.
    @ObservationIgnored var _trainGraceBuffer: [String: (vehicle: TrainVehicle, missedAt: Date)] = [:]
    /// Bus vehicles that disappeared in the latest poll. Kept for a grace
    /// period (≤12 s) to avoid markers vanishing on a single SIRI dropout,
    /// which causes the "On Route" → "Scheduled" chip flicker.
    @ObservationIgnored var _busGraceBuffer: [String: (vehicle: BusVehicleResponse, missedAt: Date)] = [:]

    // MARK: - Route Shape LRU Cache
    //
    // Keeps the 10 most-recently-viewed route shapes in memory so re-selecting
    // a route renders its polyline instantly without a network round-trip.
    // Entries auto-expire after 5 minutes to avoid stale data.

    private struct CachedShape {
        let shape: RouteShapeResponse
        let fetchedAt: Date
    }

    /// In-memory LRU cache: routeId → (shape, timestamp).
    @ObservationIgnored private var _routeShapeCache: [String: CachedShape] = [:]
    private let _routeShapeCacheMaxAge: TimeInterval = 300  // 5 min
    private let _routeShapeCacheMaxSize = 10

    /// Returns a cached route shape if it exists and is < 5 min old.
    private func getCachedRouteShape(for routeId: String) -> RouteShapeResponse? {
        guard let entry = _routeShapeCache[routeId] else { return nil }
        if Date().timeIntervalSince(entry.fetchedAt) > _routeShapeCacheMaxAge {
            _routeShapeCache.removeValue(forKey: routeId)
            return nil
        }
        return entry.shape
    }

    /// Stores a route shape in the LRU cache, evicting oldest if over capacity.
    private func cacheRouteShape(_ shape: RouteShapeResponse, for routeId: String) {
        _routeShapeCache[routeId] = CachedShape(shape: shape, fetchedAt: Date())
        // Evict oldest entries if over capacity
        if _routeShapeCache.count > _routeShapeCacheMaxSize {
            let sorted = _routeShapeCache.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            for entry in sorted.prefix(_routeShapeCache.count - _routeShapeCacheMaxSize) {
                _routeShapeCache.removeValue(forKey: entry.key)
            }
        }
    }

    var routeShape: RouteShapeResponse? {
        didSet {
            schedulePolylineRebuild()
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

    /// Schedules an async polyline rebuild on a background thread.
    /// Heavy decode → unify → smooth work runs off MainActor to avoid blocking
    /// the UI — prevents the "incredible long for the polyline to show" freeze.
    /// Cancels any in-flight rebuild so rapid direction switches don't pile up.
    private func schedulePolylineRebuild() {
        // Always cancel any in-flight rebuild first — if the user dismisses
        // while a previous decode/smooth task is still running, that stale
        // task would otherwise complete and write old polylines back into
        // the cached arrays, causing the dismissed route to reappear.
        _polylineRebuildTask?.cancel()
        _polylineRebuildTask = nil

        guard let shape = routeShape else {
            cachedRoutePolylines = []
            cachedInactivePolylines = []
            cachedInterpolationPolyline = []
            return
        }

        // Capture all values needed for the computation so the heavy
        // work can run outside @MainActor.
        let dirIndex = selectedDirectionIndex
        let dirName = selectedDirectionName
        let isBus = selectedGroupedRoute?.isBus == true
        let shouldFilter = !shape.directions.isEmpty

        // Clear stale polylines immediately so the map doesn't briefly
        // render the previous route's geometry with the new route's data.
        cachedRoutePolylines = []
        cachedInactivePolylines = []
        cachedInterpolationPolyline = []

        _polylineRebuildTask = Task { [weak self] in
            // Jump off the main actor for heavy decode → unify → smooth work.
            let result = await Task.detached(priority: .userInitiated) {
                () -> ([[CLLocationCoordinate2D]], [[CLLocationCoordinate2D]], [CLLocationCoordinate2D]) in

                // 1) Decode active-direction segments.
                let activeRaw = shouldFilter
                    ? shape.polylinesForDirection(index: dirIndex, name: dirName)
                    : shape.decodedPolylines

                // 2) Process polylines differently for bus vs train.
                //
                //    TRAINS: Drop near-duplicate segments (express/local
                //    overlaps), merge into chains, consolidate into one
                //    continuous path, then Catmull-Rom smooth at 8 segments
                //    per curve — subway turns should look fluid even at
                //    maximum zoom.
                //
                //    BUSES: Bus routes follow street grids with legitimate
                //    sharp right-angle turns.  We only merge adjacent
                //    fragments and apply light smoothing (4 segments per
                //    curve) to avoid rounding street corners.  No dedup
                //    or consolidation — buses can have loops/branches that
                //    would be destroyed by those algorithms.
                let routePolys: [[CLLocationCoordinate2D]]

                if isBus {
                    // Bus pipeline: merge only + light smoothing
                    let merged = mergeAdjacentPolylines(activeRaw)
                    routePolys = merged.filter { $0.count >= 2 }.map {
                        smoothPolyline($0, segmentsPerCurve: 4)
                    }
                } else {
                    // Train pipeline: dedup → merge → consolidate → heavy smooth
                    let deduped = removeDuplicateSegments(activeRaw)
                    let merged = mergeAdjacentPolylines(deduped)

                    let unified: [[CLLocationCoordinate2D]]
                    if merged.count > 1 {
                        let single = consolidateIntoSinglePolyline(merged)
                        unified = single.count >= 2 ? [single] : merged
                    } else {
                        unified = merged
                    }

                    routePolys = unified.filter { $0.count >= 2 }.map {
                        smoothPolyline($0, segmentsPerCurve: 8)
                    }
                }

                // For interpolation we need the pre-smoothed unified segments.
                let unified = isBus
                    ? mergeAdjacentPolylines(activeRaw)
                    : {
                        let d = removeDuplicateSegments(activeRaw)
                        let m = mergeAdjacentPolylines(d)
                        if m.count > 1 {
                            let s = consolidateIntoSinglePolyline(m)
                            return s.count >= 2 ? [s] : m
                        }
                        return m
                    }()

                // 5) Build inactive polylines from all OTHER directions.
                //    Now includes bus routes so users can visually distinguish
                //    the selected direction from alternate paths (dimmed).
                var inactivePolys: [[CLLocationCoordinate2D]] = []
                if shouldFilter && shape.directions.count > 1 {
                    let activeDir = shape.matchedDirection(index: dirIndex, name: dirName)
                    let activePolylineSet = Set(activeDir?.polylines ?? [])
                    var seenEncodedPolylines = activePolylineSet
                    var inactive: [[CLLocationCoordinate2D]] = []
                    for dir in shape.directions {
                        if let active = activeDir, dir.directionId == active.directionId,
                           dir.headsign == active.headsign { continue }
                        for encodedPoly in dir.polylines {
                            if seenEncodedPolylines.contains(encodedPoly) { continue }
                            seenEncodedPolylines.insert(encodedPoly)
                            let decoded = decodePolyline(encodedPoly)
                            if decoded.count >= 2 { inactive.append(decoded) }
                        }
                    }
                    // Inactive directions: merge + deduplicate but keep
                    // separate per-direction lines (multiple visual lines OK).
                    let mergedInactive = mergeAdjacentPolylines(inactive)
                    let unifiedInactive = isBus
                        ? mergedInactive
                        : unifyTrainPolylines(mergedInactive)
                    inactivePolys = unifiedInactive.filter { $0.count >= 2 }.map {
                        smoothPolyline($0, segmentsPerCurve: isBus ? 4 : 8)
                    }
                }

                // 6) Build interpolation polyline from raw (pre-smooth) unified segments.
                //    Snap/interpolation doesn't need visual smoothing — using the raw
                //    polyline avoids 4× point inflation for every O(N) snap call.
                let interpPolyline = unified.count == 1
                    ? (unified[0].count >= 2 ? unified[0] : [])
                    : {
                        let rawFiltered = unified.filter { $0.count >= 2 }
                        let interpMerged = mergeAdjacentPolylines(rawFiltered)
                        return interpMerged.first(where: { $0.count >= 2 }) ?? []
                    }()

                return (routePolys, inactivePolys, interpPolyline)
            }.value

            guard !Task.isCancelled, let self, self.routeShape != nil else { return }

            // Bounce results back to MainActor (we're already there since
            // the outer Task inherits @MainActor from the enclosing class).
            self.cachedRoutePolylines = result.0
            self.cachedInactivePolylines = result.1
            self.cachedInterpolationPolyline = result.2
            // Rebuild directional split now that polylines are available.
            self.rebuildDirectionalSplit()
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

    // MARK: - Direction-Filtered Vehicles (Cached)

    /// Cached result of `filteredBusVehicles`. Invalidated when `busVehicles`,
    /// `selectedDirectionIndex`, or `selectedGroupedRoute` changes.
    @ObservationIgnored private var _filteredBusVehiclesCache: [BusVehicleResponse]?
    /// Cached result of `filteredTrainVehicles`. Invalidated on same triggers.
    @ObservationIgnored private var _filteredTrainVehiclesCache: [TrainVehicle]?

    /// Bus vehicles filtered to the currently selected direction.
    /// Uses a cache that's invalidated when inputs change, avoiding
    /// recomputation on every `@Observable` property access.
    var filteredBusVehicles: [BusVehicleResponse] {
        if let cached = _filteredBusVehiclesCache { return cached }
        let result = _computeFilteredBusVehicles()
        _filteredBusVehiclesCache = result
        return result
    }

    /// GTFS only defines `directionRef` 0/1, which breaks for routes with 3+ directions
    /// (branches, short-turns). Strategy:
    ///   1. Match by destination name against the selected direction's headsign/arrivals.
    ///   2. Fall back to `directionRef` == `selectedDirectionIndex` for simple 2-dir routes.
    ///   3. Show all vehicles if nothing matches (missing backend data).
    private func _computeFilteredBusVehicles() -> [BusVehicleResponse] {
        // No route selected → no vehicles on map
        guard selectedRouteId != nil else { return [] }
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

        // 3) No vehicles matched this direction — return empty rather than
        //    showing all vehicles (which leaks wrong-direction markers onto the map).
        return []
    }

    /// Train vehicles filtered to the currently selected direction.
    /// Uses a cache that's invalidated when inputs change.
    var filteredTrainVehicles: [TrainVehicle] {
        if let cached = _filteredTrainVehiclesCache { return cached }
        let result = _computeFilteredTrainVehicles()
        _filteredTrainVehiclesCache = result
        return result
    }

    /// Subway directions use "N"/"S" (or destination names); we match by
    /// checking the direction string of the arrivals in the selected group,
    /// and also map compass codes to ensure GTFS-RT "N"/"S" values match.
    private func _computeFilteredTrainVehicles() -> [TrainVehicle] {
        // No route selected → no vehicles on map
        guard selectedRouteId != nil else { return [] }
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
        let compassExpansions = DirectionConstants.compassExpansions
        let reverseCompass = DirectionConstants.reverseCompass
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
            // No trip/vehicle match found — return empty rather than showing
            // all vehicles (which leaks wrong-direction markers onto the map).
            return []
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
    typealias TrunkRouteLabel = MapSystemViewModel.TrunkRouteLabel
    typealias ConsolidatedStation = MapSystemViewModel.ConsolidatedStation

    // MARK: - System Map Forwarding (backward compatibility)

    /// Forwarding properties so existing views can still use `viewModel.flattenedSubwayPolylines`, etc.
    var flattenedSubwayPolylines: [MapSystemViewModel.FlattenedMapPolyline] {
        mapSystem.flattenedSubwayPolylines
    }
    var flattenedCommuterRailPolylines: [MapSystemViewModel.FlattenedMapPolyline] {
        mapSystem.flattenedCommuterRailPolylines
    }
    var trunkRouteLabels: [MapSystemViewModel.TrunkRouteLabel] {
        mapSystem.trunkRouteLabels
    }
    var cachedStations: [MapSystemViewModel.CachedSubwayStation] {
        mapSystem.cachedStations
    }
    var consolidatedStations: [MapSystemViewModel.ConsolidatedStation] {
        mapSystem.consolidatedStations
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

    /// Whether ANY route is currently being tracked (regardless of which one).
    var isTrackingAny: Bool { currentTrackedRoute != nil }

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
    ///
    /// Checks **direction-filtered** vehicles first so the zoom only
    /// targets markers actually visible on the map.  Falls back to the
    /// full vehicle index for edge cases (e.g. vehicle just switched
    /// direction and hasn't been re-filtered yet).
    func coordinateForTappedVehicle(_ vehicleId: String) -> CLLocationCoordinate2D? {
        // Check direction-filtered bus vehicles first (visible markers)
        if let bus = filteredBusVehicles.first(where: { $0.vehicleId == vehicleId }) {
            return CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
        }
        // Check direction-filtered train vehicles
        if let train = filteredTrainVehicles.first(where: { $0.tripId == vehicleId || $0.id == vehicleId }) {
            return CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
        }
        // Fallback: full index (vehicle may not be filtered yet after a refresh)
        if let bus = _busVehicleIndex[vehicleId] {
            return CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
        }
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

    // MARK: - Session Cache (Two-Phase Loading)

    /// Loads cached transit data from the previous session so route cards
    /// appear instantly on cold launch (~5ms disk read) instead of showing
    /// skeleton placeholders for 5+ seconds while the network fetch runs.
    ///
    /// Call this **before** the first `refresh()` in `onAppearSetup()`.
    /// When cache exists:
    ///   - `groupedTransit` is populated immediately → skeletons never show
    ///   - `hasLoadedOnce = true` → subsequent `refresh()` runs silently
    ///   - `isRefreshing = true` → UI shows a subtle "Updating…" indicator
    ///
    /// The v2 cache envelope stores the GPS location where data was saved.
    /// If the user's current location is significantly different (> 400m),
    /// the cache is still shown immediately but the ``isRefreshing`` flag
    /// makes the "Updating…" indicator more prominent, and the return
    /// value signals the caller to force-refresh without delay.
    ///
    /// - Returns: `true` when cached data was loaded; `false` otherwise.
    @discardableResult
    func loadSessionCache(cachedLocation: CLLocation? = nil) -> Bool {
        guard !hasLoadedOnce else { return false }
        guard let result = TransitSessionCache.load(near: cachedLocation),
              !result.groups.isEmpty else {
            AppLogger.shared.log(
                "CACHE",
                message: "📭 No session cache — showing skeletons for first load"
            )
            return false
        }

        groupedTransit = result.groups

        // Seed the GPS reference so the first render after cache load
        // can sort routes by distance instead of falling back to
        // "all in Near You" (referenceLocation was nil without this).
        if let cachedLocation {
            lastKnownUserLocation = cachedLocation
        }

        // Populate flat transit array for fallback code paths
        var seenIDs = Set<String>()
        nearbyTransit = result.groups
            .flatMap(\.directions)
            .flatMap(\.arrivals)
            .filter { seenIDs.insert($0.id).inserted }

        hasLoadedOnce = true
        isRefreshing = true
        // Set a recent refresh date so `canSkipRefresh` blocks the
        // duplicate refresh that `handleScenePhaseChange(.active)` would
        // otherwise fire (it sees hasLoadedOnce=true and calls refresh).
        // The forced refresh from onAppearSetup still runs because it
        // uses force=true which bypasses canSkipRefresh.
        lastRefreshDate = Date()

        // Signal ContentView that critical-path data is available so
        // performFullSync() can fire immediately instead of waiting.
        TransitDataReadyFlag.markReady()
        NotificationCenter.default.post(name: .transitDataLoaded, object: nil)

        if result.isLocationStale {
            let distStr = result.distanceFromCurrent.map { "\(Int($0))m away" } ?? "unknown distance"
            AppLogger.shared.log(
                "CACHE",
                message: "⚠️ Loaded \(result.groups.count) cached groups but location is stale (\(distStr), \(Int(result.age))s old) — force refresh needed"
            )
        } else {
            AppLogger.shared.log(
                "CACHE",
                message: "📦 Loaded \(result.groups.count) cached route groups (\(Int(result.age))s old, same area) — skipping skeletons"
            )
        }
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

        // Guard: if a refresh is already in-flight, don't stack another.
        // The timer fires every 20s but a cold-start fetch can take 30-60s.
        // Without this guard, each timer tick spawns a new refresh() call
        // that never gets blocked by canSkipRefresh (hasLoadedOnce is still
        // false), creating a pile-up of coalesced-but-redundant work.
        if _refreshInFlight && !force {
            AppLogger.shared.log("REFRESH", message: "⏭️ Skipped — refresh already in flight")
            return false
        }

        // Skip if data is still fresh and user hasn't moved far.
        // force=true bypasses this (used by pull-to-refresh / mode switch).
        if !force && canSkipRefresh(for: loc) {
            AppLogger.shared.log("REFRESH", message: "⏭️ Skipped — data still fresh")
            isRefreshing = false
            return false
        }

        _refreshInFlight = true
        defer { _refreshInFlight = false }

        AppLogger.shared.log(
            "REFRESH",
            message: "🔄 Running \(force ? "(forced)" : "") mode=\(selectedMode)"
        )

        // If the user has moved significantly since the last fetch,
        // expire grace counters so stale routes from the old position
        // are evicted on the very next merge.
        if let loc, let lastLoc = lastRefreshLocation {
            let moved = loc.distance(from: lastLoc)
            if moved >= AppSettings.shared.significantMovementMeters {
                expireAllGraceCounters()
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
        let wasFirstLoad = !hasLoadedOnce
        hasLoadedOnce = true
        isLoading = false
        isRefreshing = false

        // Signal ContentView that critical-path data has landed so it can
        // kick off the lower-priority performFullSync() immediately.
        if wasFirstLoad {
            TransitDataReadyFlag.markReady()
            NotificationCenter.default.post(name: .transitDataLoaded, object: nil)
        }
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
        // New location context — expire grace so stale routes from the
        // previous location are evicted on the next merge.
        expireAllGraceCounters()
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
        expireAllGraceCounters()
        goMode.walkingRoute = nil
        nearestStopCoordinate = nil
        isStopManuallySelected = false
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
        if let userLocation { self.lastKnownUserLocation = userLocation }
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
        isStopManuallySelected = false
        busVehicles = []
        trainVehicles = []
        cachedTrainArrivals = []
        routeShape = nil
        busSchedule = nil

        selectedRouteId = group.routeId
        let loadingRouteId: String = group.routeId   // capture for staleness checks after await

        if group.isBus {
            // Fire schedule fetch in parallel — don't wait for shape/vehicles.
            // The schedule is independent data from OBA and can take several
            // seconds due to multiple serial OBA HTTP calls on the backend.
            Task { [weak self] in
                guard let self else { return }
                await self.fetchBusScheduleIfNeeded(expectedRouteId: loadingRouteId)
            }

            // Check shape cache first — avoids network call on re-select
            let cachedShape: RouteShapeResponse? = getCachedRouteShape(for: group.routeId)

            // Fetch shape + vehicles truly in parallel and process each
            // result the instant it arrives (no sequential bottleneck).
            // Using parallel Tasks instead of withTaskGroup to avoid
            // `sending` closure warnings with @MainActor-isolated self.
            let vehicleTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let vehicles = try await TrackAPI.fetchBusVehicles(routeID: loadingRouteId)
                    guard self.selectedRouteId == loadingRouteId else { return }
                    self.busVehicles = vehicles
                    self._targetBusGPS = Dictionary(
                        vehicles.map { ($0.vehicleId, $0) },
                        uniquingKeysWith: { $1 }
                    )
                    for v in vehicles {
                        self.previousBusPositions[v.vehicleId] = BusSnapshot(
                            lat: v.lat, lon: v.lon, timestamp: Date()
                        )
                    }
                    self.lastBusUpdateTime = Date()
                } catch {
                    AppLogger.shared.logError("fetchBusVehicles(\(loadingRouteId))", error: error)
                }
            }

            let shapeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let loadedShape: RouteShapeResponse
                    if let cached = cachedShape {
                        loadedShape = cached
                        AppLogger.shared.log("SHAPE_CACHE", message: "HIT \(loadingRouteId)")
                    } else {
                        loadedShape = try await TrackAPI.fetchRouteShape(routeID: loadingRouteId)
                        self.cacheRouteShape(loadedShape, for: loadingRouteId)
                    }
                    guard self.selectedRouteId == loadingRouteId else { return }
                    self.routeShape = loadedShape
                    let decoded: [[CLLocationCoordinate2D]] = loadedShape.decodedPolylines
                    let totalPoints: Int = decoded.reduce(0) { $0 + $1.count }
                    AppLogger.shared.log(
                        "BUS_SHAPE",
                        message:
                            "Loaded shape for \(loadingRouteId): \(loadedShape.polylines.count) polylines (\(totalPoints) total points), \(loadedShape.stops.count) stops"
                    )
                    self.enrichGroupWithShapeDirections(loadedShape)
                } catch {
                    AppLogger.shared.logError("fetchRouteShape(\(loadingRouteId))", error: error)
                }
            }
            _ = await vehicleTask.value
            _ = await shapeTask.value
            // Polling handled by HomeView.onChange(of: selectedRouteId)
        } else if group.isLIRR {
            // LIRR: fetch the branch-specific polyline + live arrivals
            do {
                let cachedLIRRShape: RouteShapeResponse? = getCachedRouteShape(for: group.routeId)
                async let arrivalsTask = TrackAPI.fetchLIRRArrivals()

                let loadedShape: RouteShapeResponse
                if let cached = cachedLIRRShape {
                    loadedShape = cached
                    AppLogger.shared.log("SHAPE_CACHE", message: "HIT \(group.routeId)")
                } else {
                    loadedShape = try await TrackAPI.fetchLIRRShape(routeID: group.routeId)
                    cacheRouteShape(loadedShape, for: group.routeId)
                }
                guard selectedRouteId == loadingRouteId else { return }
                routeShape = loadedShape
                populateStopsFromArrivals(group: group)
                AppLogger.shared.log(
                    "LIRR_SHAPE",
                    message: "Loaded shape for \(group.routeId) (\(group.displayName))")
                if let shape = routeShape { enrichGroupWithShapeDirections(shape) }

                // Filter arrivals to this specific branch and interpolate
                let allArrivals = try await arrivalsTask
                guard selectedRouteId == loadingRouteId else { return }
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
                let cachedMNRShape: RouteShapeResponse? = getCachedRouteShape(for: group.routeId)
                async let arrivalsTask = TrackAPI.fetchMNRArrivals()

                let loadedShape: RouteShapeResponse
                if let cached = cachedMNRShape {
                    loadedShape = cached
                    AppLogger.shared.log("SHAPE_CACHE", message: "HIT \(group.routeId)")
                } else {
                    loadedShape = try await TrackAPI.fetchMNRShape(routeID: group.routeId)
                    cacheRouteShape(loadedShape, for: group.routeId)
                }
                guard selectedRouteId == loadingRouteId else { return }
                routeShape = loadedShape
                populateStopsFromArrivals(group: group)
                AppLogger.shared.log(
                    "MNR_SHAPE", message: "Loaded shape for \(group.routeId) (\(group.displayName))"
                )
                if let shape = routeShape { enrichGroupWithShapeDirections(shape) }

                // Filter arrivals to this specific line and interpolate
                let allArrivals = try await arrivalsTask
                guard selectedRouteId == loadingRouteId else { return }
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
                let cachedSubwayShape = getCachedRouteShape(for: group.displayName)
                async let arrivalsTask = TrackAPI.fetchSubwayArrivals(lineID: group.displayName)

                let loadedShape: RouteShapeResponse
                if let cached = cachedSubwayShape {
                    loadedShape = cached
                    AppLogger.shared.log("SHAPE_CACHE", message: "HIT \(group.displayName)")
                } else {
                    loadedShape = try await TrackAPI.fetchSubwayShape(routeID: group.displayName)
                    cacheRouteShape(loadedShape, for: group.displayName)
                }
                guard selectedRouteId == loadingRouteId else { return }
                routeShape = loadedShape
                let arrivals = try await arrivalsTask
                guard selectedRouteId == loadingRouteId else { return }
                updateTrainPositions(arrivals: arrivals)
                if let shape = routeShape { enrichGroupWithShapeDirections(shape) }

            } catch {
                AppLogger.shared.logError("fetchSubwayData(\(group.displayName))", error: error)
            }
        }

        // Find nearest stop and calculate walking route.
        // Use referenceLocation — single source of truth for pin vs GPS.
        //
        // CRITICAL: Re-read `selectedGroupedRoute` here — enrichGroupWithShapeDirections
        // may have reordered directions and updated `selectedDirectionIndex`.  The original
        // `group` parameter still has the PRE-enrichment order, so using it with the
        // POST-enrichment index yields the WRONG direction (e.g. a direction with 0
        // arrivals instead of the one with 7).  This caused the arrival-based fallback
        // to fail and select a shape stop with no matching arrivals.
        let currentGroup = selectedGroupedRoute ?? group
        let refLocation = referenceLocation
        let fallbackStops = routeShape?.stopsForDirection(index: selectedDirectionIndex) ?? []

        var targetStopCoord: CLLocationCoordinate2D?
        var targetStopId: String?

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
                // Verify the shape's nearest stop has at least one live
                // arrival.  SIRI only reports predictions at monitored
                // timepoint stops — the shape's nearest stop may NOT be
                // one of them.  When that happens, the polyline filter in
                // RouteDetailSheet treats approaching buses as "passed"
                // and hides the very bus the home row shows as "arriving".
                let activeDir = currentGroup.directions.indices.contains(selectedDirectionIndex)
                    ? currentGroup.directions[selectedDirectionIndex]
                    : currentGroup.directions.first
                let bareShapeId = stripMTAStopPrefix(closest.id)
                let arrivalHasStop = activeDir?.liveArrivals.contains(where: { arrival in
                    guard let sid = arrival.stopId else { return false }
                    return sid == closest.id
                        || stripMTAStopPrefix(sid) == bareShapeId
                        || arrival.stopName == closest.name
                }) ?? false

                if arrivalHasStop {
                    targetStopCoord = CLLocationCoordinate2D(latitude: closest.lat, longitude: closest.lon)
                    targetStopId = closest.id

                    #if DEBUG
                    print("[WALK DIST] \(currentGroup.routeId) (\(currentGroup.mode))  source=routeShape (\(fallbackStops.count) stops)  nearest stop='\(closest.name)' id=\(closest.id)  (\(String(format: "%.5f", closest.lat)),\(String(format: "%.5f", closest.lon)))  straight-line=\(Int(minDistance))m / \(String(format: "%.2f", minDistance / 1609.34))mi  ← polyline targets this stop")
                    #endif
                } else {
                    // Shape stop has no arrivals — SIRI only reports
                    // predictions at monitored timepoint stops, so the
                    // physically nearest stop may not have an ETA.
                    //
                    // Always use the nearest shape stop for walking
                    // distance (the user walks to the closest physical
                    // stop regardless of where the next prediction is).
                    // But set selectedStopId to the nearest *arrival*
                    // stop so chip filtering shows the correct ETAs.
                    targetStopCoord = CLLocationCoordinate2D(latitude: closest.lat, longitude: closest.lon)
                    targetStopId = closest.id  // default to shape stop

                    if let activeDir, let userRef = refLocation {
                        var bestArrival: NearbyTransitResponse?
                        var bestDist: CLLocationDistance = .greatestFiniteMagnitude
                        for arrival in activeDir.liveArrivals {
                            guard let lat = arrival.stopLat, let lon = arrival.stopLon else { continue }
                            let dist = userRef.distance(from: CLLocation(latitude: lat, longitude: lon))
                            if dist < bestDist { bestDist = dist; bestArrival = arrival }
                        }
                        if let best = bestArrival {
                            // Use arrival stop ID for chip matching only —
                            // walking coordinate stays at the shape stop.
                            targetStopId = best.stopId
                            #if DEBUG
                            print("[WALK DIST] \(currentGroup.routeId) (\(currentGroup.mode))  source=routeShape (nearest shape stop '\(closest.name)' has no arrivals; chips→'\(best.stopName)')  nearest stop='\(closest.name)' id=\(closest.id)  (\(String(format: "%.5f", closest.lat)),\(String(format: "%.5f", closest.lon)))  straight-line=\(Int(minDistance))m / \(String(format: "%.2f", minDistance / 1609.34))mi  ← polyline targets this stop")
                            #endif
                        } else {
                            #if DEBUG
                            print("[WALK DIST] \(currentGroup.routeId) (\(currentGroup.mode))  source=routeShape (\(fallbackStops.count) stops)  nearest stop='\(closest.name)' id=\(closest.id)  (\(String(format: "%.5f", closest.lat)),\(String(format: "%.5f", closest.lon)))  straight-line=\(Int(minDistance))m / \(String(format: "%.2f", minDistance / 1609.34))mi  ← polyline targets this stop (no arrival match)")
                            #endif
                        }
                    }
                }
            }
        }
        
        // Fallback: zoom to the first arrival's stop coordinates when
        // route shape data is unavailable or user location is missing.
        if targetStopCoord == nil {
            let activeDirection = currentGroup.directions.indices.contains(selectedDirectionIndex) ? currentGroup.directions[selectedDirectionIndex] : currentGroup.directions.first
            if let first = activeDirection?.arrivals.first,
                let lat = first.stopLat, let lon = first.stopLon
            {
                targetStopCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                targetStopId = first.stopId

                #if DEBUG
                if let userLoc = refLocation {
                    let fallbackDist = userLoc.distance(from: CLLocation(latitude: lat, longitude: lon))
                    print("[WALK DIST] \(currentGroup.routeId) (\(currentGroup.mode))  source=arrivalFallback (no shape stops)  stop='\(first.stopName)'  (\(String(format: "%.5f", lat)),\(String(format: "%.5f", lon)))  straight-line=\(Int(fallbackDist))m / \(String(format: "%.2f", fallbackDist / 1609.34))mi  ← polyline targets this stop")
                }
                #endif
            }
        }

        if let targetCoord = targetStopCoord {
            nearestStopCoordinate = targetCoord
            selectedStopId = targetStopId
            
            if let userLoc = refLocation {
                let from = userLoc.coordinate
                Task { await fetchWalkingRoute(from: from, to: targetCoord) }
            }
        }

        // Schedule fetch already launched in parallel above for bus routes.
        // No sequential call needed here.

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

        // Guard against race conditions: if the user navigated to a different
        // route while the shape was loading, the shape's directions belong to
        // the old route.  Applying them would contaminate the new route's
        // direction picker (e.g. subway headsigns leaking into bus directions).
        //
        // Use normalizeMTARouteToken so SBS variants match:
        //   shape "MTA NYCT_M34+"  →  "M34"
        //   group "M34-SBS"        →  "M34"
        let shapeRoute = normalizeMTARouteToken(shape.routeId)
        let groupRoute = normalizeMTARouteToken(group.routeId)
        // For subway, the shape routeId is the line letter/number (e.g. "7")
        // while the group displayName carries the same value.
        let groupDisplay = normalizeMTARouteToken(group.displayName)
        guard shapeRoute == groupRoute || shapeRoute == groupDisplay else {
            AppLogger.shared.log(
                "ROUTE_DETAIL",
                message:
                    "SKIP enrichment: shape route '\(shape.routeId)' does not match selected route '\(group.routeId)' (display: \(group.displayName))"
            )
            return
        }

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
                    // or its direction key is a generic backfill label.
                    // Only treat single-char codes ("N","S") and explicit backfill
                    // labels as generic.  Two-char compass codes like "NW","SE" are
                    // meaningful direction labels and must NOT be replaced — doing so
                    // caused cross-route headsign contamination (e.g. subway headsigns
                    // leaking into bus routes whose shape API returned wrong headsigns).
                    let isGeneric = ["opposite", "n/a", "loop"].contains(dir.direction.lowercased())
                        || dir.direction.count <= 1  // single-char like "N", "S"
                    return dir.liveArrivals.isEmpty && isGeneric
                }

                if let pidx = placeholderIdx {
                    // Replace the placeholder with a proper direction entry
                    // carrying the shape's headsign but keeping any arrivals.
                    // Guard against cross-mode contamination: reject headsigns
                    // that reference a different transit mode (e.g. "7 TRAIN"
                    // from OBA data leaking into a bus route).
                    let existing = group.directions[pidx]
                    let hsLower = shapeDir.headsign.lowercased()
                    let isCrossMode = (group.isBus && (hsLower.contains("train") || hsLower.contains("subway")))
                        || (group.isCommuterRail && hsLower.contains("bus"))
                    let directionString =
                        shapeDir.headsign.isEmpty || isCrossMode
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

        // Append any existing directions that didn't match any shape direction,
        // BUT skip generic compass-code placeholders ("N", "S", "SE", "W", etc.)
        // that have no live arrivals. These are backfilled by the nearby API
        // and create confusing extra tabs (e.g. Q10 showing "S", "SE", "W" tabs).
        let compassCodes: Set<String> = ["n","s","e","w","ne","nw","se","sw"]
        for (idx, dir) in group.directions.enumerated() where !usedExistingIndices.contains(idx) {
            let isCompass = compassCodes.contains(dir.direction.lowercased())
            let hasLive = !dir.liveArrivals.isEmpty
            if isCompass && !hasLive {
                #if DEBUG
                print("[ENRICH] Dropping empty compass direction '\(dir.direction)' from \(group.routeId)")
                #endif
                continue
            }
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

            // ── Resolve the correct direction index BEFORE publishing the
            //    new group.  Setting selectedDirectionIndex after
            //    selectedGroupedRoute would mutate a @Binding while SwiftUI
            //    is already re-evaluating the view for the group change,
            //    triggering "precondition failure: setting value during
            //    update" (AttributeGraph crash).
            //
            //    Also skip the assignment entirely when the value is
            //    unchanged to avoid redundant DIR_CHANGE / flip-flopping.
            if let key = previousSelectedDirectionKey,
               let resolvedIndex = updatedGroup.directions.firstIndex(where: {
                   normalizedDirectionKey($0) == key
               }) {
                if resolvedIndex != selectedDirectionIndex {
                    let previousIndex = selectedDirectionIndex
                    selectedDirectionIndex = resolvedIndex

                    #if DEBUG
                    AppLogger.shared.log(
                        "DIR_PREF",
                        message:
                            "RESTORE route=\(updatedGroup.routeId) mode=\(updatedGroup.mode) oldIdx=\(previousIndex) newIdx=\(resolvedIndex) oldKey=\(key) newDir=\(updatedGroup.directions[resolvedIndex].direction)"
                    )
                    #endif
                }
            } else {
                let clamped = max(
                    0,
                    min(selectedDirectionIndex, max(0, updatedGroup.directions.count - 1))
                )
                if clamped != selectedDirectionIndex {
                    let previousIndex = selectedDirectionIndex
                    selectedDirectionIndex = clamped

                    #if DEBUG
                    AppLogger.shared.log(
                        "DIR_PREF",
                        message:
                            "RESTORE_FALLBACK route=\(updatedGroup.routeId) mode=\(updatedGroup.mode) oldIdx=\(previousIndex) newIdx=\(clamped) reason=no-key-match"
                    )
                    #endif
                }
            }

            // Now publish the group — view re-render will see the already-
            // correct selectedDirectionIndex.
            selectedGroupedRoute = updatedGroup

            AppLogger.shared.log(
                "ROUTE_DETAIL",
                message:
                    "Enriched \(group.displayName) from \(existingCount) → \(orderedDirections.count) directions (ordered by shape direction_id)"
            )
        }
    }

    /// Returns a camera position centered on the first arrival's stop.
    func cameraPositionForRoute(_ group: GroupedNearbyTransitResponse) -> TrackCameraPosition {
        if let first = group.directions.first?.arrivals.first,
            let lat = first.stopLat, let lon = first.stopLon
        {
            return MapCameraPresets.center(
                on: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                is3D: false
            )
        }
        return .automatic
    }

    /// Computes a camera position that frames the user's walking path
    /// to the nearest stop. The route polyline is already drawn on the map —
    /// users can pan to explore it — so we zoom to what matters most:
    /// seeing yourself and how to get to the station/stop.
    ///
    /// When `sheetFraction > 0` the returned camera already accounts for
    /// the bottom sheet — callers should **not** wrap the result in
    /// `aboveSheet()` to avoid double-compensation.
    ///
    /// Delegates to `MapCameraPresets.fitWalkingPathAboveSheet` when a
    /// sheet is visible, or `fitWalkingPath` otherwise.
    func cameraPositionFittingRoute(
        userLocation: CLLocation?,
        is3D: Bool,
        sheetFraction: Double = 0
    ) -> TrackCameraPosition? {
        guard routeShape != nil else { return nil }

        let refLocation = effectiveLocation(userLocation: userLocation)

        // ── Optimal: actual walking route polyline (if fetched) ─────
        if let route = walkingRoute {
            // Extract bounding box from MKRoute polyline
            let rect = route.polyline.boundingMapRect
            let latSpan = MKMapPoint(x: rect.midX, y: rect.minY)
                .distance(to: MKMapPoint(x: rect.midX, y: rect.maxY))
            let lonSpan = MKMapPoint(x: rect.minX, y: rect.midY)
                .distance(to: MKMapPoint(x: rect.maxX, y: rect.midY))
            let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate

            let routeCamera = MapCameraPresets.fitWalkingRouteAboveSheet(
                latSpanMeters: latSpan,
                lonSpanMeters: lonSpan,
                center: center,
                is3D: is3D,
                sheetFraction: sheetFraction
            )
            // The MKRoute bounding box can be very tight for short walks.
            // Enforce a minimum distance that guarantees both the user's
            // GPS dot and the nearest stop are visible above the sheet.
            if let nearestCoord = nearestStopCoordinate,
               let userLoc = refLocation,
               let routeCam = routeCamera.camera {
                let endpointsFit = MapCameraPresets.fitTwoPoints(
                    from: userLoc.coordinate,
                    to: nearestCoord,
                    is3D: is3D
                )
                if let endpointsCam = endpointsFit.camera,
                   routeCam.distance < endpointsCam.distance {
                    // Keep the walking route's center but use the
                    // more generous distance so both points fit.
                    return .camera(TrackCamera(
                        centerCoordinate: routeCam.centerCoordinate,
                        distance: endpointsCam.distance,
                        heading: routeCam.heading,
                        pitch: routeCam.pitch
                    ))
                }
            }
            return routeCamera
        }

        // ── Primary: fit user → nearest stop (straight-line fallback) ──────────
        if let nearestCoord = nearestStopCoordinate, let userLoc = refLocation {
            return MapCameraPresets.fitWalkingPathAboveSheet(
                user: userLoc.coordinate,
                stop: nearestCoord,
                is3D: is3D,
                sheetFraction: sheetFraction
            )
        }

        // ── Secondary: nearest stop known but no user location ───────
        if let nearestCoord = nearestStopCoordinate {
            let base = MapCameraPresets.center(
                on: nearestCoord,
                distance: 1200,
                is3D: is3D
            )
            return sheetFraction > 0.05
                ? MapCameraPresets.sheetCompensated(base, sheetFraction: sheetFraction)
                : base
        }

        // ── Fallback: center on user at a comfortable zoom ──────────
        if let userLoc = refLocation {
            return MapCameraPresets.focusVehicle(at: userLoc.coordinate, is3D: is3D)
        }

        return nil
    }
}
