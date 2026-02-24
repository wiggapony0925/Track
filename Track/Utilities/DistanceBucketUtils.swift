//
//  DistanceBucketUtils.swift
//  Track
//
//  Shared distance-bucketing logic used by NearbyDashboard, SubwayDashboard,
//  BusDashboard, LIRRDashboard, and MNRDashboard. Centralised here so that
//  strict-ring enforcement, adaptive promotion, and radius-reading all live
//  in exactly one place.
//

import CoreLocation

private let distanceTieEpsilon: CLLocationDistance = 0.5

private func groupedDistanceSort(
    _ lhs: GroupedNearbyTransitResponse,
    _ rhs: GroupedNearbyTransitResponse,
    location: CLLocation
) -> Bool {
    let d1 = groupMinDistance(for: lhs, from: location)
    let d2 = groupMinDistance(for: rhs, from: location)
    if abs(d1 - d2) > distanceTieEpsilon { return d1 < d2 }
    if lhs.soonestMinutes != rhs.soonestMinutes { return lhs.soonestMinutes < rhs.soonestMinutes }
    let leftName = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
    if leftName != .orderedSame { return leftName == .orderedAscending }
    return lhs.routeId.localizedCaseInsensitiveCompare(rhs.routeId) == .orderedAscending
}

/// Shared deterministic sort for grouped routes.
/// - With location: closest → farthest, then soonest ETA, then stable name/id tiebreak.
/// - Without location: soonest ETA, then stable name/id tiebreak.
func sortGroupedByDistance(
    groups: [GroupedNearbyTransitResponse],
    from location: CLLocation?
) -> [GroupedNearbyTransitResponse] {
    guard let location else {
        return groups.sorted {
            if $0.soonestMinutes != $1.soonestMinutes { return $0.soonestMinutes < $1.soonestMinutes }
            let leftName = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if leftName != .orderedSame { return leftName == .orderedAscending }
            return $0.routeId.localizedCaseInsensitiveCompare($1.routeId) == .orderedAscending
        }
    }
    return groups.sorted { groupedDistanceSort($0, $1, location: location) }
}

private func flatArrivalDistanceSort(
    _ lhs: NearbyTransitResponse,
    _ rhs: NearbyTransitResponse,
    location: CLLocation
) -> Bool {
    let d1 = arrivalDistance(for: lhs, from: location)
    let d2 = arrivalDistance(for: rhs, from: location)
    if abs(d1 - d2) > distanceTieEpsilon { return d1 < d2 }
    if lhs.minutesAway != rhs.minutesAway { return lhs.minutesAway < rhs.minutesAway }
    let leftRoute = lhs.routeId.localizedCaseInsensitiveCompare(rhs.routeId)
    if leftRoute != .orderedSame { return leftRoute == .orderedAscending }
    return lhs.stopName.localizedCaseInsensitiveCompare(rhs.stopName) == .orderedAscending
}

// MARK: - Distance Helpers

/// Returns the minimum distance from a reference location to any stop in a
/// grouped transit response (i.e. the closest entrance / stop).
func groupMinDistance(
    for group: GroupedNearbyTransitResponse,
    from location: CLLocation
) -> CLLocationDistance {
    let allArrivals = group.directions.flatMap { $0.arrivals }
    let distances = allArrivals.compactMap { arrival -> CLLocationDistance? in
        guard let lat = arrival.stopLat, let lon = arrival.stopLon else { return nil }
        return location.distance(from: CLLocation(latitude: lat, longitude: lon))
    }
    return distances.min() ?? Double.greatestFiniteMagnitude
}

/// Returns the distance from a reference location to a single flat arrival.
func arrivalDistance(
    for arrival: NearbyTransitResponse,
    from location: CLLocation
) -> CLLocationDistance {
    guard let lat = arrival.stopLat, let lon = arrival.stopLon else {
        return Double.greatestFiniteMagnitude
    }
    return location.distance(from: CLLocation(latitude: lat, longitude: lon))
}

// MARK: - Grouped Bucketing (3 tiers)

