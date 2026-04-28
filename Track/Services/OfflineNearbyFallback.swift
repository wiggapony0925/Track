//
//  OfflineNearbyFallback.swift
//  Track
//
//  Synthesizes [GroupedNearbyTransitResponse] from the on-device
//  LocalGTFSBundle when the network is unreachable.  The synthesized
//  groups carry placeholder arrivals only — minutesAway = 99,
//  no arrivalTs, no vehicleId — so they pass `isPlaceholder` checks
//  and the UI degrades gracefully:
//
//      • route badges + colors render correctly
//      • direction tabs appear (one per direction observed locally)
//      • no spurious "Now" or "Late 3m" indicators
//      • liveArrivals is empty → live tracking UX disables itself
//
//  This is the data engine for the user mandate "the only thing that
//  needs network is live tracking".
//

import Foundation
import CoreLocation

enum OfflineNearbyFallback {
    /// Synthesize nearby groups from the on-device bundle.
    ///
    /// **Threading**: this runs SQLite queries that can take 30-150 ms
    /// on an 8 km radius in NYC.  Callers MUST hop off the main actor
    /// before invoking this — otherwise drag-search bounces and stutters
    /// because every settle event blocks the UI thread.  The required
    /// `bundle` argument exists so callers grab the reference on
    /// MainActor (cheap) then dispatch the heavy work to a background
    /// task.
    nonisolated static func synthesize(
        lat: Double,
        lon: Double,
        radiusMeters: Double = 800,
        mode: String? = nil,
        bundle: LocalGTFSBundle
    ) -> [GroupedNearbyTransitResponse]? {

        let radii = searchRadii(startingAt: radiusMeters)
        for radius in radii {
            if let result = synthesizeOnce(
                lat: lat,
                lon: lon,
                radiusMeters: radius,
                mode: mode,
                bundle: bundle
            ), !result.isEmpty {
                return result
            }
        }
        return []
    }

    private nonisolated static func synthesizeOnce(
        lat: Double,
        lon: Double,
        radiusMeters: Double,
        mode: String?,
        bundle: LocalGTFSBundle
    ) -> [GroupedNearbyTransitResponse]? {

        let bbox = boundingBox(lat: lat, lon: lon, radiusMeters: radiusMeters)
        let modeFilter: Set<String>? = mode.map { Set([normalizeMode($0)]) }

        // Pull a generous working set from the R*Tree.  An 8 km radius in
        // NYC covers ~6 000 stops, so a small LIMIT here would silently
        // truncate the nearest bus stops (R*Tree returns rows in
        // insertion order, not by distance), leaving "near you" empty
        // while a few far-away subway stations survive.  We pull up to
        // 10 000 candidates then haversine-filter to the actual radius.
        let bboxStops = bundle.stops(
            inBbox: bbox.minLat, maxLat: bbox.maxLat,
            minLon: bbox.minLon, maxLon: bbox.maxLon,
            modes: modeFilter,
            limit: 10_000
        )
        guard !bboxStops.isEmpty else { return [] }

        // Haversine-filter to the true circular radius and keep only the
        // closest 1 500 stops (more than enough for any real radius —
        // even Manhattan in 8 km has ~3 k bus + ~200 subway platforms,
        // all of which fit, but we cap to keep the route-join cheap).
        var measured: [(stop: LocalStop, dist: Double)] = []
        measured.reserveCapacity(bboxStops.count)
        for stop in bboxStops {
            let d = haversineMeters(
                lat1: lat, lon1: lon, lat2: stop.latitude, lon2: stop.longitude
            )
            if d <= radiusMeters {
                measured.append((stop, d))
            }
        }
        guard !measured.isEmpty else { return [] }
        measured.sort { $0.dist < $1.dist }
        if measured.count > 1_500 {
            measured = Array(measured.prefix(1_500))
        }
        let stops = measured.map(\.stop)
        let distances: [String: Double] = measured.reduce(into: [:]) { acc, m in
            acc[m.stop.stopID] = m.dist
        }

        let routesByStop = bundle.routes(forStops: stops.map(\.stopID))

        struct Acc { var route: LocalRoute; var stops: [LocalStop]; var minDist: Double }
        var byRoute: [String: Acc] = [:]
        for stop in stops {
            guard let routes = routesByStop[stop.stopID] else { continue }
            let dist = distances[stop.stopID] ?? .infinity
            for route in routes {
                if var existing = byRoute[route.routeID] {
                    existing.stops.append(stop)
                    if dist < existing.minDist { existing.minDist = dist }
                    byRoute[route.routeID] = existing
                } else {
                    byRoute[route.routeID] = Acc(
                        route: route, stops: [stop], minDist: dist
                    )
                }
            }
        }

        return byRoute.values
            .sorted { $0.minDist < $1.minDist }
            .map { acc in
                buildGroup(
                    route: acc.route,
                    stops: acc.stops,
                    distances: distances,
                    bundle: bundle
                )
            }
    }

