// Data models for the trip planning feature.
// These power saved places, recent destinations, search results,
// and the TrackEngine-backed Go/plan responses used by the Plan tab.

import CoreLocation
import Foundation
import SwiftData

// MARK: - Saved Location

@Model
final class SavedLocation {
    var id: UUID
    var enginePlaceID: Int?
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var category: String
    var iconName: String
    var createdAt: Date
    var lastUsedAt: Date?

    init(
        enginePlaceID: Int? = nil,
        name: String,
        address: String,
        latitude: Double,
        longitude: Double,
        category: SavedLocationCategory = .custom,
        iconName: String? = nil,
        createdAt: Date = .now,
        lastUsedAt: Date? = nil
    ) {
        self.id = UUID()
        self.enginePlaceID = enginePlaceID
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.category = category.rawValue
        self.iconName = iconName ?? category.defaultIcon
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var resolvedCategory: SavedLocationCategory {
        SavedLocationCategory(rawValue: category) ?? .custom
    }
}

enum SavedLocationCategory: String, CaseIterable, Codable {
    case home = "home"
    case work = "work"
    case school = "school"
    case partner = "partner"
    case custom = "custom"
    case calendar = "calendar"

    init(engineKind: String) {
        switch engineKind.lowercased() {
        case "home":
            self = .home
        case "work":
            self = .work
        case "school":
            self = .school
        case "partner", "girlfriend", "boyfriend", "girlfriend_house", "partner_house":
            self = .partner
        case "calendar":
            self = .calendar
        default:
            self = .custom
        }
    }

    var label: String {
        switch self {
        case .home:
            return "Home"
        case .work:
            return "Work"
        case .school:
            return "School"
        case .partner:
            return "Partner"
        case .custom:
            return "Saved"
        case .calendar:
            return "Calendar"
        }
    }

    var defaultIcon: String {
        switch self {
        case .home:
            return "house.fill"
        case .work:
            return "briefcase.fill"
        case .school:
            return "graduationcap.fill"
        case .partner:
            return "heart.fill"
        case .custom:
            return "mappin"
        case .calendar:
            return "calendar"
        }
    }
}

// MARK: - Recent Search Location

@Model
final class RecentSearchLocation {
    var id: UUID
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var searchedAt: Date

