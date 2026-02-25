//
//  ArrivalETAEngine.swift
//  Track
//
//  Smart ETA calculator that uses live vehicle positions, route polyline
//  distance, and real-time speed estimation to compute accurate arrival
//  times. Falls back to the feed's arrivalTs when no vehicle position
//  is available.
//
//  Algorithm summary
//  -----------------
//  1. If a live vehicle GPS coord + a route polyline exist:
//     a. Measure distance along the polyline from vehicle → stop.
//     b. Estimate speed from recent position history (or use mode defaults).
//     c. If vehicle is dwelling near a preceding stop, subtract expected
//        dwell time so the timer does not stall.
//     d. If vehicle is within 50 m of the TARGET stop → "Now".
//     e. Blend position-based ETA with the feed's arrivalTs countdown:
//        - Close stop (< 500 m): 70% position / 30% feed.
//        - Mid range (500 m–2 km): linear blend.
//        - Far (> 2 km): 30% position / 70% feed.
//     f. Smooth the result against the previous blended ETA to prevent
//        the timer jumping backwards when a vehicle dwells at an
//        intermediate stop.
//  2. Fall back to arrivalTs countdown (pure feed).
//  3. Fall back to static minutesAway.
//
//  Uses VehicleInterpolator (already in Utilities/) to snap vehicles
//  to polylines and measure distance along the actual route path.
//

import CoreLocation
import Foundation

// MARK: - ETA Result

/// The computed ETA for a single arrival, with context about how it was derived.
struct SmartETA {
    /// Seconds until the vehicle reaches the stop. Always >= 0.
    let secondsRemaining: Double
    /// Minutes (convenience). Rounds up so "0 min" only shows at ≤30s.
    var minutesRemaining: Int { max(0, Int(ceil(secondsRemaining / 60))) }
    /// True when the vehicle is within ~50m of the stop — show "Now".
    let isAtStop: Bool
    /// True when the arrival timestamp is in the past — the vehicle already
    /// passed this stop and should be removed from the list.
    let isPastArrival: Bool
    /// How the ETA was computed.
    let source: ETASource
    /// Average speed used (m/s), if computed from position data.
    let estimatedSpeedMps: Double?

    enum ETASource: String {
        /// Derived from live vehicle GPS + polyline distance.
        case vehiclePosition
        /// Used the feed's arrivalTs countdown (no vehicle position available).
        case feedTimestamp
        /// Static minutesAway from the feed (no timestamp, no vehicle).
        case staticMinutes
    }
}

// MARK: - ETA Context

/// Lightweight bundle of live data needed to compute a position-aware ETA.
/// Pass this from the ViewModel into NearbyTransitRow so rows outside
/// RouteDetailSheet can also benefit from vehicle-position ETAs.
struct ETAContext {
    /// Live GPS coordinate of the vehicle (bus or train), if known.
    let vehicleCoord: CLLocationCoordinate2D?
    /// Coordinate of the destination stop.
    let stopCoord: CLLocationCoordinate2D?
    /// Decoded route polyline for measuring distance along the actual path.
    let polyline: [CLLocationCoordinate2D]?
    /// Unique vehicle or trip ID used to look up speed history.
    let vehicleKey: String?
}

// MARK: - Engine

@MainActor
enum ArrivalETAEngine {

    // MARK: - Position History (for speed estimation)

    /// Stores recent positions so we can compute actual vehicle speed
    /// instead of assuming a constant. Keyed by vehicleId or tripId.
    private static var positionHistory: [String: [PositionSample]] = [:]
    /// Max samples to keep per vehicle — enough for ~2 min of 15s updates.
    private static let maxSamples = 10

    /// Smoothed ETA per vehicle — prevents the countdown jumping backwards
    /// when a vehicle dwells at an intermediate stop.
    /// Keyed by vehicleKey. Value is (seconds remaining, wall-clock timestamp).
    private static var smoothedETA: [String: (seconds: Double, timestamp: Date)] = [:]

    struct PositionSample {
        let coordinate: CLLocationCoordinate2D
        let timestamp: Date
    }

    /// Records a vehicle's current position. Call this each time you get a
    /// fresh GPS update (bus poll, GTFS-RT update, interpolation tick).
    /// The engine uses the history to compute real speed.
    static func recordPosition(
        vehicleKey: String,
        coordinate: CLLocationCoordinate2D,
        at time: Date = .now
    ) {
        var samples = positionHistory[vehicleKey] ?? []
        samples.append(PositionSample(coordinate: coordinate, timestamp: time))
        // Keep only the most recent samples
        if samples.count > maxSamples {
            samples = Array(samples.suffix(maxSamples))
        }
        positionHistory[vehicleKey] = samples
    }