    // MARK: - Helpers

    nonisolated private static func searchRadii(startingAt radiusMeters: Double) -> [Double] {
        let base = max(300, radiusMeters)
        var radii: [Double] = []
        var seen = Set<Int>()
        for radius in [base, base * 1.75, base * 3.0, 2_500, 5_000, 8_000] {
            let rounded = Int(radius.rounded())
            if seen.insert(rounded).inserted {
                radii.append(Double(rounded))
            }
        }
        return radii.sorted()
    }

    nonisolated private static func boundingBox(
        lat: Double, lon: Double, radiusMeters: Double
    ) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        let degLat = radiusMeters / 111_320.0
        let degLon = radiusMeters / (111_320.0 * max(cos(lat * .pi / 180), 0.01))
        return (lat - degLat, lat + degLat, lon - degLon, lon + degLon)
    }

    nonisolated private static func haversineMeters(
        lat1: Double, lon1: Double, lat2: Double, lon2: Double
    ) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
            * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    nonisolated private static func normalizeMode(_ raw: String) -> String {
        switch raw.lowercased() {
        case "subway", "bus", "lirr", "mnr", "ferry", "rail":
            return raw.lowercased()
        case "commuter", "commuter_rail", "commuterrail":
            return "rail"
        default:
            return raw.lowercased()
        }
    }

    nonisolated private static func buildGroup(
        route: LocalRoute,
        stops: [LocalStop],
        distances: [String: Double],
        bundle: LocalGTFSBundle
    ) -> GroupedNearbyTransitResponse {
        let routeStops = bundle.routeStops(routeID: route.routeID)
        let estimated = bundle.expectedWaitMinutes(routeID: route.routeID)
        let directions = buildLocalDirections(
            route: route,
            nearbyStops: stops,
            distances: distances,
            routeStops: routeStops,
            estimatedWaitMinutes: estimated
        )

        return GroupedNearbyTransitResponse(
            routeId: route.routeID,
            displayName: displayName(for: route),
            mode: route.mode,
            colorHex: route.colorHex,
            directions: directions,
            sortingKey: route.routeID,
            alerts: [],
            expressRoutes: [],
            busServiceType: busServiceType(for: route)
        )
    }

    nonisolated static func buildLocalDirections(
        route: LocalRoute,
        nearbyStops: [LocalStop],
        distances: [String: Double],
        routeStops: [LocalRouteStop],
        estimatedWaitMinutes: Int?,
        now: Date = Date.now
    ) -> [DirectionArrivalsResponse] {
        guard let closest = nearbyStops.min(by: {
            (distances[$0.stopID] ?? .infinity) < (distances[$1.stopID] ?? .infinity)
        }) else { return [] }

        let nearbyStopIds = Set(nearbyStops.map(\.stopID))
        let nearbyRouteStops = routeStops.filter { nearbyStopIds.contains($0.stop.stopID) }
        let allStopsByDirection = Dictionary(grouping: routeStops, by: \.directionID)
            .mapValues { entries in entries.map(\.stop) }
        let directionalStops = nearbyRouteStops.isEmpty
            ? [nil: nearbyStops]
            : Dictionary(grouping: nearbyRouteStops, by: \.directionID)
                .mapValues { entries in entries.map(\.stop) }

        let sortedKeys = directionalStops.keys.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case let (.some(left), .some(right)): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
            }
        }

        let directions = sortedKeys.compactMap { directionID -> DirectionArrivalsResponse? in
            let stopsForDirection = directionalStops[directionID] ?? []
            let directionClosest = stopsForDirection.min {
                (distances[$0.stopID] ?? .infinity) < (distances[$1.stopID] ?? .infinity)
            } ?? closest
            let terminal = terminalStop(
                from: allStopsByDirection[directionID] ?? stopsForDirection,
                relativeTo: directionClosest
            )
            return buildLocalDirection(
                route: route,
                closest: directionClosest,
                terminal: terminal,
                distance: distances[directionClosest.stopID],
                directionID: directionID,
                totalDirections: sortedKeys.count,
                estimatedWaitMinutes: estimatedWaitMinutes,
                now: now
            )
        }

        if directions.isEmpty {
            return [buildLocalDirection(
                route: route,
                closest: closest,
                terminal: nil,
                distance: distances[closest.stopID],
                directionID: nil,
                totalDirections: 1,
                estimatedWaitMinutes: estimatedWaitMinutes,
                now: now
            )]
        }
        return directions
    }

    nonisolated private static func buildLocalDirection(
        route: LocalRoute,
        closest: LocalStop,
        terminal: LocalStop?,
        distance: Double?,
        directionID: Int?,
        totalDirections: Int,
        estimatedWaitMinutes: Int?,
        now: Date
    ) -> DirectionArrivalsResponse {
        // Use the local headway table only as a static/scheduled estimate.
        // It is not live vehicle data, so provide an arrival timestamp and
        // keep `isRealTime=false`; the row will render a muted "Sched" pill
        // until the live backend response replaces this optimistic result.
        let minutesAway = estimatedWaitMinutes ?? 99
        let arrivalTs = estimatedWaitMinutes.map {
            Int(now.addingTimeInterval(TimeInterval($0 * 60)).timeIntervalSince1970)
        }
        let directionName = localDirectionLabel(
            route: route,
            closest: closest,
            terminal: terminal,
            directionID: directionID,
            totalDirections: totalDirections
        )

        let placeholder = NearbyTransitResponse(
            routeId: route.routeID,
            stopName: closest.name,
            direction: directionName,
            destination: directionName,
            minutesAway: minutesAway,
            status: estimatedWaitMinutes == nil ? "No Data" : "Scheduled",
            mode: route.mode,
            stopLat: closest.latitude,
            stopLon: closest.longitude,
            arrivalTs: arrivalTs,
            vehicleId: nil,
            tripId: nil,
            stopId: closest.stopID,
            distanceM: distance,
            isRealTime: false,
            colorHex: route.colorHex,
            busServiceType: busServiceType(for: route)
        )

        let direction = DirectionArrivalsResponse(
            direction: directionName,
            directionLabel: directionName,
            directionId: directionID.map(String.init),
            branchId: nil,
            arrivals: [placeholder]
        )
        return direction
    }

    nonisolated private static func displayName(for route: LocalRoute) -> String {
        switch route.mode.lowercased() {
        case "lirr", "mnr":
            return BranchNames.resolveDisplayName(routeId: route.routeID, mode: route.mode)
        default:
            return route.shortName?.nonEmpty
                ?? route.longName?.nonEmpty
                ?? stripMTAPrefix(route.routeID)
        }
    }

    nonisolated private static func localDirectionLabel(
        route: LocalRoute,
        closest: LocalStop,
        terminal: LocalStop?,
        directionID: Int?,
        totalDirections: Int
    ) -> String {
        if let terminalName = terminal?.name.nonEmpty,
           normalizeStopName(terminalName) != normalizeStopName(closest.name) {
            return "To \(terminalName)"
        }

        if let directionID, totalDirections > 1 {
            let key = "DIRECTION \(directionID)"
            if let label = DirectionConstants.labels[key] {
                return label
            }
            return "Branch \(directionID)"
        }

        switch route.mode.lowercased() {
        case "bus":
            return "Nearby stops"
        default:
            return closest.name.nonEmpty ?? "Nearby stops"
        }
    }

    nonisolated private static func terminalStop(
        from stops: [LocalStop],
        relativeTo closest: LocalStop
    ) -> LocalStop? {
        let candidates = deduplicatedStops(stops).filter {
            normalizeStopName($0.name) != normalizeStopName(closest.name)
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            distanceMeters(from: closest, to: lhs) < distanceMeters(from: closest, to: rhs)
        }
    }

    nonisolated private static func deduplicatedStops(_ stops: [LocalStop]) -> [LocalStop] {
        var seen = Set<String>()
        var result: [LocalStop] = []
        for stop in stops {
            let key = stop.stopID.nonEmpty ?? normalizeStopName(stop.name)
            guard seen.insert(key).inserted else { continue }
            result.append(stop)
        }
        return result
    }

    nonisolated private static func distanceMeters(from lhs: LocalStop, to rhs: LocalStop) -> Double {
        haversineMeters(
            lat1: lhs.latitude,
            lon1: lhs.longitude,
            lat2: rhs.latitude,
            lon2: rhs.longitude
        )
    }

    nonisolated private static func normalizeStopName(_ value: String) -> String {
        value.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    nonisolated private static func busServiceType(for route: LocalRoute) -> String? {
        guard route.mode.lowercased() == "bus" else { return nil }
        let upper = (route.shortName ?? route.routeID).uppercased()
        if upper.contains("SBS") || upper.hasSuffix("+") { return "Select Bus Service" }
        if upper.hasPrefix("BXM") || upper.hasPrefix("BM")
            || upper.hasPrefix("QM") || upper.hasPrefix("SIM")
            || upper.hasPrefix("X") { return "Express" }
        return "Local"
    }
}

private extension String {
    nonisolated var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
