// Route selection, vehicle refresh, nearby transit, and tracking methods
// extracted from HomeViewModel. All API calls and data loading live here.
// Note: busSchedule and cachedTrainArrivals stored properties live in
// HomeViewModel.swift so @Observable can instrument them.

import CoreLocation
import Foundation
import SwiftData
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
            // Attempt to fetch fresh data for this route to get
            // the full context (colors, directions, other arrivals)
            // If that fails or isn't implemented, we fall back
            // to a minimal group.

            // Note: Currently we don't have a direct
            // "fetch single route group" endpoint that aligns
            // perfectly
            // with GroupedNearbyTransitResponse structure
            // without fetching *all* nearby routes.
            // However, we can construct a better "mock" group
            // if we had more info, or we could trigger a refresh.
            // For now, we use the minimal group to immediately show the user what they tapped,
            // but we ensure the route logic (shape, vehicles) is triggered by selectGroupedRoute.

            // Create a minimal group to satisfy the unified logic
            let minimalGroup = GroupedNearbyTransitResponse(
                routeId: arrival.routeId,
                displayName: arrival.displayName,
                mode: arrival.mode,
                colorHex: arrival.colorHex,
                directions: [
                    DirectionArrivalsResponse(
                        direction: arrival.direction,
                        arrivals: [arrival]
                    )
                ],
                busServiceType: arrival.busServiceType
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
    private func buildSyncedBusGroup(
        _ vehicles: [BusVehicleResponse]
    ) async -> GroupedNearbyTransitResponse? {
        guard let currentGroup = await MainActor.run(
            body: { selectedGroupedRoute }
        ) else { return nil }

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
                        let candidates = directionStopSets.filter {
                            $0.stopIds.contains(normalized)
                        }
                        if candidates.count == 1 {
                            return candidates[0].dirKey
                        }
                    }

                    // 2) Destination/headsign text matching
                    if let destName = (call.destinationName ?? vehicle.statusText)?
                        .uppercased(), !destName.isEmpty
                    {
                        for (dirKey, dests) in directionDestinations {
                            if dests.contains(where: {
                                destName.contains($0) || $0.contains(destName)
                            }) {
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
                    destination: call.destinationName ?? vehicle.statusText,
                    minutesAway: minutes,
                    status: vehicle.isRealtime
                        ? (call.statusText == "Scheduled" ? "En Route" : call.statusText)
                        : "Scheduled",
                    mode: "bus",
                    stopLat: stopLat,
                    stopLon: stopLon,
                    arrivalTs: call.expectedArrival.map { Int($0.timeIntervalSince1970) } ?? 0,
                    vehicleId: vehicle.vehicleId,
                    tripId: nil,
                    stopId: call.stopId,
                    distanceM: dist,
                    isRealTime: vehicle.isRealtime,
                    colorHex: currentGroup.colorHex,
                    busServiceType: currentGroup.busServiceType
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
        print(
            "[HomeVM] syncBusArrivals:"
            + " \(newArrivals.count) arrivals,"
            + " \(uniqueStopIds.count) unique stops."
            + " Sample IDs:"
            + " \(Array(uniqueStopIds.prefix(5)))"
        )
        print("[HomeVM] syncBusArrivals: selectedStopId = '\(selectedStopId ?? "nil")'")
        #endif

        // Preserve existing direction labels/structure
        var newDirections: [DirectionArrivalsResponse] = []

        // Snapshot which stop IDs are covered by the new onward-call data.
        // Old live arrivals for stops NOT in this set originated from
        // stop-monitoring (nearby API) and must be carried forward —
        // otherwise the user-selected stop loses its live data every
        // time the vehicle-monitoring sync fires.
        let coveredStopIds: Set<String> = Set(
            newArrivals.compactMap(\.stopId)
                .filter { !$0.isEmpty }
        )

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
                guard let vid = sched.vehicleId else {
                    // No vehicleId — keep if arrival time is still in the future
                    // or within the last 2 minutes (clock skew buffer). Drop
                    // entries that are 5+ minutes past their arrivalTs to prevent
                    // stale ghost arrivals accumulating over bus-sync cycles.
                    if let ts = sched.arrivalTs, ts > 0 {
                        let secFromNow = TimeInterval(ts) - Date().timeIntervalSince1970
                        return secFromNow > -120 // keep if <2 min past
                    }
                    return true
                }
                return !liveVehicleIds.contains(vid)
            }

            // Preserve old LIVE arrivals whose stop is NOT covered by
            // onward calls.  SIRI vehicle-monitoring truncates the call
            // list (typically ~30 future stops), so stops further ahead
            // or those a bus hasn't reached yet may vanish from the new
            // data.  Keeping these prevents the user-selected stop from
            // flapping between "7 LIVE" and "0 LIVE" every 10s poll.
            let oldLiveForUncoveredStops = oldDir.arrivals.filter { arr in
                guard arr.isRealTime,
                      let sid = arr.stopId, !sid.isEmpty,
                      !coveredStopIds.contains(sid) else { return false }
                // Don't carry forward if the vehicle is already represented
                // in the new onward-call data (it just doesn't list this stop).
                if let vid = arr.vehicleId, liveVehicleIds.contains(vid) { return false }
                // Drop arrivals that have already passed (negative ETA)
                if let ts = arr.arrivalTs, ts > 0 {
                    let remaining = TrackingTimeSync.remainingMinutes(
                        until: Date(
                            timeIntervalSince1970: TimeInterval(ts)
                        )
                    )
                    if remaining < -2 { return false }
                }
                return true
            }

            let merged = sorted + oldLiveForUncoveredStops + filteredScheduled

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
            directions: newDirections,
            sortingKey: currentGroup.sortingKey,
            alerts: currentGroup.alerts,
            expressRoutes: currentGroup.expressRoutes,
            busServiceType: currentGroup.busServiceType
        )

        #if DEBUG
        AppLogger.shared.log(
            "SYNC_BUS",
            message:
                "route=\(currentGroup.routeId)"
                + " vehicles=\(vehicles.count)"
                + " calls=\(newArrivals.count)"
                + " snapshot=\(debugDirectionSnapshot(updatedGroup))"
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
    private func buildSyncedTrainGroup(
        _ arrivals: [TrainArrival],
        mode: String = "subway"
    ) async -> GroupedNearbyTransitResponse? {
        guard let currentGroup = await MainActor.run(
            body: { selectedGroupedRoute }
        ) else { return nil }
        
        // Get the user's selected stop — arrivals at THIS stop are protected
        // from being overwritten by route-specific API data
        let protectedStopId = await MainActor.run(body: { selectedStopId })

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
                    isRealTime: a.status.lowercased() != "scheduled",
                    colorHex: currentGroup.colorHex,
                    busServiceType: currentGroup.busServiceType
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
            if let label = dir.directionLabel?
                .uppercased()
                .replacingOccurrences(of: "→ ", with: ""),
               !label.isEmpty
            {
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
                if !arrDest.isEmpty && matches.contains(where: {
                    arrDest.contains($0) || $0.contains(arrDest)
                }) {
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

        // Helper to check if a stop ID matches the protected stop
        func isProtectedStop(_ stopId: String?) -> Bool {
            guard let protected = protectedStopId, !protected.isEmpty,
                  let sid = stopId, !sid.isEmpty else { return false }
            // Exact match or normalized match (strip MTA prefix + N/S suffix)
            if sid == protected { return true }
            let norm1 = normalizeStopId(sid)
            let norm2 = normalizeStopId(protected)
            return norm1 == norm2 && !norm1.isEmpty
        }

        // ── STOP-AWARE MERGE: protect arrivals at user's selected stop ──
        // The nearby API returns arrivals pre-filtered to the user's nearest stop.
        // The route-specific API returns ALL stops on the line.
        // 
        // CRITICAL: For the user's selected stop, KEEP the nearby API data.
        // The route-specific API may show fewer arrivals at that stop because
        // it wasn't filtered for proximity. This prevents chip count drops.
        func mergeArrivals(
            existing: [NearbyTransitResponse],
            new: [NearbyTransitResponse]
        ) -> [NearbyTransitResponse] {
            let now = Date()
            let expiryThreshold = now.addingTimeInterval(-60) // 1 min grace

            // Partition existing by protected vs other stops
            var protectedArrivals: [NearbyTransitResponse] = []
            var otherExisting: [String: NearbyTransitResponse] = [:]
            
            for arrival in existing {
                if isProtectedStop(arrival.stopId) {
                    // ALWAYS keep arrivals at user's selected stop
                    protectedArrivals.append(arrival)
                } else {
                    let key = arrival.tripId ?? arrival.vehicleId ?? arrival.id
                    otherExisting[key] = arrival
                }
            }

            // Build merged result for non-protected stops
            var merged: [String: NearbyTransitResponse] = [:]

            // Add new arrivals (but skip any at protected stop — keeping existing)
            for arrival in new {
                // Skip arrivals at protected stop — use existing nearby API data
                if isProtectedStop(arrival.stopId) { continue }
                
                let key = arrival.tripId ?? arrival.vehicleId ?? arrival.id

                // Check for suspicious ETA jumps on same trip AT SAME STOP.
                // Cross-stop comparisons produce false positives because ETAs
                // naturally differ between stops along a route — comparing
                // trip X at stop A (old) vs stop B (new) is NOT a real jump.
                if let existing = otherExisting[key],
                   let newTs = arrival.arrivalTs,
                   let oldTs = existing.arrivalTs,
                   arrival.stopId != nil && existing.stopId == arrival.stopId {
                    let timeDiff = newTs - oldTs
                    if timeDiff > 600 { // >10 min later — suspicious
                        // ── Anti-latch: release protection after 30 s ──
                        // Once we keep the old ETA, subsequent polls see
                        // an even larger diff and reject forever.  Track
                        // when we first protected this trip and accept the
                        // new value once 30 s have elapsed.
                        let oldArrivalDate = Date(timeIntervalSince1970: TimeInterval(oldTs))
                        let oldAlreadyPast = oldArrivalDate < now.addingTimeInterval(-60)

                        let protectionStart = _mergeProtectionStarts[key] ?? now
                        if _mergeProtectionStarts[key] == nil {
                            _mergeProtectionStarts[key] = now
                        }
                        let protectedTooLong = now.timeIntervalSince(protectionStart) > 30

                        if oldAlreadyPast || protectedTooLong {
                            // Old ETA expired or protected too long — accept API update
                            #if DEBUG
                            let reason = oldAlreadyPast ? "old ETA in past" : "protected >30s"
                            print(
                                "[MERGE_ARRIVAL] ✅ Released latch"
                                + " for \(key):"
                                + " old=\(oldTs) new=\(newTs)"
                                + " diff=+\(timeDiff/60)min"
                                + " — \(reason)"
                            )
                            #endif
                            // Don't remove from _mergeProtectionStarts here;
                            // end-of-merge cleanup handles it.  Removing mid-loop
                            // resets the 30 s timer when later iterations re-trigger
                            // protection for the same trip key at a different stop.
                            merged[key] = arrival
                            continue
                        }

                        #if DEBUG
                        print(
                            "[MERGE_ARRIVAL] ⚠️ Suspicious ETA jump"
                            + " for \(key):"
                            + " old=\(oldTs) new=\(newTs)"
                            + " diff=+\(timeDiff/60)min"
                            + " — keeping old"
                        )
                        #endif
                        merged[key] = existing
                        continue
                    } else {
                        // Normal update at same stop — clear any protection tracking
                        _mergeProtectionStarts.removeValue(forKey: key)
                    }
                }

                merged[key] = arrival
            }

            // Add non-protected existing arrivals that weren't in new set AND haven't expired
            for arrival in otherExisting.values {
                let key = arrival.tripId ?? arrival.vehicleId ?? arrival.id
                guard merged[key] == nil else { continue }

                if let ts = arrival.arrivalTs {
                    let arrivalTime = Date(timeIntervalSince1970: TimeInterval(ts))
                    guard arrivalTime > expiryThreshold else { continue }
                }

                merged[key] = arrival
            }

            // Remove expired protected arrivals
            let validProtected = protectedArrivals.filter { arrival in
                guard let ts = arrival.arrivalTs else { return true }
                return Date(timeIntervalSince1970: TimeInterval(ts)) > expiryThreshold
            }

            #if DEBUG
            if !validProtected.isEmpty {
                print("[MERGE_ARRIVAL] 🛡️ Protected "
                    + "\(validProtected.count) arrivals "
                    + "at stop \(protectedStopId ?? "nil")")
            }
            #endif

            // Purge stale entries from the protection tracker (trips no longer in either set)
            let activeKeys = Set(merged.keys).union(otherExisting.keys)
            _mergeProtectionStarts = _mergeProtectionStarts.filter { activeKeys.contains($0.key) }

            return validProtected + Array(merged.values)
        }

        // Preserve existing direction labels and MERGE arrivals
        for oldDir in currentGroup.directions {
            let newArrivalsForDir = grouped[oldDir.direction] ?? []

            // Merge arrivals from both data sources
            let mergedArrivals = mergeArrivals(existing: oldDir.arrivals, new: newArrivalsForDir)
            let sorted = mergedArrivals.sorted { $0.minutesAway < $1.minutesAway }

            // Only replace if we got arrivals; otherwise keep existing to avoid flashing empty
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
            directions: newDirections,
            sortingKey: currentGroup.sortingKey,
            alerts: currentGroup.alerts,
            expressRoutes: currentGroup.expressRoutes,
            busServiceType: currentGroup.busServiceType
        )

        #if DEBUG
        AppLogger.shared.log(
            "SYNC_TRAIN",
            message:
                "route=\(currentGroup.routeId)"
                + " mode=\(mode)"
                + " arrivals=\(newArrivals.count)"
                + " snapshot=\(debugDirectionSnapshot(updatedGroup))"
        )
        #endif

        return updatedGroup
    }

    // MARK: - Bus Schedule


    /// Fetches the schedule for the currently selected bus route.
    /// Used to show scheduled departures when no live buses are running.
    /// - Parameter expectedRouteId: The route ID that was selected when this
    ///   call was enqueued.  If the user navigated away before the network
    ///   response arrives, we discard the result to avoid polluting a
    ///   different route's data.
    func fetchBusScheduleIfNeeded(expectedRouteId: String? = nil) async {
        guard let group = selectedGroupedRoute, group.isBus else { return }
        let routeId = group.routeId
        do {
            let schedule = try await TrackAPI.fetchBusSchedule(routeID: routeId)
            // Staleness guard: only publish if the user is still on the same route.
            guard selectedRouteId == (expectedRouteId ?? routeId) else {
                #if DEBUG
                print("[SCHEDULE] Discarding stale schedule "
                    + "for \(routeId) — user moved "
                    + "to \(selectedRouteId ?? "nil")")
                #endif
                // Still cache it so re-opening this route later is instant.
                busScheduleByRoute[routeId] = schedule
                return
            }
            busSchedule = schedule
            busScheduleByRoute[routeId] = schedule
            #if DEBUG
            let dirSummary = schedule.directions
                .map { "\($0.direction): \($0.departures.count) deps" }
                .joined(separator: ", ")
            print("[SCHEDULE] Loaded schedule for \(routeId): "
                + "\(schedule.directions.count) dirs [\(dirSummary)]")
            #endif
        } catch {
            AppLogger.shared.logError("fetchBusSchedule(\(routeId))", error: error)
            // Only nil out if we're still on the same route AND there's no
            // cached fallback.  Prefer stale schedule data over empty chips.
            if selectedRouteId == (expectedRouteId ?? routeId),
               busScheduleByRoute[routeId] == nil {
                busSchedule = nil
            }
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
        goMode.cancelWalkingRoute()
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
        
        // When the user manually tapped a stop, keep that stop as the
        // walking-route destination — only update the "from" leg so the
        // polyline tracks their live GPS position.
        if !isStopManuallySelected {
            // Recalculate nearest stop (may or may not change)
            updateNearestStop(userLocation: userLocation)
        }
        
        // Always refetch the walking route from the effective origin to
        // the nearest stop so the dotted polyline tracks the user live.
        // When a drag-search pin is active, walk from the pin — not GPS.
        if let stopCoord = nearestStopCoordinate {
            let origin = effectiveLocation(userLocation: userLocation)?.coordinate
                         ?? userLocation.coordinate
            await fetchWalkingRoute(from: origin, to: stopCoord)
        }
    }

    func updateNearestStop(userLocation: CLLocation?) {
        let refLocation = effectiveLocation(userLocation: userLocation)
        let dirStops = routeShape?.stopsForDirection(
            index: selectedDirectionIndex,
            name: selectedDirectionName
        ) ?? []

        guard !dirStops.isEmpty, let userLoc = refLocation else {
            // Fallback: try first arrival's stop
            if let group = selectedGroupedRoute {
                let safeIdx = min(selectedDirectionIndex, group.directions.count - 1)
                let dir = group.directions.indices.contains(safeIdx)
                    ? group.directions[safeIdx] : nil
                if let first = dir?.arrivals.first,
                   let lat = first.stopLat,
                   let lon = first.stopLon {
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
            // Skip redundant updates — multiple triggers (direction change,
            // GPS callback, walking refresh) can fire within the same frame.
            guard closest.id != selectedStopId else { return }
            nearestStopCoordinate = CLLocationCoordinate2D(
                latitude: closest.lat,
                longitude: closest.lon
            )
            selectedStopId = closest.id
            #if DEBUG
            print("[HomeVM] updateNearestStop → "
                + "selectedStopId = '\(closest.id)' "
                + "(stop: \(closest.name))")
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
        guard !busVehicles.isEmpty else { return }
        let elapsed = Date().timeIntervalSince(lastBusUpdateTime)
        let duration: TimeInterval = 10.0  // seconds between GPS poll

        let polyline = cachedInterpolationPolyline
        let hasPolyline = polyline.count >= 2

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

            let newCoord: CLLocationCoordinate2D
            let newBearing: Double?
            if hasPolyline {
                // Polyline-snapped interpolation (preferred)
                let result = VehicleInterpolator.smoothBusPosition(
                    previous: CLLocationCoordinate2D(latitude: prev.lat, longitude: prev.lon),
                    current: targetCoord,
                    elapsed: elapsed,
                    duration: duration,
                    along: polyline
                )
                newCoord = result.coordinate
                newBearing = result.bearing
            } else {
                // ── Direct linear interpolation fallback ──
                // When route shape hasn't loaded yet, still move markers
                // toward the target GPS so they don't freeze on the map.
                let t = min(1.0, elapsed / duration)
                let lat = prev.lat + (targetCoord.latitude - prev.lat) * t
                let lon = prev.lon + (targetCoord.longitude - prev.lon) * t
                newCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                newBearing = nil
            }

            let currentLoc = CLLocation(latitude: updated[i].lat, longitude: updated[i].lon)
            let newLoc = CLLocation(
                latitude: newCoord.latitude, longitude: newCoord.longitude)
            if newLoc.distance(from: currentLoc) >= moveThreshold {
                updated[i] = updated[i].withInterpolatedPosition(
                    lat: newCoord.latitude,
                    lon: newCoord.longitude,
                    bearing: newBearing ?? updated[i].bearing ?? 0
                )
                anyMoved = true
            }
            ArrivalETAEngine.recordPosition(
                vehicleKey: vid,
                coordinate: newCoord)
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
            let ts = arrival.scheduledTime
                .timeIntervalSince1970
            let key =
                arrival.tripId
                ?? "\(arrival.direction)"
                + "-\(arrival.destination ?? "unk")"
                + "-\(ts)"
            trips[key, default: []].append(arrival)
        }

        // Snapshot current display positions before rebuilding.
        for v in trainVehicles {
            _previousTrainPositions[v.id] = CLLocationCoordinate2D(
                latitude: v.lat,
                longitude: v.lon
            )
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
                                let gap = nextStop.estimatedTime
                                    .timeIntervalSince(
                                        prevArrival.estimatedTime
                                    ) / 60.0
                                if gap > 0.5 && gap < 20 { return gap }
                            }
                        }
                        // Fallback: estimate from haversine distance
                        let dist = CLLocation(latitude: prevStop.lat, longitude: prevStop.lon)
                            .distance(from: CLLocation(
                                latitude: targetStop.lat,
                                longitude: targetStop.lon
                            ))
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
    /// - Parameter quick: When `true` (drag-to-search), tells the backend to
    ///   skip expensive bus backfill phases (D/E/F) for sub-second response.
    func refreshNearbyTransit(
        location: CLLocation?,
        skipGlobalFeeds: Bool = false,
        quick: Bool = false,
        silent: Bool = false
    ) async {
        guard let location = location else {
            errorMessage = "Location required"
            return
        }

        let refreshStart = Date()
        let launchElapsed = AppLogger.shared.timeSinceLaunch

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

        AppLogger.shared.log(
            "TIMING",
            message: "refreshNearbyTransit START "
                + "(T+\(AppLogger.formatDuration(launchElapsed)) "
                + "since launch, silent=\(silent))"
        )

        // ── Health gate: wait for backend before firing requests ────
        // When Render is cold-starting (after a crash/deploy/idle), the
        // backend returns 502 for 30-90 seconds.  Without this gate, the
        // app fires 6+ requests that all timeout (60s each), then retries
        // them — wasting 2+ minutes on doomed requests.
        //
        // The health probe runs in parallel with session cache loading,
        // so the user sees cached route cards and map polylines while we
        // wait.  Once /health returns 200, we know the backend is ready
        // and every subsequent request will succeed quickly.
        //
        // On normal launches (backend already warm), this resolves in <1ms.
        await TrackAPI.waitForBackendReady()

        // ── Cancel stale side-effect Tasks from the previous refresh ──
        // These fire-and-forget Tasks can outlive their refresh cycle.
        // If a slow OBA response returns *after* a new refresh has
        // already fetched fresh stops, the stale Task would overwrite
        // fresh data with old data. Cancel them here.
        _busStopsFetchTask?.cancel()
        _globalFeedsFetchTask?.cancel()
        _shapePrefetchTask?.cancel()

        // ── Bus stops: fire-and-forget ──────────────────────────────
        // Bus stops are supplementary metadata (used for distance badges).
        // Fetching them through OBA can be slow during cold starts (25 s+),
        // and `async let` structured concurrency forces us to await ALL
        // child tasks before the scope exits.  That kept `_refreshInFlight`
        // true for 50+ seconds even though `/nearby/grouped` data was ready
        // in 30 s.  By running bus stops in an unstructured Task, the
        // refresh completes as soon as grouped + stations arrive, and bus
        // stops update asynchronously afterward.
        //
        // During drag-to-search, rapid refreshes cancel previous tasks
        // before they complete. To avoid losing bus stop data entirely,
        // we keep the existing nearbyBusStops when cancelled — they may
        // be slightly stale but still useful for distance calculations.
        _busStopsFetchTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let stops = (try? await TrackAPI.fetchNearbyBusStops(
                lat: lat, lon: lon, radius: Self.busStopsNearbyRadius
            )) ?? self.nearbyBusStops
            // Don't discard results just because a new refresh started —
            // stale bus stops are better than no bus stops.
            let augmented = Self.augmentBusStops(stops, from: self.groupedTransit)
            // Only update if the stop set actually changed — avoids an
            // unnecessary @Observable notification that would cascade into
            // heavy NearbyDashboard body re-evaluations.
            let oldIDs = Set(self.nearbyBusStops.map(\.id))
            let newIDs = Set(augmented.map(\.id))
            if oldIDs != newIDs || augmented.count != self.nearbyBusStops.count {
                self.nearbyBusStops = augmented
            }
            // Rebuild distance cache with fresh bus stop data.
            self.rebuildDistanceCache(location: location)
        }

        // ── Alerts + Accessibility ────────────────────────────────────
        // On warm launches (backend already up, we have previous data), fire
        // these at T+0 alongside /nearby/grouped — saves 1-3s wall-clock.
        // On cold start (no grouped data yet), DEFER these until after grouped
        // succeeds. The 1-CPU Render backend can't handle 5+ concurrent
        // requests during cold start — alerts/access timeout and grouped is
        // delayed. By deferring, only 3 requests hit at once (grouped +
        // stations + bus stops), and alerts fire once the backend is proven warm.
        let isFirstLoad = groupedTransit.isEmpty
        if !skipGlobalFeeds && !isFirstLoad {
            _globalFeedsFetchTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                await self.refreshGlobalFeeds()
            }
        }

        do {
            // Fire grouped arrivals and station metadata in parallel.
            // Grouped is the critical path; stations refine distance badges.
            //
            // FIX: The combined endpoint (/nearby/grouped without mode filter)
            // can time out on subway when the search radius is large (8047m).
            // The backend processes bus + rail + subway in parallel with a 42s
            // budget, but with large radii the subway task runs out of time.
            //
            // To fix this, we also fire a dedicated subway request (mode=subway)
            // in parallel. If subway is missing from the combined response but
            // present in the dedicated response, we merge it in.
            let groupedStart = Date()
            async let groupedTask = TrackAPI.fetchNearbyGrouped(lat: lat, lon: lon, quick: quick)
            async let subwayTask = TrackAPI.fetchNearbyGrouped(lat: lat, lon: lon, mode: "subway", quick: quick)
            async let stationsTask = repository.fetchNearbyStations(
                latitude: lat, longitude: lon
            )

            // Await combined first, then merge subway if needed
            let combined = try await groupedTask
            let subway = (try? await subwayTask) ?? []
            
            // Count subway in combined response
            let combinedSubwayCount = combined.filter { $0.mode == "subway" }.count
            
            // Merge subway groups that aren't already in combined response
            var mergedGrouped = combined
            if combinedSubwayCount == 0 && !subway.isEmpty {
                let existingRouteIds = Set(combined.map(\.routeId))
                for group in subway where !existingRouteIds.contains(group.routeId) {
                    mergedGrouped.append(group)
                }
                AppLogger.shared.log(
                    "SUBWAY_FIX",
                    message: "Combined had 0 subway, merged \(subway.count) from dedicated fetch"
                )
            }

            // Keep ALL routes (including ghost/placeholder-only routes) so they
            // appear in the ghostRoutes computed property and are rendered in
            // the Inactive Lines section.  Downstream filters (filteredGroupedTransit,
            // filteredNearbyGroupedSubwayArrivals, etc.) already exclude ghosts
            // from the active dashboard via the hasRealArrivals guard.
            let newGrouped = mergedGrouped
            let groupedElapsed = Date().timeIntervalSince(groupedStart)
            let subwayCount = newGrouped.filter { $0.mode == "subway" && $0.hasRealArrivals }.count
            let busCount = newGrouped.filter { $0.mode == "bus" && $0.hasRealArrivals }.count
            AppLogger.shared.log(
                "TIMING",
                message: "  nearby/grouped → \(newGrouped.count) "
                    + "groups (\(subwayCount) subway, "
                    + "\(busCount) bus) in "
                    + "\(AppLogger.formatDuration(groupedElapsed))"
            )

            // Flat arrivals — exclude placeholder-only arrivals from ghost routes
            // so the flat arrival list doesn't show "99 min" stubs.
            let rawTransit = newGrouped
                .filter(\.hasRealArrivals)
                .flatMap(\ .directions)
                .flatMap(\ .arrivals)

            // Merge new grouped data with existing data using a multi-cycle
            // grace period so routes don't vanish when the MTA feed briefly
            // drops them.  A route survives up to 3 consecutive misses.
            groupedTransit = mergeGroupedTransit(
                new: newGrouped,
                existing: groupedTransit,
                isAtTransitSpeed: location.speed >= AppSettings.transitSpeedThreshold
            )

            // Fetch inactive routes from backend (fire-and-forget, non-blocking).
            // Send ALL grouped route names (including ghost routes) so the backend
            // doesn't return duplicates. Ghost routes are already shown in the
            // inactive section as GroupedRouteRow with full detail.
            let activeNames = newGrouped.map(\.displayName)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let inactive = try await TrackAPI.fetchInactiveRoutes(
                        lat: location.coordinate.latitude,
                        lon: location.coordinate.longitude,
                        activeRoutes: activeNames
                    )
                    await MainActor.run {
                        self.inactiveGroupedTransit = inactive
                    }
                } catch {
                    AppLogger.shared.log(
                        "INACTIVE",
                        message: "Failed to fetch inactive routes: \(error.localizedDescription)"
                    )
                }
            }

            // Server responded — cancel any in-flight cold-start retry chain
            // and reset the attempt counter so the next cold-start (after a
            // long idle period) starts fresh.
            _coldStartRetryTask?.cancel()
            _coldStartRetryTask = nil
            _coldStartRetryAttempt = 0

            // Update pulse state for station capsules with imminent arrivals
            mapSystem.updateImminentStations(from: groupedTransit)

            // Persist for instant display on next cold launch.
            // Include the fetch location so the next launch can detect
            // if the user has moved significantly since this data was saved.
            let fetchLocation: CLLocation = lastKnownUserLocation ?? location
            TransitSessionCache.save(groupedTransit, location: fetchLocation)

            if !rawTransit.isEmpty || nearbyTransit.isEmpty {
                // Deduplicate: Keep the first occurrence of each unique ID
                var seenIDs = Set<String>()
                nearbyTransit = rawTransit.filter { seenIDs.insert($0.id).inserted }
            } else {
                AppLogger.shared.log(
                    "REFRESH",
                    message: "API returned 0 flat arrivals "
                        + "but we had \(nearbyTransit.count) "
                        + "— keeping previous data"
                )
            }

            // NOTE: Frontend ML delay-factor prefetch removed. The backend's
            // /nearby/grouped endpoint already ML-corrects minutesAway via
            // LightGBM + recency + alert boost. Calling /predict/delay here
            // was redundant (same model) and caused double-dipping in
            // computeETA path 3. This saves ~6 HTTP requests per refresh cycle.

            // ── Shape prefetch: Transit-app-level instant opens ────────
            // Fire-and-forget background tasks to prefetch route shapes for
            // the top 3 bus routes while the user is still on the home screen.
            // When they tap a route, the shape is already in the LRU/disk
            // cache → stops list, polyline, and banner appear instantly.
            prefetchTopBusShapes(from: newGrouped.filter(\.hasRealArrivals))

            // On first load (cold start), global feeds were deferred until
            // grouped succeeds — fire them now that the backend is proven warm.
            if isFirstLoad && !skipGlobalFeeds {
                _globalFeedsFetchTask = Task { @MainActor [weak self] in
                    guard !Task.isCancelled else { return }
                    await self?.refreshGlobalFeeds()
                }
            }

            // Sync the selected route if it's currently open
            updateSelectedRouteFromRefreshedData(groupedTransit)

            let stations = (try? await stationsTask) ?? nearbyStations
            let stationsElapsed = Date().timeIntervalSince(groupedStart)
            AppLogger.shared.log(
                "TIMING",
                message: "  stations → \(stations.count) "
                    + "stations in "
                    + "\(AppLogger.formatDuration(stationsElapsed))"
            )
            // Augment nearbyStations with LIRR/MNR station data extracted from
            // grouped arrivals. The subway-only /stations/nearby endpoint never
            // returns commuter rail stations, so this keeps the primary
            // station-matching path working for all modes.
            nearbyStations = Self.augmentStations(stations, from: groupedTransit)

            // Pre-compute distance cache so dashboard body evaluations
            // do O(1) lookups instead of scanning nearbyBusStops/nearbyStations.
            rebuildDistanceCache(location: location)

            // ── Refresh complete: log timing summary ──
            let refreshElapsed = Date().timeIntervalSince(refreshStart)
            let totalFromLaunch = AppLogger.shared.timeSinceLaunch
            let finalSubwayCount = newGrouped.filter { $0.mode == "subway" && $0.hasRealArrivals }.count
            let finalBusCount = newGrouped.filter { $0.isBus && $0.hasRealArrivals }.count
            let commuterCount = newGrouped.filter { $0.isCommuterRail && $0.hasRealArrivals }.count
            let ghostCount = newGrouped.filter { !$0.hasRealArrivals }.count
            let launchDur = AppLogger.formatDuration(
                totalFromLaunch
            )
            let doneMsg = "refreshNearbyTransit DONE in "
                + "\(AppLogger.formatDuration(refreshElapsed))"
                + " — \(newGrouped.count) groups"
                + " (\(finalSubwayCount) subway,"
                + " \(finalBusCount) bus,"
                + " \(commuterCount) commuter,"
                + " \(ghostCount) ghost)"
                + " T+\(launchDur) since launch"
            AppLogger.shared.log("TIMING", message: doneMsg)

        } catch {
            let refreshElapsed = Date().timeIntervalSince(refreshStart)
            let elapsedStr = AppLogger.formatDuration(
                refreshElapsed
            )
            let launchFmt = AppLogger.shared
                .timeSinceLaunchFormatted
            let failMsg = "refreshNearbyTransit FAILED"
                + " after \(elapsedStr)"
                + " — \(error.localizedDescription)"
                + " (T+\(launchFmt) since launch)"
            AppLogger.shared.log("TIMING", message: failMsg)
            AppLogger.shared.logError("fetchNearbyTransit", error: error)
            errorMessage = (error as? TransitError)?.description ?? error.localizedDescription

            // ── Auto-retry on server error ─────────────────────────────
            // Schedule a retry chain with exponential backoff.
            // Fires on ANY 5xx failure — not just cold-start.
            // Render's proxy often returns 502 even after *some* endpoints
            // succeed (so serverWarmedUp can be true).  Check the error
            // type instead of the warmed-up flag.
            // Only one chain runs at a time — if `_coldStartRetryTask`
            // is already active, skip.  This prevents geometric explosion
            // where each failed fetch spawns a new independent retry that
            // itself spawns another on failure.
            let isServerError: Bool = {
                if case TrackAPIError.serverError = error { return true }
                if error.localizedDescription.contains("Server error") { return true }
                return !TrackAPI.serverWarmedUp  // also retry during cold start
            }()
            if isServerError && _coldStartRetryTask == nil {
                let attempt = _coldStartRetryAttempt
                guard attempt < Self.maxColdStartRetries else {
                    AppLogger.shared.log(
                        "REFRESH",
                        message: "⛔ Cold-start retry limit "
                            + "reached (\(attempt)"
                            + "/\(Self.maxColdStartRetries)) "
                            + "— waiting for timer"
                    )
                    return
                }
                let delay = min(3.0 * pow(2.0, Double(attempt)), 20.0) // 3, 6, 12, 20, 20
                AppLogger.shared.log(
                    "REFRESH",
                    message: "⏳ Cold-start retry "
                        + "#\(attempt + 1)"
                        + "/\(Self.maxColdStartRetries) "
                        + "scheduled (\(Int(delay)) s)"
                )
                let retryLocation = location
                _coldStartRetryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self._coldStartRetryTask = nil
                    self._coldStartRetryAttempt += 1
                    await self.refreshNearbyTransit(
                        location: retryLocation,
                        skipGlobalFeeds: skipGlobalFeeds,
                        quick: quick,
                        silent: true
                    )
                }
            }
        }

        // If no nearby transit found, search a wider radius for a recommendation
        if nearbyTransit.isEmpty && groupedTransit.isEmpty && errorMessage == nil {
            await fetchNearestMetro(location: location)
        }

        // Evict stale ETA engine entries that accumulate from departed vehicles.
        ArrivalETAEngine.evictStaleEntries()

        isLoading = false
    }

    // MARK: - Shape Prefetch

    /// Prefetches route shapes for the top N bus routes in the background.
    /// Called after each nearby refresh so shapes are cached before the user
    /// taps a route — eliminating the 0.3–0.7 s shape fetch on open.
    /// Only prefetches routes NOT already in the LRU or disk cache.

    func prefetchTopBusShapes(from groups: [GroupedNearbyTransitResponse]) {
        _shapePrefetchTask?.cancel()
        _shapePrefetchTask = Task { [weak self] in
            guard let self else { return }

            // Take the first 4 bus routes (sorted by soonest arrival, which
            // is the order the user is most likely to tap).
            let busRoutes = groups
                .filter { $0.isBus }
                .sorted { $0.soonestMinutes < $1.soonestMinutes }
                .prefix(4)

            for group in busRoutes {
                guard !Task.isCancelled else { return }
                // Skip if already cached (memory or disk)
                if self.getCachedRouteShape(for: group.routeId) != nil { continue }

                do {
                    let shape = try await TrackAPI.fetchRouteShape(routeID: group.routeId)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.cacheRouteShape(shape, for: group.routeId)
                    }
                    AppLogger.shared.log(
                        "SHAPE_PREFETCH",
                        message: "\(group.routeId) cached "
                            + "(\(shape.stops.count) stops)"
                    )
                    // Small yield to avoid hogging the event loop
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                } catch {
                    // Prefetch is best-effort — never propagate errors
                    AppLogger.shared.log(
                        "SHAPE_PREFETCH",
                        message: "\(group.routeId) failed: "
                            + "\(error.localizedDescription)"
                    )
                }
            }
        }
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
        source: String = "nearby",
        isAtTransitSpeed: Bool = false
    ) -> [GroupedNearbyTransitResponse] {
        // Server hiccup guard: if the API returned nothing keep previous data.
        guard !new.isEmpty || existing.isEmpty else {
            AppLogger.shared.log(
                "REFRESH",
                message: "[\(source)] API returned 0 "
                    + "grouped routes but we had "
                    + "\(existing.count) — keeping "
                    + "previous data"
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
                        !winner.directions.contains {
                            $0.direction.uppercased()
                                == newDir.direction.uppercased()
                        }
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
        // At transit speed (on a train/bus) routes fly by faster, so use
        // only 1 grace cycle to evict stale data sooner.
        let maxGraceCycles = isAtTransitSpeed ? 1 : 3
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
            // expired (> 90 s in the past).  Uses the model's `isExpired`
            // property — same check as `liveArrivals` and `visibleDirections`
            // — so all layers agree on when data is stale.
            if oldGroup.isExpired {
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
                message: "[\(source)] Grace "
                    + "\(count)/\(maxGraceCycles) "
                    + "for \(oldGroup.routeId) "
                    + "— keeping visible"
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

            nearbyGroupedSubwayArrivals = mergeGroupedTransit(
                new: filtered,
                existing: nearbyGroupedSubwayArrivals,
                source: "subway",
                isAtTransitSpeed: location.speed >= AppSettings.transitSpeedThreshold
            )

            // Update pulse state for station capsules with imminent arrivals
            mapSystem.updateImminentStations(from: nearbyGroupedSubwayArrivals)

            updateSelectedRouteFromRefreshedData(nearbyGroupedSubwayArrivals)

            let stations = (try? await stationsTask) ?? nearbyStations
            // Augment with subway AND existing commuter rail groups so a
            // subway-only refresh doesn't wipe LIRR/MNR station data from
            // nearbyStations (distance matching breaks otherwise).
            var allGroupsForAugment = nearbyGroupedSubwayArrivals as [GroupedNearbyTransitResponse]
            allGroupsForAugment += nearbyGroupedLIRRArrivals
            allGroupsForAugment += nearbyGroupedMNRArrivals
            nearbyStations = Self.augmentStations(stations, from: allGroupsForAugment)
            rebuildDistanceCache(location: location)
        } catch {            AppLogger.shared.logError("refreshSubway", error: error)
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

            nearbyGroupedBusArrivals = mergeGroupedTransit(
                new: filtered,
                existing: nearbyGroupedBusArrivals,
                source: "bus",
                isAtTransitSpeed: location.speed >= AppSettings.transitSpeedThreshold
            )

            updateSelectedRouteFromRefreshedData(nearbyGroupedBusArrivals)

            let stops: [BusStop]
            do {
                stops = try await nearbyBusStopsTask
            } catch {
                AppLogger.shared.logError("fetchNearbyBusStops", error: error)
                stops = nearbyBusStops
            }
            nearbyBusStops = Self.augmentBusStops(stops, from: nearbyGroupedBusArrivals)
            rebuildDistanceCache(location: location)

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
                    source: "lirr",
                    isAtTransitSpeed: loc.speed >= AppSettings.transitSpeedThreshold
                )
                // Inject LIRR station data so distance matching works
                nearbyStations = Self.augmentStations(nearbyStations, from: newGrouped)
                rebuildDistanceCache(location: loc)
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
                    source: "mnr",
                    isAtTransitSpeed: loc.speed >= AppSettings.transitSpeedThreshold
                )
                // Inject MNR station data so distance matching works
                nearbyStations = Self.augmentStations(nearbyStations, from: newGrouped)
                rebuildDistanceCache(location: loc)
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
    ///
    /// CRITICAL: When bus vehicle sync has already enriched the selected route
    /// with 100+ onward-call arrivals (per direction), the nearby API's 2-arrival
    /// response must NOT overwrite that data.  Instead we merge: keep the enriched
    /// arrivals as the base, and only fold in genuinely new nearby arrivals that
    /// the vehicle sync doesn't cover (e.g. scheduled-only entries).
    private func updateSelectedRouteFromRefreshedData(_ newGroups: [GroupedNearbyTransitResponse]) {
        guard let current = selectedGroupedRoute else { return }

        // Find the updated group that matches the current route ID
        guard let match = newGroups.first(where: { $0.routeId == current.routeId }) else { return }

        // ── Bus routes with active vehicle sync: MERGE instead of replace ────
        // The vehicle sync (`syncBusArrivals`) populates every direction with
        // 50-150+ arrivals from onwardCalls.  The nearby API only returns 1-4
        // per direction.  A wholesale replace causes the chip strip to flap
        // between 4 chips and 140+ chips every 20-40 seconds.
        //
        // Strategy: if the current group has significantly more arrivals than
        // the incoming nearby data (indicating an active vehicle sync), keep
        // the current group and only merge in nearby arrivals for stops that
        // the vehicle sync didn't reach.
        let currentTotal = current.directions.reduce(0) { $0 + $1.arrivals.count }
        let matchTotal = match.directions.reduce(0) { $0 + $1.arrivals.count }
        let isBusWithActiveSync = current.isBus
            && currentTotal > matchTotal * 3
            && currentTotal > 20

        if isBusWithActiveSync {
            // Merge: keep current enriched group, fold in nearby's scheduled-only
            // arrivals and update metadata (colorHex etc).
            var mergedDirections: [DirectionArrivalsResponse] = []
            for currentDir in current.directions {
                let matchDir = match.directions.first(
                    where: { $0.direction == currentDir.direction }
                )
                guard let matchDir else {
                    mergedDirections.append(currentDir)
                    continue
                }
                // Find nearby arrivals not already covered by the current set
                let existingKeys = Set(currentDir.arrivals.compactMap { $0.vehicleId ?? $0.tripId })
                let existingStopTs = Set(
                    currentDir.arrivals.map {
                        "\($0.stopId ?? "")_\($0.arrivalTs ?? 0)"
                    }
                )
                let newFromNearby = matchDir.arrivals.filter { arrival in
                    if let key = arrival.vehicleId ?? arrival.tripId, existingKeys.contains(key) {
                        return false
                    }
                    let stopTsKey = "\(arrival.stopId ?? "")_\(arrival.arrivalTs ?? 0)"
                    return !existingStopTs.contains(stopTsKey)
                }
                let merged = currentDir.arrivals + newFromNearby
                mergedDirections.append(DirectionArrivalsResponse(
                    direction: currentDir.direction,
                    directionLabel: currentDir.directionLabel ?? matchDir.directionLabel,
                    arrivals: merged
                ))
            }
            let mergedGroup = GroupedNearbyTransitResponse(
                routeId: current.routeId,
                displayName: match.displayName,
                mode: match.mode,
                colorHex: match.colorHex ?? current.colorHex,
                directions: mergedDirections,
                sortingKey: match.sortingKey.isEmpty ? current.sortingKey : match.sortingKey,
                alerts: match.alerts.isEmpty ? current.alerts : match.alerts,
                expressRoutes: match.expressRoutes.isEmpty ? current.expressRoutes : match.expressRoutes,
                busServiceType: match.busServiceType ?? current.busServiceType
            )
            self.selectedGroupedRoute = mergedGroup
        } else {
            // Non-bus or no active sync — replace as before
            self.selectedGroupedRoute = match
        }
        // Re-apply shape-based direction ordering so direction indices
        // stay consistent with the route shape (and selectedStopId).
        if let shape = self.routeShape {
            self.enrichGroupWithShapeDirections(shape)
        }
        let syncSuffix = isBusWithActiveSync
            ? " (merged, kept \(currentTotal) arrivals)"
            : ""
        AppLogger.shared.log(
            "SYNC",
            message: "Updated selected route: "
                + "\(match.routeId)\(syncSuffix)"
        )
        #if DEBUG
        if let selected = self.selectedGroupedRoute {
            let snap = self.debugDirectionSnapshot(
                selected
            )
            AppLogger.shared.log(
                "SYNC",
                message: "Persist "
                    + "route=\(selected.routeId) "
                    + "mode=\(selected.mode) "
                    + "selectedDirIdx="
                    + "\(self.selectedDirectionIndex) "
                    + "snapshot=\(snap)"
            )
        }
        #endif
    }

    func debugDirectionSnapshot(
        _ group: GroupedNearbyTransitResponse
    ) -> String {
        group.directions.enumerated().map { index, direction in
            let rtCount = direction.arrivals
                .filter { $0.isRealTime }.count
            return "#\(index):\(direction.direction)"
                + "{all:\(direction.arrivals.count)"
                + ",live:\(direction.liveArrivals.count)"
                + ",rt:\(rtCount)}"
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
        _ subwayStations: [(stationID: String, name: String,
                           lat: Double, lon: Double,
                           routeIDs: [String])],
        from groups: [GroupedNearbyTransitResponse]
    ) -> [(stationID: String, name: String,
           lat: Double, lon: Double,
           routeIDs: [String])] {
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
                    crStops[key] = (
                        name: arrival.stopName,
                        lat: lat,
                        lon: lon,
                        routeIDs: [group.routeId]
                    )
                }
            }
        }

        guard !crStops.isEmpty else { return subwayStations }

        var result = subwayStations
        let existingIDs = Set(subwayStations.map(\.stationID))
        for (key, data) in crStops where !existingIDs.contains(key) {
            result.append((
                stationID: key,
                name: data.name,
                lat: data.lat,
                lon: data.lon,
                routeIDs: Array(data.routeIDs)
            ))
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
                    if !routes.contains(where: {
                        normalizeMTARouteToken($0)
                            == normalizeMTARouteToken(
                                group.routeId)
                    }) {
                        routes.append(group.routeId)
                        existing.routeIds = routes
                        stopMap[key] = existing
                        modifiedExisting = true
                    }
                } else if var pending = newStops[key] {
                    // Already queued from a different arrival — add route ID
                    var routes = pending.routeIds ?? []
                    if !routes.contains(where: {
                        normalizeMTARouteToken($0)
                            == normalizeMTARouteToken(
                                group.routeId)
                    }) {
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