    /// Clears history for a vehicle (e.g. when it completes its trip).
    static func clearHistory(for vehicleKey: String) {
        positionHistory.removeValue(forKey: vehicleKey)
        smoothedETA.removeValue(forKey: vehicleKey)
    }

    // MARK: - Compute Smart ETA

    /// Computes a smart ETA for a vehicle heading toward a stop.
    ///
    /// Priority:
    /// 1. If we have the vehicle's live position AND a route polyline,
    ///    measure distance along the polyline from vehicle → stop,
    ///    estimate speed from position history (or use mode defaults),
    ///    and compute ETA = distance / speed.
    /// 2. If the vehicle is within 50m of the stop → "Now".
    /// 3. Dwell detection: if speed ≈ 0 and vehicle is within 150 m of
    ///    the stop, it's arriving — show "Now".
    /// 4. Fall back to arrivalTs countdown.
    /// 5. Fall back to static minutesAway.
    ///
    /// - Parameters:
    ///   - vehicleCoord: The vehicle's current GPS position (nil if unknown).
    ///   - vehicleKey: Unique ID for speed history (vehicleId or tripId).
    ///   - stopCoord: The destination stop's coordinates.
    ///   - polyline: The route's decoded polyline (for measuring distance along route).
    ///   - arrivalTs: The feed's predicted arrival epoch (if available).
    ///   - staticMinutes: The feed's minutesAway value (last resort).
    ///   - mode: Transit mode — affects default speed assumptions.
    static func computeETA(
        vehicleCoord: CLLocationCoordinate2D?,
        vehicleKey: String?,
        stopCoord: CLLocationCoordinate2D?,
        polyline: [CLLocationCoordinate2D]? = nil,
        arrivalTs: Int? = nil,
        staticMinutes: Int = 99,
        mode: String = "subway"
    ) -> SmartETA {

        // Check if arrivalTs is in the past (vehicle already came and went).
        // 90-second grace period allows for brief dwell time / door open.
        let isPast: Bool = {
            guard let ts = arrivalTs else { return false }
            let elapsed = Date.now.timeIntervalSince1970 - Double(ts)
            return elapsed > 90  // More than 90s past → gone
        }()

        // ── 1. Try vehicle-position-based ETA ──
        if let vCoord = vehicleCoord, let sCoord = stopCoord {
            let straightLine = CLLocation(latitude: vCoord.latitude, longitude: vCoord.longitude)
                .distance(from: CLLocation(latitude: sCoord.latitude, longitude: sCoord.longitude))

            // Vehicle is at the stop (within 50 m)
            if straightLine < 50 {
                if let key = vehicleKey { smoothedETA.removeValue(forKey: key) }
                return SmartETA(
                    secondsRemaining: 0, isAtStop: true, isPastArrival: isPast,
                    source: .vehiclePosition, estimatedSpeedMps: nil)
            }

            // Measure distance along the polyline if available
            let routeDistance: Double
            if let poly = polyline, poly.count >= 2 {
                routeDistance = distanceAlongPolyline(
                    from: vCoord, to: sCoord, polyline: poly)
                    ?? straightLine * 1.3  // Fallback: inflate straight-line by 30%
            } else {
                // No polyline — inflate straight-line to approximate route distance
                routeDistance = straightLine * 1.3
            }

            // Estimate speed from position history
            let speed = estimateSpeed(
                vehicleKey: vehicleKey, mode: mode, routeDistance: routeDistance)

            // ── Dwell detection ──
            // If the vehicle is stopped (speed ≈ 0) and is very close to the
            // DESTINATION stop, it is arriving — treat as "Now" rather than stalled.
            if speed < 0.5, routeDistance < 150 {
                if let key = vehicleKey { smoothedETA.removeValue(forKey: key) }
                return SmartETA(
                    secondsRemaining: 0, isAtStop: true, isPastArrival: isPast,
                    source: .vehiclePosition, estimatedSpeedMps: 0)
            }

            // If completely stopped but not near the destination stop, fall
            // back to the feed timestamp (the driver / operator determines
            // when they leave the current stop).
            if speed < 0.5 {
                if let ts = arrivalTs {
                    let feedSeconds = max(0, Double(ts) - Date.now.timeIntervalSince1970)
                    return smoothed(
                        vehicleKey: vehicleKey,
                        raw: SmartETA(
                            secondsRemaining: feedSeconds, isAtStop: false,
                            isPastArrival: isPast,
                            source: .feedTimestamp, estimatedSpeedMps: 0))
                }
                let eta = routeDistance / defaultSpeed(for: mode)
                return smoothed(
                    vehicleKey: vehicleKey,
                    raw: SmartETA(
                        secondsRemaining: eta, isAtStop: false, isPastArrival: isPast,
                        source: .vehiclePosition, estimatedSpeedMps: defaultSpeed(for: mode)))
            }

            let positionETA = routeDistance / speed

            // Subtract mode-specific expected dwell time at intermediate stops.
            // When the vehicle is sitting at a stop before ours, the raw ETA
            // inflates by the full dwell duration. This correction prevents
            // the countdown stalling while the vehicle waits at a preceding stop.
            let dwellCorrection = dwellTimeCorrection(mode: mode, routeDistance: routeDistance)
            let correctedPositionETA = max(0, positionETA - dwellCorrection)

            if let ts = arrivalTs {
                let feedSeconds = max(0, Double(ts) - Date.now.timeIntervalSince1970)
                let blended = blendETAs(
                    positionSeconds: correctedPositionETA,
                    feedSeconds: feedSeconds,
                    routeDistance: routeDistance)

                return smoothed(
                    vehicleKey: vehicleKey,
                    raw: SmartETA(
                        secondsRemaining: blended, isAtStop: false, isPastArrival: isPast,
                        source: .vehiclePosition, estimatedSpeedMps: speed))
            }

            return smoothed(
                vehicleKey: vehicleKey,
                raw: SmartETA(
                    secondsRemaining: correctedPositionETA, isAtStop: false, isPastArrival: isPast,
                    source: .vehiclePosition, estimatedSpeedMps: speed))
        }

        // ── 2. Fall back to arrivalTs ──
        if let ts = arrivalTs {
            let rawSeconds = Double(ts) - Date.now.timeIntervalSince1970
            let seconds = max(0, rawSeconds)
            return SmartETA(
                secondsRemaining: seconds, isAtStop: seconds <= 30,
                isPastArrival: isPast,
                source: .feedTimestamp, estimatedSpeedMps: nil)
        }

        // ── 3. Static minutesAway ──
        return SmartETA(
            secondsRemaining: Double(staticMinutes) * 60, isAtStop: false,
            isPastArrival: staticMinutes <= 0,
            source: .staticMinutes, estimatedSpeedMps: nil)
    }