    init(
        name: String,
        address: String,
        latitude: Double,
        longitude: Double,
        searchedAt: Date = .now
    ) {
        self.id = UUID()
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.searchedAt = searchedAt
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Trip Plan

struct TripPlan: Identifiable, Codable, Equatable {
    var id = UUID()
    var itineraryID: String = UUID().uuidString
    let departureTime: Date
    let arrivalTime: Date
    let totalDurationMinutes: Int
    let legs: [TripLeg]
    let totalWalkMeters: Double
    let numTransfers: Int
    var routeChips: [TripRouteChip] = []
    var nextAction: TripNextAction?
    var status: String = "upcoming"
    var reliabilityScore: Int = 100
    var rankingScore: Double = 0
    var disruptionLevel: String = "normal"
    var serviceAlerts: [TripServiceAlert] = []
    var leaveInSeconds: Int? = nil
    var arriveInSeconds: Int? = nil

    var departureTimeString: String {
        Self.timeFormatter.string(from: departureTime)
    }

    var arrivalTimeString: String {
        Self.timeFormatter.string(from: arrivalTime)
    }

    var durationString: String {
        let hours = totalDurationMinutes / 60
        let mins = totalDurationMinutes % 60
        if hours > 0 {
            return "\(hours) h \(String(format: "%02d", mins)) min"
        }
        return "\(mins) min"
    }

    var primaryAlert: TripServiceAlert? {
        serviceAlerts.sorted { $0.severityRank > $1.severityRank }.first
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

struct TripLeg: Identifiable, Codable, Equatable {
    var id = UUID()
    let mode: TripLegMode
    let routeId: String?
    let routeName: String?
    let routeColor: String?
    let textColorHex: String?
    let modeName: String?
    let headsign: String?
    let boardStopId: String?
    let alightStopId: String?
    let boardStopName: String
    let alightStopName: String
    let departureTime: Date
    let arrivalTime: Date
    let numStops: Int
    let durationMinutes: Int
    let walkMeters: Double
    let busServiceType: String?
    let liveStatus: TripLegLiveStatus?
    let alerts: [TripServiceAlert]

    init(
        mode: TripLegMode,
        routeId: String?,
        routeName: String?,
        routeColor: String?,
        textColorHex: String? = nil,
        modeName: String? = nil,
        headsign: String?,
        boardStopId: String? = nil,
        alightStopId: String? = nil,
        boardStopName: String,
        alightStopName: String,
        departureTime: Date,
        arrivalTime: Date,
        numStops: Int,
        durationMinutes: Int,
        walkMeters: Double = 0,
        busServiceType: String? = nil,
        liveStatus: TripLegLiveStatus? = nil,
        alerts: [TripServiceAlert] = []
    ) {
        self.mode = mode
        self.routeId = routeId
        self.routeName = routeName
        self.routeColor = routeColor
        self.textColorHex = textColorHex
        self.modeName = modeName
        self.headsign = headsign
        self.boardStopId = boardStopId
        self.alightStopId = alightStopId
        self.boardStopName = boardStopName
        self.alightStopName = alightStopName
        self.departureTime = departureTime
        self.arrivalTime = arrivalTime
        self.numStops = numStops
        self.durationMinutes = durationMinutes
        self.walkMeters = walkMeters
        self.busServiceType = busServiceType
        self.liveStatus = liveStatus
        self.alerts = alerts
    }

    var isTransit: Bool {
        mode != .walk && mode != .transfer
    }
}

enum TripLegMode: String, Codable, Equatable {
    case subway = "subway"
    case bus = "bus"
    case lirr = "lirr"
    case mnr = "mnr"
    case walk = "walk"
    case transfer = "transfer"

    init(engineMode: String) {
        switch engineMode.lowercased() {
        case "subway":
            self = .subway
        case "bus":
            self = .bus
        case "lirr":
            self = .lirr
        case "mnr", "metro_north":
            self = .mnr
        case "transfer":
            self = .transfer
        default:
            self = .walk
        }
    }

    var icon: String {
        switch self {
        case .subway:
            return "tram.fill"
        case .bus:
            return "bus.fill"
        case .lirr:
            return "train.side.front.car"
        case .mnr:
            return "train.side.rear.car"
        case .walk:
            return "figure.walk"
        case .transfer:
            return "arrow.triangle.swap"
        }
    }

    var label: String {
        switch self {
        case .subway:
            return "Subway"
        case .bus:
            return "Bus"
        case .lirr:
            return "LIRR"
        case .mnr:
            return "Metro-North"
        case .walk:
            return "Walk"
        case .transfer:
            return "Transfer"
        }
    }
}

struct TripRouteChip: Codable, Equatable {
    let kind: String
    let label: String
    let routeId: String?
    let colorHex: String?
    let textColorHex: String?
    let mode: String?
    let modeName: String?
    let durationSeconds: Int?
    let walkMeters: Double?

    var isWalk: Bool {
        kind == "walk"
    }

    var routeMode: TripLegMode? {
        guard let mode else { return nil }
        return TripLegMode(engineMode: mode)
    }
}

struct TripLegLiveStatus: Codable, Equatable {
    let source: String
    let status: String
    let predictedDepartureTime: Date?
    let predictedArrivalTime: Date?
    let delaySeconds: Int?
    let statusText: String?
    let isRealtime: Bool?
    let matchedTripId: String?

    var shortLabel: String? {
        if let statusText, !statusText.isEmpty {
            return statusText
        }
        guard let delaySeconds else { return nil }
        if abs(delaySeconds) < 60 {
            return "On time"
        }
        let minutes = Int(round(Double(delaySeconds) / 60.0))
        return minutes > 0 ? "\(minutes)m late" : "\(abs(minutes))m early"
    }
}

struct TripServiceAlert: Codable, Equatable, Identifiable {
    let routeId: String?
    let severity: String
    let title: String
    let description: String
    let mode: String
    let alertType: String?
    let activePeriodEnd: Date?

    var id: String {
        [routeId ?? "system", mode, title].joined(separator: ":")
    }

    var severityRank: Int {
        switch severity.lowercased() {
        case "severe":
            return 3
        case "warning":
            return 2
        default:
            return 1
        }
    }
}

struct TripNextAction: Codable, Equatable {
    let status: String
    let title: String
    let subtitle: String
    let dueAt: Date
    let dueInSeconds: Int
}

// MARK: - Departure Option

enum DepartureOption: Equatable {
    case leaveNow
    case departAt(Date)
    case arriveBy(Date)

    var label: String {
        switch self {
        case .leaveNow:
            return "Leave now"
        case .departAt(let date):
            return "Depart \(Self.shortTime(date))"
        case .arriveBy(let date):
            return "Arrive \(Self.shortTime(date))"
        }
    }

    var departureTimestamp: Int? {
        if case .departAt(let date) = self {
            return Int(date.timeIntervalSince1970)
        }
        return nil
    }

    var arrivalTimestamp: Int? {
        if case .arriveBy(let date) = self {
            return Int(date.timeIntervalSince1970)
        }
        return nil
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Plan Location

enum PlanLocation: Equatable {
    case currentLocation
    case saved(SavedLocation)
    case recent(RecentSearchLocation)
    case custom(name: String, address: String, lat: Double, lon: Double)

    var displayName: String {
        switch self {
        case .currentLocation:
            return "My location"
        case .saved(let loc):
            return loc.name
        case .recent(let loc):
            return loc.name
        case .custom(let name, _, _, _):
            return name
        }
    }

    var displayAddress: String? {
        switch self {
        case .currentLocation:
            return nil
        case .saved(let loc):
            return loc.address
        case .recent(let loc):
            return loc.address
        case .custom(_, let address, _, _):
            return address
        }
    }

    var coordinate: CLLocationCoordinate2D? {
        switch self {
        case .currentLocation:
            return nil
        case .saved(let loc):
            return loc.coordinate
        case .recent(let loc):
            return loc.coordinate
        case .custom(_, _, let lat, let lon):
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
}

// MARK: - Recent Trip Cards

@Model
final class SavedTrip {
    var id: UUID
    var originName: String
    var originAddress: String
    var originLat: Double
    var originLon: Double
    var destinationName: String
    var destinationAddress: String
    var destinationLat: Double
    var destinationLon: Double
    var legSummary: [String]
    var legModes: [String]
    var savedAt: Date
    var lastUsedAt: Date?
    var usageCount: Int

    init(
        originName: String,
        originAddress: String,
        originLat: Double,
        originLon: Double,
        destinationName: String,
        destinationAddress: String,
        destinationLat: Double,
        destinationLon: Double,
        legSummary: [String] = [],
        legModes: [String] = [],
        savedAt: Date = .now,
        lastUsedAt: Date? = nil,
        usageCount: Int = 1
    ) {
        self.id = UUID()
        self.originName = originName
        self.originAddress = originAddress
        self.originLat = originLat
        self.originLon = originLon
        self.destinationName = destinationName
        self.destinationAddress = destinationAddress
        self.destinationLat = destinationLat
        self.destinationLon = destinationLon
        self.legSummary = legSummary
        self.legModes = legModes
        self.savedAt = savedAt
        self.lastUsedAt = lastUsedAt
        self.usageCount = usageCount
    }
}

// MARK: - Planner Search / Recommendation Models

struct PlannerSearchResult: Identifiable, Codable, Equatable {
    let source: String
    let label: String
    let subtitle: String
    let lat: Double
    let lon: Double
    let score: Double
    let stopID: String?
    let placeID: Int?
    let icon: String?
    let mode: String?

    enum CodingKeys: String, CodingKey {
        case source
        case label
        case subtitle
        case lat
        case lon
        case score
        case stopID = "stop_id"
        case placeID = "place_id"
        case icon
        case mode
    }

    var id: String {
        [source, label, stopID ?? "", String(lat), String(lon)].joined(separator: ":")
    }

    var iconName: String {
        if let icon, !icon.isEmpty {
            return icon
        }
        switch source {
        case "saved_place":
            return "star.fill"
        case "recent_destination":
            return "clock.arrow.circlepath"
        default:
            return mode == "subway" ? "tram.fill" : "mappin"
        }
    }
}

struct PlannerRecommendation: Identifiable, Codable, Equatable {
    let source: String
    let label: String
    let subtitle: String
    let lat: Double
    let lon: Double
    let score: Double
    let reason: String
    let upcomingAt: Int?
    let placeID: Int?
    let savedTripID: Int?

    enum CodingKeys: String, CodingKey {
        case source
        case label
        case subtitle
        case lat
        case lon
        case score
        case reason
        case upcomingAt = "upcoming_at"
        case placeID = "place_id"
        case savedTripID = "saved_trip_id"
    }

    var id: String {
        [source, label, String(lat), String(lon), String(upcomingAt ?? 0)].joined(separator: ":")
    }

    var upcomingDate: Date? {
        guard let upcomingAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(upcomingAt))
    }
}

struct PlannerSavedPlaceRecord: Codable, Equatable {
    let placeID: Int
    let userID: String
    let label: String
    let kind: String
    let lat: Double
    let lon: Double
    let address: String?
    let icon: String?
    let createdAt: Int
    let updatedAt: Int
    let lastUsedAt: Int?

    enum CodingKeys: String, CodingKey {
        case placeID = "place_id"
        case userID = "user_id"
        case label
        case kind
        case lat
        case lon
        case address
        case icon
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastUsedAt = "last_used_at"
    }
}

struct EngineSavedPlaceUpsertRequest: Encodable, Equatable {
    let userID: String
    let label: String
    let kind: String
    let lat: Double
    let lon: Double
    let address: String?
    let icon: String?
    let placeID: Int?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case label
        case kind
        case lat
        case lon
        case address
        case icon
        case placeID = "place_id"
    }
}

struct PlannerRecentTripRecord: Codable, Equatable {
    let recentTripID: Int
    let userID: String
    let originLabel: String
    let originLat: Double
    let originLon: Double
    let destinationLabel: String
    let destinationLat: Double
    let destinationLon: Double
    let requestedAt: Int
    let leaveAtTS: Int
    let arriveAtTS: Int
    let summary: String
    let routeTokens: [String]

    enum CodingKeys: String, CodingKey {
        case recentTripID = "recent_trip_id"
        case userID = "user_id"
        case originLabel = "origin_label"
        case originLat = "origin_lat"
        case originLon = "origin_lon"
        case destinationLabel = "destination_label"
        case destinationLat = "destination_lat"
        case destinationLon = "destination_lon"
        case requestedAt = "requested_at"
        case leaveAtTS = "leave_at_ts"
        case arriveAtTS = "arrive_at_ts"
        case summary
        case routeTokens = "route_tokens"
    }
}

// MARK: - TrackEngine Request / Response DTOs

struct EngineLocationPayloadRequest: Encodable, Equatable {
    let label: String
    let lat: Double?
    let lon: Double?
    let stopID: String?
    let address: String?

    enum CodingKeys: String, CodingKey {
        case label
        case lat
        case lon
        case stopID = "stop_id"
        case address
    }
}

struct EngineGoRequestPayload: Encodable, Equatable {
    let origin: EngineLocationPayloadRequest
    let destination: EngineLocationPayloadRequest
    let userID: String?
    let departAtTS: Int?
    let arriveByTS: Int?
    let maxTransfers: Int
    let maxOriginWalkM: Int
    let maxDestinationWalkM: Int
    let maxTransferWalkM: Int
    let searchWindowMinutes: Int
    let numItineraries: Int
    let modes: [String]
    let recordRecent: Bool
    let nowTS: Int?

    enum CodingKeys: String, CodingKey {
        case origin
        case destination
        case userID = "user_id"
        case departAtTS = "depart_at_ts"
        case arriveByTS = "arrive_by_ts"
        case maxTransfers = "max_transfers"
        case maxOriginWalkM = "max_origin_walk_m"
        case maxDestinationWalkM = "max_destination_walk_m"
        case maxTransferWalkM = "max_transfer_walk_m"
        case searchWindowMinutes = "search_window_minutes"
        case numItineraries = "num_itineraries"
        case modes
        case recordRecent = "record_recent"
        case nowTS = "now_ts"
    }
}

struct EngineGoResponseDTO: Codable, Equatable {
    let engineVersion: String
    let requestedAtTS: Int
    let nowTS: Int
    let sessionKind: String
    let primaryTrip: EngineGoTripDTO?
    let alternatives: [EngineGoTripDTO]
    let scheduleNote: String?

    enum CodingKeys: String, CodingKey {
        case engineVersion = "engine_version"
        case requestedAtTS = "requested_at_ts"
        case nowTS = "now_ts"
        case sessionKind = "session_kind"
        case primaryTrip = "primary_trip"
        case alternatives
        case scheduleNote = "schedule_note"
    }

    var tripPlans: [TripPlan] {
        var plans: [TripPlan] = []
        if let primaryTrip {
            plans.append(primaryTrip.toTripPlan())
        }
        plans.append(contentsOf: alternatives.map { $0.toTripPlan() })
        return plans
    }
}

struct EngineGoTripDTO: Codable, Equatable {
    let itinerary: EngineItineraryDTO
    let routeChips: [EngineRouteChipDTO]
    let nextAction: EngineGoActionDTO?
    let status: String
    let leaveInS: Int
    let arriveInS: Int
    let reliabilityScore: Int
    let rankingScore: Double
    let disruptionLevel: String
    let serviceAlerts: [EngineServiceAlertDTO]

    enum CodingKeys: String, CodingKey {
        case itinerary
        case routeChips = "route_chips"
        case nextAction = "next_action"
        case status
        case leaveInS = "leave_in_s"
        case arriveInS = "arrive_in_s"
        case reliabilityScore = "reliability_score"
        case rankingScore = "ranking_score"
        case disruptionLevel = "disruption_level"
        case serviceAlerts = "service_alerts"
    }

    func toTripPlan() -> TripPlan {
        TripPlan(
            itineraryID: itinerary.itineraryID,
            departureTime: Date(timeIntervalSince1970: TimeInterval(itinerary.leaveAtTS)),
            arrivalTime: Date(timeIntervalSince1970: TimeInterval(itinerary.arriveAtTS)),
            totalDurationMinutes: max(1, itinerary.totalDurationS / 60),
            legs: itinerary.legs.map { $0.toTripLeg() },
            totalWalkMeters: itinerary.walkMeters,
            numTransfers: itinerary.transferCount,
            routeChips: routeChips.map { $0.toTripRouteChip() },
            nextAction: nextAction?.toTripNextAction(),
            status: status,
            reliabilityScore: reliabilityScore,
            rankingScore: rankingScore,
            disruptionLevel: disruptionLevel,
            serviceAlerts: serviceAlerts.map { $0.toTripServiceAlert() },
            leaveInSeconds: leaveInS,
            arriveInSeconds: arriveInS
        )
    }
}

struct EngineItineraryDTO: Codable, Equatable {
    let itineraryID: String
    let leaveAtTS: Int
    let arriveAtTS: Int
    let totalDurationS: Int
    let transferCount: Int
    let walkMeters: Double
    let legs: [EngineTripLegDTO]

    enum CodingKeys: String, CodingKey {
        case itineraryID = "itinerary_id"
        case leaveAtTS = "leave_at_ts"
        case arriveAtTS = "arrive_at_ts"
        case totalDurationS = "total_duration_s"
        case transferCount = "transfer_count"
        case walkMeters = "walk_meters"
        case legs
    }
}

struct EngineTripLegDTO: Codable, Equatable {
    let mode: String
    let routeID: String
    let routeName: String
    let colorHex: String?
    let textColorHex: String?
    let modeName: String?
    let headsign: String?
    let boardStopID: String
    let boardStopName: String
    let alightStopID: String
    let alightStopName: String
    let departureTS: Int
    let arrivalTS: Int
    let stopCount: Int
    let walkMeters: Double
    let busServiceType: String?
    let liveStatus: EngineLegLiveStatusDTO?
    let alerts: [EngineServiceAlertDTO]

    enum CodingKeys: String, CodingKey {
        case mode
        case routeID = "route_id"
        case routeName = "route_name"
        case colorHex = "color_hex"
        case textColorHex = "text_color_hex"
        case modeName = "mode_name"
        case headsign
        case boardStopID = "board_stop_id"
        case boardStopName = "board_stop_name"
        case alightStopID = "alight_stop_id"
        case alightStopName = "alight_stop_name"
        case departureTS = "departure_ts"
        case arrivalTS = "arrival_ts"
        case stopCount = "stop_count"
        case walkMeters = "walk_meters"
        case busServiceType = "bus_service_type"
        case liveStatus = "live_status"
        case alerts
    }

    func toTripLeg() -> TripLeg {
        TripLeg(
            mode: TripLegMode(engineMode: mode),
            routeId: mode == "walk" ? nil : routeID,
            routeName: mode == "walk" ? nil : routeName,
            routeColor: colorHex,
            textColorHex: textColorHex,
            modeName: modeName,
            headsign: headsign,
            boardStopId: boardStopID,
            alightStopId: alightStopID,
            boardStopName: boardStopName,
            alightStopName: alightStopName,
            departureTime: Date(timeIntervalSince1970: TimeInterval(departureTS)),
            arrivalTime: Date(timeIntervalSince1970: TimeInterval(arrivalTS)),
            numStops: stopCount,
            durationMinutes: max(1, Int(round(Double(max(arrivalTS - departureTS, 60)) / 60.0))),
            walkMeters: walkMeters,
            busServiceType: busServiceType,
            liveStatus: liveStatus?.toTripLegLiveStatus(),
            alerts: alerts.map { $0.toTripServiceAlert() }
        )
    }
}

struct EngineRouteChipDTO: Codable, Equatable {
    let kind: String
    let label: String
    let routeID: String?
    let colorHex: String?
    let textColorHex: String?
    let mode: String?
    let modeName: String?
    let durationS: Int?
    let walkMeters: Double?

    enum CodingKeys: String, CodingKey {
        case kind
        case label
        case routeID = "route_id"
        case colorHex = "color_hex"
        case textColorHex = "text_color_hex"
        case mode
        case modeName = "mode_name"
        case durationS = "duration_s"
        case walkMeters = "walk_meters"
    }

    func toTripRouteChip() -> TripRouteChip {
        TripRouteChip(
            kind: kind,
            label: label,
            routeId: routeID,
            colorHex: colorHex,
            textColorHex: textColorHex,
            mode: mode,
            modeName: modeName,
            durationSeconds: durationS,
            walkMeters: walkMeters
        )
    }
}

struct EngineGoActionDTO: Codable, Equatable {
    let status: String
    let title: String
    let subtitle: String
    let dueAtTS: Int
    let dueInS: Int

    enum CodingKeys: String, CodingKey {
        case status
        case title
        case subtitle
        case dueAtTS = "due_at_ts"
        case dueInS = "due_in_s"
    }

    func toTripNextAction() -> TripNextAction {
        TripNextAction(
            status: status,
            title: title,
            subtitle: subtitle,
            dueAt: Date(timeIntervalSince1970: TimeInterval(dueAtTS)),
            dueInSeconds: dueInS
        )
    }
}

struct EngineLegLiveStatusDTO: Codable, Equatable {
    let source: String
    let status: String
    let predictedDepartureTS: Int?
    let predictedArrivalTS: Int?
    let delayS: Int?
    let statusText: String?
    let isRealtime: Bool?
    let matchedTripID: String?

    enum CodingKeys: String, CodingKey {
        case source
        case status
        case predictedDepartureTS = "predicted_departure_ts"
        case predictedArrivalTS = "predicted_arrival_ts"
        case delayS = "delay_s"
        case statusText = "status_text"
        case isRealtime = "is_realtime"
        case matchedTripID = "matched_trip_id"
    }

    func toTripLegLiveStatus() -> TripLegLiveStatus {
        TripLegLiveStatus(
            source: source,
            status: status,
            predictedDepartureTime: predictedDepartureTS.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            predictedArrivalTime: predictedArrivalTS.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            delaySeconds: delayS,
            statusText: statusText,
            isRealtime: isRealtime,
            matchedTripId: matchedTripID
        )
    }
}

struct EngineServiceAlertDTO: Codable, Equatable {
    let routeID: String?
    let severity: String
    let title: String
    let description: String
    let mode: String
    let alertType: String?
    let activePeriodEnd: Int?

    enum CodingKeys: String, CodingKey {
        case routeID = "route_id"
        case severity
        case title
        case description
        case mode
        case alertType = "alert_type"
        case activePeriodEnd = "active_period_end"
    }

    func toTripServiceAlert() -> TripServiceAlert {
        TripServiceAlert(
            routeId: routeID,
            severity: severity,
            title: title,
            description: description,
            mode: mode,
            alertType: alertType,
            activePeriodEnd: activePeriodEnd.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            }
        )
    }
}
