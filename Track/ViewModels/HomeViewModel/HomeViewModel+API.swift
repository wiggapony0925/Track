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
    ///
    /// CRITICAL: Updates `busVehicles` and `selectedGroupedRoute` in a single
    /// MainActor dispatch so that `isVehicleLiveOnMap` never sees a mismatch
    /// between the vehicle list and the arrival data — eliminating the chip
    /// flicker between "On Route" and "Scheduled".
    ///
    /// NOTE: We do NOT replace `busVehicles` coordinates with the raw GPS
    /// response — that caused the snap-forward → jump-back flicker.  Instead
    /// we store the new GPS in `_targetBusGPS` and let `updateBusSimulation()`
    /// smoothly interpolate the display positions toward the targets each tick.
    func refreshBusVehicles() async {
        guard let routeId = selectedRouteId,
            selectedGroupedRoute?.isBus == true
        else { return }
        do {
            let vehicles = try await TrackAPI.fetchBusVehicles(routeID: routeId)

            // Staleness check: user may have dismissed the route while the
            // network request was in-flight.  Discard the result so we don't
            // overwrite the cleared state from clearRoute().
            guard selectedRouteId == routeId else { return }

            // Compute the synced group OFF the main thread.
            let updatedGroup = await buildSyncedBusGroup(vehicles)

            // Re-check after another await boundary.
            guard selectedRouteId == routeId else { return }

            // Apply atomically on MainActor.
            await MainActor.run {
                // Final staleness check inside the MainActor block.
                guard self.selectedRouteId == routeId else { return }
                let isFirstLoad = self.busVehicles.isEmpty

                // 1) Snapshot current DISPLAY positions as interpolation origins.
                for v in self.busVehicles {
                    self.previousBusPositions[v.vehicleId] = BusSnapshot(
                        lat: v.lat, lon: v.lon, timestamp: self.lastBusUpdateTime
                    )
                }

                // 2) Store new GPS as targets (simulation reads these).
                self._targetBusGPS = Dictionary(
                    vehicles.map { ($0.vehicleId, $0) },
                    uniquingKeysWith: { $1 }
                )
                self.lastBusUpdateTime = Date()

                // 3) Update the vehicle LIST (add/remove) without changing
                //    coordinates of existing vehicles. This keeps
                //    `isVehicleLiveOnMap` accurate while avoiding the snap.
                if isFirstLoad {
                    // First load: show at raw GPS — no previous position to lerp from.
                    self.busVehicles = vehicles
                    for v in vehicles {
                        self.previousBusPositions[v.vehicleId] = BusSnapshot(
                            lat: v.lat, lon: v.lon, timestamp: Date()
                        )
                    }
                } else {
                    let existingById = Dictionary(
                        self.busVehicles.map { ($0.vehicleId, $0) },
                        uniquingKeysWith: { $1 }
                    )
                    let newIds = Set(vehicles.map(\.vehicleId))
                    let now = Date()

                    var merged: [BusVehicleResponse] = []
                    // Keep existing vehicles at their current display positions
                    for v in self.busVehicles where newIds.contains(v.vehicleId) {
                        merged.append(v)
                    }
                    // Add brand-new vehicles at their raw GPS position
                    for v in vehicles where existingById[v.vehicleId] == nil {
                        merged.append(v)
                        self.previousBusPositions[v.vehicleId] = BusSnapshot(
                            lat: v.lat, lon: v.lon, timestamp: Date()
                        )
                    }

                    // Grace buffer: keep vehicles that vanished this poll for up to 12 s
                    // so the chip doesn't flicker from "On Route" to "Scheduled".
                    for v in self.busVehicles where !newIds.contains(v.vehicleId) {
                        if self._busGraceBuffer[v.vehicleId] == nil {
                            self._busGraceBuffer[v.vehicleId] = (vehicle: v, missedAt: now)
                        }
                    }
                    var expiredIds: [String] = []
                    for (vid, entry) in self._busGraceBuffer {
                        if newIds.contains(vid) {
                            expiredIds.append(vid)
                        } else if now.timeIntervalSince(entry.missedAt) > 12 {
                            expiredIds.append(vid)
                            self.previousBusPositions.removeValue(forKey: vid)
                            self._targetBusGPS.removeValue(forKey: vid)
                        } else {
                            merged.append(entry.vehicle)
                        }
                    }
                    for vid in expiredIds { self._busGraceBuffer.removeValue(forKey: vid) }

                    self.busVehicles = merged
                }

                if let updatedGroup,
                   self.selectedGroupedRoute?.routeId == updatedGroup.routeId {
                    self.selectedGroupedRoute = updatedGroup
                }
            }
        } catch {
            AppLogger.shared.logError("refreshBusVehicles(\(routeId))", error: error)
        }
    }

    /// Computes the synced bus group from live vehicle onwardCalls WITHOUT
    /// touching any @Published properties.  Returns the updated group, or nil
    /// if there were no onwardCalls to process.
    private func buildSyncedBusGroup(_ vehicles: [BusVehicleResponse]) async -> GroupedNearbyTransitResponse? {
        guard let currentGroup = await MainActor.run(body: { selectedGroupedRoute }) else { return nil }

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
                    status: vehicle.isRealtime ? call.statusText : "Scheduled",
                    mode: "bus",
                    stopLat: stopLat,
                    stopLon: stopLon,
                    arrivalTs: call.expectedArrival.map { Int($0.timeIntervalSince1970) } ?? 0,
                    vehicleId: vehicle.vehicleId,
                    tripId: nil,
                    stopId: call.stopId,
                    distanceM: dist,
                    isRealTime: vehicle.isRealtime
                )
                newArrivals.append(arrival)
            }
        }

        // If no OnwardCalls were found (e.g. all buses just started or API didn't return them),
        // fallback to keeping the existing list to avoid flashing empty.
        if newArrivals.isEmpty { return nil }

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
            // Keep ALL arrivals from all vehicles — multiple buses heading to
            // the same stop are genuinely distinct upcoming arrivals.  The
            // per-stop dedup here was collapsing 3+ chip arrivals to 1, which
            // caused the countdown chip strip to change drastically after the
            // first vehicle sync.  Downstream `nearestStopArrivals` already
            // deduplicates by vehicleId/tripId and sorts by ETA.
            let sorted = liveArrivals.sorted { $0.minutesAway < $1.minutesAway }

            // Preserve the old direction's SCHEDULED (non-realtime) arrivals
            // that came from the nearby API top-off.  SIRI onward calls only
            // carry live vehicle data, so without this merge the user loses
            // all scheduled arrivals when the first sync fires.  When they
            // then tap a different stop, only the one live bus shows up
            // instead of the full schedule for that stop.
            let oldScheduled = oldDir.arrivals.filter { !$0.isRealTime }
            // Avoid dupes: drop old scheduled entries whose stop already has
            // a live arrival from the same vehicle (meaning the bus went live).
            let liveVehicleIds = Set(sorted.compactMap(\.vehicleId))
            let filteredScheduled = oldScheduled.filter { sched in
                guard let vid = sched.vehicleId else { return true }
                return !liveVehicleIds.contains(vid)
            }

            let merged = sorted + filteredScheduled

            // Only replace if we got new arrivals; otherwise keep existing to avoid flashing empty
            if merged.isEmpty && !oldDir.arrivals.isEmpty {
                newDirections.append(oldDir)
            } else {
                newDirections.append(
                    DirectionArrivalsResponse(
                        direction: oldDir.direction,
                        directionLabel: oldDir.directionLabel,
                        arrivals: merged
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

        return updatedGroup
    }

    /// Refreshes only the vehicle positions for the currently selected subway route.
    ///
    /// CRITICAL: Updates `trainVehicles` (via `updateTrainPositions`) and
    /// `selectedGroupedRoute` atomically so that `isVehicleLiveOnMap` never
    /// sees a mismatch — eliminating the chip flicker.
    func refreshTrainVehicles() async {
        guard let routeId = selectedRouteId else { return }
        do {
            let arrivals = try await TrackAPI.fetchSubwayArrivals(lineID: routeId)

            // Staleness check: user may have dismissed while the fetch ran.
            guard selectedRouteId == routeId else { return }

            // Compute positions and synced group before publishing.
            let updatedGroup = await buildSyncedTrainGroup(arrivals)

            // Re-check after another await boundary.
            guard selectedRouteId == routeId else { return }

            // Apply all updates atomically on MainActor.
            // NOTE: No outer withAnimation — updateTrainPositions() applies
            // its own .linear(duration: 1.0). Double-wrapping caused stuttering.
            await MainActor.run {
                guard self.selectedRouteId == routeId else { return }
                updateTrainPositions(arrivals: arrivals)
                if let updatedGroup,
                   self.selectedGroupedRoute?.routeId == updatedGroup.routeId {
                    self.selectedGroupedRoute = updatedGroup
                }
            }
        } catch {
            // Silently ignore failures on fast poll, or log debug
        }
    }

    /// Refreshes vehicle positions for the currently selected LIRR or MNR route.
    /// Uses the same GTFS-RT arrivals → interpolation pipeline as subway.
    /// Atomic update: positions + group published together.
    func refreshCommuterRailVehicles() async {
        guard let group = selectedGroupedRoute,
            group.isCommuterRail
        else { return }
        let capturedRouteId = group.routeId
        do {
            let arrivals: [TrainArrival]
            if group.isLIRR {
                arrivals = try await TrackAPI.fetchLIRRArrivals()
            } else {
                arrivals = try await TrackAPI.fetchMNRArrivals()
            }

            // Staleness check after await.
            guard selectedRouteId == capturedRouteId else { return }

            // Filter to only this route's arrivals
            let routeArrivals = arrivals.filter { arrival in
                let id = arrival.routeID.lowercased()
                let target = group.routeId.lowercased()
                return id == target
                    || id == target.replacingOccurrences(of: "lirr_", with: "")
                    || id == target.replacingOccurrences(of: "mnr_", with: "")
                    || "lirr_\(id)" == target
                    || "mnr_\(id)" == target
            }

            let mode = group.isLIRR ? "lirr" : "mnr"
            let updatedGroup = await buildSyncedTrainGroup(routeArrivals, mode: mode)

            guard selectedRouteId == capturedRouteId else { return }

            // NOTE: No outer withAnimation — updateTrainPositions() handles it.
            await MainActor.run {
                guard self.selectedRouteId == capturedRouteId else { return }
                updateTrainPositions(arrivals: routeArrivals)
                if let updatedGroup,
                   self.selectedGroupedRoute?.routeId == updatedGroup.routeId {
                    self.selectedGroupedRoute = updatedGroup
                }
            }
        } catch {
            AppLogger.shared.logError("refreshCommuterRailVehicles", error: error)
        }
    }

    /// Computes the synced train group from GTFS-RT arrivals WITHOUT
    /// touching any @Published properties. Returns the updated group, or nil
    /// if there were no arrivals to process.
    private func buildSyncedTrainGroup(_ arrivals: [TrainArrival], mode: String = "subway") async -> GroupedNearbyTransitResponse? {
        guard let currentGroup = await MainActor.run(body: { selectedGroupedRoute }) else { return nil }

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
                    distanceM: dist,
                    isRealTime: a.status.lowercased() != "scheduled"
                ))
        }

        if newArrivals.isEmpty { return nil }

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
        let compassExpansions = DirectionConstants.compassExpansions
        let reverseCompass = DirectionConstants.reverseCompass

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

        return updatedGroup
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
        _targetBusGPS = [:]
        _previousTrainPositions = [:]
        _trainGraceBuffer = [:]
        _busGraceBuffer = [:]
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
    /// Recalculates the nearest stop and walking route from the user's
    /// current position. Called on every significant GPS movement (~20m)
    /// while a route detail sheet is open. Only updates the walking
    /// polyline — the camera re-zooms only if `nearestStopCoordinate`
    /// actually changes (SwiftUI .onChange handles that automatically).
    func refreshWalkingState(userLocation: CLLocation) async {
        guard selectedRouteId != nil else { return }
        
        // Keep lastKnownUserLocation fresh so referenceLocation resolves correctly
        lastKnownUserLocation = userLocation
        
        // Recalculate nearest stop (may or may not change)
        updateNearestStop(userLocation: userLocation)
        
        // Always refetch the walking route from the new GPS position to
        // the nearest stop so the dotted polyline tracks the user live.
        if let stopCoord = nearestStopCoordinate {
            await fetchWalkingRoute(from: userLocation.coordinate, to: stopCoord)
        }
    }

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
    ///
    /// Reads target GPS from `_targetBusGPS` (set by `refreshBusVehicles`)
    /// and smoothly moves the display positions in `busVehicles` toward
    /// them, producing glitch-free gliding along the polyline.
    func updateBusSimulation() {
        guard !busVehicles.isEmpty, routeShape != nil else { return }
        let elapsed = Date().timeIntervalSince(lastBusUpdateTime)
        let duration: TimeInterval = 10.0  // seconds between GPS poll

        let polyline = cachedInterpolationPolyline
        guard polyline.count >= 2 else { return }

        var updated = busVehicles
        var anyMoved = false
        // Low threshold ensures smooth sub-pixel movement at all zoom levels.
        let moveThreshold: CLLocationDistance = 0.5  // metres
        for i in updated.indices {
            let vid = updated[i].vehicleId
            guard let prev = previousBusPositions[vid] else { continue }
            // Use the target GPS from the latest server response.
            // If no target exists yet, fall back to the vehicle's own coords.
            let target = _targetBusGPS[vid]
            let targetCoord = CLLocationCoordinate2D(
                latitude: target?.lat ?? updated[i].lat,
                longitude: target?.lon ?? updated[i].lon
            )
            let result = VehicleInterpolator.smoothBusPosition(
                previous: CLLocationCoordinate2D(latitude: prev.lat, longitude: prev.lon),
                current: targetCoord,
                elapsed: elapsed,
                duration: duration,
                along: polyline
            )
            let currentLoc = CLLocation(latitude: updated[i].lat, longitude: updated[i].lon)
            let newLoc = CLLocation(
                latitude: result.coordinate.latitude, longitude: result.coordinate.longitude)
            if newLoc.distance(from: currentLoc) >= moveThreshold {
                updated[i] = updated[i].withInterpolatedPosition(
                    lat: result.coordinate.latitude,
                    lon: result.coordinate.longitude,
                    bearing: result.bearing
                )
                anyMoved = true
            }
            ArrivalETAEngine.recordPosition(
                vehicleKey: vid,
                coordinate: result.coordinate)
        }
        guard anyMoved else { return }
        // Duration < tick interval (1 s) so the animation completes before
        // the next tick fires — prevents mid-animation interruption jumps.
        withAnimation(.easeOut(duration: 0.85)) {
            self.busVehicles = updated
        }
    }

    /// Solves for "Ghost Trains" by interpolating position between stations
    /// along the actual route polyline for realistic curved movement.
    /// Builds vehicles from ALL directions (not just the selected one) so
    /// `filteredTrainVehicles` can properly filter them.
    ///
    /// Smooth-movement improvements:
    ///  • Existing vehicles blend from their previous display position to
    ///    the newly computed target using `.linear(duration: 1.0)`.
    ///  • Vehicles that vanish for a single poll cycle are kept in a grace
    ///    buffer (≤12 s) so their Annotation isn't destroyed and recreated,
    ///    which would cause a visible pop/flash.
    func updateTrainPositions(arrivals: [TrainArrival]) {
        guard let shape = routeShape else { return }
        self.cachedTrainArrivals = arrivals

        // Build stops and polyline per direction so we can match arrivals
        // against the correct direction's stops.
        struct DirectionContext {
            let stops: [BusStop]
            let polyline: [CLLocationCoordinate2D]
        }

        // Build direction contexts for all available directions.
        // Each context gets its OWN polyline so vehicles interpolate
        // along the correct direction's path — not the selected one.
        var dirContexts: [DirectionContext] = []
        if !shape.directions.isEmpty {
            // Pre-decode a shared fallback from the route-level polylines.
            // Only used when a specific direction has no polylines of its own
            // (rare — most GTFS shapes provide per-direction polylines).
            let sharedFallback: [CLLocationCoordinate2D] = {
                let all = shape.decodedPolylines.flatMap { $0 }
                return all.count >= 2 ? all : []
            }()
            for i in 0..<shape.directions.count {
                let ds = shape.stopsForDirection(index: i)
                let stops = ds.isEmpty ? shape.stops : ds
                let pl = shape.polylinesForDirection(index: i)
                let polyline: [CLLocationCoordinate2D] =
                    pl.isEmpty
                    ? sharedFallback
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

        // Snapshot current display positions before rebuilding.
        for v in trainVehicles {
            _previousTrainPositions[v.id] = CLLocationCoordinate2D(latitude: v.lat, longitude: v.lon)
        }

        var newVehicles: [TrainVehicle] = []
        var newIds = Set<String>()

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

                var targetLat = dirStops[nextStopIndex].lat
                var targetLon = dirStops[nextStopIndex].lon
                var bearing: Double = 0

                let previousIndex = nextStopIndex > 0 ? nextStopIndex - 1 : nextStopIndex
                let nextIndex = nextStopIndex

                if previousIndex != nextIndex {
                    let prevStop = dirStops[previousIndex]
                    let targetStop = dirStops[nextIndex]

                    let timeUntilArrival = nextStop.estimatedTime.timeIntervalSinceNow
                    let minutes = timeUntilArrival / 60.0

                    // Estimate actual travel time from the schedule.
                    // If the previous stop in the trip has a known time, use that.
                    // Otherwise, compute from the inter-station distance at a
                    // mode-appropriate speed (subway ~30 km/h avg with stops,
                    // express ~45 km/h).  The old hardcoded 3.0 min caused
                    // markers to sit at the previous stop for the entire dwell
                    // and then race to the next.
                    let travelTime: Double = {
                        // Try to find the departure time from the previous station
                        // in this trip's sorted arrivals.
                        if previousIndex > 0, previousIndex < dirStops.count {
                            let prevStopIdBase = dirStops[previousIndex].id.prefix(3)
                            if let prevArrival = sorted.first(where: {
                                $0.stationID.hasPrefix(prevStopIdBase)
                            }) {
                                let gap = nextStop.estimatedTime.timeIntervalSince(prevArrival.estimatedTime) / 60.0
                                if gap > 0.5 && gap < 20 { return gap }
                            }
                        }
                        // Fallback: estimate from haversine distance
                        let dist = CLLocation(latitude: prevStop.lat, longitude: prevStop.lon)
                            .distance(from: CLLocation(latitude: targetStop.lat, longitude: targetStop.lon))
                        // ~30 km/h = 500 m/min for local, slightly faster for express
                        let speedMpm: Double = dist > 2000 ? 750 : 500
                        return max(1.0, dist / speedMpm)
                    }()

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
                        targetLat = result.coordinate.latitude
                        targetLon = result.coordinate.longitude
                        bearing = result.bearing
                    } else {
                        // Fallback: straight-line lerp
                        targetLat = prevStop.lat + (targetStop.lat - prevStop.lat) * progress
                        targetLon = prevStop.lon + (targetStop.lon - prevStop.lon) * progress
                        bearing =
                            atan2(
                                targetStop.lon - prevStop.lon,
                                targetStop.lat - prevStop.lat
                            ) * 180 / .pi
                        if bearing < 0 { bearing += 360 }
                    }
                }

                // Smooth from previous display position toward the new target.
                // Use a time-aware blend that converges within ~2 seconds
                // rather than the old asymptotic 0.35 factor that kept the
                // marker permanently lagging behind the computed position.
                var finalLat = targetLat
                var finalLon = targetLon
                if let prev = _previousTrainPositions[tripId] {
                    // Distance-adaptive blend: move faster when far away
                    // (catch up after a next-stop shift), slower when close
                    // (smooth micro-jitter).  0.55 per tick covers ~90% in
                    // 3 ticks (3 s) vs old 0.35 which took 6+ ticks.
                    let distance = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                        .distance(from: CLLocation(latitude: targetLat, longitude: targetLon))
                    let blendFactor = distance > 200 ? 0.7 : 0.55
                    finalLat = prev.latitude + (targetLat - prev.latitude) * blendFactor
                    finalLon = prev.longitude + (targetLon - prev.longitude) * blendFactor
                }

                newVehicles.append(
                    TrainVehicle(
                        id: tripId,
                        tripId: tripId,
                        routeId: nextStop.routeID,
                        direction: nextStop.direction,
                        lat: finalLat,
                        lon: finalLon,
                        bearing: bearing,
                        nextStationName: dirStops[nextStopIndex].name,
                        estimatedArrival: nextStop.estimatedTime
                    ))
                newIds.insert(tripId)
                // Record position for smart ETA speed estimation
                ArrivalETAEngine.recordPosition(
                    vehicleKey: tripId,
                    coordinate: CLLocationCoordinate2D(latitude: finalLat, longitude: finalLon))
                break  // Found a matching direction, stop searching
            }
        }

        // Grace buffer: keep vehicles that vanished this tick for up to 12 s
        // so the Annotation isn't destroyed/recreated on a single GTFS-RT dropout.
        let now = Date()
        for v in trainVehicles where !newIds.contains(v.id) {
            if _trainGraceBuffer[v.id] == nil {
                _trainGraceBuffer[v.id] = (vehicle: v, missedAt: now)
            }
        }
        // Re-add graced vehicles and purge expired ones
        var expiredIds: [String] = []
        for (id, entry) in _trainGraceBuffer {
            if newIds.contains(id) {
                // Vehicle reappeared — remove from grace
                expiredIds.append(id)
            } else if now.timeIntervalSince(entry.missedAt) > 12 {
                // Genuinely gone — purge
                expiredIds.append(id)
                _previousTrainPositions.removeValue(forKey: id)
            } else {
                // Still within grace period — keep on map
                newVehicles.append(entry.vehicle)
            }
        }
        for id in expiredIds { _trainGraceBuffer.removeValue(forKey: id) }

        // Duration < tick interval (1 s) so the animation completes before
        // the next tick fires — prevents mid-animation interruption jumps.
        withAnimation(.easeOut(duration: 0.85)) {
            self.trainVehicles = newVehicles
        }
    }

    // MARK: - Nearby Transit (Unified)

    /// Search radius (meters) used for the wider "nearest metro" fallback.
    private static let nearestMetroRadius = AppSettings.shared.nearestMetroFallbackRadiusMeters

    /// Maximum radius we'll ever send to the OBA bus-stops-for-location
    /// endpoint.  OBA hard-caps results at ~100 stops per request; beyond
    /// ~2500 m in dense Manhattan, the 100 slots get diluted with far-away
    /// stops, pushing out the physically nearest ones.
    private static let busStopsMaxRadius: Int = 2500

    /// Adaptive radius for the OBA bus-stops-for-location call.
    ///
    /// **Why adaptive?**  The OBA API returns at most ~100 stops regardless
    /// of the requested bounding box.  If we use the user's full slider
    /// radius (up to 8047 m / 5 mi), those 100 slots are spread over the
    /// entire area — so a physical stop 250 ft away gets displaced by
    /// stops 3 miles out.  The distance formula then computes against the
    /// *wrong* stop and displays, say, 1000 ft instead of 250 ft.
    ///
    /// **The algorithm:**
    /// 1. Start with the user's "Farther Away" tier radius (r₂) so every
    ///    stop in Zone 1 and Zone 2 is covered by precise physical-stop
    ///    coordinates.
    /// 2. Cap at `busStopsMaxRadius` (2500 m ≈ 1.55 mi) so the 100 OBA
    ///    slots stay dense enough for accurate distances.
    /// 3. Floor at 800 m so even tiny slider settings get a usable set.
    ///
    /// Routes in Zone 3 ("Much Farther") naturally fall back to
    /// `groupMinDistance`, which computes from live-arrival stop coordinates
    /// — accurate for farther tiers where ±50 m doesn't matter.
    ///
    /// This works everywhere in the city:
    /// - **Dense Midtown**: many stops → cap prevents dilution
    /// - **Waterfront / coastal**: half the circle is water → fewer stops
    ///   returned → cap is irrelevant
    /// - **Sparse outer boroughs**: few stops anyway → cap is irrelevant
    private static var busStopsNearbyRadius: Int {
        let r2 = AppSettings.shared.fartherAwayRadiusMeters
        return max(800, min(Int(r2), busStopsMaxRadius))
    }

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
            // Fire all location-dependent fetches in parallel so auxiliary
            // stop metadata (bus stops, stations) is ready BEFORE we set
            // groupedTransit — eliminating the second SwiftUI render pass
            // that used to flash stale distance badges.
            async let groupedTask = TrackAPI.fetchNearbyGrouped(lat: lat, lon: lon)
            // Use a capped radius for bus stops (OBA has a ~100-stop hard
            // limit per call).  With the full 8047 m radius the 100 slots
            // are spread over 5 miles, so a physical stop 250 ft away may
            // be displaced by far-away stops. 1600 m keeps all 100 slots
            // within ~1 mi, giving dense coverage for the "Near You" tier.
            // Routes beyond 1 mi fall back to groupMinDistance from live
            // arrival coordinates, which is accurate for farther tiers.
            async let busStopsTask = TrackAPI.fetchNearbyBusStops(
                lat: lat, lon: lon, radius: Self.busStopsNearbyRadius
            )
            async let stationsTask = repository.fetchNearbyStations(
                latitude: lat, longitude: lon
            )

            let newGrouped = (try await groupedTask).filter { $0.hasRealArrivals }

            // Resolve auxiliary data (best-effort) before publishing groups.
            let stops = (try? await busStopsTask) ?? nearbyBusStops
            let stations = (try? await stationsTask) ?? nearbyStations

            // Augment nearbyStations with LIRR/MNR station data extracted from
            // grouped arrivals.  The subway-only /stations/nearby endpoint never
            // returns commuter rail stations, so LIRR/MNR distance matching
            // always fell back to groupMinDistance.  By injecting arrival stop
            // coordinates here, the primary matching path works for all modes.
            nearbyStations = Self.augmentStations(stations, from: newGrouped)

            // Augment nearbyBusStops with stop data from bus arrivals whose
            // stops weren't returned by the /bus/nearby OBA fetch (smaller
            // radius or OBA API cap).  This lets distance matching work for
            // routes like Q7 whose closest stop is within range but wasn't
            // in the OBA response.
            nearbyBusStops = Self.augmentBusStops(stops, from: newGrouped)

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

            // Persist for instant display on next cold launch
            TransitSessionCache.save(groupedTransit)

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

            // Pre-fetch ML delay factors for arrivals that lack live vehicle
            // positions. Runs in the background so it doesn't block rendering.
            if !rawTransit.isEmpty {
                Task {
                    await ArrivalETAEngine.prefetchDelayFactors(for: rawTransit)
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

        // ── Within-batch dedup ────────────────────────────────────────
        // Different MTA feeds may return the same route under different
        // casings (SIRI → "BXM2", OBA → "BxM2").  The backend merge-key
        // normalises, but belt-and-suspenders: collapse duplicates here
        // so two cards for the same route never appear simultaneously.
        let deduped: [GroupedNearbyTransitResponse] = {
            var seen: [String: Int] = [:]          // uppercased routeId → index
            var result: [GroupedNearbyTransitResponse] = []
            for group in new {
                let key = group.routeId.uppercased()
                if let existing = seen[key] {
                    // Merge directions from the duplicate into the first-seen group.
                    // Keep the entry whose routeId has more mixed-case ("BxM2" > "BXM2")
                    // since that's the canonical display name.
                    var winner = result[existing]
                    let extra = group.directions.filter { newDir in
                        !winner.directions.contains { $0.direction.uppercased() == newDir.direction.uppercased() }
                    }
                    if !extra.isEmpty {
                        winner.directions.append(contentsOf: extra)
                        result[existing] = winner
                    }
                } else {
                    seen[key] = result.count
                    result.append(group)
                }
            }
            return result
        }()

        // First load or previous was empty — nothing to merge.
        guard !existing.isEmpty else {
            graceMissCountBySource[source] = [:]
            return deduped
        }

        // Case-insensitive route ID matching — different MTA feeds can
        // return different casings for the same route (e.g. SIRI → "BXM2",
        // OBA/GTFS → "BxM2").  Uppercasing prevents ghost duplicates.
        let newRouteIds = Set(deduped.map { $0.routeId.uppercased() })
        var missCounts = graceMissCountBySource[source] ?? [:]

        // Routes that reappeared — reset their miss counter.
        for id in newRouteIds {
            missCounts.removeValue(forKey: id)
        }

        // Start with all new (fresh) data.
        var merged = deduped
        // Track uppercased route keys already in merged so the grace
        // loop doesn't re-add a case-variant that the dedup already kept
        // (e.g. cache has both "BxM2" and "BXM2" — only keep one).
        var mergedKeys = Set(merged.map { $0.routeId.uppercased() })

        // Keep each old route that's NOT in the new data, up to a limit.
        // After 3 consecutive misses the route is stale (likely the user
        // moved away) and its stop coordinates may no longer be accurate,
        // which causes displayDistanceMeters to bucket it incorrectly.
        let maxGraceCycles = 3
        let nowEpoch = Date.now.timeIntervalSince1970
        for oldGroup in existing where !newRouteIds.contains(oldGroup.routeId.uppercased()) {
            let graceKey = oldGroup.routeId.uppercased()
            let count = (missCounts[graceKey] ?? 0) + 1
            missCounts[graceKey] = count
            if count > maxGraceCycles {
                AppLogger.shared.log(
                    "REFRESH",
                    message: "[\(source)] Evicting \(oldGroup.routeId) after \(count) grace cycles"
                )
                continue   // drop it from merged
            }

            // Early-evict graced routes whose arrival timestamps have ALL
            // expired (> 90 s in the past).  Keeping them would show a blank
            // card ("--") that provides no useful information to the user.
            let hasAnyFreshArrival = oldGroup.directions.contains { dir in
                dir.arrivals.contains { arrival in
                    guard !arrival.isPlaceholder else { return false }
                    if let ts = arrival.arrivalTs, ts > 0 {
                        return (nowEpoch - Double(ts)) <= 90
                    }
                    // Arrivals with no timestamp but non-placeholder minutes
                    // are likely schedule-based and still valid.
                    return arrival.minutesAway > 0 && arrival.minutesAway < 99
                }
            }
            if !hasAnyFreshArrival {
                AppLogger.shared.log(
                    "REFRESH",
                    message: "[\(source)] Early-evicting \(oldGroup.routeId) — all arrivals expired"
                )
                missCounts[graceKey] = maxGraceCycles + 1  // prevent re-grace
                continue
            }

            // Skip case-duplicate already in merged (e.g. BxM2 when BXM2 is already there)
            guard mergedKeys.insert(graceKey).inserted else { continue }
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

        // Global feeds (alerts, accessibility) — debounced to 1× per 30 s.
        Task { await refreshGlobalFeedsIfNeeded() }

        do {
            async let groupedTask = TrackAPI.fetchNearbyGrouped(lat: lat, lon: lon, mode: "subway")
            async let stationsTask = repository.fetchNearbyStations(
                latitude: lat, longitude: lon
            )

            let allGrouped = try await groupedTask
            let filtered = allGrouped.filter { $0.mode == "subway" && $0.hasRealArrivals }

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
    }

    // MARK: - Bus

    func refreshBus(location: CLLocation?) async {
        guard let location = location else {
            errorMessage = "Location required for bus arrivals"
            return
        }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        // Global feeds (alerts, accessibility) — debounced to 1× per 30 s.
        Task { await refreshGlobalFeedsIfNeeded() }

        do {
            async let groupedTask = TrackAPI.fetchNearbyGrouped(lat: lat, lon: lon, mode: "bus")
            async let nearbyBusStopsTask = TrackAPI.fetchNearbyBusStops(
                lat: lat, lon: lon, radius: Self.busStopsNearbyRadius
            )

            let allGrouped = try await groupedTask
            let filtered = allGrouped.filter { $0.mode == "bus" && $0.hasRealArrivals }

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

            // Fetch full route catalog only once — it rarely changes and is
            // cached for 30 s in the API memoizer.  Fire-and-forget so it
            // doesn't lengthen the critical bus-tab render path.
            if allBusRoutes.isEmpty {
                Task { [weak self] in
                    guard let routes = try? await TrackAPI.fetchBusRoutes() else { return }
                    await MainActor.run { self?.allBusRoutes = routes }
                }
            }
        } catch {
            AppLogger.shared.logError("refreshBus", error: error)
            errorMessage = (error as? TransitError)?.description ?? error.localizedDescription
        }
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
        // Global feeds (alerts, accessibility) — debounced to 1× per 30 s.
        Task { await refreshGlobalFeedsIfNeeded() }

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
                // Inject LIRR station data so distance matching works
                nearbyStations = Self.augmentStations(nearbyStations, from: newGrouped)
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
    }

    // MARK: - Metro-North

    func refreshMNR(location: CLLocation?) async {
        // Global feeds (alerts, accessibility) — debounced to 1× per 30 s.
        Task { await refreshGlobalFeedsIfNeeded() }

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
                // Inject MNR station data so distance matching works
                nearbyStations = Self.augmentStations(nearbyStations, from: newGrouped)
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

        Task {
            await LiveActivityManager.shared.startActivity(
                lineId: arrival.isBus ? stripMTAPrefix(arrival.routeId) : arrival.routeId,
                destination: arrival.destination ?? arrival.direction,
                arrivalTime: eta,
                isBus: arrival.isBus,
                nextArrivals: nextArrivals
            )
        }
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

        Task {
            await LiveActivityManager.shared.startActivity(
                lineId: arrival.routeID,
                destination: arrival.direction,
                arrivalTime: eta,
                isBus: false,
                nextArrivals: nextArrivals
            )
        }
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

        Task {
            await LiveActivityManager.shared.startActivity(
                lineId: stripMTAPrefix(arrival.routeId),
                destination: "Bus Tracking",
                arrivalTime: arrivalTime,
                isBus: true,
                nextArrivals: nextArrivals
            )
        }
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

        Task {
            await LiveActivityManager.shared.startActivity(
                lineId: arrival.routeID,
                destination: arrival.direction,
                arrivalTime: eta,
                isBus: false,
                nextArrivals: nextArrivals
            )
        }
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
            let rtCount = direction.arrivals.filter { $0.isRealTime }.count
            return "#\(index):\(direction.direction){all:\(direction.arrivals.count),live:\(direction.liveArrivals.count),rt:\(rtCount)}"
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

    // MARK: - Station / Stop Augmentation

    /// Augments the subway-only `nearbyStations` with LIRR/MNR station data
    /// extracted from grouped transit arrivals.
    ///
    /// The `/subway/stations/nearby` endpoint only returns subway stations, so
    /// `displayDistanceMeters` could never match LIRR or MNR groups by station.
    /// This method extracts unique stop coordinates from commuter-rail arrivals
    /// and appends them with proper route IDs so the primary matching path works.
    static func augmentStations(
        _ subwayStations: [(stationID: String, name: String, lat: Double, lon: Double, routeIDs: [String])],
        from groups: [GroupedNearbyTransitResponse]
    ) -> [(stationID: String, name: String, lat: Double, lon: Double, routeIDs: [String])] {
        // Collect commuter rail stops: keyed by stopId (or lat/lon fallback)
        // so a station served by multiple branches accumulates all route IDs.
        var crStops: [String: (name: String, lat: Double, lon: Double, routeIDs: Set<String>)] = [:]

        for group in groups where group.isCommuterRail {
            for arrival in group.directions.flatMap(\.arrivals) {
                guard let lat = arrival.stopLat, let lon = arrival.stopLon else { continue }
                // Prefix with mode so LIRR stop_id "118" (Long Island City)
                // doesn't collide with subway station_id "118" (Cathedral Pkwy).
                let rawKey = arrival.stopId ?? "\(lat),\(lon)"
                let key = "\(group.mode)_\(rawKey)"
                if var existing = crStops[key] {
                    existing.routeIDs.insert(group.routeId)
                    crStops[key] = existing
                } else {
                    crStops[key] = (name: arrival.stopName, lat: lat, lon: lon, routeIDs: [group.routeId])
                }
            }
        }

        guard !crStops.isEmpty else { return subwayStations }

        var result = subwayStations
        let existingIDs = Set(subwayStations.map(\.stationID))
        for (key, data) in crStops where !existingIDs.contains(key) {
            result.append((stationID: key, name: data.name, lat: data.lat, lon: data.lon, routeIDs: Array(data.routeIDs)))
        }
        return result
    }

    /// Augments `nearbyBusStops` with stop data extracted from bus arrivals
    /// in the grouped transit response.
    ///
    /// The OBA `/bus/nearby` endpoint may not return every stop that the grouped
    /// transit response references (different radius, API cap, route coverage).
    /// This injects missing stops so `displayDistanceMeters` can match them
    /// by route token instead of falling back to `groupMinDistance`.
    static func augmentBusStops(
        _ obaStops: [BusStop],
        from groups: [GroupedNearbyTransitResponse]
    ) -> [BusStop] {
        // Build a dictionary of existing stops keyed by stop ID, so we can
        // add route IDs to existing stops and insert new ones.
        var stopMap: [String: BusStop] = [:]
        for stop in obaStops {
            stopMap[stop.id] = stop
        }

        var newStops: [String: BusStop] = [:]  // stops not in OBA response
        var modifiedExisting = false  // track route_id additions to existing stops

        for group in groups where group.isBus {
            for arrival in group.directions.flatMap(\.arrivals) {
                guard let lat = arrival.stopLat, let lon = arrival.stopLon else { continue }
                let key = arrival.stopId ?? "\(lat),\(lon)"

                if var existing = stopMap[key] {
                    // Stop exists in OBA data — ensure it lists this route too
                    var routes = existing.routeIds ?? []
                    if !routes.contains(where: { normalizeMTARouteToken($0) == normalizeMTARouteToken(group.routeId) }) {
                        routes.append(group.routeId)
                        existing.routeIds = routes
                        stopMap[key] = existing
                        modifiedExisting = true
                    }
                } else if var pending = newStops[key] {
                    // Already queued from a different arrival — add route ID
                    var routes = pending.routeIds ?? []
                    if !routes.contains(where: { normalizeMTARouteToken($0) == normalizeMTARouteToken(group.routeId) }) {
                        routes.append(group.routeId)
                        pending.routeIds = routes
                        newStops[key] = pending
                    }
                } else {
                    newStops[key] = BusStop(
                        id: key,
                        name: arrival.stopName,
                        lat: lat,
                        lon: lon,
                        direction: arrival.direction,
                        routeIds: [group.routeId]
                    )
                }
            }
        }

        guard !newStops.isEmpty || modifiedExisting || stopMap.count != obaStops.count else {
            return obaStops
        }

        // Merge: updated OBA stops + new stops from arrivals
        return Array(stopMap.values) + Array(newStops.values)
    }
}