    // MARK: - Distance Along Polyline

    /// Measures the distance along a polyline from point A to point B.
    /// Returns nil if either point can't be snapped to the polyline.
    static func distanceAlongPolyline(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> Double? {
        guard let snapFrom = VehicleInterpolator.snap(coordinate: from, to: polyline),
              let snapTo = VehicleInterpolator.snap(coordinate: to, to: polyline)
        else { return nil }

        // If the snap is too far from the polyline (>500m), the vehicle
        // might be off-route — don't trust the polyline distance.
        guard snapFrom.distanceFromPolyline < 500,
              snapTo.distanceFromPolyline < 500
        else { return nil }

        let totalLength = VehicleInterpolator.polylineLength(polyline)
        let fromDist = snapFrom.fractionAlongPolyline * totalLength
        let toDist = snapTo.fractionAlongPolyline * totalLength

        // Distance is absolute — vehicle could be before or after the stop
        return abs(toDist - fromDist)
    }

    // MARK: - Speed Estimation

    /// Estimates the vehicle's current speed from position history.
    /// Returns m/s. Falls back to mode-specific defaults if history is thin.
    private static func estimateSpeed(
        vehicleKey: String?,
        mode: String,
        routeDistance: Double
    ) -> Double {
        guard let key = vehicleKey,
              let samples = positionHistory[key],
              samples.count >= 2
        else {
            return defaultSpeed(for: mode)
        }

        // Use the last few samples to compute average speed
        let recent = Array(samples.suffix(4))
        var totalDist: Double = 0
        var totalTime: TimeInterval = 0

        for i in 1..<recent.count {
            let prev = recent[i - 1]
            let curr = recent[i]
            let dt = curr.timestamp.timeIntervalSince(prev.timestamp)
            guard dt > 0 else { continue }
            let dist = CLLocation(latitude: prev.coordinate.latitude, longitude: prev.coordinate.longitude)
                .distance(from: CLLocation(latitude: curr.coordinate.latitude, longitude: curr.coordinate.longitude))
            totalDist += dist
            totalTime += dt
        }

        guard totalTime > 2 else {
            return defaultSpeed(for: mode)
        }

        let measuredSpeed = totalDist / totalTime  // m/s

        // Sanity bounds: if measured speed is near-zero the vehicle is stopped.
        // If it's unrealistically fast (>40 m/s ≈ 90mph), cap it.
        if measuredSpeed < 0.5 {
            // Vehicle appears stopped — check if it's been stopped for a while
            if totalTime > 15 {
                return 0  // Stopped for 15+ s → definitely dwelling
            }
            // Might just be a brief pause — use a fraction of default
            return defaultSpeed(for: mode) * 0.3
        }

        return min(measuredSpeed, 40.0)
    }

    /// Mode-specific default average speeds (m/s) for when we have no history.
    /// These are NYC-realistic averages including stops and dwell time.
    private static func defaultSpeed(for mode: String) -> Double {
        switch mode.lowercased() {
        case "bus":     return 4.5   // ~10 mph (NYC bus average with stops)
        case "subway":  return 9.0   // ~20 mph (NYC subway average with stops)
        case "lirr":    return 16.0  // ~36 mph (commuter rail average)
        case "mnr":     return 16.0  // ~36 mph (commuter rail average)
        default:        return 9.0
        }
    }

    // MARK: - Dwell Time Correction

    /// How long a vehicle typically dwells at a preceding stop before departing.
    /// Subtracted from the position-based ETA when the vehicle is NOT at the
    /// destination stop yet, so the countdown does not stall mid-journey.
    /// Only applied when routeDistance suggests the vehicle is mid-route.
    private static func dwellTimeCorrection(mode: String, routeDistance: Double) -> Double {
        // Only correct when vehicle is far enough to plausibly be at a prior stop.
        // Very close vehicles (< 200 m) are already approaching — do not subtract.
        guard routeDistance > 200 else { return 0 }
        switch mode.lowercased() {
        case "subway": return 30   // ~30 s average subway dwell
        case "bus":    return 15   // ~15 s bus stop dwell
        case "lirr", "mnr": return 0  // Commuter rail dwell is unpredictable
        default:       return 20
        }
    }

    // MARK: - ETA Smoothing

    /// Applies time-aware smoothing to prevent the countdown oscillating
    /// between "counting up" and "counting down."
    ///
    /// **Between TimelineView ticks** (< 3 s apart): the countdown ONLY
    /// decreases. If the raw ETA tries to increase, we project the
    /// expected value (previous − elapsed wall-clock time) and clamp.
    ///
    /// **After an API poll** (≥ 3 s since last evaluation): upward jumps
    /// are allowed but capped at +30 s to prevent wild swings from a
    /// single delayed poll.
    private static func smoothed(vehicleKey: String?, raw: SmartETA) -> SmartETA {
        guard let key = vehicleKey else { return raw }

        let rawSecs = raw.secondsRemaining
        let now = Date.now

        if let prev = smoothedETA[key] {
            let elapsed = now.timeIntervalSince(prev.timestamp)

            if elapsed < 3.0 {
                // ── Between TimelineView ticks — monotonic decrease only ──
                // The expected value is the previous smoothed value minus
                // how much wall-clock time passed (i.e. "count down normally").
                let expected = max(0, prev.seconds - elapsed)

                if rawSecs > expected {
                    // Raw ETA is HIGHER than expected → vehicle data fluctuation.
                    // Hold the smoothed countdown at the expected decreasing value.
                    smoothedETA[key] = (expected, now)
                    return SmartETA(
                        secondsRemaining: expected,
                        isAtStop: raw.isAtStop,
                        isPastArrival: raw.isPastArrival,
                        source: raw.source,
                        estimatedSpeedMps: raw.estimatedSpeedMps)
                }
            } else {
                // ── New data arrived (API poll, ≥ 3 s gap) ──
                // Allow controlled upward jump, capped at +30 s.
                let expectedAfterElapsed = max(0, prev.seconds - elapsed)
                if rawSecs > expectedAfterElapsed + 30 {
                    let damped = expectedAfterElapsed + 30
                    smoothedETA[key] = (damped, now)
                    return SmartETA(
                        secondsRemaining: damped,
                        isAtStop: raw.isAtStop,
                        isPastArrival: raw.isPastArrival,
                        source: raw.source,
                        estimatedSpeedMps: raw.estimatedSpeedMps)
                }
            }
        }

        smoothedETA[key] = (rawSecs, now)
        return raw
    }

    // MARK: - ETA Blending

    /// Blends position-based and feed-based ETAs.
    /// Close to the stop, position data is more accurate (we can see it coming).
    /// Far from the stop, the feed knows about intermediate stops/dwell times.
    private static func blendETAs(
        positionSeconds: Double,
        feedSeconds: Double,
        routeDistance: Double
    ) -> Double {
        // Within 500m: trust position data more (0.7 position, 0.3 feed)
        // 500m–2km: equal blend
        // Beyond 2km: trust feed more (0.3 position, 0.7 feed)
        let positionWeight: Double
        if routeDistance < 500 {
            positionWeight = 0.7
        } else if routeDistance < 2000 {
            // Linear interpolation from 0.7 to 0.3
            let t = (routeDistance - 500) / 1500
            positionWeight = 0.7 - t * 0.4
        } else {
            positionWeight = 0.3
        }

        let blended = positionSeconds * positionWeight + feedSeconds * (1 - positionWeight)

        // Never return less than the position-based ETA when vehicle is close
        // (prevents the timer jumping ahead of reality when vehicle is visibly approaching)
        if routeDistance < 300 {
            return max(blended, positionSeconds * 0.8)
        }

        return max(blended, 0)
    }
}
