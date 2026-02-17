//
//  DistanceBucketUtils.swift
//  Track
//
//  Shared distance-bucketing logic used by NearbyDashboard, SubwayDashboard,
//  and BusDashboard. Centralised here so that strict-ring enforcement,
//  adaptive promotion, and radius-reading all live in exactly one place.
//

import CoreLocation

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
/// **Adaptive promotion:** When "Near You" is empty the closest 4 routes
/// from the outer rings are promoted so the user always sees something.
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

    // Enforce strict ring ordering with a 100m minimum gap
    let r1 = rawR1
    let r2 = max(rawR2, r1 + 100)
    let r3 = max(rawR3, r2 + 100)

    var nearYou:     [GroupedNearbyTransitResponse] = []
    var fartherAway: [GroupedNearbyTransitResponse] = []
    var muchFarther: [GroupedNearbyTransitResponse] = []

    for group in groups {
        let dist = groupMinDistance(for: group, from: location)
        if dist <= r1 {
            nearYou.append(group)
        } else if dist <= r2 {
            fartherAway.append(group)
        } else if dist <= r3 {
            muchFarther.append(group)
        }
        // Beyond r3 → dropped; the API shouldn't have returned these
    }

    // Adaptive promotion
    if nearYou.isEmpty && (!fartherAway.isEmpty || !muchFarther.isEmpty) {
        var outer = fartherAway + muchFarther
        outer.sort { groupMinDistance(for: $0, from: location) < groupMinDistance(for: $1, from: location) }
        let promoteCount = min(4, outer.count)
        let promoted    = Array(outer.prefix(promoteCount))
        let promotedIds = Set(promoted.map(\.routeId))

        nearYou     = promoted
        fartherAway = fartherAway.filter  { !promotedIds.contains($0.routeId) }
        muchFarther = muchFarther.filter  { !promotedIds.contains($0.routeId) }
    }

    return (nearYou, fartherAway, muchFarther)
}

// MARK: - Flat Arrival Bucketing (2 tiers)

/// Separates flat arrivals into "Near You" and "Farther Away" using strict
/// non-overlapping rings. Also applies adaptive promotion when nothing is
/// within the first ring.
func separateFlatArrivalsByDistance(
    arrivals: [NearbyTransitResponse],
    from location: CLLocation?
) -> (nearYou: [NearbyTransitResponse],
      fartherAway: [NearbyTransitResponse]) {

    guard let location = location else {
        return (arrivals, [])
    }

    let rawR1 = AppSettings.shared.nearYouRadiusMeters
    let rawR2 = AppSettings.shared.fartherAwayRadiusMeters
    let r1 = rawR1
    let r2 = max(rawR2, r1 + 100)

    var nearYou:     [NearbyTransitResponse] = []
    var fartherAway: [NearbyTransitResponse] = []

    for arrival in arrivals {
        let dist = arrivalDistance(for: arrival, from: location)
        if dist <= r1 {
            nearYou.append(arrival)
        } else if dist <= r2 {
            fartherAway.append(arrival)
        }
    }

    // Adaptive promotion
    if nearYou.isEmpty && !fartherAway.isEmpty {
        var sorted = fartherAway
        sorted.sort { arrivalDistance(for: $0, from: location) < arrivalDistance(for: $1, from: location) }
        let promoteCount = min(6, sorted.count)
        nearYou     = Array(sorted.prefix(promoteCount))
        fartherAway = Array(sorted.dropFirst(promoteCount))
    }

    return (nearYou, fartherAway)
}
