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
}
