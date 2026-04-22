import CoreLocation
import Foundation
import Observation

enum StopDetailKind: String, Equatable {
    case bus
    case subway
    case lirr
    case mnr

    nonisolated var mode: String {
        switch self {
        case .bus: return "bus"
        case .subway: return "subway"
        case .lirr: return "lirr"
        case .mnr: return "mnr"
        }
    }

    nonisolated var title: String {
        switch self {
        case .bus: return "Bus Stop"
        case .subway: return "Subway Station"
        case .lirr: return "LIRR Stop"
        case .mnr: return "Metro-North Stop"
        }
    }

    nonisolated var iconName: String {
        switch self {
        case .bus: return "bus.fill"
        case .subway: return "tram.fill"
        case .lirr: return "train.side.front.car"
        case .mnr: return "train.side.rear.car"
        }
    }
}

struct StopServedRoute: Identifiable, Equatable {
    let rawRouteID: String
    let displayName: String
    let mode: String

    nonisolated var id: String { "\(mode)-\(rawRouteID)" }
}

struct StopDetailSelection: Identifiable, Equatable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let kind: StopDetailKind
    let routeIDs: [String]
    let stopIDs: [String]
    let directionLabel: String?

    nonisolated var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    nonisolated var mode: String { kind.mode }

    nonisolated var primaryStopID: String? { stopIDs.first }

    nonisolated var servedRoutes: [StopServedRoute] {
        Self.sortedRouteIDs(routeIDs, mode: mode).map { routeID in
            StopServedRoute(
                rawRouteID: routeID,
                displayName: Self.displayName(for: routeID, mode: mode),
                mode: mode
            )
        }
    }

    nonisolated static func bus(
        _ stop: BusStop,
        fallbackRouteID: String? = nil
    ) -> StopDetailSelection {
        routeStop(stop, mode: "bus", fallbackRouteID: fallbackRouteID)
    }

    nonisolated static func routeStop(
        _ stop: BusStop,
        mode: String,
        fallbackRouteID: String? = nil
    ) -> StopDetailSelection {
        var routeIDs = stop.routeIds ?? []
        if routeIDs.isEmpty, let fallbackRouteID, !fallbackRouteID.isEmpty {
            routeIDs = [fallbackRouteID]
        }

        let kind = kind(for: mode)

        return StopDetailSelection(
            id: "\(kind.rawValue)-\(stop.id)",
            name: stop.name,
            latitude: stop.lat,
            longitude: stop.lon,
            kind: kind,
            routeIDs: sortedRouteIDs(routeIDs, mode: mode),
            stopIDs: [stop.id],
            directionLabel: stop.direction
        )
    }

    nonisolated static func station(
        _ station: MapSystemViewModel.ConsolidatedStation
    ) -> StopDetailSelection {
        let kind = inferredKind(for: station.routes)
        let sortedStopIDs = Array(station.sourceStopIDs).sorted()

        return StopDetailSelection(
            id: "\(kind.rawValue)-\(station.id)-\(sortedStopIDs.joined(separator: "|"))",
            name: station.name,
            latitude: station.coordinate.latitude,
            longitude: station.coordinate.longitude,
            kind: kind,
            routeIDs: sortedRouteIDs(station.routes, mode: kind.mode),
            stopIDs: sortedStopIDs,
            directionLabel: nil
        )
    }

    nonisolated static func displayName(for routeID: String, mode: String) -> String {
        BranchNames.resolveDisplayName(routeId: routeID, mode: mode)
    }

    nonisolated static func sortedRouteIDs(_ routeIDs: [String], mode: String) -> [String] {
        let deduped = Array(Set(routeIDs.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }))

        if mode == "subway" {
            let numericRoutes: [String: Int] = [
                "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "6X": 7,
                "7": 8, "7X": 9,
            ]

            return deduped.sorted { lhs, rhs in
                let left = stripMTAPrefix(lhs).uppercased()
                let right = stripMTAPrefix(rhs).uppercased()

                let leftNumeric = numericRoutes[left]
                let rightNumeric = numericRoutes[right]
                if let leftNumeric, let rightNumeric, leftNumeric != rightNumeric {
                    return leftNumeric < rightNumeric
                }
                if leftNumeric != nil, rightNumeric == nil { return true }
                if leftNumeric == nil, rightNumeric != nil { return false }
                return left.localizedStandardCompare(right) == .orderedAscending
            }
        }

        return deduped.sorted {
            displayName(for: $0, mode: mode)
                .localizedStandardCompare(displayName(for: $1, mode: mode))
                == .orderedAscending
        }
    }

    private nonisolated static func inferredKind(for routeIDs: [String]) -> StopDetailKind {
        let uppercased = routeIDs.map { $0.uppercased() }
        if !uppercased.isEmpty, uppercased.allSatisfy({ $0.hasPrefix("LIRR_") }) {
            return .lirr
        }
        if !uppercased.isEmpty, uppercased.allSatisfy({ $0.hasPrefix("MNR_") }) {
            return .mnr
        }
        return .subway
    }

    private nonisolated static func kind(for mode: String) -> StopDetailKind {
        switch mode.lowercased() {
        case "bus": return .bus
        case "lirr": return .lirr
        case "mnr": return .mnr
        default: return .subway
        }
    }
}

