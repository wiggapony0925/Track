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

    static func hasRenderableGeometry(_ shape: RouteShapeResponse) -> Bool {
        guard !isStopDerivedShape(shape) else { return false }
        if shape.decodedPolylines.contains(where: { $0.count >= 2 }) {
            return true
        }
        return shape.directions.contains { direction in
            direction.decodedPolylines.contains { $0.count >= 2 }
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

        var seenStopIds = Set<String>()
        var stops = bundle.stops
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

        seenStopIds.formUnion(stops.map(\.id))
        if let gtfsBundle = GTFSBundleManager.shared.bootstrap() {
            let routeStops = gtfsBundle.routeStops(routeID: routeID)
            let groupedStops = Dictionary(grouping: routeStops) { $0.directionID ?? 0 }
            let supplementalStops = groupedStops.keys.sorted().flatMap { directionID in
                orderedStops(groupedStops[directionID] ?? [], directionID: directionID)
            }
            for localStop in supplementalStops where seenStopIds.insert(localStop.stopID).inserted {
                stops.append(
                    BusStop(
                        id: localStop.stopID,
                        name: localStop.name,
                        lat: localStop.latitude,
                        lon: localStop.longitude,
                        direction: nil,
                        routeIds: [routeID]
                    )
                )
            }
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
        let orderedStops = orderedStopsAlongBranches(stops, branches: branches)
        let reversedStops = Array(orderedStops.reversed())
        let reversedPolylines = branches
            .map { Array($0.reversed()) }
            .filter { $0.count >= 2 }
            .map(encodePolyline)

        return [
            DirectionShapeResponse(
                directionId: 0,
                headsign: orderedStops.last.map { "To \($0.name)" } ?? "Outbound",
                polylines: polylines,
                stops: orderedStops,
                serviceType: nil
            ),
            DirectionShapeResponse(
                directionId: 1,
                headsign: reversedStops.last.map { "To \($0.name)" } ?? "Inbound",
                polylines: reversedPolylines,
                stops: reversedStops,
                serviceType: nil
            )
        ]
    }

    private static func orderedStopsAlongBranches(
        _ stops: [BusStop],
        branches: [[CLLocationCoordinate2D]]
    ) -> [BusStop] {
        guard !stops.isEmpty, !branches.isEmpty else { return stops }

        struct ScoredStop {
            let stop: BusStop
            let branchIndex: Int
            let fraction: Double
            let distance: CLLocationDistance
        }

        let scored = stops.map { stop -> ScoredStop in
            let coordinate = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
            var bestBranch = 0
            var bestFraction = 0.0
            var bestDistance = CLLocationDistance.greatestFiniteMagnitude

            for (branchIndex, branch) in branches.enumerated() where branch.count >= 2 {
                guard let snap = snapFraction(coordinate, to: branch) else { continue }
                if snap.distance < bestDistance {
                    bestBranch = branchIndex
                    bestFraction = snap.fraction
                    bestDistance = snap.distance
                }
            }

            return ScoredStop(
                stop: stop,
                branchIndex: bestBranch,
                fraction: bestFraction,
                distance: bestDistance
            )
        }

        return scored.sorted { left, right in
            if left.branchIndex != right.branchIndex {
                return left.branchIndex < right.branchIndex
            }
            if abs(left.fraction - right.fraction) > 0.000001 {
                return left.fraction < right.fraction
            }
            if abs(left.distance - right.distance) > 0.5 {
                return left.distance < right.distance
            }
            return left.stop.name.localizedStandardCompare(right.stop.name) == .orderedAscending
        }.map(\.stop)
    }

    private static func snapFraction(
        _ coordinate: CLLocationCoordinate2D,
        to polyline: [CLLocationCoordinate2D]
    ) -> (fraction: Double, distance: CLLocationDistance)? {
        guard polyline.count >= 2 else { return nil }

        let source = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var totalLength = CLLocationDistance(0)
        var segmentLengths: [CLLocationDistance] = []
        segmentLengths.reserveCapacity(polyline.count - 1)
        for i in 0..<(polyline.count - 1) {
            let length = CLLocation(
                latitude: polyline[i].latitude,
                longitude: polyline[i].longitude
            ).distance(from: CLLocation(
                latitude: polyline[i + 1].latitude,
                longitude: polyline[i + 1].longitude
            ))
            segmentLengths.append(length)
            totalLength += length
        }
        guard totalLength > 0 else { return nil }

        var distanceBeforeSegment = CLLocationDistance(0)
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        var bestDistanceAlong = CLLocationDistance(0)
        for i in 0..<(polyline.count - 1) {
            let projected = projectPoint(coordinate, ontoSegmentFrom: polyline[i], to: polyline[i + 1])
            let projectedLocation = CLLocation(
                latitude: projected.coordinate.latitude,
                longitude: projected.coordinate.longitude
            )
            let distance = source.distance(from: projectedLocation)
            if distance < bestDistance {
                bestDistance = distance
                bestDistanceAlong = distanceBeforeSegment + segmentLengths[i] * projected.fraction
            }
            distanceBeforeSegment += segmentLengths[i]
        }

        return (fraction: bestDistanceAlong / totalLength, distance: bestDistance)
    }

    private static func projectPoint(
        _ point: CLLocationCoordinate2D,
        ontoSegmentFrom a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> (coordinate: CLLocationCoordinate2D, fraction: Double) {
        let dx = b.longitude - a.longitude
        let dy = b.latitude - a.latitude
        let lenSq = dx * dx + dy * dy
        guard lenSq >= 1e-18 else { return (a, 0) }

        let raw = ((point.longitude - a.longitude) * dx + (point.latitude - a.latitude) * dy) / lenSq
        let fraction = min(max(raw, 0), 1)
        return (
            CLLocationCoordinate2D(
                latitude: a.latitude + fraction * dy,
                longitude: a.longitude + fraction * dx
            ),
            fraction
        )
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
            return directionID == 0 ? "Outbound" : "Inbound"
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