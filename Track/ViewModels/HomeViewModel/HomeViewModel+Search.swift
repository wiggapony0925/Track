// Search filtering computed properties extracted from HomeViewModel.
// Contains all filteredXxx computed vars and their private search helper methods.

import Foundation

extension HomeViewModel {

    // MARK: - Search Helpers

    /// Checks whether a `GroupedNearbyTransitResponse` matches the given query.
    /// Searches display name, route ID, directions, arrival stop names,
    /// destination names, AND all stations served by the route.
    func groupMatchesQuery(
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
    func stationRoutesForQuery(_ query: String) -> Set<String> {
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
    ///
    /// Groups whose real arrivals have ALL expired (arrivalTs > 90 s past)
    /// are stripped so stale "--" cards never appear.  Placeholder-only
    /// routes (no live data at all) are preserved so the user always sees
    /// every route that serves their area.
    var filteredGroupedTransit: [GroupedNearbyTransitResponse] {
        // During the stale-while-revalidate window (showStaleRows = true), keep
        // ALL cached groups — including expired ones — so route structure is
        // visible while the background refresh runs.  Expired groups render
        // with "--" arrival times and are replaced when fresh data arrives.
        // Without this guard, a session cache that is >90 s old produces an
        // empty list here, making the stale-while-revalidate optimization a
        // no-op and showing a blank screen until the network refresh finishes.
        let base = groupedTransit.filter { $0.hasRealArrivals && (!$0.isExpired || showStaleRows) }
        guard !searchText.isEmpty else { return base }
        let query = searchText.lowercased()
        let stationRoutes = stationRoutesForQuery(query)
        return base.filter {
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
        let source = (nearbyGroupedBusArrivals.isEmpty
            ? groupedTransit.filter { $0.mode == "bus" }
            : nearbyGroupedBusArrivals
        ).filter { $0.hasRealArrivals && (!$0.isExpired || showStaleRows) }
        guard !searchText.isEmpty else { return source }
        let query = searchText.lowercased()
        let stationRoutes = stationRoutesForQuery(query)
        return source.filter {
            groupMatchesQuery($0, query: query, stationRoutes: stationRoutes)
        }
    }

    /// Grouped subway arrivals filtered by search text (from the nearby/grouped API).
    var filteredNearbyGroupedSubwayArrivals: [GroupedNearbyTransitResponse] {
        let source = (nearbyGroupedSubwayArrivals.isEmpty
            ? groupedTransit.filter { $0.mode == "subway" }
            : nearbyGroupedSubwayArrivals
        ).filter { $0.hasRealArrivals && (!$0.isExpired || showStaleRows) }
        guard !searchText.isEmpty else { return source }
        let query = searchText.lowercased()
        let stationRoutes = stationRoutesForQuery(query)
        return source.filter {
            groupMatchesQuery($0, query: query, stationRoutes: stationRoutes)
        }
    }

    /// Grouped LIRR arrivals filtered by search text (from nearby/grouped API).
    var filteredNearbyGroupedLIRRArrivals: [GroupedNearbyTransitResponse] {
        let source = (nearbyGroupedLIRRArrivals.isEmpty
            ? groupedTransit.filter { $0.mode == "lirr" }
            : nearbyGroupedLIRRArrivals
        ).filter { $0.hasRealArrivals && (!$0.isExpired || showStaleRows) }
        guard !searchText.isEmpty else { return source }
        let query = searchText.lowercased()
        let stationRoutes = stationRoutesForQuery(query)
        return source.filter {
            groupMatchesQuery($0, query: query, stationRoutes: stationRoutes)
        }
    }

    /// Grouped Metro-North arrivals filtered by search text (from nearby/grouped API).
    var filteredNearbyGroupedMNRArrivals: [GroupedNearbyTransitResponse] {
        let source = (nearbyGroupedMNRArrivals.isEmpty
            ? groupedTransit.filter { $0.mode == "mnr" }
            : nearbyGroupedMNRArrivals
        ).filter { $0.hasRealArrivals && (!$0.isExpired || showStaleRows) }
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
}
