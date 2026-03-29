//
//  WeatherService.swift
//  Track
//
//  Fetches current weather conditions for the weather chip UI.
//
//  Primary source:  Apple WeatherKit  (beautiful data, native SF Symbols)
//  Fallback source: Track backend /weather endpoint (Open-Meteo via server)
//
//  WeatherKit fails on the iOS Simulator because the JWT authenticator
//  can't generate device-level tokens.  When that happens, this service
//  automatically falls back to the backend Open-Meteo endpoint so the
//  weather chip still works during development.
//
//  On real devices WeatherKit succeeds and the backend is never called.
//
//  Results are cached for 10 minutes.  Repeated failures use exponential
//  backoff (30 s → 1 min → 2 min → 4 min → cap 5 min) to avoid flooding
//  the console with error logs every 20 seconds.
//

import CoreLocation
import Foundation
import WeatherKit

/// Lightweight weather snapshot for UI display.
struct WeatherSnapshot: Equatable {
    let temperature: Double           // Celsius
    let temperatureFormatted: String  // "72°F" (localized, user's preferred unit)
    let conditionSymbol: String       // SF Symbol name (e.g. "cloud.rain.fill")
    let conditionDescription: String  // "Partly Cloudy"
    let category: WeatherCondition    // .clear / .rain / .snow
    let fetchedAt: Date
}

/// Uses @Observable so it participates in the same observation graph as
/// HomeViewModel (@Observable).  The old ObservableObject/Combine approach
/// was invisible to the Observation framework — changes to `current` never
/// triggered SwiftUI re-renders in views that read `viewModel.weatherSnapshot`.
@Observable
@MainActor
final class WeatherService {
    static let shared = WeatherService()

    private(set) var current: WeatherSnapshot?
    private(set) var isLoading = false

    private let weatherKitService = WeatherKit.WeatherService.shared
    private let cacheDuration: TimeInterval = 600 // 10 minutes
    private var lastFetchLocation: CLLocation?
    private var fetchTask: Task<Void, Never>?

    // ── Failure backoff ──────────────────────────────────────────────────
    /// Consecutive failure count — drives exponential backoff.
    private var consecutiveFailures = 0
    /// Timestamp of last failed attempt.
    private var lastFailureDate: Date?
    /// Backoff intervals: 30s, 60s, 120s, 240s, cap 300s.
    private var backoffInterval: TimeInterval {
        min(30 * pow(2.0, Double(consecutiveFailures - 1)), 300)
    }
    /// True when WeatherKit has failed at least once — enables backend fallback.
    private var weatherKitUnavailable = false

    private init() {}

    /// Fetch current weather for the given location.
    /// Skips the network call if cached data is fresh and location hasn't moved far.
    func update(for location: CLLocation) {
        // Skip if we fetched recently from a nearby location
        if let snapshot = current,
           Date().timeIntervalSince(snapshot.fetchedAt) < cacheDuration,
           let lastLoc = lastFetchLocation,
           lastLoc.distance(from: location) < 1000 {
            return
        }

        // Respect backoff on repeated failures
        if consecutiveFailures > 0, let lastFail = lastFailureDate,
           Date().timeIntervalSince(lastFail) < backoffInterval {
            return
        }

        // If a fetch is already in flight for a nearby location, let it finish
        // instead of cancelling it.  Two rapid location updates (e.g. GPS
        // accuracy refinement) would otherwise cancel the first task mid-
        // backend-fallback, causing a spurious "cancelled" error.
        if isLoading,
           let lastLoc = lastFetchLocation,
           lastLoc.distance(from: location) < 1000 {
            return
        }

        fetchTask?.cancel()
        lastFetchLocation = location
        fetchTask = Task {
            await fetch(location: location)
        }
    }

    private func fetch(location: CLLocation) async {
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }

        // ── Try WeatherKit first (unless it already failed) ──────────────
        if !weatherKitUnavailable {
            if let snapshot = await fetchFromWeatherKit(location: location) {
                applySnapshot(snapshot, location: location)
                return
            }
            // WeatherKit not available — switch to backend for this session.
            weatherKitUnavailable = true
            AppLogger.shared.log("WEATHER", message: "Using backend fallback (WeatherKit not available on this device)")
        }

