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
    private var lastRefreshLocation: CLLocation?
    /// Tracks which modes have had their dedicated data arrays populated
    /// via a mode-specific API call.  Prevents tab switches from relying
    /// solely on `groupedTransit` fallback data that can later vanish.
    private var modesEverRefreshed: Set<TransportMode> = []

    /// The currently tracked route for the widget, loaded from UserDefaults.
    var currentTrackedRoute: TrackedRoute? = nil

    /// When `true`, the app should navigate to the currently tracked route's
    /// detail page once grouped transit data has loaded. Set by deep-link
    /// handling (e.g. tapping a Live Activity).
    var pendingDeepLink = false

    // MARK: - Search

    /// User-entered search text for filtering transit results.
    var searchText = ""

    // MARK: - Search Helpers

    /// Checks whether a `GroupedNearbyTransitResponse` matches the given query.
    /// Searches display name, route ID, directions, arrival stop names,
    /// destination names, AND all stations served by the route.
    private func groupMatchesQuery(
        _ group: GroupedNearbyTransitResponse, query: String, stationRoutes: Set<String>
    ) -> Bool {
        // Match by route display name or ID
        group.displayName.lowercased().contains(query)
            || group.routeId.lowercased().contains(query)
            // Match by direction, stop name, or destination name
            || group.directions.contains { direction in
                direction.direction.lowercased().contains(query)
                    || direction.arrivals.contains {
                        $0.stopName.lowercased().contains(query)
                            || ($0.destination?.lowercased().contains(query) ?? false)
                    }
            }
            // Match if this route serves any station matching the query
            || stationRoutes.contains(group.displayName)
            || stationRoutes.contains(group.routeId)
    }

    /// Returns the set of route names that serve stations matching the query.
    /// Computed once per search to avoid O(n²) lookups.
    private func stationRoutesForQuery(_ query: String) -> Set<String> {
        Set(
            cachedStations
                .filter { $0.name.lowercased().contains(query) }
                .flatMap { $0.routes }
        )
    }

    /// Grouped transit results filtered by the current search query.
    /// Returns all results when the search text is empty.
    /// Searches route names, directions, current arrival stops, destinations,
    /// AND all stations served by the route.
    var filteredGroupedTransit: [GroupedNearbyTransitResponse] {
        guard !searchText.isEmpty else { return groupedTransit }
        let query = searchText.lowercased()
        let stationRoutes = stationRoutesForQuery(query)
        return groupedTransit.filter {
            groupMatchesQuery($0, query: query, stationRoutes: stationRoutes)
        }
    }

    /// LIRR arrivals filtered by search text.
    /// Searches route ID, station ID, station name, direction, and destination.
    var filteredLIRRArrivals: [TrainArrival] {
        guard !searchText.isEmpty else { return lirrArrivals }
        let query = searchText.lowercased()
        return lirrArrivals.filter { arrival in
            arrival.routeID.lowercased().contains(query)
                || arrival.stationID.lowercased().contains(query)
                || arrival.stationName.lowercased().contains(query)
                || arrival.direction.lowercased().contains(query)
                || (arrival.destination?.lowercased().contains(query) ?? false)
        }
    }

    /// Metro-North arrivals filtered by search text.
    /// Searches route ID, station ID, station name, direction, and destination.
    var filteredMNRArrivals: [TrainArrival] {
        guard !searchText.isEmpty else { return mnrArrivals }
        let query = searchText.lowercased()
        return mnrArrivals.filter { arrival in
            arrival.routeID.lowercased().contains(query)
                || arrival.stationID.lowercased().contains(query)
                || arrival.stationName.lowercased().contains(query)
                || arrival.direction.lowercased().contains(query)
                || (arrival.destination?.lowercased().contains(query) ?? false)
        }
    }

    /// Subway arrivals filtered by search text.
    var filteredSubwayArrivals: [TrainArrival] {
        guard !searchText.isEmpty else { return upcomingArrivals }
        let query = searchText.lowercased()
        return upcomingArrivals.filter { arrival in
            arrival.routeID.lowercased().contains(query)
                || arrival.stationID.lowercased().contains(query)
                || arrival.stationName.lowercased().contains(query)
                || arrival.direction.lowercased().contains(query)
                || (arrival.destination?.lowercased().contains(query) ?? false)
        }
    }

    /// Bus arrivals filtered by search text.
    /// Searches both the full routeId, stopId, destination, and the status text.
    var filteredBusArrivals: [BusArrival] {
        guard !searchText.isEmpty else { return busArrivals }
        let query = searchText.lowercased()
        return busArrivals.filter { arrival in
            arrival.routeId.lowercased().contains(query)
                || arrival.stopId.lowercased().contains(query)
                || arrival.statusText.lowercased().contains(query)
                || (arrival.destinationName?.lowercased().contains(query) ?? false)
        }
    }

    /// Bus stops filtered by search text.
    var filteredBusStops: [BusStop] {
        guard !searchText.isEmpty else { return nearbyBusStops }
        let query = searchText.lowercased()
        return nearbyBusStops.filter { stop in
            stop.name.lowercased().contains(query)
                || stop.id.lowercased().contains(query)
        }
    }

    /// Grouped bus arrivals filtered by search text (from the nearby/grouped API).
    var filteredNearbyGroupedBusArrivals: [GroupedNearbyTransitResponse] {
        let source = nearbyGroupedBusArrivals.isEmpty
            ? groupedTransit.filter { $0.mode == "bus" }
            : nearbyGroupedBusArrivals
        guard !searchText.isEmpty else { return source }
        let query = searchText.lowercased()
        let stationRoutes = stationRoutesForQuery(query)
        return source.filter {
            groupMatchesQuery($0, query: query, stationRoutes: stationRoutes)
        }
    }

    /// Grouped subway arrivals filtered by search text (from the nearby/grouped API).
    var filteredNearbyGroupedSubwayArrivals: [GroupedNearbyTransitResponse] {
        let source = nearbyGroupedSubwayArrivals.isEmpty
            ? groupedTransit.filter { $0.mode == "subway" }
            : nearbyGroupedSubwayArrivals
        guard !searchText.isEmpty else { return source }
        let query = searchText.lowercased()
        let stationRoutes = stationRoutesForQuery(query)
        return source.filter {
            groupMatchesQuery($0, query: query, stationRoutes: stationRoutes)
        }
    }

    /// Grouped LIRR arrivals filtered by search text (from nearby/grouped API).
    var filteredNearbyGroupedLIRRArrivals: [GroupedNearbyTransitResponse] {
        let source = nearbyGroupedLIRRArrivals.isEmpty
            ? groupedTransit.filter { $0.mode == "lirr" }
            : nearbyGroupedLIRRArrivals
        guard !searchText.isEmpty else { return source }
        let query = searchText.lowercased()
        let stationRoutes = stationRoutesForQuery(query)
        return source.filter {
            groupMatchesQuery($0, query: query, stationRoutes: stationRoutes)
        }
    }

    /// Grouped Metro-North arrivals filtered by search text (from nearby/grouped API).
    var filteredNearbyGroupedMNRArrivals: [GroupedNearbyTransitResponse] {
        let source = nearbyGroupedMNRArrivals.isEmpty
            ? groupedTransit.filter { $0.mode == "mnr" }
            : nearbyGroupedMNRArrivals
        guard !searchText.isEmpty else { return source }
        let query = searchText.lowercased()
        let stationRoutes = stationRoutesForQuery(query)
        return source.filter {
            groupMatchesQuery($0, query: query, stationRoutes: stationRoutes)
        }
    }

    /// Returns whether the selected mode already has renderable cached data
    /// from a **dedicated** API call (not just fallback from Nearby's `groupedTransit`).
    /// This prevents modes from thinking they have data when they're actually
    /// depending on Nearby's transient fallback which can later be evicted.
    func hasCachedData(for mode: TransportMode) -> Bool {
        // A mode only counts as "cached" if it has been explicitly fetched
        // at least once.  Otherwise the fallback from groupedTransit might
        // give a false positive and the dedicated array stays empty forever.
        guard modesEverRefreshed.contains(mode) else { return false }
        switch mode {
        case .nearby:
            return !groupedTransit.isEmpty || !nearbyTransit.isEmpty
        case .subway:
            return !nearbyGroupedSubwayArrivals.isEmpty
        case .bus:
            return !nearbyGroupedBusArrivals.isEmpty
        case .lirr:
            return !nearbyGroupedLIRRArrivals.isEmpty
        case .mnr:
            return !nearbyGroupedMNRArrivals.isEmpty
        }
    }

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
    private func groupTrainArrivals(_ arrivals: [TrainArrival], mode: String)
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
    private var graceMissCountBySource: [String: [String: Int]] = [:]

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
    var selectedDirectionIndex: Int = 0 {
        didSet {
            rebuildCachedPolylines()
            rebuildDirectionalSplit()
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
    var nearestStopCoordinate: CLLocationCoordinate2D? {
        didSet { rebuildDirectionalSplit() }
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
    var busVehicles: [BusVehicleResponse] = []

    var trainVehicles: [TrainVehicle] = []

    // Smooth bus interpolation state — stores the previous GPS snapshot
    // so we can glide between updates along the route polyline.
    /// Previous GPS positions keyed by vehicle ID for smooth interpolation.
    var previousBusPositions: [String: BusSnapshot] = [:]
    /// When the last bus GPS batch arrived (for elapsed-time calculation).
    var lastBusUpdateTime: Date = .distantPast

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

        cachedRoutePolylines =
            shouldFilter
            ? shape.polylinesForDirection(index: selectedDirectionIndex, name: selectedDirectionName)
            : shape.decodedPolylines

        // Build inactive polylines from all OTHER directions.
        // These get rendered at low opacity so branches/short-turns are visible.
        if shouldFilter && shape.directions.count > 1 {
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
                    let decoded = decodePolyline(encodedPoly)
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
        // Check bus vehicles
        if let bus = busVehicles.first(where: { $0.vehicleId == vehicleId }) {
            return CLLocationCoordinate2D(latitude: bus.lat, longitude: bus.lon)
        }
        // Check train vehicles (by tripId or id)
        if let train = trainVehicles.first(where: { $0.tripId == vehicleId || $0.id == vehicleId })
        {
            return CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
        }
        return nil
    }

    /// Finds the map coordinate for a tracked arrival.
    /// Looks up the live vehicle position first (bus by vehicleId, train by tripId);
    /// falls back to the arrival's stop lat/lon if no live vehicle is found.
    /// Works for all modes: subway, bus, LIRR, Metro-North.
    func coordinateForTrackedArrival(_ arrival: NearbyTransitResponse) -> CLLocationCoordinate2D? {
        // 1. Try to find a live bus vehicle by vehicleId
        if arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty {
            if let vehicle = busVehicles.first(where: { $0.vehicleId == vid }) {
                return CLLocationCoordinate2D(latitude: vehicle.lat, longitude: vehicle.lon)
            }
        }

        // 2. Try to find a live train vehicle by tripId
        if !arrival.isBus, let tripId = arrival.tripId, !tripId.isEmpty {
            if let train = trainVehicles.first(where: { $0.tripId == tripId }) {
                return CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
            }
        }

        // 3. Try to find a train vehicle by vehicleId
        if !arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty {
            if let train = trainVehicles.first(where: { $0.id == vid }) {
                return CLLocationCoordinate2D(latitude: train.lat, longitude: train.lon)
            }
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
    func isVehicleLiveOnMap(_ arrival: NearbyTransitResponse) -> Bool {
        if arrival.isBus, let vid = arrival.vehicleId, !vid.isEmpty {
            return filteredBusVehicles.contains(where: { $0.vehicleId == vid })
        }
        if !arrival.isBus {
            if let tripId = arrival.tripId, !tripId.isEmpty {
                if filteredTrainVehicles.contains(where: { $0.tripId == tripId }) { return true }
            }
            if let vid = arrival.vehicleId, !vid.isEmpty {
                if filteredTrainVehicles.contains(where: { $0.id == vid }) { return true }
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
            mode: arrival.mode
        )
    }

    // MARK: - GO Mode Forwarding (backward compatibility)

    var isGoModeActive: Bool { goMode.isGoModeActive }
    var goModeRouteName: String? { goMode.goModeRouteName }
    var goModeRouteColor: Color? { goMode.goModeRouteColor }
    var passedStopIds: Set<String> { goMode.passedStopIds }
    var transitEtaMinutes: Int? { goMode.transitEtaMinutes }
    var walkingRoute: MKRoute? { goMode.walkingRoute }

    private let repository = TransitRepository()

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

        switch selectedMode {
        case .nearby:
            await refreshNearbyTransit(location: loc, silent: isSilentRefresh)
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
    private func updateLiveActivityFromRefresh() {
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
                busVehicles = try await vehiclesTask
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
    private func enrichGroupWithShapeDirections(_ shape: RouteShapeResponse) {
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

    // MARK: - Route Selection and Refresh
    /// Selects a specific arrival (from flat list or search) and treats it as a route selection.
    func selectArrival(_ arrival: NearbyTransitResponse, userLocation: CLLocation?) async {
        // Find if this arrival already exists in our grouped list
        if let existingGroup = groupedTransit.first(where: { $0.routeId == arrival.routeId }) {
            let dirIndex =
                existingGroup.directions.firstIndex(where: { $0.direction == arrival.direction })
                ?? 0
            await selectGroupedRoute(
                existingGroup, directionIndex: dirIndex, userLocation: userLocation)
        } else {
            // Attempt to fetch fresh data for this route to get the full context (colors, directions, other arrivals)
            // If that fails or isn't implemented, we fall back to a minimal group.

            // Note: Currently we don't have a direct "fetch single route group" endpoint that aligns perfectly
            // with GroupedNearbyTransitResponse structure without fetching *all* nearby routes.
            // However, we can construct a better "mock" group if we had more info, or we could trigger a refresh.
            // For now, we use the minimal group to immediately show the user what they tapped,
            // but we ensure the route logic (shape, vehicles) is triggered by selectGroupedRoute.

            // Create a minimal group to satisfy the unified logic
            let minimalGroup = GroupedNearbyTransitResponse(
                routeId: arrival.routeId,
                displayName: arrival.displayName,
                mode: arrival.mode,
                colorHex: nil,
                directions: [
                    DirectionArrivalsResponse(
                        direction: arrival.direction,
                        arrivals: [arrival]
                    )
                ]
            )
            await selectGroupedRoute(minimalGroup, directionIndex: 0, userLocation: userLocation)
        }
    }

    /// Refreshes only the vehicle positions for the currently selected bus route.
    /// Stores the previous positions for smooth polyline-based interpolation.
    func refreshBusVehicles() async {
        guard let routeId = selectedRouteId,
            selectedGroupedRoute?.isBus == true
        else { return }
        do {
            let vehicles = try await TrackAPI.fetchBusVehicles(routeID: routeId)
            await MainActor.run {
                // Snapshot current positions before overwriting so that
                // updateBusSimulation() can interpolate between old → new.
                if self.busVehicles.isEmpty {
                    // First fetch: seed snapshots from the new data so
                    // interpolation can start on the very next GPS cycle
                    // instead of waiting for a second fetch.
                    for v in vehicles {
                        previousBusPositions[v.vehicleId] = BusSnapshot(
                            lat: v.lat, lon: v.lon, timestamp: Date()
                        )
                    }
                } else {
                    for v in self.busVehicles {
                        previousBusPositions[v.vehicleId] = BusSnapshot(
                            lat: v.lat, lon: v.lon, timestamp: self.lastBusUpdateTime
                        )
                    }
                }
                self.lastBusUpdateTime = Date()
                self.busVehicles = vehicles
            }
            // Sync the arrivals list with these fresh vehicle positions
            await syncBusArrivalsFromVehicles(vehicles)

        } catch {
            AppLogger.shared.logError("refreshBusVehicles(\(routeId))", error: error)
        }
    }

    /// Updates the selected route's arrival list using `onwardCalls` from live vehicles.
    /// This ensures the list stays perfectly in sync with the moving bus icons.
    private func syncBusArrivalsFromVehicles(_ vehicles: [BusVehicleResponse]) async {
        guard let currentGroup = selectedGroupedRoute else { return }

        func normalizeStopId(_ raw: String) -> String {
            let stripped = stripMTAStopPrefix(raw)
            guard stripped.count > 1, let last = stripped.last, last == "N" || last == "S" else {
                return stripped
            }
            let penultimate = stripped[stripped.index(before: stripped.index(before: stripped.endIndex))]
            if penultimate.isNumber || penultimate.isLowercase {
                return String(stripped.dropLast())
            }
            return stripped
        }

        // Build a mapping from numeric directionRef (0/1) to the existing
        // group direction key (e.g. "Inbound", "EAST NEW YORK", etc.).
        // The grouped API uses descriptive direction names while SIRI
        // vehicles use numeric directionRef 0/1. We need to bridge them
        // so arrivals land in the correct direction bucket.
        var dirRefToGroupDirection: [Int: String] = [:]
        for (idx, dir) in currentGroup.directions.enumerated() {
            // Most 2-direction routes: index 0 → directionRef 0, index 1 → directionRef 1
            dirRefToGroupDirection[idx] = dir.direction
        }
        // Also try destination-based matching for vehicles with destination info
        let directionDestinations: [String: Set<String>] = {
            var result: [String: Set<String>] = [:]
            for dir in currentGroup.directions {
                var dests = Set<String>()
                dests.insert(dir.direction.uppercased())
                for arrival in dir.arrivals {
                    if let dest = arrival.destination?.uppercased(), !dest.isEmpty {
                        dests.insert(dest)
                    }
                }
                if let label = dir.directionLabel?.uppercased(), !label.isEmpty {
                    dests.insert(label.replacingOccurrences(of: "→ ", with: ""))
                }
                result[dir.direction] = dests
            }
            return result
        }()

        // Build stop-id membership per direction from route shape.
        // This is the most reliable source for assigning arrivals to the
        // correct direction tab when destination/headsign text is ambiguous.
        let directionStopSets: [(dirKey: String, stopIds: Set<String>)] = {
            guard let shape = routeShape else { return [] }
            return currentGroup.directions.enumerated().map { index, dir in
                let ids = Set(
                    shape.stopsForDirection(index: index, name: dir.direction)
                        .map { normalizeStopId($0.id) }
                )
                return (dirKey: dir.direction, stopIds: ids)
            }
        }()

        // Flats list of all new arrivals from all vehicles, keyed to the
        // correct group direction string (not the raw numeric directionRef).
        var newArrivals: [NearbyTransitResponse] = []

        for vehicle in vehicles {
            guard let calls = vehicle.onwardCalls else { continue }

            for call in calls {
                // Resolve direction PER call (not per vehicle) so branching routes
                // don't mirror times across tabs.
                let resolvedDirection: String? = {
                    // 1) Stop-ID membership against route-shape direction stops
                    let sid = call.stopId
                    if !sid.isEmpty {
                        let normalized = normalizeStopId(sid)
                        let candidates = directionStopSets.filter { $0.stopIds.contains(normalized) }
                        if candidates.count == 1 {
                            return candidates[0].dirKey
                        }
                    }

                    // 2) Destination/headsign text matching
                    if let destName = (call.destinationName ?? vehicle.statusText)?.uppercased(), !destName.isEmpty {
                        for (dirKey, dests) in directionDestinations {
                            if dests.contains(where: { destName.contains($0) || $0.contains(destName) }) {
                                return dirKey
                            }
                        }
                    }

                    // 3) directionRef fallback for simple 2-direction mapping
                    if let ref = vehicle.directionRef, let mapped = dirRefToGroupDirection[ref] {
                        return mapped
                    }

                    // 4) Multi-direction routes: skip unknown instead of contaminating tabs.
                    if currentGroup.directions.count > 1 {
                        return nil
                    }
                    return currentGroup.directions.first?.direction
                }()

                guard let resolvedDirection else { continue }

                // Calculate minutes away
                let minutes: Int
                if let idx = call.expectedArrival {
                    minutes = TrackingTimeSync.remainingMinutes(until: idx)
                } else {
                    minutes = 99
                }
                // Attempt to backfill the missing coordinates from the downloaded Map Shape route
                var stopLat: Double? = nil
                var stopLon: Double? = nil
                if let knownStop = self.routeShape?.stops.first(where: { $0.id == call.stopId }) {
                    stopLat = knownStop.lat
                    stopLon = knownStop.lon
                }

                // Compute distance_m so the distance badge stays accurate
                // after this sync replaces the original API arrivals.
                var dist: Double? = nil
                if let sLat = stopLat, let sLon = stopLon, let ref = self.lastRefreshLocation {
                    dist = ref.distance(from: CLLocation(latitude: sLat, longitude: sLon))
                }
                let arrival = NearbyTransitResponse(
                    routeId: vehicle.routeId,
                    stopName: call.stopName ?? "Unknown Stop",
                    direction: resolvedDirection,
                    destination: call.destinationName,
                    minutesAway: minutes,
                    status: call.statusText,
                    mode: "bus",
                    stopLat: stopLat,
                    stopLon: stopLon,
                    arrivalTs: call.expectedArrival.map { Int($0.timeIntervalSince1970) } ?? 0,
                    vehicleId: vehicle.vehicleId,
                    tripId: nil,
                    stopId: call.stopId,
                    distanceM: dist
                )
                newArrivals.append(arrival)
            }
        }

        // If no OnwardCalls were found (e.g. all buses just started or API didn't return them),
        // fallback to keeping the existing list to avoid flashing empty.
        if newArrivals.isEmpty { return }

        // Group by the resolved direction key (matches existing group direction strings)
        let grouped = Dictionary(grouping: newArrivals, by: { $0.direction })

        #if DEBUG
        let uniqueStopIds = Set(newArrivals.compactMap(\.stopId))
        print("[HomeVM] syncBusArrivals: \(newArrivals.count) arrivals, \(uniqueStopIds.count) unique stops. Sample IDs: \(Array(uniqueStopIds.prefix(5)))")
        print("[HomeVM] syncBusArrivals: selectedStopId = '\(selectedStopId ?? "nil")'")
        #endif

        // Preserve existing direction labels/structure
        var newDirections: [DirectionArrivalsResponse] = []

        for oldDir in currentGroup.directions {
            let liveArrivals = grouped[oldDir.direction] ?? []
            // Deduplicate: for each stop, keep only the soonest arrival
            // (the earliest-arriving vehicle). Multiple buses heading to the
            // same stop create duplicate entries from onwardCalls — users only
            // need to see the next arrival at each stop.
            var seenStops: [String: NearbyTransitResponse] = [:]
            for arrival in liveArrivals {
                let key = arrival.stopId ?? arrival.stopName
                if let existing = seenStops[key] {
                    if arrival.minutesAway < existing.minutesAway {
                        seenStops[key] = arrival
                    }
                } else {
                    seenStops[key] = arrival
                }
            }
            let sorted = seenStops.values.sorted { $0.minutesAway < $1.minutesAway }

            // Only replace if we got new arrivals; otherwise keep existing to avoid flashing empty
            if sorted.isEmpty && !oldDir.arrivals.isEmpty {
                newDirections.append(oldDir)
            } else {
                newDirections.append(
                    DirectionArrivalsResponse(
                        direction: oldDir.direction,
                        directionLabel: oldDir.directionLabel,
                        arrivals: sorted
                    ))
            }
        }

        let updatedGroup = GroupedNearbyTransitResponse(
            routeId: currentGroup.routeId,
            displayName: currentGroup.displayName,
            mode: currentGroup.mode,
            colorHex: currentGroup.colorHex,
            directions: newDirections
        )

        #if DEBUG
        AppLogger.shared.log(
            "SYNC_BUS",
            message:
                "route=\(currentGroup.routeId) vehicles=\(vehicles.count) calls=\(newArrivals.count) snapshot=\(debugDirectionSnapshot(updatedGroup))"
        )
        #endif

        await MainActor.run {
            // Only update if the route hasn't changed in the meantime
            if self.selectedGroupedRoute?.routeId == currentGroup.routeId {
                self.selectedGroupedRoute = updatedGroup
            }
        }
    }

    /// Refreshes only the vehicle positions for the currently selected subway route.
    func refreshTrainVehicles() async {
        guard let routeId = selectedRouteId else { return }
        do {
            async let arrivalsTask = TrackAPI.fetchSubwayArrivals(lineID: routeId)
            let arrivals = try await arrivalsTask
            await MainActor.run {
                withAnimation(.interpolatingSpring(stiffness: 30, damping: 15)) {
                    updateTrainPositions(arrivals: arrivals)
                }
            }
            // Sync the arrivals list with the latest data
            await syncTrainArrivals(arrivals)
        } catch {
            // Silently ignore failures on fast poll, or log debug
        }
    }

    /// Refreshes vehicle positions for the currently selected LIRR or MNR route.
    /// Uses the same GTFS-RT arrivals → interpolation pipeline as subway.
    func refreshCommuterRailVehicles() async {
        guard let group = selectedGroupedRoute,
            group.isCommuterRail
        else { return }
        do {
            let arrivals: [TrainArrival]
            if group.isLIRR {
                arrivals = try await TrackAPI.fetchLIRRArrivals()
            } else {
                arrivals = try await TrackAPI.fetchMNRArrivals()
            }
            // Filter to only this route's arrivals
            let routeArrivals = arrivals.filter { arrival in
                let id = arrival.routeID.lowercased()
                let target = group.routeId.lowercased()
                // Match both "LIRR_9" and bare "9" forms
                return id == target
                    || id == target.replacingOccurrences(of: "lirr_", with: "")
                    || id == target.replacingOccurrences(of: "mnr_", with: "")
                    || "lirr_\(id)" == target
                    || "mnr_\(id)" == target
            }
            await MainActor.run {
                withAnimation(.interpolatingSpring(stiffness: 30, damping: 15)) {
                    updateTrainPositions(arrivals: routeArrivals)
                }
            }
            // Sync the arrivals list with the latest data
            await syncTrainArrivals(routeArrivals, mode: group.isLIRR ? "lirr" : "mnr")
        } catch {
            AppLogger.shared.logError("refreshCommuterRailVehicles", error: error)
        }
    }

    /// Updates the selected route's arrival list using the latest full arrival data.
    /// This ensures the list stays in sync with the map vehicle positions.
    private func syncTrainArrivals(_ arrivals: [TrainArrival], mode: String = "subway") async {
        guard let currentGroup = selectedGroupedRoute else { return }

        func normalizeStopId(_ raw: String) -> String {
            let stripped = stripMTAStopPrefix(raw)
            guard stripped.count > 1, let last = stripped.last, last == "N" || last == "S" else {
                return stripped
            }
            let penultimate = stripped[stripped.index(before: stripped.index(before: stripped.endIndex))]
            if penultimate.isNumber || penultimate.isLowercase {
                return String(stripped.dropLast())
            }
            return stripped
        }

        // Map TrainArrival -> NearbyTransitResponse
        // Filter to only this route if needed (though caller usually filters)
        let routeArrivals = arrivals.filter { $0.routeID == currentGroup.routeId }

        var newArrivals: [NearbyTransitResponse] = []
        for a in routeArrivals {
            // Compute distance_m so the badge stays accurate after sync
            var dist: Double? = nil
            if let sLat = a.stopLat, let sLon = a.stopLon, let ref = self.lastRefreshLocation {
                dist = ref.distance(from: CLLocation(latitude: sLat, longitude: sLon))
            }
            newArrivals.append(
                NearbyTransitResponse(
                    routeId: a.routeID,
                    stopName: a.stationName,
                    direction: a.direction,
                    destination: a.destination,
                    minutesAway: a.minutesAway,
                    status: a.status,
                    mode: mode,
                    stopLat: a.stopLat,
                    stopLon: a.stopLon,
                    arrivalTs: Int(a.estimatedTime.timeIntervalSince1970),
                    vehicleId: nil,
                    tripId: a.tripId,
                    stopId: a.stationID,
                    distanceM: dist
                ))
        }

        if newArrivals.isEmpty { return }

        // Build stop-id membership per direction from route shape, used as
        // primary assignment to prevent branch directions from sharing ETAs.
        let directionStopSets: [(dirKey: String, stopIds: Set<String>)] = {
            guard let shape = routeShape else { return [] }
            return currentGroup.directions.enumerated().map { index, dir in
                let ids = Set(
                    shape.stopsForDirection(index: index, name: dir.direction)
                        .map { normalizeStopId($0.id) }
                )
                return (dirKey: dir.direction, stopIds: ids)
            }
        }()

        // Build compass ↔ label expansion tables for fuzzy direction matching.
        // Train arrivals use GTFS-RT direction codes ("N"/"S") while the group's
        // direction keys may be headsigns ("Inwood-207 St") or compass labels
        // ("Northbound") after enrichGroupWithShapeDirections.
        let compassExpansions: [String: Set<String>] = [
            "N": ["N", "NORTHBOUND", "UPTOWN"],
            "S": ["S", "SOUTHBOUND", "DOWNTOWN"],
            "E": ["E", "EASTBOUND"],
            "W": ["W", "WESTBOUND"],
        ]
        let reverseCompass: [String: String] = [
            "NORTHBOUND": "N", "UPTOWN": "N",
            "SOUTHBOUND": "S", "DOWNTOWN": "S",
            "EASTBOUND": "E", "WESTBOUND": "W",
        ]

        // For each existing direction, build a set of all direction strings
        // that should match to it (compass codes, labels, destinations).
        var directionMatchSets: [(dirKey: String, matches: Set<String>)] = []
        for dir in currentGroup.directions {
            var matches = Set<String>()
            let upper = dir.direction.uppercased()
            matches.insert(upper)

            // Expand compass codes
            if let expansions = compassExpansions[upper] {
                matches.formUnion(expansions)
            }
            if let code = reverseCompass[upper] {
                matches.insert(code)
                if let expansions = compassExpansions[code] {
                    matches.formUnion(expansions)
                }
            }

            // Add all arrival destinations
            for arrival in dir.arrivals {
                if let dest = arrival.destination?.uppercased(), !dest.isEmpty {
                    matches.insert(dest)
                }
            }

            // Add direction label
            if let label = dir.directionLabel?.uppercased().replacingOccurrences(of: "→ ", with: ""), !label.isEmpty {
                matches.insert(label)
            }

            directionMatchSets.append((dirKey: dir.direction, matches: matches))
        }

        // Assign each new arrival to the correct group direction using fuzzy matching
        func resolveDirection(for arrival: NearbyTransitResponse) -> String {
            // 0) Stop-ID membership against route-shape direction stops
            if let sid = arrival.stopId {
                let normalized = normalizeStopId(sid)
                let candidates = directionStopSets.filter { $0.stopIds.contains(normalized) }
                if candidates.count == 1 {
                    return candidates[0].dirKey
                }
            }

            let arrDir = arrival.direction.uppercased()
            let arrDest = arrival.destination?.uppercased() ?? ""

            // Try exact match first
            for (dirKey, matches) in directionMatchSets {
                if matches.contains(arrDir) { return dirKey }
            }

            // Try destination-based match
            for (dirKey, matches) in directionMatchSets {
                if !arrDest.isEmpty && matches.contains(where: { arrDest.contains($0) || $0.contains(arrDest) }) {
                    return dirKey
                }
            }

            // Try compass expansion match
            if let code = reverseCompass[arrDir] {
                for (dirKey, matches) in directionMatchSets {
                    if matches.contains(code) { return dirKey }
                }
            }

            // Last resort: return raw direction (will create new direction tab if needed)
            return arrival.direction
        }

        // Group arrivals using the resolved direction keys
        let grouped = Dictionary(grouping: newArrivals, by: { resolveDirection(for: $0) })

        var newDirections: [DirectionArrivalsResponse] = []

        // Preserve existing direction labels
        for oldDir in currentGroup.directions {
            let liveArrivals = grouped[oldDir.direction] ?? []
            let sorted = liveArrivals.sorted { $0.minutesAway < $1.minutesAway }

            // Only replace if we got new arrivals; otherwise keep existing to avoid flashing empty
            if sorted.isEmpty && !oldDir.arrivals.isEmpty {
                newDirections.append(oldDir)
            } else {
                newDirections.append(
                    DirectionArrivalsResponse(
                        direction: oldDir.direction,
                        directionLabel: oldDir.directionLabel,
                        arrivals: sorted
                    ))
            }
        }

        // Handle new directions that don't match any existing direction
        for (dir, dirArrivals) in grouped {
            if !newDirections.contains(where: { $0.direction == dir }) {
                let sorted = dirArrivals.sorted { $0.minutesAway < $1.minutesAway }
                newDirections.append(
                    DirectionArrivalsResponse(
                        direction: dir,
                        directionLabel: nil,
                        arrivals: sorted
                    ))
            }
        }

        let updatedGroup = GroupedNearbyTransitResponse(
            routeId: currentGroup.routeId,
            displayName: currentGroup.displayName,
            mode: currentGroup.mode,
            colorHex: currentGroup.colorHex,
            directions: newDirections
        )

        #if DEBUG
        AppLogger.shared.log(
            "SYNC_TRAIN",
            message:
                "route=\(currentGroup.routeId) mode=\(mode) arrivals=\(newArrivals.count) snapshot=\(debugDirectionSnapshot(updatedGroup))"
        )
        #endif

        await MainActor.run {
            if self.selectedGroupedRoute?.routeId == currentGroup.routeId {
                self.selectedGroupedRoute = updatedGroup
            }
        }
    }

    // MARK: - Bus Schedule

    /// Cached bus schedule for the currently selected bus route.
    var busSchedule: BusScheduleResponse?

    /// Fetches the schedule for the currently selected bus route.
    /// Used to show scheduled departures when no live buses are running.
    func fetchBusScheduleIfNeeded() async {
        guard let group = selectedGroupedRoute, group.isBus else { return }
        do {
            busSchedule = try await TrackAPI.fetchBusSchedule(routeID: group.routeId)
        } catch {
            AppLogger.shared.logError("fetchBusSchedule(\(group.routeId))", error: error)
            busSchedule = nil
        }
    }

    /// Clears the selected route and remove bus/train markers from the map.
    func clearRoute() {
        selectedRouteId = nil
        selectedDirectionIndex = 0
        busVehicles = []
        trainVehicles = []
        cachedTrainArrivals = []
        previousBusPositions = [:]
        lastBusUpdateTime = .distantPast
        routeShape = nil
        errorMessage = nil
        nearestStopCoordinate = nil
        highlightedVehicleId = nil
        trackedVehicleCoordinate = nil
        tappedVehicleId = nil
        selectedStopId = nil
        goMode.walkingRoute = nil
        busSchedule = nil
    }

    /// Recalculates the nearest stop and `selectedStopId` for the current direction.
    /// Call when the direction changes or the user's location updates significantly.
    func updateNearestStop(userLocation: CLLocation?) {
        let refLocation = effectiveLocation(userLocation: userLocation)
        let dirStops = routeShape?.stopsForDirection(index: selectedDirectionIndex, name: selectedDirectionName) ?? []

        guard !dirStops.isEmpty, let userLoc = refLocation else {
            // Fallback: try first arrival's stop
            if let group = selectedGroupedRoute {
                let safeIdx = min(selectedDirectionIndex, group.directions.count - 1)
                let dir = group.directions.indices.contains(safeIdx) ? group.directions[safeIdx] : nil
                if let first = dir?.arrivals.first, let lat = first.stopLat, let lon = first.stopLon {
                    nearestStopCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    selectedStopId = first.stopId
                }
            }
            return
        }

        var closestStop: BusStop?
        var minDistance: CLLocationDistance = .greatestFiniteMagnitude

        for stop in dirStops {
            let stopLoc = CLLocation(latitude: stop.lat, longitude: stop.lon)
            let distance = userLoc.distance(from: stopLoc)
            if distance < minDistance {
                minDistance = distance
                closestStop = stop
            }
        }

        if let closest = closestStop {
            nearestStopCoordinate = CLLocationCoordinate2D(latitude: closest.lat, longitude: closest.lon)
            selectedStopId = closest.id
            #if DEBUG
            print("[HomeVM] updateNearestStop → selectedStopId = '\(closest.id)' (stop: \(closest.name))")
            #endif
        }
    }

    // Cache latest arrivals to allow client-side simulation between network fetches
    private(set) var cachedTrainArrivals: [TrainArrival] = []

    /// Re-calculates train positions based on the current time and cached arrivals.
    /// Call this frequently (e.g. every 1s) to animate trains smoothly.
    func updateSimulation() {
        guard !cachedTrainArrivals.isEmpty else { return }
        updateTrainPositions(arrivals: cachedTrainArrivals)
    }

    /// Interpolates bus positions along the route polyline between GPS fetches.
    /// Called every tick (1s) for smooth movement between the 10s GPS refresh.
    func updateBusSimulation() {
        guard !busVehicles.isEmpty, routeShape != nil else { return }
        let elapsed = Date().timeIntervalSince(lastBusUpdateTime)
        let duration: TimeInterval = 10.0  // seconds between GPS poll (matches handleRouteSelection timer)

        let polyline = cachedInterpolationPolyline
        guard polyline.count >= 2 else { return }

        var updated = busVehicles
        for i in updated.indices {
            guard let prev = previousBusPositions[updated[i].vehicleId] else { continue }
            let result = VehicleInterpolator.smoothBusPosition(
                previous: CLLocationCoordinate2D(latitude: prev.lat, longitude: prev.lon),
                current: CLLocationCoordinate2D(
                    latitude: updated[i].lat, longitude: updated[i].lon),
                elapsed: elapsed,
                duration: duration,
                along: polyline
            )
            // Update the vehicle's display position via a mutable copy
            // (BusVehicleResponse is a struct, so this is a value-type update)
            updated[i] = updated[i].withInterpolatedPosition(
                lat: result.coordinate.latitude,
                lon: result.coordinate.longitude,
                bearing: result.bearing
            )
            // Record position for smart ETA speed estimation
            ArrivalETAEngine.recordPosition(
                vehicleKey: updated[i].vehicleId,
                coordinate: result.coordinate)
        }
        withAnimation(.linear(duration: 1.0)) {
            self.busVehicles = updated
        }
    }

    /// Solves for "Ghost Trains" by interpolating position between stations
    /// along the actual route polyline for realistic curved movement.
    /// Builds vehicles from ALL directions (not just the selected one) so
    /// `filteredTrainVehicles` can properly filter them.
    private func updateTrainPositions(arrivals: [TrainArrival]) {
        guard let shape = routeShape else { return }
        self.cachedTrainArrivals = arrivals

        // Build stops and polyline per direction so we can match arrivals
        // against the correct direction's stops.
        struct DirectionContext {
            let stops: [BusStop]
            let polyline: [CLLocationCoordinate2D]
        }

        // Build direction contexts for all available directions
        var dirContexts: [DirectionContext] = []
        if !shape.directions.isEmpty {
            for i in 0..<shape.directions.count {
                let ds = shape.stopsForDirection(index: i)
                let stops = ds.isEmpty ? shape.stops : ds
                let pl = shape.polylinesForDirection(index: i)
                let polyline: [CLLocationCoordinate2D] =
                    pl.isEmpty
                    ? cachedInterpolationPolyline
                    : pl.flatMap { $0 }
                dirContexts.append(DirectionContext(stops: stops, polyline: polyline))
            }
        }
        // If no direction data, use the combined stops
        if dirContexts.isEmpty {
            dirContexts.append(
                DirectionContext(
                    stops: shape.stops,
                    polyline: cachedInterpolationPolyline
                ))
        }

        // 1. Group arrivals by UNIQUE trip.
        var trips: [String: [TrainArrival]] = [:]

        for arrival in arrivals {
            let key =
                arrival.tripId
                ?? "\(arrival.direction)-\(arrival.destination ?? "unk")-\(arrival.scheduledTime.timeIntervalSince1970)"
            trips[key, default: []].append(arrival)
        }

        var newVehicles: [TrainVehicle] = []

        // 2. Process each trip to find its "current location"
        // Try matching against each direction's stops until we find a match.
        for (tripId, tripArrivals) in trips {
            let sorted = tripArrivals.sorted { $0.estimatedTime < $1.estimatedTime }

            guard
                let nextStop = sorted.first(where: { $0.estimatedTime.timeIntervalSinceNow > -30 })
            else { continue }

            let nextStopIdBase = nextStop.stationID.prefix(3)

            // Try each direction context to find which one has this stop
            for ctx in dirContexts {
                guard
                    let nextStopIndex = ctx.stops.firstIndex(where: {
                        $0.id.hasPrefix(nextStopIdBase)
                    })
                else { continue }

                let dirStops = ctx.stops
                let polyline = ctx.polyline

                var lat = dirStops[nextStopIndex].lat
                var lon = dirStops[nextStopIndex].lon
                var bearing: Double = 0

                let previousIndex = nextStopIndex > 0 ? nextStopIndex - 1 : nextStopIndex
                let nextIndex = nextStopIndex

                if previousIndex != nextIndex {
                    let prevStop = dirStops[previousIndex]
                    let targetStop = dirStops[nextIndex]

                    let timeUntilArrival = nextStop.estimatedTime.timeIntervalSinceNow
                    let minutes = timeUntilArrival / 60.0
                    let travelTime = 3.0
                    let t = min(max(minutes / travelTime, 0.0), 1.0)

                    // progress: 0.0 at prevStop → 1.0 at targetStop
                    let rawProgress = 1.0 - t

                    let progress: Double
                    if AppSettings.shared.simulationEasingEnabled {
                        progress =
                            rawProgress < 0.5
                            ? 2 * rawProgress * rawProgress
                            : 1 - pow(-2 * rawProgress + 2, 2) / 2
                    } else {
                        progress = rawProgress
                    }

                    // Use polyline-aware interpolation if we have a polyline
                    if polyline.count >= 2 {
                        let fromCoord = CLLocationCoordinate2D(
                            latitude: prevStop.lat, longitude: prevStop.lon)
                        let toCoord = CLLocationCoordinate2D(
                            latitude: targetStop.lat, longitude: targetStop.lon)
                        let result = VehicleInterpolator.interpolateBetweenStops(
                            from: fromCoord, to: toCoord,
                            progress: progress, along: polyline)
                        lat = result.coordinate.latitude
                        lon = result.coordinate.longitude
                        bearing = result.bearing
                    } else {
                        // Fallback: straight-line lerp
                        lat = prevStop.lat + (targetStop.lat - prevStop.lat) * progress
                        lon = prevStop.lon + (targetStop.lon - prevStop.lon) * progress
                        bearing =
                            atan2(
                                targetStop.lon - prevStop.lon,
                                targetStop.lat - prevStop.lat
                            ) * 180 / .pi
                        if bearing < 0 { bearing += 360 }
                    }
                }

                newVehicles.append(
                    TrainVehicle(
                        id: tripId,
                        tripId: tripId,
                        routeId: nextStop.routeID,
                        direction: nextStop.direction,
                        lat: lat,
                        lon: lon,
                        bearing: bearing,
                        nextStationName: dirStops[nextStopIndex].name,
                        estimatedArrival: nextStop.estimatedTime
                    ))
                // Record position for smart ETA speed estimation
                ArrivalETAEngine.recordPosition(
                    vehicleKey: tripId,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                break  // Found a matching direction, stop searching
            }
        }

        withAnimation(.linear(duration: 1.0)) {
            self.trainVehicles = newVehicles
        }
    }

    // MARK: - Nearby Transit (Unified)

    /// Search radius (meters) used for the wider "nearest metro" fallback.
    private static let nearestMetroRadius = AppSettings.shared.nearestMetroFallbackRadiusMeters

    /// Fetches all nearby transit (buses + trains) in one call.
    /// Uses the grouped endpoint to deduplicate routes.
    /// When no results are found within the default radius, fetches
    /// with a wider radius and exposes the closest stop as ``nearestTransit``.
    ///
    /// - Parameter skipGlobalFeeds: When `true` (e.g. during drag-to-search),
    ///   skips alerts and accessibility fetches since those are location-independent
    ///   and are loaded during the initial app refresh. This makes area scanning
    ///   noticeably faster.
    func refreshNearbyTransit(location: CLLocation?, skipGlobalFeeds: Bool = false, silent: Bool = false) async {
        guard let location = location else {
            errorMessage = "Location required"
            return
        }

        if !silent {
            isLoading = true
            // Only clear the nearest-metro recommendation on a visible
            // (non-silent) refresh so it doesn't briefly vanish when
            // data is reloaded in the background.
            nearestTransit = nil
            nearestTransitDistance = nil
        }
        errorMessage = nil

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        do {
            async let groupedTask = TrackAPI.fetchNearbyGrouped(lat: lat, lon: lon)

            let newGrouped = try await groupedTask
            let rawTransit = newGrouped
                .flatMap(\ .directions)
                .flatMap(\ .arrivals)

            // Merge new grouped data with existing data using a multi-cycle
            // grace period so routes don't vanish when the MTA feed briefly
            // drops them.  A route survives up to 3 consecutive misses.
            groupedTransit = mergeGroupedTransit(
                new: newGrouped,
                existing: groupedTransit
            )

            if !rawTransit.isEmpty || nearbyTransit.isEmpty {
                // Deduplicate: Keep the first occurrence of each unique ID
                var seenIDs = Set<String>()
                nearbyTransit = rawTransit.filter { seenIDs.insert($0.id).inserted }
            } else {
                AppLogger.shared.log(
                    "REFRESH",
                    message: "API returned 0 flat arrivals but we had \(nearbyTransit.count) — keeping previous data"
                )
            }

            // Load auxiliary stop metadata in the background so first transit
            // rows render immediately. These fields only refine distance display.
            // Run both fetches in parallel so nearbyStations is populated before
            // the first SwiftUI render that calls displayDistanceMeters.
            Task {
                // Both async let bindings start concurrently.
                async let busStopsTask = TrackAPI.fetchNearbyBusStops(lat: lat, lon: lon)
                async let stationsTask = repository.fetchNearbyStations(
                    latitude: lat, longitude: lon
                )

                var stops: [BusStop] = []
                do { stops = try await busStopsTask }
                catch { AppLogger.shared.logError("fetchNearbyBusStops", error: error) }

                let stations = (try? await stationsTask) ?? nearbyStations
                await MainActor.run {
                    nearbyBusStops = stops
                    nearbyStations = stations
                }
            }

            // Fetch alerts and accessibility only on full refreshes — these are
            // global feeds that don't change by location. Skipping them during
            // drag-to-search avoids 2 extra network calls per pan gesture.
            if !skipGlobalFeeds {
                Task {
                    async let alertsTask = TrackAPI.fetchAlerts()
                    async let accessTask = TrackAPI.fetchAccessibility()
                    do {
                        let alerts = try await alertsTask
                        await MainActor.run {
                            serviceAlerts = alerts
                            AlertNotificationManager.shared.processAlerts(alerts)
                        }
                    } catch {}
                    do {
                        let accessibility = try await accessTask
                        await MainActor.run { elevatorOutages = accessibility }
                    } catch {}
                }
            }

            // Sync the selected route if it's currently open
            updateSelectedRouteFromRefreshedData(groupedTransit)

        } catch {
            AppLogger.shared.logError("fetchNearbyTransit", error: error)
            errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
        }

        // If no nearby transit found, search a wider radius for a recommendation
        if nearbyTransit.isEmpty && groupedTransit.isEmpty && errorMessage == nil {
            await fetchNearestMetro(location: location)
        }

        isLoading = false
    }

    // MARK: - Grouped Transit Merge

    /// Merges freshly fetched grouped transit data with existing data,
    /// retaining previously visible routes while the location context
    /// remains stable so rows do not vanish on transient upstream gaps.
    ///
    /// - Routes present in the new response → use fresh data and reset miss count.
    /// - Routes missing from new response → keep prior row and increment miss count.
    /// - If the new response is completely empty but we had data, keep everything.
    ///
    /// Grace counters are cleared when the location context changes
    /// (significant movement or search-pin set/clear).
    private func mergeGroupedTransit(
        new: [GroupedNearbyTransitResponse],
        existing: [GroupedNearbyTransitResponse],
        source: String = "nearby"
    ) -> [GroupedNearbyTransitResponse] {
        // Server hiccup guard: if the API returned nothing keep previous data.
        guard !new.isEmpty || existing.isEmpty else {
            AppLogger.shared.log(
                "REFRESH",
                message: "[\(source)] API returned 0 grouped routes but we had \(existing.count) — keeping previous data"
            )
            return existing
        }

        // First load or previous was empty — nothing to merge.
        guard !existing.isEmpty else {
            graceMissCountBySource[source] = [:]
            return new
        }

        let newRouteIds = Set(new.map(\.routeId))
        var missCounts = graceMissCountBySource[source] ?? [:]

        // Routes that reappeared — reset their miss counter.
        for id in newRouteIds {
            missCounts.removeValue(forKey: id)
        }

        // Start with all new (fresh) data.
        var merged = new

        // Keep each old route that's NOT in the new data, up to a limit.
        // After 3 consecutive misses the route is stale (likely the user
        // moved away) and its stop coordinates may no longer be accurate,
        // which causes displayDistanceMeters to bucket it incorrectly.
        let maxGraceCycles = 3
        for oldGroup in existing where !newRouteIds.contains(oldGroup.routeId) {
            let count = (missCounts[oldGroup.routeId] ?? 0) + 1
            missCounts[oldGroup.routeId] = count
            if count > maxGraceCycles {
                AppLogger.shared.log(
                    "REFRESH",
                    message: "[\(source)] Evicting \(oldGroup.routeId) after \(count) grace cycles"
                )
                continue   // drop it from merged
            }
            merged.append(oldGroup)
            AppLogger.shared.log(
                "REFRESH",
                message: "[\(source)] Grace \(count)/\(maxGraceCycles) for \(oldGroup.routeId) — keeping visible"
            )
        }

        graceMissCountBySource[source] = missCounts
        return merged
    }

    /// Searches a wider radius to find the nearest metro stop when
    /// the default radius returns empty results.
    private func fetchNearestMetro(location: CLLocation) async {
        do {
            let results = try await TrackAPI.fetchNearbyTransit(
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude,
                radius: Self.nearestMetroRadius
            )
            guard let closest = results.first else { return }
            nearestTransit = closest

            // Compute distance from user to the stop
            if let stopLat = closest.stopLat, let stopLon = closest.stopLon {
                let stopLocation = CLLocation(latitude: stopLat, longitude: stopLon)
                nearestTransitDistance = location.distance(from: stopLocation)
            }
        } catch {
            AppLogger.shared.logError("fetchNearestMetro", error: error)
        }
    }

    // MARK: - Subway

    private func refreshSubway(location: CLLocation?) async {
        guard let location = location else {
            errorMessage = "Location required for subway arrivals"
            return
        }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        // Fire alerts and accessibility in parallel with transit data
        async let alertsTask: Void = refreshAlerts()
        async let accessTask: [ElevatorStatus]? = { try? await TrackAPI.fetchAccessibility() }()

        do {
            async let groupedTask = TrackAPI.fetchNearbyGrouped(lat: lat, lon: lon, mode: "subway")
            async let stationsTask = repository.fetchNearbyStations(
                latitude: lat, longitude: lon
            )

            let allGrouped = try await groupedTask
            let filtered = allGrouped.filter { $0.mode == "subway" }

            // Resolve stations BEFORE grouped data so displayDistanceMeters()
            // has fresh physical-station distances when SwiftUI re-renders.
            nearbyStations = (try? await stationsTask) ?? nearbyStations

            nearbyGroupedSubwayArrivals = mergeGroupedTransit(
                new: filtered,
                existing: nearbyGroupedSubwayArrivals,
                source: "subway"
            )

            updateSelectedRouteFromRefreshedData(nearbyGroupedSubwayArrivals)
        } catch {
            AppLogger.shared.logError("refreshSubway", error: error)
            errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
        }

        // Await the parallel global feeds
        _ = await alertsTask
        if let outages = await accessTask { elevatorOutages = outages }
    }

    // MARK: - Bus

    private func refreshBus(location: CLLocation?) async {
        guard let location = location else {
            errorMessage = "Location required for bus arrivals"
            return
        }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        // Fire alerts and accessibility in parallel with transit data
        async let alertsTask: Void = refreshAlerts()
        async let accessTask: [ElevatorStatus]? = { try? await TrackAPI.fetchAccessibility() }()

        do {
            async let groupedTask = TrackAPI.fetchNearbyGrouped(lat: lat, lon: lon, mode: "bus")
            async let nearbyBusStopsTask = TrackAPI.fetchNearbyBusStops(lat: lat, lon: lon)

            let allGrouped = try await groupedTask
            let filtered = allGrouped.filter { $0.mode == "bus" }

            // Resolve bus stops BEFORE updating grouped arrivals so that
            // when SwiftUI re-renders the dashboard, displayDistanceMeters()
            // already has fresh nearbyBusStops to match against.
            do {
                nearbyBusStops = try await nearbyBusStopsTask
            } catch {
                AppLogger.shared.logError("fetchNearbyBusStops", error: error)
            }

            nearbyGroupedBusArrivals = mergeGroupedTransit(
                new: filtered,
                existing: nearbyGroupedBusArrivals,
                source: "bus"
            )

            updateSelectedRouteFromRefreshedData(nearbyGroupedBusArrivals)

            do { allBusRoutes = try await TrackAPI.fetchBusRoutes() } catch {}
        } catch {
            AppLogger.shared.logError("refreshBus", error: error)
            errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
        }

        // Await the parallel global feeds
        _ = await alertsTask
        if let outages = await accessTask { elevatorOutages = outages }
    }

    /// Fetches live bus arrivals for a specific stop.
    func fetchBusArrivals(for stop: BusStop) async {
        selectedBusStop = stop
        do {
            busArrivals = try await TrackAPI.fetchBusArrivals(stopID: stop.id)
        } catch {
            AppLogger.shared.logError("fetchBusArrivals(\(stop.id))", error: error)
            errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
        }
    }

    // MARK: - LIRR

    private func refreshLIRR(location: CLLocation?) async {
        // Fire alerts and accessibility in parallel with transit data
        async let alertsTask: Void = refreshAlerts()
        async let accessTask: [ElevatorStatus]? = { try? await TrackAPI.fetchAccessibility() }()

        do {
            lirrArrivals = try await TrackAPI.fetchLIRRArrivals()
        } catch {
            AppLogger.shared.logError("fetchLIRRArrivals", error: error)
            errorMessage = (error as? TrackAPIError)?.description ?? error.localizedDescription
        }

        // Fetch grouped LIRR arrivals from backend (with display names and colors)
        if let loc = location {
            do {
                let newGrouped = try await TrackAPI.fetchNearbyGrouped(
                    lat: loc.coordinate.latitude,
                    lon: loc.coordinate.longitude,
                    mode: "lirr"
                )
                nearbyGroupedLIRRArrivals = mergeGroupedTransit(
                    new: newGrouped,
                    existing: nearbyGroupedLIRRArrivals,
                    source: "lirr"
                )
            } catch {
                AppLogger.shared.logError("fetchGroupedLIRR", error: error)
                if nearbyGroupedLIRRArrivals.isEmpty {
                    nearbyGroupedLIRRArrivals = groupTrainArrivals(lirrArrivals, mode: "lirr")
                }
            }
        } else if nearbyGroupedLIRRArrivals.isEmpty {
            nearbyGroupedLIRRArrivals = groupTrainArrivals(lirrArrivals, mode: "lirr")
        }

        updateSelectedRouteFromRefreshedData(nearbyGroupedLIRRArrivals)

        // Await the parallel global feeds
        _ = await alertsTask
        if let outages = await accessTask { elevatorOutages = outages }
    }

    // MARK: - Metro-North

    private func refreshMNR(location: CLLocation?) async {
        // Fire alerts and accessibility in parallel with transit data
        async let alertsTask: Void = refreshAlerts()
        async let accessTask: [ElevatorStatus]? = { try? await TrackAPI.fetchAccessibility() }()

        do {
            mnrArrivals = try await TrackAPI.fetchMNRArrivals()
        } catch {
            AppLogger.shared.logError("fetchMNRArrivals", error: error)
            errorMessage = (error as? TrackAPIError)?.description ?? error.localizedDescription
        }

        // Fetch grouped MNR arrivals from backend (with display names and colors)
        if let loc = location {
            do {
                let newGrouped = try await TrackAPI.fetchNearbyGrouped(
                    lat: loc.coordinate.latitude,
                    lon: loc.coordinate.longitude,
                    mode: "mnr"
                )
                nearbyGroupedMNRArrivals = mergeGroupedTransit(
                    new: newGrouped,
                    existing: nearbyGroupedMNRArrivals,
                    source: "mnr"
                )
            } catch {
                AppLogger.shared.logError("fetchGroupedMNR", error: error)
                if nearbyGroupedMNRArrivals.isEmpty {
                    nearbyGroupedMNRArrivals = groupTrainArrivals(mnrArrivals, mode: "mnr")
                }
            }
        } else if nearbyGroupedMNRArrivals.isEmpty {
            nearbyGroupedMNRArrivals = groupTrainArrivals(mnrArrivals, mode: "mnr")
        }

        updateSelectedRouteFromRefreshedData(nearbyGroupedMNRArrivals)

        // Await the parallel global feeds
        _ = await alertsTask
        if let outages = await accessTask { elevatorOutages = outages }
    }

    /// Starts tracking a nearby transit arrival via Widget.
    func trackNearbyArrival(_ arrival: NearbyTransitResponse, location: CLLocation?) {
        // End any existing tracking session first — only one route at a time.
        if currentTrackedRoute != nil { stopTracking() }

        // Log track interaction to Supabase for analytics
        Task {
            await SupabaseManager.shared.logRouteInteraction(
                routeId: arrival.routeId,
                mode: arrival.isBus ? "bus" : "subway",
                type: "track"
            )
        }

        // Record commute pattern for smart suggestions
        SmartSuggester.recordPattern(
            context: DataController.shared.container.mainContext,
            routeID: arrival.routeId,
            direction: arrival.direction,
            startLocation: location ?? CLLocation(latitude: 0, longitude: 0),
            destinationStationID: arrival.stopId ?? arrival.stopName,
            destinationName: arrival.destination ?? arrival.direction,
            cloudSyncHandler: {
                routeId, direction, lat, lon, destId, destName, hour, weekday, freq in
                await SyncManager.shared.syncCommutePattern(
                    routeId: routeId,
                    direction: direction,
                    startLatitude: lat,
                    startLongitude: lon,
                    destinationStationId: destId,
                    destinationName: destName,
                    timeOfDay: hour,
                    dayOfWeek: weekday,
                    frequency: freq
                )
            }
        )

        // Save to TrackedRoute for Single Route Widget
        let trackedRoute = TrackedRoute(
            routeId: arrival.routeId,
            displayName: arrival.displayName,
            stopName: arrival.stopName,
            direction: arrival.direction,
            destination: arrival.destination,
            mode: arrival.isBus ? "bus" : "subway",
            trackedAt: Date()
        )
        currentTrackedRoute = trackedRoute
        trackedRoute.save()

        // Update visual highlighting on the map — set tappedVehicleId so
        // the marker scales up and the matching arrival row highlights.
        if arrival.isBus {
            self.tappedVehicleId = arrival.vehicleId
            self.highlightedVehicleId = arrival.vehicleId
            AppLogger.shared.log(
                "TRACKING", message: "Highlighting bus vehicle: \(arrival.vehicleId ?? "none")")
        } else {
            self.tappedVehicleId = arrival.tripId
            self.highlightedVehicleId = arrival.tripId
            AppLogger.shared.log(
                "TRACKING", message: "Highlighting train trip: \(arrival.tripId ?? "none")")
        }

        // Set the zoom-to coordinate so the map centers on the tracked vehicle/stop.
        // Prioritizes live vehicle position; falls back to stop coordinates.
        self.trackedVehicleCoordinate = coordinateForTrackedArrival(arrival)

        // Immediately refresh the Live Activity
        updateLiveActivityFromRefresh()

        // Update local state and reload widgets
        WidgetCenter.shared.reloadAllTimelines()

        // Start Live Activity using the same smart ETA path as route detail.
        let eta = Date().addingTimeInterval(smartETA(for: arrival).secondsRemaining)

        // Find sibling arrivals for the "Other upcoming trains" section
        let now = Date()
        let currentArrival = eta
        let siblingTimes =
            (groupedTransit.first(where: { $0.routeId == arrival.routeId })?
            .directions.first(where: { $0.direction == arrival.direction })?
            .arrivals
            .filter { $0.id != arrival.id }
            .map { now.addingTimeInterval(smartETA(for: $0).secondsRemaining) } ?? [])

        let nextArrivals = TrackingTimeSync.nextArrivalMinutes(
            arrivalTimes: siblingTimes,
            after: currentArrival,
            now: now
        )

        LiveActivityManager.shared.startActivity(
            lineId: arrival.isBus ? stripMTAPrefix(arrival.routeId) : arrival.routeId,
            destination: arrival.destination ?? arrival.direction,
            arrivalTime: eta,
            isBus: arrival.isBus,
            nextArrivals: nextArrivals
        )
    }

    /// Starts tracking a subway arrival.
    func trackSubwayArrival(_ arrival: TrainArrival, location: CLLocation?) {
        // End any existing tracking session first — only one route at a time.
        if currentTrackedRoute != nil { stopTracking() }

        // Log track interaction to Supabase for analytics
        Task {
            await SupabaseManager.shared.logRouteInteraction(
                routeId: arrival.routeID,
                mode: "subway",
                type: "track"
            )
        }

        let trackedRoute = TrackedRoute(
            routeId: arrival.routeID,
            displayName: arrival.routeID,
            stopName: arrival.stationID,
            direction: arrival.direction,
            destination: nil,
            mode: "subway",
            trackedAt: Date()
        )
        trackedRoute.save()

        currentTrackedRoute = trackedRoute
        WidgetCenter.shared.reloadAllTimelines()

        // Start Live Activity using feed timestamp (`estimatedTime`) for precision.
        let eta = arrival.estimatedTime

        // Find sibling arrivals for the "Other upcoming trains" section
        let nextArrivals = TrackingTimeSync.nextArrivalMinutes(
            arrivalTimes: upcomingArrivals
                .filter {
                    $0.direction == arrival.direction
                        && $0.stationID == arrival.stationID
                        && $0.id != arrival.id
                }
                .map(\ .estimatedTime),
            after: eta
        )

        LiveActivityManager.shared.startActivity(
            lineId: arrival.routeID,
            destination: arrival.direction,
            arrivalTime: eta,
            isBus: false,
            nextArrivals: nextArrivals
        )
    }

    /// Starts tracking a bus arrival.
    func trackBusArrival(_ arrival: BusArrival, location: CLLocation?) {
        // End any existing tracking session first — only one route at a time.
        if currentTrackedRoute != nil { stopTracking() }

        // Log track interaction to Supabase for analytics
        Task {
            await SupabaseManager.shared.logRouteInteraction(
                routeId: arrival.routeId,
                mode: "bus",
                type: "track"
            )
        }

        let trackedRoute = TrackedRoute(
            routeId: arrival.routeId,
            displayName: stripMTAPrefix(arrival.routeId),
            stopName: arrival.stopId,
            direction: "",
            destination: nil,
            mode: "bus",
            trackedAt: Date()
        )
        trackedRoute.save()

        currentTrackedRoute = trackedRoute
        WidgetCenter.shared.reloadAllTimelines()

        // Start Live Activity
        let arrivalTime = arrival.expectedArrival ?? Date().addingTimeInterval(300)

        // Find sibling arrivals for the "Other upcoming trains" section
        let nextArrivals = TrackingTimeSync.nextArrivalMinutes(
            arrivalTimes: busArrivals
                .filter { $0.routeId == arrival.routeId && $0.stopId == arrival.stopId }
                .compactMap(\ .expectedArrival),
            after: arrivalTime
        )

        LiveActivityManager.shared.startActivity(
            lineId: stripMTAPrefix(arrival.routeId),
            destination: "Bus Tracking",
            arrivalTime: arrivalTime,
            isBus: true,
            nextArrivals: nextArrivals
        )
    }

    /// Starts tracking an LIRR arrival.
    func trackLIRRArrival(_ arrival: TrainArrival, location: CLLocation?) {
        trackRailArrival(arrival, location: location, agency: "lirr")
    }

    /// Starts tracking a Metro-North arrival.
    func trackMNRArrival(_ arrival: TrainArrival, location: CLLocation?) {
        trackRailArrival(arrival, location: location, agency: "mnr")
    }

    /// Generic rail arrival tracking (LIRR & MNR).
    private func trackRailArrival(_ arrival: TrainArrival, location: CLLocation?, agency: String) {
        // End any existing tracking session first — only one route at a time.
        if currentTrackedRoute != nil { stopTracking() }

        // Log track interaction to Supabase for analytics
        Task {
            await SupabaseManager.shared.logRouteInteraction(
                routeId: arrival.routeID,
                mode: agency,
                type: "track"
            )
        }

        let trackedRoute = TrackedRoute(
            routeId: arrival.routeID,
            displayName: arrival.routeID,
            stopName: arrival.stationID,
            direction: arrival.direction,
            destination: nil,
            mode: agency,
            trackedAt: Date()
        )
        trackedRoute.save()

        currentTrackedRoute = trackedRoute
        WidgetCenter.shared.reloadAllTimelines()

        // Start Live Activity using feed timestamp (`estimatedTime`) for precision.
        let eta = arrival.estimatedTime

        // Find sibling arrivals for the "Other upcoming trains" section
        let agencyArrivals = agency == "lirr" ? lirrArrivals : mnrArrivals
        let nextArrivals = TrackingTimeSync.nextArrivalMinutes(
            arrivalTimes: agencyArrivals
                .filter {
                    $0.direction == arrival.direction
                        && $0.stationID == arrival.stationID
                        && $0.id != arrival.id
                }
                .map(\ .estimatedTime),
            after: eta
        )

        LiveActivityManager.shared.startActivity(
            lineId: arrival.routeID,
            destination: arrival.direction,
            arrivalTime: eta,
            isBus: false,
            nextArrivals: nextArrivals
        )
    }

    /// Stops tracking and clears widget tracking.
    func stopTracking() {
        currentTrackedRoute = nil
        // Clear tracked route from widget
        TrackedRoute.clear()
        WidgetCenter.shared.reloadAllTimelines()

        // End Live Activity
        LiveActivityManager.shared.endActivity()
    }

    // MARK: - GO Mode Forwarding (methods)

    func activateGoMode(routeName: String, routeColor: Color) {
        goMode.activateGoMode(routeName: routeName, routeColor: routeColor)
    }

    func deactivateGoMode() {
        goMode.deactivateGoMode()
    }

    func markStopPassed(_ stopId: String) {
        goMode.markStopPassed(stopId)
    }

    func isStopPassed(_ stop: BusStop) -> Bool {
        goMode.isStopPassed(stop)
    }

    func updatePassedStops(userLocation: CLLocation?) {
        goMode.updatePassedStops(userLocation: userLocation, routeShape: routeShape)
    }

    func fetchTransitETA(
        from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D
    ) async {
        await goMode.fetchTransitETA(from: source, to: destination)
    }

    func fetchWalkingRoute(
        from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D
    ) async {
        await goMode.fetchWalkingRoute(from: source, to: destination)
    }

    // MARK: - Route Selection Sync

    /// Syncs the currently selected route (RouteDetailSheet) with the latest data
    /// fetched from a refresh, ensuring the sheet shows live updates.
    private func updateSelectedRouteFromRefreshedData(_ newGroups: [GroupedNearbyTransitResponse]) {
        guard let current = selectedGroupedRoute else { return }

        // Find the updated group that matches the current route ID
        if let match = newGroups.first(where: { $0.routeId == current.routeId }) {
            // Must update on MainActor since it publishes changes
            Task { @MainActor in
                self.selectedGroupedRoute = match
                // Re-apply shape-based direction ordering so direction indices
                // stay consistent with the route shape (and selectedStopId).
                // Without this, fresh nearby data can scramble direction order,
                // causing the stop-filtering in RouteDetailSheet to compare
                // arrivals from the wrong direction against selectedStopId.
                if let shape = self.routeShape {
                    self.enrichGroupWithShapeDirections(shape)
                }
                AppLogger.shared.log("SYNC", message: "Updated selected route: \(match.routeId)")
                #if DEBUG
                if let selected = self.selectedGroupedRoute {
                    AppLogger.shared.log(
                        "SYNC",
                        message:
                            "Persist route=\(selected.routeId) mode=\(selected.mode) selectedDirIdx=\(self.selectedDirectionIndex) snapshot=\(self.debugDirectionSnapshot(selected))"
                    )
                }
                #endif
            }
        }
    }

    private func debugDirectionSnapshot(_ group: GroupedNearbyTransitResponse) -> String {
        group.directions.enumerated().map { index, direction in
            "#\(index):\(direction.direction){all:\(direction.arrivals.count),live:\(direction.liveArrivals.count)}"
        }.joined(separator: " | ")
    }

    // MARK: - Deep Link

    /// Finds the matching `GroupedNearbyTransitResponse` for the currently tracked
    /// route. Returns `nil` if no match is found (data not loaded yet, etc.).
    func groupForTrackedRoute() -> (group: GroupedNearbyTransitResponse, directionIndex: Int)? {
        guard let tracked = currentTrackedRoute ?? TrackedRoute.load() else { return nil }

        // Match by routeId first
        guard let group = groupedTransit.first(where: { $0.routeId == tracked.routeId }) else {
            return nil
        }

        // Find the direction index that matches the tracked destination/direction
        let dirIndex = group.directions.firstIndex(where: { dir in
            dir.direction == tracked.direction
                || dir.direction == tracked.destination
        }) ?? 0

        return (group, dirIndex)
    }
}
