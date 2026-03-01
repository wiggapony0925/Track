//
//  VehicleInterpolator.swift
//  Track
//
//  Polyline-aware interpolation engine for smooth vehicle movement.
//  Snaps vehicle positions to the nearest point on a route polyline
//  and interpolates along the actual route path between stops.
//
//  Used by HomeViewModel to animate subway trains, buses, and
//  commuter rail vehicles along their real-world routes.
//

import CoreLocation
import Foundation

// MARK: - Polyline Interpolator

/// Utility for interpolating positions along a route polyline.
enum VehicleInterpolator {

    // MARK: - Snap to Polyline

    /// Finds the closest point on a polyline to the given coordinate.
    /// Returns the snapped coordinate, the segment index, and the
    /// fractional distance along the polyline (0.0 → 1.0).
    struct SnapResult {
        let coordinate: CLLocationCoordinate2D
        let segmentIndex: Int
        /// Cumulative fractional distance along the full polyline (0.0 – 1.0).
        let fractionAlongPolyline: Double
        /// Distance in meters from the input point to the snapped point.
        let distanceFromPolyline: Double
    }

    /// Snaps a coordinate to the nearest point on the polyline.
    static func snap(
        coordinate: CLLocationCoordinate2D,
        to polyline: [CLLocationCoordinate2D]
    ) -> SnapResult? {
        guard polyline.count >= 2 else { return nil }

        var bestSnap: CLLocationCoordinate2D = polyline[0]
        var bestDist = Double.greatestFiniteMagnitude
        var bestSegment = 0
        var bestFractionInSegment: Double = 0

        for i in 0..<(polyline.count - 1) {
            let (proj, frac) = projectPointOntoSegment(
                point: coordinate, a: polyline[i], b: polyline[i + 1])
            let dist = haversine(proj, coordinate)
            if dist < bestDist {
                bestDist = dist
                bestSnap = proj
                bestSegment = i
                bestFractionInSegment = frac
            }
        }

        // Compute cumulative fraction along the whole polyline
        let totalLength = polylineLength(polyline)
        guard totalLength > 0 else {
            return SnapResult(
                coordinate: bestSnap, segmentIndex: bestSegment,
                fractionAlongPolyline: 0, distanceFromPolyline: bestDist)
        }
        var cumulative: Double = 0
        for i in 0..<bestSegment {
            cumulative += haversine(polyline[i], polyline[i + 1])
        }
        let segLen = haversine(polyline[bestSegment], polyline[bestSegment + 1])
        cumulative += segLen * bestFractionInSegment
        let fraction = cumulative / totalLength

        return SnapResult(
            coordinate: bestSnap, segmentIndex: bestSegment,
            fractionAlongPolyline: fraction, distanceFromPolyline: bestDist)
    }

    // MARK: - Interpolate Along Polyline

    /// Given a polyline and a fractional distance (0.0 – 1.0), returns
    /// the coordinate at that point along the polyline.
    static func interpolate(
        along polyline: [CLLocationCoordinate2D],
        fraction: Double
    ) -> CLLocationCoordinate2D? {
        guard polyline.count >= 2 else { return polyline.first }

        let t = min(max(fraction, 0), 1)
        if t <= 0 { return polyline.first }
        if t >= 1 { return polyline.last }

        let totalLength = polylineLength(polyline)
        let targetDist = totalLength * t
        var accumulated: Double = 0

        for i in 0..<(polyline.count - 1) {
            let segLen = haversine(polyline[i], polyline[i + 1])
            if accumulated + segLen >= targetDist {
                let remaining = targetDist - accumulated
                let segFrac = segLen > 0 ? remaining / segLen : 0
                return lerpCoord(polyline[i], polyline[i + 1], t: segFrac)
            }
            accumulated += segLen
        }
        return polyline.last
    }

    /// Returns the bearing (heading) at a given fraction along the polyline.
    static func bearing(
        along polyline: [CLLocationCoordinate2D],
        fraction: Double
    ) -> Double {
        guard polyline.count >= 2 else { return 0 }

        let t = min(max(fraction, 0), 1)
        let totalLength = polylineLength(polyline)
        let targetDist = totalLength * t
        var accumulated: Double = 0

        for i in 0..<(polyline.count - 1) {
            let segLen = haversine(polyline[i], polyline[i + 1])
            if accumulated + segLen >= targetDist || i == polyline.count - 2 {
                return bearingBetween(polyline[i], polyline[i + 1])
            }
            accumulated += segLen
        }
        return bearingBetween(polyline[polyline.count - 2], polyline[polyline.count - 1])
    }

    // MARK: - Interpolate Between Two Stops on a Polyline

