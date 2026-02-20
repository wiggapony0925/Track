//
//  TrackTests.swift
//  TrackTests
//
//  Created by Jeffrey Fernandez on 2/10/26.
//

import Testing
@testable import Track

struct TrackTests {

    // MARK: - DelayCalculator Tests

    @Test func delayCalculatorReturnsOriginalTimeInClearWeatherOffPeak() async throws {
        let prediction = DelayCalculator.predictLocally(
            mtaMinutes: 5,
            routeID: "L",
            timeOfDay: 14, // 2 PM, off-peak
            dayOfWeek: 4,  // Wednesday
            weather: .clear
        )
        #expect(prediction.adjustedMinutes == 5)
        #expect(prediction.adjustmentReason == nil)
    }

    @Test func delayCalculatorAppliesRushHourAdjustment() async throws {
        let prediction = DelayCalculator.predictLocally(
            mtaMinutes: 10,
            routeID: "4",
            timeOfDay: 8,  // 8 AM morning rush
            dayOfWeek: 3,  // Tuesday (weekday)
            weather: .clear
        )
        // Rush hour adds 10%, so 10 * 1.1 = 11
        #expect(prediction.adjustedMinutes == 11)
        #expect(prediction.adjustmentReason != nil)
        #expect(prediction.adjustmentReason!.contains("rush hour"))
    }

    @Test func delayCalculatorAppliesRainAdjustment() async throws {
        let prediction = DelayCalculator.predictLocally(
            mtaMinutes: 10,
            routeID: "L",
            timeOfDay: 14,
            dayOfWeek: 1,  // Sunday (not a weekday)
            weather: .rain
        )
        // Rain adds 10%, so 10 * 1.1 = 11
        #expect(prediction.adjustedMinutes == 11)
        #expect(prediction.adjustmentReason!.contains("rain"))
    }

    @Test func delayCalculatorAppliesSnowAdjustment() async throws {
        let prediction = DelayCalculator.predictLocally(
            mtaMinutes: 10,
            routeID: "L",
            timeOfDay: 14,
            dayOfWeek: 1,
            weather: .snow
        )
        // Snow adds 20%, so 10 * 1.2 = 12
        #expect(prediction.adjustedMinutes == 12)
        #expect(prediction.adjustmentReason!.contains("snow"))
    }

    @Test func delayCalculatorCombinesRushHourAndWeather() async throws {
        let prediction = DelayCalculator.predictLocally(
            mtaMinutes: 10,
            routeID: "A",
            timeOfDay: 17, // 5 PM evening rush
            dayOfWeek: 2,  // Monday (weekday)
            weather: .rain
        )
        // Rush hour 10% + Rain 10% = 1.2, so 10 * 1.2 = 12
        #expect(prediction.adjustedMinutes == 12)
        #expect(prediction.adjustmentReason!.contains("rush hour"))
        #expect(prediction.adjustmentReason!.contains("rain"))
    }

    @Test func delayCalculatorNoRushOnWeekend() async throws {
        let prediction = DelayCalculator.predictLocally(
            mtaMinutes: 10,
            routeID: "L",
            timeOfDay: 8,  // 8 AM but Saturday
            dayOfWeek: 7,  // Saturday
            weather: .clear
        )
        #expect(prediction.adjustedMinutes == 10)
        #expect(prediction.adjustmentReason == nil)
    }

    // MARK: - WeatherCondition Tests

    @Test func weatherConditionCodable() async throws {
        let conditions: [WeatherCondition] = [.clear, .rain, .snow]
        for condition in conditions {
            let data = try JSONEncoder().encode(condition)
            let decoded = try JSONDecoder().decode(WeatherCondition.self, from: data)
            #expect(decoded == condition)
        }
    }

    // MARK: - DelayPrediction Tests

    @Test func delayPredictionProperties() async throws {
        let prediction = DelayPrediction(
            adjustedMinutes: 6,
            originalMinutes: 5,
            adjustmentReason: "Adjusted for rain (+1m)",
            delayFactor: 1.2
        )
        #expect(prediction.adjustedMinutes == 6)
        #expect(prediction.originalMinutes == 5)
        #expect(prediction.delayFactor == 1.2)
        #expect(prediction.adjustmentReason == "Adjusted for rain (+1m)")
    }

