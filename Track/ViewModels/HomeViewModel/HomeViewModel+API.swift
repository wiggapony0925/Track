//
//  HomeViewModel+API.swift
//  Track
//
//  Route selection, vehicle refresh, nearby transit, and tracking methods
//  extracted from HomeViewModel. All API calls and data loading live here.
//  Note: busSchedule and cachedTrainArrivals stored properties live in
//  HomeViewModel.swift so @Observable can instrument them.
//

import CoreLocation
import Foundation
import SwiftData
import MapKit
import SwiftUI
import WidgetKit

extension HomeViewModel {

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
        // Track whether any vehicle actually moved enough to warrant a
        // MapKit annotation diff. Replacing busVehicles every tick even
        // when positions haven't changed causes @Observable to broadcast
        // a change, forcing the Map to re-diff all bus Annotation views.
        var anyMoved = false
        let moveThreshold: CLLocationDistance = 2.0  // metres — sub-pixel at normal zoom
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
            // Only flag a move when the interpolated position has actually
            // shifted far enough to be visible on screen.
            let currentLoc = CLLocation(latitude: updated[i].lat, longitude: updated[i].lon)
            let newLoc = CLLocation(
                latitude: result.coordinate.latitude, longitude: result.coordinate.longitude)
            if newLoc.distance(from: currentLoc) >= moveThreshold {
                // Update the vehicle's display position via a mutable copy
                // (BusVehicleResponse is a struct, so this is a value-type update)
                updated[i] = updated[i].withInterpolatedPosition(
                    lat: result.coordinate.latitude,
                    lon: result.coordinate.longitude,
                    bearing: result.bearing
                )
                anyMoved = true
            }
            // Always record for ETA engine regardless of render update
            ArrivalETAEngine.recordPosition(
                vehicleKey: updated[i].vehicleId,
                coordinate: result.coordinate)
        }
        // Skip the whole-array assignment (and its @Observable broadcast +
        // MapKit annotation diff) when nothing moved visibly.
        guard anyMoved else { return }
        withAnimation(.linear(duration: 1.0)) {
            self.busVehicles = updated
        }
    }

    /// Solves for "Ghost Trains" by interpolating position between stations
    /// along the actual route polyline for realistic curved movement.
    /// Builds vehicles from ALL directions (not just the selected one) so
    /// `filteredTrainVehicles` can properly filter them.
    func updateTrainPositions(arrivals: [TrainArrival]) {
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

    func refreshSubway(location: CLLocation?) async {
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

    func refreshBus(location: CLLocation?) async {
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

    func refreshLIRR(location: CLLocation?) async {
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

    func refreshMNR(location: CLLocation?) async {
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

    func debugDirectionSnapshot(_ group: GroupedNearbyTransitResponse) -> String {
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