        // ── Fallback: Track backend /weather ─────────────────────────────
        if let snapshot = await fetchFromBackend(location: location) {
            applySnapshot(snapshot, location: location)
            return
        }

        // Both sources failed
        consecutiveFailures += 1
        lastFailureDate = Date()
        AppLogger.shared.log("WEATHER", message: "All weather sources failed (attempt \(consecutiveFailures), next retry in \(Int(backoffInterval))s)")
    }

    private func applySnapshot(_ snapshot: WeatherSnapshot, location: CLLocation) {
        self.current = snapshot
        self.lastFetchLocation = location
        self.consecutiveFailures = 0
        self.lastFailureDate = nil
    }

    // MARK: - WeatherKit (primary)

    private func fetchFromWeatherKit(location: CLLocation) async -> WeatherSnapshot? {
        do {
            let weather = try await weatherKitService.weather(for: location, including: .current)
            guard !Task.isCancelled else { return nil }

            let temp = weather.temperature
            let formatter = MeasurementFormatter()
            formatter.numberFormatter.maximumFractionDigits = 0
            formatter.unitStyle = .short
            let formatted = formatter.string(from: temp)
                .replacingOccurrences(of: " ", with: "")

            let symbol = weather.symbolName
            let description = weather.condition.description.capitalized

            let category: WeatherCondition = {
                switch weather.condition {
                case .rain, .heavyRain, .drizzle, .freezingRain,
                     .thunderstorms, .strongStorms, .isolatedThunderstorms,
                     .scatteredThunderstorms, .tropicalStorm, .hurricane:
                    return .rain
                case .snow, .heavySnow, .flurries, .freezingDrizzle,
                     .sleet, .blizzard, .wintryMix, .blowingSnow:
                    return .snow
                default:
                    return .clear
                }
            }()

            return WeatherSnapshot(
                temperature: temp.value,
                temperatureFormatted: formatted,
                conditionSymbol: symbol,
                conditionDescription: description,
                category: category,
                fetchedAt: Date()
            )
        } catch {
            // Silently return nil — the caller will flip to the backend
            // fallback and log a single clean message; no need to spam
            // the console with the raw WeatherKit error each time.
            #if DEBUG
            print("[WEATHER] WeatherKit error: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // MARK: - Backend fallback (Open-Meteo via /weather)

    /// Response shape from the Track backend `/weather` endpoint.
    private struct BackendWeatherResponse: Decodable {
        let temperature_c: Double?
        let temperature_f: Double?
        let wmo_code: Int
        let symbol: String
        let description: String
        let category: String
        let windspeed_kmh: Double?
        let is_day: Bool?
    }

    private func fetchFromBackend(location: CLLocation) async -> WeatherSnapshot? {
        let base = TrackAPI.baseURL
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        guard let url = URL(string: "\(base)/weather?lat=\(lat)&lon=\(lon)") else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }

            let decoded = try JSONDecoder().decode(BackendWeatherResponse.self, from: data)
            guard let tempC = decoded.temperature_c else { return nil }

            // Format temperature using the user's locale preferences
            let measurement = Measurement(value: tempC, unit: UnitTemperature.celsius)
            let formatter = MeasurementFormatter()
            formatter.numberFormatter.maximumFractionDigits = 0
            formatter.unitStyle = .short
            let formatted = formatter.string(from: measurement)
                .replacingOccurrences(of: " ", with: "")

            let weatherCategory: WeatherCondition = {
                switch decoded.category {
                case "rain":  return .rain
                case "snow":  return .snow
                default:      return .clear
                }
            }()

            return WeatherSnapshot(
                temperature: tempC,
                temperatureFormatted: formatted,
                conditionSymbol: decoded.symbol,
                conditionDescription: decoded.description,
                category: weatherCategory,
                fetchedAt: Date()
            )
        } catch {
            AppLogger.shared.log("WEATHER", message: "Backend /weather failed: \(error.localizedDescription)")
            return nil
        }
    }
}