    // MARK: - RouteSuggestion Tests

    @Test func routeSuggestionProperties() async throws {
        let suggestion = RouteSuggestion(
            routeID: "2",
            direction: "Uptown",
            destinationName: "Work",
            score: 5.0
        )
        #expect(suggestion.routeID == "2")
        #expect(suggestion.direction == "Uptown")
        #expect(suggestion.destinationName == "Work")
        #expect(suggestion.score == 5.0)
    }

    // MARK: - TransitError Tests

    @Test func transitErrorDescriptions() async throws {
        #expect(TransitError.networkUnavailable.description == "No network connection available")
        #expect(TransitError.feedParsingFailed.description == "Unable to read transit data")
        #expect(TransitError.signalLost.description == "Signal Lost in Tunnel")
    }

    // MARK: - Polyline Simplification Tests

    @Test func simplifyPolylinePreservesEndpoints() async throws {
        let coords: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
            CLLocationCoordinate2D(latitude: 40.7130, longitude: -74.0058),
            CLLocationCoordinate2D(latitude: 40.7132, longitude: -74.0056),
            CLLocationCoordinate2D(latitude: 40.7135, longitude: -74.0050),
        ]
        let simplified = simplifyPolyline(coords, tolerance: 0.001)
        #expect(simplified.first!.latitude == coords.first!.latitude)
        #expect(simplified.first!.longitude == coords.first!.longitude)
        #expect(simplified.last!.latitude == coords.last!.latitude)
        #expect(simplified.last!.longitude == coords.last!.longitude)
    }

    @Test func simplifyPolylineReducesCollinearPoints() async throws {
        // Three collinear points — the middle one should be removed
        let coords: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 40.7000, longitude: -74.0000),
            CLLocationCoordinate2D(latitude: 40.7500, longitude: -74.0000),
            CLLocationCoordinate2D(latitude: 40.8000, longitude: -74.0000),
        ]
        let simplified = simplifyPolyline(coords, tolerance: 0.0001)
        #expect(simplified.count == 2)
    }

    @Test func simplifyPolylineKeepsSharpTurns() async throws {
        // L-shaped path — the corner point must be preserved
        let coords: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 40.7000, longitude: -74.0000),
            CLLocationCoordinate2D(latitude: 40.7000, longitude: -73.9000),
            CLLocationCoordinate2D(latitude: 40.8000, longitude: -73.9000),
        ]
        let simplified = simplifyPolyline(coords, tolerance: 0.0001)
        #expect(simplified.count == 3)
    }

    @Test func simplifyPolylineHandlesShortArrays() async throws {
        // Empty array
        let empty: [CLLocationCoordinate2D] = []
        #expect(simplifyPolyline(empty, tolerance: 0.001).isEmpty)

        // Single point
        let single = [CLLocationCoordinate2D(latitude: 40.7, longitude: -74.0)]
        #expect(simplifyPolyline(single, tolerance: 0.001).count == 1)

        // Two points — returned as-is
        let two = [
            CLLocationCoordinate2D(latitude: 40.7, longitude: -74.0),
            CLLocationCoordinate2D(latitude: 40.8, longitude: -74.0),
        ]
        #expect(simplifyPolyline(two, tolerance: 0.001).count == 2)
    }

    @Test func simplifyPolylineWithZeroToleranceKeepsAll() async throws {
        let coords: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 40.7000, longitude: -74.0000),
            CLLocationCoordinate2D(latitude: 40.7001, longitude: -74.0001),
            CLLocationCoordinate2D(latitude: 40.7003, longitude: -74.0000),
            CLLocationCoordinate2D(latitude: 40.7005, longitude: -74.0002),
        ]
        let simplified = simplifyPolyline(coords, tolerance: 0)
        #expect(simplified.count == coords.count)
    }

    // MARK: - ArrivalETAEngine Tests

    /// Vehicle coord + stop coord provided → source should be vehiclePosition.
    @Test func etaEngineUsesVehiclePositionWhenProvided() async throws {
        // Vehicle is ~500 m north of the stop along the same longitude
        let vehicleCoord = CLLocationCoordinate2D(latitude: 40.7050, longitude: -74.0060)
        let stopCoord    = CLLocationCoordinate2D(latitude: 40.7005, longitude: -74.0060)
        let futureTs = Int(Date.now.timeIntervalSince1970) + 300  // 5 min from now

        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: vehicleCoord,
            vehicleKey: "test-v1",
            stopCoord: stopCoord,
            polyline: nil,
            arrivalTs: futureTs,
            staticMinutes: 10,
            mode: "subway"
        )
        #expect(eta.source == .vehiclePosition)
        #expect(!eta.isPastArrival)
    }

    /// No vehicle coord → engine should count down from the feed's arrivalTs.
    @Test func etaEngineFallsBackToFeedTimestamp() async throws {
        let futureTs = Int(Date.now.timeIntervalSince1970) + 240  // 4 min from now
        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: nil,
            vehicleKey: nil,
            stopCoord: nil,
            polyline: nil,
            arrivalTs: futureTs,
            staticMinutes: 99,
            mode: "bus"
        )
        #expect(eta.source == .feedTimestamp)
        // secondsRemaining should be close to 240 (±5 s for execution time)
        #expect(eta.secondsRemaining >= 230)
        #expect(eta.secondsRemaining <= 245)
    }

    /// Vehicle within 50 m of stop → isAtStop must be true.
    @Test func etaEngineReturnsNowWhenVehicleAtStop() async throws {
        // Close enough: ~10 m offset
        let stopCoord    = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let vehicleCoord = CLLocationCoordinate2D(latitude: 40.71281, longitude: -74.0060)

        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: vehicleCoord,
            vehicleKey: "test-v2",
            stopCoord: stopCoord,
            polyline: nil,
            arrivalTs: nil,
            staticMinutes: 1,
            mode: "subway"
        )
        #expect(eta.isAtStop)
        #expect(eta.secondsRemaining == 0)
    }

    /// Stopped vehicle within 150 m of destination stop → treated as "Now"
    /// (dwell detection: speed ≈ 0 && routeDistance < 150 m).
    @Test func etaEngineStoppedVehicleNearStopIsNow() async throws {
        // Place vehicle ~80 m south of the stop — well within 150 m
        let stopCoord    = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let vehicleCoord = CLLocationCoordinate2D(latitude: 40.7121, longitude: -74.0060)

        // Record the same position twice with 20 s gap → speed = 0
        let key = "test-dwell"
        ArrivalETAEngine.recordPosition(
            vehicleKey: key,
            coordinate: vehicleCoord,
            at: Date.now.addingTimeInterval(-20))
        ArrivalETAEngine.recordPosition(
            vehicleKey: key,
            coordinate: vehicleCoord,
            at: Date.now)

        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: vehicleCoord,
            vehicleKey: key,
            stopCoord: stopCoord,
            polyline: nil,
            arrivalTs: nil,
            staticMinutes: 2,
            mode: "subway"
        )
        // With speed=0 and routeDistance < 150 m, engine returns isAtStop=true
        #expect(eta.isAtStop)
        ArrivalETAEngine.clearHistory(for: key)
    }

    /// When routeDistance > 2 km and no position history, the feed timestamp
    /// is weighted more heavily (positionWeight ≈ 0.3).
    @Test func etaEngineBlendedETAFavorsFeedWhenFar() async throws {
        // Vehicle is ~3 km north of stop
        let vehicleCoord = CLLocationCoordinate2D(latitude: 40.7400, longitude: -74.0060)
        let stopCoord    = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        // Feed says 5 min; position-speed would estimate ~3000/9 = 333 s ≈ 5.5 min
        let futureTs = Int(Date.now.timeIntervalSince1970) + 300

        let eta = ArrivalETAEngine.computeETA(
            vehicleCoord: vehicleCoord,
            vehicleKey: "test-far",
            stopCoord: stopCoord,
            polyline: nil,
            arrivalTs: futureTs,
            staticMinutes: 5,
            mode: "subway"
        )
        #expect(eta.source == .vehiclePosition)
        // Blended result should be close to the feed (5 min = 300 s) —
        // with 0.3 position weight and similar estimates, expect ~300–360 s
        #expect(eta.secondsRemaining >= 200)
        #expect(eta.secondsRemaining <= 400)
    }
}