/// Separates grouped transit responses into three strict, non-overlapping
/// distance rings based on the user's current radius settings.
///
/// Ring 1 — "Near You":       `[0 … R1]`
/// Ring 2 — "A Bit Farther":  `(R1 … R2]`   (strictly outside ring 1)
/// Ring 3 — "Much Farther":   `(R2 … R3]`   (strictly outside ring 2)
///
/// Never promotes outer-ring routes into inner rings, and never includes
/// routes outside `R3`. This keeps section boundaries truthful to settings.
func separateGroupsByDistance(
    groups: [GroupedNearbyTransitResponse],
    from location: CLLocation?
) -> (nearYou: [GroupedNearbyTransitResponse],
      fartherAway: [GroupedNearbyTransitResponse],
      muchFarther: [GroupedNearbyTransitResponse]) {

    guard let location = location else {
        return (groups, [], [])
    }

    // Read current settings
    let rawR1 = AppSettings.shared.nearYouRadiusMeters
    let rawR2 = AppSettings.shared.fartherAwayRadiusMeters
    let rawR3 = AppSettings.shared.muchFartherAwayRadiusMeters

    // Enforce monotonic ring ordering without expanding user-configured circles.
    // If synced values are inconsistent, clamp minimally so boundaries remain valid.
    let r1 = rawR1
    let r2 = max(rawR2, r1)
    let r3 = max(rawR3, r2)

    var nearYou:     [GroupedNearbyTransitResponse] = []
    var fartherAway: [GroupedNearbyTransitResponse] = []
    var muchFarther: [GroupedNearbyTransitResponse] = []

    for group in groups {
        let hasCoordinates = group.directions.flatMap(\.arrivals).contains {
            $0.stopLat != nil && $0.stopLon != nil
        }
        if !hasCoordinates {
            muchFarther.append(group)
            continue
        }

        let dist = groupMinDistance(for: group, from: location)
        if dist <= r1 {
            nearYou.append(group)
        } else if dist <= r2 {
            fartherAway.append(group)
        } else if dist <= r3 {
            muchFarther.append(group)
        }
    }

    // Sort within each tier: closest stop first (top → bottom = nearest → farthest)
    nearYou.sort     { groupedDistanceSort($0, $1, location: location) }
    fartherAway.sort { groupedDistanceSort($0, $1, location: location) }
    muchFarther.sort { groupedDistanceSort($0, $1, location: location) }

    // Debug: log final tier assignments with distances
    #if DEBUG
    let tierLog: (String, [GroupedNearbyTransitResponse]) -> Void = { tier, items in
        for g in items {
            let d = groupMinDistance(for: g, from: location)
            let hasCoords = g.directions.flatMap(\.arrivals).contains { $0.stopLat != nil && $0.stopLon != nil }
            AppLogger.shared.log("SORT", message: "\(tier) | \(g.displayName) (\(g.routeId)) → \(Int(d))m  coords=\(hasCoords)")
        }
    }
    if !nearYou.isEmpty || !fartherAway.isEmpty || !muchFarther.isEmpty {
        AppLogger.shared.log("SORT", message: "── Tier breakdown  R1=\(Int(r1))m  R2=\(Int(r2))m  R3=\(Int(r3))m  ref=(\(String(format: "%.5f", location.coordinate.latitude)), \(String(format: "%.5f", location.coordinate.longitude))) ──")
        tierLog("Near You     ", nearYou)
        tierLog("A Bit Farther", fartherAway)
        tierLog("Much Farther ", muchFarther)
    }
    #endif

    return (nearYou, fartherAway, muchFarther)
}

// MARK: - Flat Arrival Bucketing (2 tiers)

/// Separates flat arrivals into "Near You" and "Farther Away" using strict
/// non-overlapping rings. Never promotes outer-ring arrivals into "Near You".
func separateFlatArrivalsByDistance(
    arrivals: [NearbyTransitResponse],
    from location: CLLocation?
) -> (nearYou: [NearbyTransitResponse],
      fartherAway: [NearbyTransitResponse]) {

    guard let location = location else {
        return (arrivals, [])
    }

    let rawR1 = AppSettings.shared.nearYouRadiusMeters
    let r1 = rawR1

    var nearYou:     [NearbyTransitResponse] = []
    var fartherAway: [NearbyTransitResponse] = []

    for arrival in arrivals {
        let dist = arrivalDistance(for: arrival, from: location)
        if dist <= r1 {
            nearYou.append(arrival)
        } else {
            // Everything beyond r1 goes into "Farther Away".
            // Never silently drop data the API returned.
            fartherAway.append(arrival)
        }
    }

    // Sort within each tier: closest stop first
    nearYou.sort     { flatArrivalDistanceSort($0, $1, location: location) }
    fartherAway.sort { flatArrivalDistanceSort($0, $1, location: location) }

    return (nearYou, fartherAway)
}