struct StopDetailClient: Sendable {
    var fetchBusArrivals: @Sendable (String) async throws -> [BusArrival]
    var fetchSubwayArrivals: @Sendable (String) async throws -> [TrainArrival]
    var fetchLIRRArrivals: @Sendable () async throws -> [TrainArrival]
    var fetchMNRArrivals: @Sendable () async throws -> [TrainArrival]
    var fetchStationAccessibility: @Sendable ([String], String?) async throws -> StationAccessibility?

    nonisolated static let live = StopDetailClient(
        fetchBusArrivals: { try await TrackAPI.fetchBusArrivals(stopID: $0) },
        fetchSubwayArrivals: { try await TrackAPI.fetchSubwayArrivals(lineID: $0) },
        fetchLIRRArrivals: { try await TrackAPI.fetchLIRRArrivals() },
        fetchMNRArrivals: { try await TrackAPI.fetchMNRArrivals() },
        fetchStationAccessibility: { try await TrackAPI.fetchStationAccessibility(stopIDs: $0, name: $1) }
    )
}

@MainActor
@Observable
final class StopDetailViewModel {
    struct DepartureTime: Identifiable, Equatable {
        let id: String
        /// Initial label rendered before the live countdown takes over.
        /// When `arrivalDate` is non-nil the chip recomputes the label every
        /// 15 s from the timestamp, so the stop-detail page stays in sync
        /// with the route detail / row chips and never freezes on a stale
        /// integer like "5 min" while the bus has actually moved on.
        let label: String
        /// Wall-clock arrival time. When present, the chip computes minutes
        /// live from this instead of using the static `label`.
        let arrivalDate: Date?
        let isRealtime: Bool
        let isImminent: Bool
        let isAlert: Bool
        let isScheduledOnly: Bool
    }

    struct DepartureRow: Identifiable, Equatable {
        let id: String
        let primaryText: String
        let secondaryText: String?
        let times: [DepartureTime]
        let statusText: String?
    }

    struct DepartureSection: Identifiable, Equatable {
        let route: StopServedRoute
        let rows: [DepartureRow]
        let totalArrivalCount: Int

        var id: String { route.id }
    }

    let selection: StopDetailSelection

    var isLoading = false
    var hasLoaded = false
    var errorMessage: String?
    var sections: [DepartureSection] = []
    var accessibilityOutages: [ElevatorStatus] = []
    var stationAccessibility: StationAccessibility?
    var lastUpdated: Date?

    private let client: StopDetailClient
    private let allElevatorOutages: [ElevatorStatus]

    init(
        selection: StopDetailSelection,
        elevatorOutages: [ElevatorStatus] = [],
        client: StopDetailClient = .live
    ) {
        self.selection = selection
        self.client = client
        self.allElevatorOutages = elevatorOutages
        self.accessibilityOutages = Self.matchingAccessibilityOutages(
            for: selection,
            from: elevatorOutages
        )
    }

    var totalArrivalCount: Int {
        sections.reduce(0) { $0 + $1.totalArrivalCount }
    }

    var hasRealtimeDepartures: Bool {
        sections.contains { section in
            section.rows.contains { row in
                row.times.contains { $0.isRealtime && !$0.isScheduledOnly }
            }
        }
    }

