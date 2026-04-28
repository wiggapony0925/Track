import CoreLocation
import Foundation

enum LocalRouteShapeProvider {
    @MainActor
    static func shape(for group: GroupedNearbyTransitResponse) -> RouteShapeResponse? {
        if group.mode == "subway", let subwayShape = subwayShape(for: group) {
            return subwayShape
        }

        guard let bundle = GTFSBundleManager.shared.bootstrap() else { return nil }
        return sqliteShape(for: group, bundle: bundle)
    }

    static func isStopDerivedShape(_ shape: RouteShapeResponse) -> Bool {
        guard !shape.directions.isEmpty else { return false }
        return shape.directions.allSatisfy { direction in
            if direction.polylines.isEmpty, !direction.stops.isEmpty {
                return true
            }
            guard direction.polylines.count == 1,
                  let polyline = direction.decodedPolylines.first,
                  polyline.count == direction.stops.count,
                  polyline.count >= 2
            else { return false }

            return zip(polyline, direction.stops).allSatisfy { coordinate, stop in
                abs(coordinate.latitude - stop.lat) < 0.00001
                    && abs(coordinate.longitude - stop.lon) < 0.00001
            }
        }
    }

    private static func subwayShape(for group: GroupedNearbyTransitResponse) -> RouteShapeResponse? {
        let routeID = stripMTAPrefix(group.displayName).uppercased()
        let bundle = SubwayRoutesData.loadBundle()
        let branches = bundle.routes.branches(for: routeID)
        guard !branches.isEmpty else { return nil }

        let decodedBranches = branches
            .map { branch in
                branch.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                }
            }
            .filter { $0.count >= 2 }
        let polylines = decodedBranches
            .map(encodePolyline)

        let stops = bundle.stops
            .filter { stop in
                stop.routes?.contains(where: {
                    stripMTAPrefix($0).caseInsensitiveCompare(routeID) == .orderedSame
                }) == true
            }
            .map { stop in
                BusStop(
                    id: stop.id,
                    name: stop.name,
                    lat: stop.lat,
                    lon: stop.lon,
                    direction: nil,
                    routeIds: [routeID]
                )
            }

        let directions = subwayDirections(
            stops: stops,
            branches: decodedBranches,
            polylines: polylines
        )

        return RouteShapeResponse(
            routeId: routeID,
            polylines: polylines,
            stops: stops,
            directions: directions,
            serviceType: nil
        )
    }

    private static func sqliteShape(
        for group: GroupedNearbyTransitResponse,
        bundle: LocalGTFSBundle
    ) -> RouteShapeResponse? {
        let routeStops = bundle.routeStops(routeID: group.routeId)
        guard !routeStops.isEmpty else { return nil }

        let route = routeStops[0].route
        let grouped = Dictionary(grouping: routeStops) { $0.directionID ?? 0 }
        let directions = grouped.keys.sorted().compactMap { directionID -> DirectionShapeResponse? in
            let stops = orderedStops(grouped[directionID] ?? [], directionID: directionID)
            guard !stops.isEmpty else { return nil }
            let busStops = stops.map { localStop in
                BusStop(
                    id: localStop.stopID,
                    name: localStop.name,
                    lat: localStop.latitude,
                    lon: localStop.longitude,
                    direction: String(directionID),
                    routeIds: [route.routeID]
                )
            }
            let polyline: [String]
            if group.isBus {
                polyline = []
            } else {
                polyline = busStops.count >= 2
                    ? [encodePolyline(busStops.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    })]
                    : []
            }
            return DirectionShapeResponse(
                directionId: directionID,
                headsign: headsign(for: busStops, directionID: directionID),
                polylines: polyline,
                stops: busStops,
                serviceType: serviceType(for: group, route: route)
            )
        }
        guard !directions.isEmpty else { return nil }

        var seenStops = Set<String>()
        let allStops = directions.flatMap(\.stops).filter { stop in
            seenStops.insert(stop.id).inserted
        }
        let allPolylines = directions.flatMap(\.polylines)

        return RouteShapeResponse(
            routeId: route.routeID,
            polylines: allPolylines,
            stops: allStops,
            directions: directions,
            serviceType: serviceType(for: group, route: route)
        )
    }

    private static func subwayDirections(
        stops: [BusStop],
        branches: [[CLLocationCoordinate2D]],
        polylines: [String]
    ) -> [DirectionShapeResponse] {
        let firstBranch = branches.first ?? []
        let outbound = firstBranch.last.flatMap { nearestStop(to: $0, in: stops) }?.name
        let inbound = firstBranch.first.flatMap { nearestStop(to: $0, in: stops) }?.name

        return [0, 1].map { directionID in
            let terminal = directionID == 0 ? outbound : inbound
            return DirectionShapeResponse(
                directionId: directionID,
                headsign: terminal.map { "To \($0)" } ?? "Direction \(directionID)",
                polylines: polylines,
                stops: stops,
                serviceType: nil
            )
        }
    }

    private static func orderedStops(
        _ routeStops: [LocalRouteStop],
        directionID: Int
    ) -> [LocalStop] {
        var seen = Set<String>()
        let stops = routeStops.map(\.stop).filter { seen.insert($0.stopID).inserted }
        guard stops.count > 2 else { return stops }

        let minLat = stops.map(\.latitude).min() ?? 0
        let maxLat = stops.map(\.latitude).max() ?? 0
        let minLon = stops.map(\.longitude).min() ?? 0
        let maxLon = stops.map(\.longitude).max() ?? 0
        let sortByLongitude = (maxLon - minLon) >= (maxLat - minLat)

        let sorted = stops.sorted { left, right in
            if sortByLongitude, left.longitude != right.longitude {
                return left.longitude < right.longitude
            }
            if left.latitude != right.latitude { return left.latitude < right.latitude }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        return directionID == 1 ? Array(sorted.reversed()) : sorted
    }

    private static func headsign(
        for stops: [BusStop],
        directionID: Int
    ) -> String {
        guard let terminal = stops.last?.name, !terminal.isEmpty else {
            return "Direction \(directionID)"
        }
        return "To \(terminal)"
    }

    private static func nearestStop(
        to coordinate: CLLocationCoordinate2D,
        in stops: [BusStop]
    ) -> BusStop? {
        stops.min { left, right in
            squaredDistance(from: coordinate, to: left) < squaredDistance(from: coordinate, to: right)
        }
    }

    private static func squaredDistance(
        from coordinate: CLLocationCoordinate2D,
        to stop: BusStop
    ) -> Double {
        let dLat = coordinate.latitude - stop.lat
        let dLon = coordinate.longitude - stop.lon
        return dLat * dLat + dLon * dLon
    }

    private static func serviceType(
        for group: GroupedNearbyTransitResponse,
        route: LocalRoute
    ) -> String? {
        if let busServiceType = group.busServiceType { return busServiceType.lowercased() }
        guard group.isBus else { return nil }
        let upper = (route.shortName ?? route.routeID).uppercased()
        if upper.contains("SBS") || upper.hasSuffix("+") { return "select" }
        if upper.hasPrefix("BXM") || upper.hasPrefix("BM")
            || upper.hasPrefix("QM") || upper.hasPrefix("SIM")
            || upper.hasPrefix("X") { return "express" }
        return "local"
    }
}