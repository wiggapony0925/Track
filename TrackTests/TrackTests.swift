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
        let prediction = DelayCalculator.predict(
            mtaMinutes: 5,
            routeID: "L",
            timeOfDay: 14, // 2 PM, off-peak
            dayOfWeek: 4,  // Wednesday
            weather: .clear,
            historicDelays: []
        )
        #expect(prediction.adjustedMinutes == 5)
        #expect(prediction.adjustmentReason == nil)
    }

    @Test func delayCalculatorAppliesRushHourAdjustment() async throws {
        let prediction = DelayCalculator.predict(
            mtaMinutes: 10,
            routeID: "4",
            timeOfDay: 8,  // 8 AM morning rush
            dayOfWeek: 3,  // Tuesday (weekday)
            weather: .clear,
            historicDelays: []
        )
        // Rush hour adds 10%, so 10 * 1.1 = 11
        #expect(prediction.adjustedMinutes == 11)
        #expect(prediction.adjustmentReason != nil)
        #expect(prediction.adjustmentReason!.contains("rush hour"))
    }

    @Test func delayCalculatorAppliesRainAdjustment() async throws {
        let prediction = DelayCalculator.predict(
            mtaMinutes: 10,
            routeID: "L",
            timeOfDay: 14,
            dayOfWeek: 1,  // Sunday (not a weekday)
            weather: .rain,
            historicDelays: []
        )
        // Rain adds 10%, so 10 * 1.1 = 11
        #expect(prediction.adjustedMinutes == 11)
        #expect(prediction.adjustmentReason!.contains("rain"))
    }

    @Test func delayCalculatorAppliesSnowAdjustment() async throws {
        let prediction = DelayCalculator.predict(
            mtaMinutes: 10,
            routeID: "L",
            timeOfDay: 14,
            dayOfWeek: 1,
            weather: .snow,
            historicDelays: []
        )
        // Snow adds 20%, so 10 * 1.2 = 12
        #expect(prediction.adjustedMinutes == 12)
        #expect(prediction.adjustmentReason!.contains("snow"))
    }

    @Test func delayCalculatorCombinesRushHourAndWeather() async throws {
        let prediction = DelayCalculator.predict(
            mtaMinutes: 10,
            routeID: "A",
            timeOfDay: 17, // 5 PM evening rush
            dayOfWeek: 2,  // Monday (weekday)
            weather: .rain,
            historicDelays: []
        )
        // Rush hour 10% + Rain 10% = 1.2, so 10 * 1.2 = 12
        #expect(prediction.adjustedMinutes == 12)
        #expect(prediction.adjustmentReason!.contains("rush hour"))
        #expect(prediction.adjustmentReason!.contains("rain"))
    }

    @Test func delayCalculatorNoRushOnWeekend() async throws {
        let prediction = DelayCalculator.predict(
            mtaMinutes: 10,
            routeID: "L",
            timeOfDay: 8,  // 8 AM but Saturday
            dayOfWeek: 7,  // Saturday
            weather: .clear,
            historicDelays: []
        )
        #expect(prediction.adjustedMinutes == 10)
        #expect(prediction.adjustmentReason == nil)
    }

    @Test func delayCalculatorUsesHistoricData() async throws {
        let prediction = DelayCalculator.predict(
            mtaMinutes: 10,
            routeID: "L",
            timeOfDay: 14,
            dayOfWeek: 1,
            weather: .clear,
            historicDelays: [120, 60, 180] // Average 120 seconds = 2 minutes
        )
        // Historic factor: (600 + 120) / 600 = 1.2
        // Blended: (1.0 + 1.2) / 2 = 1.1
        // 10 * 1.1 = 11
        #expect(prediction.adjustedMinutes == 11)
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
}