    var accessibilityHeadline: String {
        // Use rich station accessibility data when available
        if let ada = stationAccessibility {
            if ada.outageCount > 0 {
                let outages = ada.outageCount == 1
                    ? "1 elevator/escalator out of service."
                    : "\(ada.outageCount) elevators/escalators out of service."
                return outages
            }
            switch ada.adaStatus {
            case 1:
                return "Fully accessible — all elevators in service."
            case 2:
                let direction = ada.adaNotes.isEmpty ? "one direction" : ada.adaNotes
                return "Partially accessible — \(direction)."
            default:
                return "This station is not ADA-accessible."
            }
        }

        // Fallback to legacy outage matching
        if accessibilityOutages.isEmpty {
            switch selection.kind {
            case .bus:
                return "No active accessibility advisories reported."
            default:
                return "No active elevator or escalator outages reported."
            }
        }

        if accessibilityOutages.count == 1 {
            return "1 active accessibility advisory."
        }
        return "\(accessibilityOutages.count) active accessibility advisories."
    }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        accessibilityOutages = Self.matchingAccessibilityOutages(
            for: selection,
            from: allElevatorOutages
        )

        do {
            // Fetch departures and station accessibility in parallel
            async let departuresTask: [DepartureSection] = {
                switch selection.kind {
                case .bus:
                    return try await loadBusSections()
                case .subway:
                    return try await loadSubwaySections()
                case .lirr:
                    return try await loadCommuterRailSections(mode: .lirr)
                case .mnr:
                    return try await loadCommuterRailSections(mode: .mnr)
                }
            }()
            async let accessibilityTask: StationAccessibility? = {
                // Only fetch station accessibility for subway/rail (not bus)
                guard selection.kind != .bus else { return nil }
                return try? await client.fetchStationAccessibility(
                    selection.stopIDs,
                    selection.name
                )
            }()

            let (deps, ada) = try await (departuresTask, accessibilityTask)
            sections = deps
            stationAccessibility = ada
            lastUpdated = Date()
        } catch {
            sections = []
            errorMessage = error.localizedDescription
        }