    /// Computes an interpolated position between two stops using the actual
    /// polyline path. `progress` is 0.0 at `fromStop` and 1.0 at `toStop`.
    ///
    /// This follows the polyline segments between the stops rather than
    /// doing a straight-line lerp, giving realistic curved movement.
    ///
    /// Guards against inverted snap fractions: when `fromStop` snaps to a
    /// later point on the polyline than `toStop` (common on routes that
    /// double-back or share overlapping segments), the interpolated fraction
    /// would sweep backwards across the entire polyline, causing markers to
    /// glitch up and down the route.  When the span exceeds half the polyline
    /// or the fractions are inverted, we fall back to a safe straight-line lerp.
    static func interpolateBetweenStops(
        from fromStop: CLLocationCoordinate2D,
        to toStop: CLLocationCoordinate2D,
        progress: Double,
        along polyline: [CLLocationCoordinate2D]
    ) -> (coordinate: CLLocationCoordinate2D, bearing: Double) {
        guard polyline.count >= 2 else {
            let coord = lerpCoord(fromStop, toStop, t: progress)
            return (coord, bearingBetween(fromStop, toStop))
        }

        // Find the closest polyline fraction for each stop
        guard let snapFrom = snap(coordinate: fromStop, to: polyline),
              let snapTo = snap(coordinate: toStop, to: polyline)
        else {
            let coord = lerpCoord(fromStop, toStop, t: progress)
            return (coord, bearingBetween(fromStop, toStop))
        }

        let startFrac = snapFrom.fractionAlongPolyline
        let endFrac = snapTo.fractionAlongPolyline

        // Guard: if the snap fractions are inverted (end < start) or the
        // span covers more than half the polyline, the stops snapped to
        // the wrong parts of a looping/overlapping route.  Fall back to
        // straight-line lerp to prevent the marker from sweeping across
        // the entire polyline.
        let span = endFrac - startFrac
        if span <= 0 || span > 0.5 {
            let coord = lerpCoord(fromStop, toStop, t: progress)
            return (coord, bearingBetween(fromStop, toStop))
        }

        // Interpolate between the two fractions
        let targetFrac = startFrac + span * progress

        let coord = interpolate(along: polyline, fraction: targetFrac)
            ?? lerpCoord(fromStop, toStop, t: progress)
        let head = bearing(along: polyline, fraction: targetFrac)

        return (coord, head)
    }

    // MARK: - Smooth Bus Position

    /// Smoothly transitions a bus from its previous known position to
    /// its new GPS position along the route polyline.
    ///
    /// - Parameters:
    ///   - previous: The last known coordinate.
    ///   - current: The newly received GPS coordinate.
    ///   - elapsed: Seconds since the last GPS update.
    ///   - duration: Expected total seconds until the next GPS update.
    ///   - polyline: The route's decoded polyline.
    /// - Returns: An interpolated position along the polyline.
    static func smoothBusPosition(
        previous: CLLocationCoordinate2D,
        current: CLLocationCoordinate2D,
        elapsed: TimeInterval,
        duration: TimeInterval,
        along polyline: [CLLocationCoordinate2D]
    ) -> (coordinate: CLLocationCoordinate2D, bearing: Double) {
        let t = duration > 0 ? min(elapsed / duration, 1.0) : 1.0
        // Apply ease-in-out for natural deceleration
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2

        return interpolateBetweenStops(
            from: previous, to: current,
            progress: eased, along: polyline)
    }

    // MARK: - Private Helpers

    /// Projects a point onto a line segment (a→b) and returns the
    /// projected coordinate and the fraction along the segment (0–1).
    private static func projectPointOntoSegment(
        point: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> (CLLocationCoordinate2D, Double) {
        let dx = b.longitude - a.longitude
        let dy = b.latitude - a.latitude
        let lenSq = dx * dx + dy * dy

        if lenSq < 1e-18 { return (a, 0) }

        var t = ((point.longitude - a.longitude) * dx + (point.latitude - a.latitude) * dy) / lenSq
        t = min(max(t, 0), 1)

        return (
            CLLocationCoordinate2D(
                latitude: a.latitude + t * dy,
                longitude: a.longitude + t * dx
            ),
            t
        )
    }

    /// Haversine distance between two coordinates in meters.
    private static func haversine(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D
    ) -> Double {
        let R = 6_371_000.0 // Earth radius in meters
        let dLat = (b.latitude - a.latitude).degreesToRadians
        let dLon = (b.longitude - a.longitude).degreesToRadians
        let lat1 = a.latitude.degreesToRadians
        let lat2 = b.latitude.degreesToRadians

        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return R * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    /// Total length of a polyline in meters.
    static func polylineLength(_ polyline: [CLLocationCoordinate2D]) -> Double {
        guard polyline.count >= 2 else { return 0 }
        var total: Double = 0
        for i in 0..<(polyline.count - 1) {
            total += haversine(polyline[i], polyline[i + 1])
        }
        return total
    }

    /// Linear interpolation between two coordinates.
    private static func lerpCoord(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, t: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    /// Bearing from coordinate a to b in degrees (0–360).
    private static func bearingBetween(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = a.latitude.degreesToRadians
        let lat2 = b.latitude.degreesToRadians
        let dLon = (b.longitude - a.longitude).degreesToRadians

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var bearing = atan2(y, x).radiansToDegrees
        if bearing < 0 { bearing += 360 }
        return bearing
    }
}
