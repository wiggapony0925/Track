// Real-time location search powered by Apple MapKit.
// Wraps MKLocalSearchCompleter for typeahead suggestions and
// MKLocalSearch for resolving a completion to coordinates.
//
// Usage:
//   let service = LocationSearchService()
//   service.updateQuery("Times Square")
//   // observe service.completions for suggestions
//   let placemark = try await service.resolve(completion)

import MapKit

@MainActor
@Observable
final class LocationSearchService: NSObject {

    // MARK: - Published State

    /// Live autocomplete suggestions from Apple.
    var completions: [MKLocalSearchCompletion] = []

    /// Whether a search query is currently in-flight.
    var isSearching = false

    // MARK: - Private

    private let completer = MKLocalSearchCompleter()
    private var currentQuery = ""

    // NYC-centric search region (still finds results everywhere,
    // but ranks nearby results higher).
    private let nycRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
        latitudinalMeters: 50_000,
        longitudinalMeters: 50_000
    )

    // MARK: - Init

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
        completer.region = nycRegion
    }

    // MARK: - Public API

    /// Update the search query. Empty string clears results.
    func updateQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        currentQuery = trimmed

        guard !trimmed.isEmpty else {
            completions = []
            isSearching = false
            completer.cancel()
            return
        }

        isSearching = true
        completer.queryFragment = trimmed
    }

    /// Cancel any in-flight search.
    func cancel() {
        completer.cancel()
        completions = []
        isSearching = false
        currentQuery = ""
    }

    /// Resolve a completion to a full placemark with coordinates.
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> MKMapItem {
        let request = MKLocalSearch.Request(completion: completion)
        request.region = nycRegion
        request.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: request)
        let response = try await search.start()

        guard let item = response.mapItems.first else {
            throw LocationSearchError.noResults
        }
        return item
    }

    /// Geocode a raw address string (for paste support).
    func geocode(_ address: String) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        request.region = nycRegion
        request.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: request)
        let response = try await search.start()

        guard let item = response.mapItems.first else {
            throw LocationSearchError.noResults
        }
        return item
    }

    /// Reverse-geocode a coordinate to a map item description.
    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async throws -> MKMapItem {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            throw LocationSearchError.noResults
        }
        let mapItems = try await request.mapItems
        guard let item = mapItems.first else {
            throw LocationSearchError.noResults
        }
        return item
    }
}

// MARK: - MKLocalSearchCompleterDelegate

extension LocationSearchService: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.completions = results
            self.isSearching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.isSearching = false
            // Don't clear completions on transient errors — keep showing
            // the last valid results while the user continues typing.
        }
    }
}

// MARK: - Helpers

enum LocationSearchError: LocalizedError {
    case noResults

    var errorDescription: String? {
        switch self {
        case .noResults: return "No results found for this location."
        }
    }
}

// MARK: - MKLocalSearchCompletion Extensions

extension MKLocalSearchCompletion: @retroactive Identifiable {
    public var id: String {
        "\(title)-\(subtitle)"
    }
}

// MARK: - MKMapItem helpers

extension MKMapItem {
    /// A human-readable address string using the new iOS 26 MKAddress API.
    var formattedAddress: String {
        address?.fullAddress
            ?? address?.shortAddress
            ?? name
            ?? ""
    }
}

extension MKLocalSearchCompletion {
    /// Best icon name for the completion type.
    var iconName: String {
        // Apple doesn't expose POI category on completions,
        // so we infer from the subtitle content.
        let sub = subtitle.lowercased()
        if sub.contains("station") || sub.contains("terminal") {
            return "tram.fill"
        } else if sub.contains("airport") {
            return "airplane"
        } else if sub.contains("hospital") || sub.contains("medical") {
            return "cross.fill"
        } else if sub.contains("school") || sub.contains("university") || sub.contains("college") {
            return "graduationcap.fill"
        } else if sub.contains("park") {
            return "leaf.fill"
        } else if sub.contains("restaurant") || sub.contains("cafe") || sub.contains("coffee") {
            return "fork.knife"
        } else if sub.contains("hotel") {
            return "bed.double.fill"
        } else if sub.contains("museum") || sub.contains("gallery") {
            return "building.columns.fill"
        } else if sub.isEmpty {
            return "magnifyingglass"
        }
        return "mappin"
    }
}
