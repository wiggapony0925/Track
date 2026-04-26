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

    private static func boundingBox(
        lat: Double, lon: Double, radiusMeters: Double
    ) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        let degLat = radiusMeters / 111_320.0
        let degLon = radiusMeters / (111_320.0 * max(cos(lat * .pi / 180), 0.01))
        return (lat - degLat, lat + degLat, lon - degLon, lon + degLon)
    }

    private static func haversineMeters(
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

    private static func normalizeMode(_ raw: String) -> String {
        switch raw.lowercased() {
        case "subway", "bus", "lirr", "mnr", "ferry", "rail":
            return raw.lowercased()
        case "commuter", "commuter_rail", "commuterrail":
            return "rail"
        default:
            return raw.lowercased()
        }
    }

    private static func buildGroup(
        route: LocalRoute,
        stops: [LocalStop],
        distances: [String: Double],
        bundle: LocalGTFSBundle
    ) -> GroupedNearbyTransitResponse {
        let closest = stops.min { (a: LocalStop, b: LocalStop) in
            (distances[a.stopID] ?? .infinity) < (distances[b.stopID] ?? .infinity)
        } ?? stops[0]

        // Phase D: prefer a real headway-based estimate from the bundle's
        // route_headways table.  Falls back to the 99-minute placeholder
        // only when no schedule data exists for the current bucket
        // (overnight gap, suspended service, unknown route).
        let estimated = bundle.expectedWaitMinutes(routeID: route.routeID) ?? 99
        let status = estimated < 99 ? "Scheduled" : "No Data"

        let placeholder = NearbyTransitResponse(
            routeId: route.routeID,
            stopName: closest.name,
            direction: "Unknown",
            destination: nil,
            minutesAway: estimated,
            status: status,
            mode: route.mode,
            stopLat: closest.latitude,
            stopLon: closest.longitude,
            arrivalTs: nil,
            vehicleId: nil,
            tripId: nil,
            stopId: closest.stopID,
            distanceM: distances[closest.stopID]
        )

        let direction = DirectionArrivalsResponse(
            direction: "Unknown",
            directionLabel: nil,
            directionId: nil,
            branchId: nil,
            arrivals: [placeholder]
        )

        return GroupedNearbyTransitResponse(
            routeId: route.routeID,
            displayName: route.shortName ?? route.longName ?? route.routeID,
            mode: route.mode,
            colorHex: route.colorHex,
            directions: [direction],
            sortingKey: route.routeID,
            alerts: [],
            expressRoutes: [],
            busServiceType: nil
        )
    }
}
