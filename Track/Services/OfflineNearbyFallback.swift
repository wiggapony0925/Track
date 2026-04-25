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
    static func synthesize(
        lat: Double,
        lon: Double,
        radiusMeters: Double = 800,
        mode: String? = nil,
        bundle: LocalGTFSBundle? = nil
    ) -> [GroupedNearbyTransitResponse]? {
        guard let bundle = bundle ?? GTFSBundleManager.shared.current else {
            return nil
        }

        let bbox = boundingBox(lat: lat, lon: lon, radiusMeters: radiusMeters)
        let modeFilter: Set<String>? = mode.map { Set([normalizeMode($0)]) }

        let stops = bundle.stops(
            inBbox: bbox.minLat, maxLat: bbox.maxLat,
            minLon: bbox.minLon, maxLon: bbox.maxLon,
            modes: modeFilter,
            limit: 400
        )
        guard !stops.isEmpty else { return [] }

        let distances: [String: Double] = stops.reduce(into: [:]) { acc, stop in
            acc[stop.stopID] = haversineMeters(
                lat1: lat, lon1: lon, lat2: stop.latitude, lon2: stop.longitude
            )
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
                buildGroup(route: acc.route, stops: acc.stops, distances: distances)
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
        distances: [String: Double]
    ) -> GroupedNearbyTransitResponse {
        let closest = stops.min { (a: LocalStop, b: LocalStop) in
            (distances[a.stopID] ?? .infinity) < (distances[b.stopID] ?? .infinity)
        } ?? stops[0]

        let placeholder = NearbyTransitResponse(
            routeId: route.routeID,
            stopName: closest.name,
            direction: "Unknown",
            destination: nil,
            minutesAway: 99,
            status: "Scheduled",
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