        hasLoaded = true
        isLoading = false
    }

    private func loadBusSections() async throws -> [DepartureSection] {
        guard let stopID = selection.primaryStopID, !stopID.isEmpty else { return [] }
        let arrivals = try await client.fetchBusArrivals(stopID)
        return Self.buildBusSections(from: arrivals, selection: selection)
    }

    private func loadSubwaySections() async throws -> [DepartureSection] {
        let routeIDs = selection.servedRoutes.map(\.rawRouteID)
        guard !routeIDs.isEmpty else { return [] }

        let client = self.client
        let arrivals = try await withThrowingTaskGroup(of: [TrainArrival].self) { group in
            for routeID in routeIDs {
                group.addTask {
                    try await client.fetchSubwayArrivals(routeID)
                }
            }

            var merged: [TrainArrival] = []
            for try await batch in group {
                merged.append(contentsOf: batch)
            }
            return merged
        }

        let filtered = Self.filterTrainArrivals(arrivals, for: selection)
        return Self.buildTrainSections(from: filtered, selection: selection)
    }

    private func loadCommuterRailSections(mode: StopDetailKind) async throws -> [DepartureSection] {
        let arrivals: [TrainArrival]
        switch mode {
        case .lirr:
            arrivals = try await client.fetchLIRRArrivals()
        case .mnr:
            arrivals = try await client.fetchMNRArrivals()
        default:
            arrivals = []
        }

        let filtered = Self.filterTrainArrivals(arrivals, for: selection)
        return Self.buildTrainSections(from: filtered, selection: selection)
    }

    nonisolated static func matchingAccessibilityOutages(
        for selection: StopDetailSelection,
        from outages: [ElevatorStatus]
    ) -> [ElevatorStatus] {
        let name = normalizedStopName(selection.name)
        guard !name.isEmpty else { return [] }

        return outages.filter { outage in
            let station = normalizedStopName(outage.station)
            return station == name || station.contains(name) || name.contains(station)
        }
    }

    nonisolated static func filterTrainArrivals(
        _ arrivals: [TrainArrival],
        for selection: StopDetailSelection
    ) -> [TrainArrival] {
        let stopIDs = Set(selection.stopIDs.map { $0.uppercased() })
        let normalizedSelectionRoutes = Set(
            selection.routeIDs.map { normalizeMTARouteToken($0).uppercased() }
        )
        let selectionName = normalizedStopName(selection.name)

        return arrivals.filter { arrival in
            let routeMatches: Bool
            if normalizedSelectionRoutes.isEmpty {
                routeMatches = true
            } else {
                routeMatches = normalizedSelectionRoutes.contains(
                    normalizeMTARouteToken(arrival.routeID).uppercased()
                )
            }

            guard routeMatches else { return false }

            let stopIDMatch = stopIDs.contains(arrival.stationID.uppercased())
            let stopNameMatch = normalizedStopName(arrival.stationName) == selectionName
            return stopIDMatch || stopNameMatch
        }
        .sorted(by: compareTrainArrivals)
    }

    nonisolated static func buildBusSections(
        from arrivals: [BusArrival],
        selection: StopDetailSelection
    ) -> [DepartureSection] {
        let filtered = arrivals
            .filter { selection.stopIDs.contains($0.stopId) }
            .sorted(by: compareBusArrivals)

        guard !filtered.isEmpty else { return [] }

        let groupedByRoute = Dictionary(grouping: filtered, by: \.routeId)
        let sortedRoutes = StopDetailSelection.sortedRouteIDs(
            Array(groupedByRoute.keys),
            mode: "bus"
        )

        return sortedRoutes.compactMap { routeID in
            guard let routeArrivals = groupedByRoute[routeID], !routeArrivals.isEmpty else {
                return nil
            }

            let rowGroups = Dictionary(grouping: routeArrivals) { arrival in
                let destination = normalizedStopName(arrival.destinationName ?? "")
                let direction = arrival.directionRef.map(String.init) ?? "?"
                return "\(direction)|\(destination)"
            }

            let rows = rowGroups.values.compactMap { group -> DepartureRow? in
                let sorted = group.sorted(by: compareBusArrivals)
                guard let first = sorted.first else { return nil }
                let routeLabel = first.destinationName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let primary = (routeLabel?.isEmpty == false) ? routeLabel! : "Upcoming service"
                let times = sorted.prefix(3).compactMap(busDepartureTime(for:))
                guard !times.isEmpty else { return nil }

                let statusText: String? = {
                    if sorted.allSatisfy({ !$0.isRealtime }) {
                        return "Scheduled"
                    }
                    return nil
                }()

                let firstETA = times.first?.label ?? primary
                return DepartureRow(
                    id: "\(routeID)-\(primary)-\(firstETA)",
                    primaryText: primary,
                    secondaryText: nil,
                    times: times,
                    statusText: statusText
                )
            }
            .sorted {
                rowSortValue($0.times.first) < rowSortValue($1.times.first)
            }

            guard !rows.isEmpty else { return nil }

            return DepartureSection(
                route: StopServedRoute(
                    rawRouteID: routeID,
                    displayName: StopDetailSelection.displayName(for: routeID, mode: "bus"),
                    mode: "bus"
                ),
                rows: rows,
                totalArrivalCount: routeArrivals.count
            )
        }
    }

    nonisolated static func buildTrainSections(
        from arrivals: [TrainArrival],
        selection: StopDetailSelection
    ) -> [DepartureSection] {
        guard !arrivals.isEmpty else { return [] }

        let groupedByRoute = Dictionary(grouping: arrivals, by: \.routeID)
        let sortedRoutes = StopDetailSelection.sortedRouteIDs(
            Array(groupedByRoute.keys),
            mode: selection.mode
        )

        return sortedRoutes.compactMap { routeID in
            guard let routeArrivals = groupedByRoute[routeID], !routeArrivals.isEmpty else {
                return nil
            }

            let rowGroups = Dictionary(grouping: routeArrivals) { arrival in
                let destination = normalizedStopName(arrival.destination ?? "")
                return "\(arrival.direction.uppercased())|\(destination)"
            }

            let rows = rowGroups.values.compactMap { group -> DepartureRow? in
                let sorted = group.sorted(by: compareTrainArrivals)
                guard let first = sorted.first else { return nil }
                let primary = trainPrimaryText(for: first, mode: selection.mode)
                let secondary = trainSecondaryText(for: first)
                let times = sorted.prefix(3).map(trainDepartureTime(for:))
                let statusText = noteworthyTrainStatus(in: sorted)
                return DepartureRow(
                    id: "\(routeID)-\(first.direction)-\(first.destination ?? "")",
                    primaryText: primary,
                    secondaryText: secondary,
                    times: times,
                    statusText: statusText
                )
            }
            .sorted {
                rowSortValue($0.times.first) < rowSortValue($1.times.first)
            }

            guard !rows.isEmpty else { return nil }

            return DepartureSection(
                route: StopServedRoute(
                    rawRouteID: routeID,
                    displayName: StopDetailSelection.displayName(for: routeID, mode: selection.mode),
                    mode: selection.mode
                ),
                rows: rows,
                totalArrivalCount: routeArrivals.count
            )
        }
    }

    private nonisolated static func busDepartureTime(for arrival: BusArrival) -> DepartureTime? {
        let label: String
        let arrivalDate: Date?
        if let eta = arrival.expectedArrival {
            let minutes = max(0, Int(ceil(eta.timeIntervalSinceNow / 60.0)))
            label = minutes <= 0 ? "Now" : "\(minutes) min"
            arrivalDate = eta
        } else if !arrival.statusText.isEmpty {
            label = arrival.statusText
            arrivalDate = nil
        } else {
            return nil
        }

        // Use a stable id (NOT including the label) so SwiftUI keeps the
        // same chip identity as the live countdown updates each minute.
        return DepartureTime(
            id: arrival.id,
            label: label,
            arrivalDate: arrivalDate,
            isRealtime: arrival.isRealtime,
            isImminent: label == "Now",
            isAlert: false,
            isScheduledOnly: !arrival.isRealtime
        )
    }

    private nonisolated static func trainDepartureTime(for arrival: TrainArrival) -> DepartureTime {
        let isCancelled = arrival.isCancelled
        let label: String
        if isCancelled {
            label = "Skipped"
        } else if arrival.minutesAway <= 0 {
            label = "Now"
        } else {
            label = "\(arrival.minutesAway) min"
        }

        let statusLower = arrival.status.lowercased()
        let isScheduled = statusLower == "scheduled"
        let isAlert = isCancelled
            || statusLower.contains("delay")
            || statusLower.contains("late")

        // Cancelled trains have no live countdown — keep the static "Skipped".
        // Otherwise use `estimatedTime` so the chip recomputes minutes live
        // and never freezes on a stale `minutesAway` integer.
        let arrivalDate: Date? = isCancelled ? nil : arrival.estimatedTime

        return DepartureTime(
            id: arrival.id,
            label: label,
            arrivalDate: arrivalDate,
            isRealtime: !isScheduled,
            isImminent: label == "Now",
            isAlert: isAlert,
            isScheduledOnly: isScheduled
        )
    }

    private nonisolated static func noteworthyTrainStatus(in arrivals: [TrainArrival]) -> String? {
        if arrivals.contains(where: \.isCancelled) {
            return "Service change"
        }

        let statuses = arrivals
            .map(\.status)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if statuses.allSatisfy({ $0.lowercased() == "scheduled" }) {
            return "Scheduled"
        }

        if let delay = statuses.first(where: {
            let lower = $0.lowercased()
            return lower.contains("delay") || lower.contains("late")
        }) {
            return delay
        }

        return nil
    }

    private nonisolated static func trainPrimaryText(
        for arrival: TrainArrival,
        mode: String
    ) -> String {
        let directionText = directionLabel(arrival.direction)
        if let destination = arrival.destination?.trimmingCharacters(in: .whitespacesAndNewlines),
           !destination.isEmpty {
            if mode == "subway" {
                return "\(directionText) to \(destination)"
            }
            return "To \(destination)"
        }
        return directionText
    }

    private nonisolated static func trainSecondaryText(for arrival: TrainArrival) -> String? {
        let directionText = directionLabel(arrival.direction)
        if directionText == arrival.direction {
            return nil
        }
        return directionText
    }

    private nonisolated static func compareTrainArrivals(
        _ lhs: TrainArrival,
        _ rhs: TrainArrival
    ) -> Bool {
        if lhs.minutesAway != rhs.minutesAway {
            return lhs.minutesAway < rhs.minutesAway
        }
        if lhs.estimatedTime != rhs.estimatedTime {
            return lhs.estimatedTime < rhs.estimatedTime
        }
        return lhs.id < rhs.id
    }

    private nonisolated static func compareBusArrivals(_ lhs: BusArrival, _ rhs: BusArrival) -> Bool {
        let left = lhs.expectedArrival ?? .distantFuture
        let right = rhs.expectedArrival ?? .distantFuture
        if left != right {
            return left < right
        }
        return lhs.id < rhs.id
    }

    private nonisolated static func rowSortValue(_ time: DepartureTime?) -> Int {
        guard let time else { return Int.max }
        if time.label == "Now" { return 0 }
        let digits = time.label
            .unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) }
        if !digits.isEmpty, let minutes = Int(String(String.UnicodeScalarView(digits))) {
            return minutes
        }
        return Int.max - 1
    }

    private nonisolated static func normalizedStopName(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "station", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ".", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
