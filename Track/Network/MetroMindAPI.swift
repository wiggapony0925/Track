// MetroMindAPI.swift
//
// Streaming client for the TrackBackend `/metromind/chat` SSE endpoint.
// Yields decoded events (`token`, `toolCall`, `toolResult`, `done`,
// `error`) over an `AsyncThrowingStream` so the chat UI can append
// text incrementally and display tool-call status chips.

import CoreLocation
import Foundation

// MARK: - Public event type

enum MetroMindEvent: Sendable {
    case token(String)
    case toolCall(name: String, label: String)
    case toolResult(name: String, ok: Bool, payload: ToolPayload?)
    case suggestions([SuggestedActionChip])
    case done(toolCalls: [String], modelUsed: String?, threadId: String?)
    case error(String)
}

/// One follow-up chip from the backend.
struct SuggestedActionChip: Sendable, Identifiable, Decodable {
    let id = UUID()
    let label: String
    let kind: String
    /// Free-form payload — we keep it as a JSON string for now since
    /// the only consumer (composer prefill) just needs `payload.text`.
    let promptText: String?
    let routeId: String?
    /// Origin label from the original `plan_route` response — used by
    /// `save_trip` chips so the iOS layer can persist the trip locally
    /// without another tool roundtrip.
    let originLabel: String?
    let destinationLabel: String?
    let tripSummary: String?
    let placeLabel: String?
    /// Concrete arrival data attached to `start_tracking` chips that
    /// follow a `get_live_arrivals` call. Lets iOS launch a Live
    /// Activity directly without a follow-up prompt.
    let arrivalDestination: String?
    let arrivalMinutesAway: Int?
    let arrivalTimestamp: Double?
    let arrivalStationName: String?
    let upcomingMinutes: [Int]?

    private enum CodingKeys: String, CodingKey {
        case label, kind, payload
    }
    private struct Payload: Decodable {
        let text: String?
        let route_id: String?
        let origin: String?
        let destination: String?
        let summary: String?
        let place_label: String?
        let minutes_away: Int?
        let arrival_ts: Double?
        let station_name: String?
        let upcoming_minutes: [Int]?
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try c.decode(String.self, forKey: .label)
        self.kind = try c.decode(String.self, forKey: .kind)
        let payload = try? c.decode(Payload.self, forKey: .payload)
        self.promptText = payload?.text
        self.routeId = payload?.route_id
        self.originLabel = payload?.origin
        self.destinationLabel = payload?.destination
        self.tripSummary = payload?.summary
        self.placeLabel = payload?.place_label
        // For start_tracking chips the `destination` field carries the
        // *train's* destination (e.g. "Coney Island") rather than a
        // user-facing trip endpoint. Same key, different meaning by
        // chip kind — surface it through a dedicated property to keep
        // call sites unambiguous.
        self.arrivalDestination = payload?.destination
        self.arrivalMinutesAway = payload?.minutes_away
        self.arrivalTimestamp = payload?.arrival_ts
        self.arrivalStationName = payload?.station_name
        self.upcomingMinutes = payload?.upcoming_minutes
    }
}

// MARK: - Tool result payloads (decoded into rich UI cards)

enum ToolPayload: Sendable {
    case route(RoutePlanPayload)
    case stations(StationSearchPayload)
    case liveArrivals(LiveArrivalsPayload)
    case stopInfo(StopInfoPayload)
    case equipmentOutages(EquipmentOutagesPayload)
    case serviceAlerts(ServiceAlertsPayload)
}

struct StopInfoPayload: Decodable, Sendable {
    let stop_id: String?
    let station_name: String?
    let accessibility: Accessibility?
    let next_departures: [Departure]?

    struct Accessibility: Decodable, Sendable {
        let ada_status: String?
        let ada_status_code: Int?
        let ada_notes: String?
        let total_elevators: Int?
        let total_escalators: Int?
        let out_of_service_count: Int?
        let out_of_service_equipment: [Equipment]?
        let next_accessible_north: String?
        let next_accessible_south: String?

        struct Equipment: Decodable, Sendable, Identifiable {
            let id = UUID()
            let equipment_id: String?
            let type: String?
            let description: String?
            let is_ada: Bool?
            let outage_reason: String?

            private enum CodingKeys: String, CodingKey {
                case equipment_id, type, description, is_ada, outage_reason
            }
        }
    }

    struct Departure: Decodable, Sendable, Identifiable {
        let id = UUID()
        let route_id: String?
        let mode: String?
        let destination: String?
        let minutes_away: Int?
        let status: String?
        let is_real_time: Bool?
        let is_cancelled: Bool?

        private enum CodingKeys: String, CodingKey {
            case route_id, mode, destination, minutes_away
            case status, is_real_time, is_cancelled
        }
    }
}

struct EquipmentOutagesPayload: Decodable, Sendable {
    let total_outages: Int?
    let returned: Int?
    let truncated: Bool?
    let filters: Filters?
    let outages: [Outage]

    struct Filters: Decodable, Sendable {
        let station_filter: String?
        let equipment_type: String?
    }

    struct Outage: Decodable, Sendable, Identifiable {
        let id = UUID()
        let station: String?
        let type: String?
        let description: String?
        let outage_since: String?

        private enum CodingKeys: String, CodingKey {
            case station, type, description, outage_since
        }
    }
}

struct ServiceAlertsPayload: Decodable, Sendable {
    let total_matching: Int?
    let alerts: [Alert]

    struct Alert: Decodable, Sendable, Identifiable {
        let id = UUID()
        let title: String?
        let description: String?
        let severity: String?
        let mode: String?
        let route_id: String?
        let affected_routes: [String]?
        let alert_type: String?
        let effect: String?
        let active_period: String?

        private enum CodingKeys: String, CodingKey {
            case title, description, severity, mode, route_id
            case affected_routes, alert_type, effect, active_period
        }
    }
}

struct LiveArrivalsPayload: Decodable, Sendable {
    let route_id: String
    let direction_filter: String?
    let station_filter: String?
    let total_returned: Int?
    let arrivals: [Arrival]
    let vehicle_count: Int?

    struct Arrival: Decodable, Sendable, Identifiable {
        let id = UUID()
        let station_name: String?
        let station_id: String?
        let direction: String?
        let destination: String?
        let minutes_away: Int?
        let arrival_ts: Int?
        let status: String?
        let is_cancelled: Bool?
        let is_skipped: Bool?
        let delay_seconds: Int?

        private enum CodingKeys: String, CodingKey {
            case station_name, station_id, direction, destination
            case minutes_away, arrival_ts, status
            case is_cancelled, is_skipped, delay_seconds
        }
    }
}

struct RoutePlanPayload: Decodable, Sendable {
    let origin: String?
    let destination: String?
    let schedule_note: String?
    let itineraries: [Itinerary]

    struct Itinerary: Decodable, Sendable, Identifiable {
        let id = UUID()
        let summary: String?
        let total_minutes: Double?
        let walk_minutes: Double?
        let transfer_count: Int?
        let departure_time: String?
        let arrival_time: String?
        let legs: [Leg]?

        private enum CodingKeys: String, CodingKey {
            case summary, total_minutes, walk_minutes, transfer_count
            case departure_time, arrival_time, legs
        }
    }

    struct Leg: Decodable, Sendable, Identifiable {
        let id = UUID()
        let mode: String?
        let route_id: String?
        let route_label: String?
        let from_name: String?
        let to_name: String?
        let depart_time: String?
        let arrive_time: String?
        let duration_minutes: Double?
        let headsign: String?
        let num_stops: Int?

        private enum CodingKeys: String, CodingKey {
            case mode, route_id, route_label
            case from_name, to_name
            case depart_time, arrive_time
            case duration_minutes, headsign, num_stops
        }
    }
}

struct StationSearchPayload: Decodable, Sendable {
    let query: String?
    let stops: [Stop]

    struct Stop: Decodable, Sendable, Identifiable {
        let id = UUID()
        let stop_id: String?
        let stop_name: String?
        let lat: Double?
        let lon: Double?

        private enum CodingKeys: String, CodingKey {
            case stop_id, stop_name, lat, lon
        }
    }
}

// MARK: - Wire-format models (mirrors backend `schemas.SSE*Event`)

private struct SSEEnvelope: Decodable {
    let type: String
    let text: String?
    let name: String?
    let label: String?
    let ok: Bool?
    let tool_calls: [String]?
    let message: String?
    let model_used: String?
    let thread_id: String?
    let actions: [SuggestedActionChip]?
    // `payload` is a free-form JSON object; we decode it on demand
    // based on the tool name once the envelope is parsed.
    let payload: AnyCodable?
}

/// Lightweight wrapper that lets us hold an arbitrary JSON object on a
/// Decodable struct and re-decode it into a typed payload later.
struct AnyCodable: Decodable, Sendable {
    let json: Data
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Round-trip through JSONSerialization so we capture whatever
        // shape the server sent.
        let value = try container.decode(JSONValue.self)
        self.json = (try? JSONEncoder().encode(value)) ?? Data()
    }

    private enum JSONValue: Codable {
        case string(String), number(Double), bool(Bool), null
        case array([JSONValue]), object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            if let n = try? c.decode(Double.self) { self = .number(n); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
            if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported JSON value"
            )
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let b): try c.encode(b)
            case .number(let n): try c.encode(n)
            case .string(let s): try c.encode(s)
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }
    }
}

// MARK: - Health response

struct MetroMindHealth: Decodable, Sendable {
    let enabled: Bool
    let model: String
    let streaming_enabled: Bool
    let llm: String
    let detail: String?
}

// MARK: - Client

enum MetroMindAPI {

    /// Probes `/metromind/health`. Returns `nil` if the backend is
    /// unreachable.
    static func health() async -> MetroMindHealth? {
        let base = await MainActor.run { TrackAPI.baseURL }
        guard let url = URL(string: base + "/metromind/health") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(MetroMindHealth.self, from: data)
        } catch {
            return nil
        }
    }

    /// A user-saved place (Home, Work, custom) sent to MetroMind so the
    /// LLM knows where "home" is without an extra round-trip.
    struct SavedPlaceContext: Sendable {
        let label: String
        let kind: String
        let lat: Double
        let lon: Double
        let address: String?
    }

    /// A recently planned trip — surfaced to the LLM for follow-ups.
    struct RecentTripContext: Sendable {
        let originLabel: String
        let destinationLabel: String
        let summary: String?
        let requestedAt: Int?
    }

    /// Submit a thumbs-up / thumbs-down rating for an assistant reply.
    /// Fire-and-forget; surfaces transport errors but never throws on
    /// HTTP-level failures so the UI can stay snappy.
    @discardableResult
    static func submitFeedback(
        rating: Int,
        threadId: String? = nil,
        clientMessageId: String? = nil,
        userPrompt: String? = nil,
        assistantText: String? = nil,
        reason: String? = nil,
        modelUsed: String? = nil
    ) async -> Bool {
        let base = await MainActor.run { TrackAPI.baseURL }
        guard let url = URL(string: base + "/metromind/feedback") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8

        var body: [String: Any] = ["rating": rating]
        if let v = threadId, !v.isEmpty { body["thread_id"] = v }
        if let v = clientMessageId, !v.isEmpty { body["client_msg_id"] = v }
        if let v = userPrompt, !v.isEmpty { body["user_prompt"] = v }
        if let v = assistantText, !v.isEmpty { body["assistant_text"] = v }
        if let v = reason, !v.isEmpty { body["reason"] = v }
        if let v = modelUsed, !v.isEmpty { body["model_used"] = v }
        let appVersion = await MainActor.run {
            let info = Bundle.main.infoDictionary
            let short = info?["CFBundleShortVersionString"] as? String ?? "?"
            let build = info?["CFBundleVersion"] as? String ?? "?"
            return "\(short) (\(build))"
        }
        body["app_version"] = appVersion

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    /// Streams a chat turn. Yields events in order until the server
    /// closes the connection. Throws on transport / HTTP errors; soft
    /// errors from the model are surfaced as `.error(msg)` events.
    static func chatStream(
        message: String,
        history: [(role: String, content: String)] = [],
        location: CLLocationCoordinate2D? = nil,
        biasLat: Double? = nil,
        biasLon: Double? = nil,
        biasSource: String? = nil,
        biasLabel: String? = nil,
        userName: String? = nil,
        savedPlaces: [SavedPlaceContext] = [],
        recentTrips: [RecentTripContext] = [],
        topRoutes: [String] = [],
        threadId: String? = nil,
        imageDataURL: String? = nil
    ) -> AsyncThrowingStream<MetroMindEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let base = await MainActor.run { TrackAPI.baseURL }
                    guard let url = URL(string: base + "/metromind/chat") else {
                        continuation.finish(throwing: URLError(.badURL))
                        return
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 60

                    var body: [String: Any] = [
                        "message": message,
                        "stream": true,
                        "history": history.map { ["role": $0.role, "content": $0.content] },
                    ]
                    if let tid = threadId, !tid.isEmpty {
                        body["thread_id"] = tid
                    }
                    if let img = imageDataURL, !img.isEmpty {
                        body["image_data_url"] = img
                    }

                    var ctx: [String: Any] = ["timezone": "America/New_York"]
                    // When the user has dropped a search pin we treat that as
                    // their *effective* location for this turn — overriding
                    // GPS so MetroMind doesn't see two coordinates and
                    // accidentally answer "near me" relative to the wrong one.
                    if let bLat = biasLat, let bLon = biasLon, biasSource == "map_pin" {
                        ctx["lat"] = bLat
                        ctx["lon"] = bLon
                    } else if let loc = location {
                        ctx["lat"] = loc.latitude
                        ctx["lon"] = loc.longitude
                    }
                    if let bLat = biasLat, let bLon = biasLon {
                        ctx["bias_lat"] = bLat
                        ctx["bias_lon"] = bLon
                        if let src = biasSource { ctx["bias_source"] = src }
                        if let lbl = biasLabel { ctx["bias_label"] = lbl }
                    }
                    if let name = userName, !name.isEmpty {
                        ctx["user_name"] = name
                    }
                    if !savedPlaces.isEmpty {
                        ctx["saved_places"] = savedPlaces.map { p -> [String: Any] in
                            var d: [String: Any] = [
                                "label": p.label,
                                "kind": p.kind,
                                "lat": p.lat,
                                "lon": p.lon,
                            ]
                            if let addr = p.address { d["address"] = addr }
                            return d
                        }
                    }
                    if !recentTrips.isEmpty {
                        ctx["recent_trips"] = recentTrips.map { t -> [String: Any] in
                            var d: [String: Any] = [
                                "origin_label": t.originLabel,
                                "destination_label": t.destinationLabel,
                            ]
                            if let s = t.summary { d["summary"] = s }
                            if let r = t.requestedAt { d["requested_at"] = r }
                            return d
                        }
                    }
                    if !topRoutes.isEmpty {
                        // Backend uses these to personalise default chip
                        // text (e.g. "Any 7 delays?" instead of always L)
                        // and to surface a "Track the {topRoute}" shortcut.
                        ctx["top_routes"] = Array(topRoutes.prefix(5))
                    }
                    if ctx.count > 1 || location != nil {
                        body["context"] = ctx
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        continuation.finish(
                            throwing: NSError(
                                domain: "MetroMindAPI",
                                code: http.statusCode,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "Server returned HTTP \(http.statusCode)",
                                ]
                            )
                        )
                        return
                    }

                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        // SSE frames look like:  data: {"type":"token", ...}
                        guard line.hasPrefix("data:") else { continue }
                        let raw = line
                            .dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        guard !raw.isEmpty,
                              let data = raw.data(using: .utf8),
                              let env = try? decoder.decode(SSEEnvelope.self, from: data)
                        else { continue }

                        switch env.type {
                        case "token":
                            continuation.yield(.token(env.text ?? ""))
                        case "tool_call":
                            continuation.yield(
                                .toolCall(
                                    name: env.name ?? "",
                                    label: env.label ?? ""
                                )
                            )
                        case "tool_result":
                            let name = env.name ?? ""
                            let payload = Self.decodeToolPayload(
                                name: name, raw: env.payload
                            )
                            continuation.yield(
                                .toolResult(
                                    name: name,
                                    ok: env.ok ?? true,
                                    payload: payload
                                )
                            )
                        case "done":
                            continuation.yield(
                                .done(
                                    toolCalls: env.tool_calls ?? [],
                                    modelUsed: env.model_used,
                                    threadId: env.thread_id
                                )
                            )
                        case "suggestions":
                            continuation.yield(.suggestions(env.actions ?? []))
                        case "error":
                            continuation.yield(.error(env.message ?? "unknown error"))
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decode the optional payload attached to a `tool_result` event.
    private static func decodeToolPayload(
        name: String,
        raw: AnyCodable?
    ) -> ToolPayload? {
        guard let data = raw?.json, !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        switch name {
        case "plan_route":
            if let p = try? decoder.decode(RoutePlanPayload.self, from: data) {
                return .route(p)
            }
        case "search_stations":
            if let p = try? decoder.decode(StationSearchPayload.self, from: data) {
                return .stations(p)
            }
        case "get_live_arrivals":
            if let p = try? decoder.decode(LiveArrivalsPayload.self, from: data) {
                return .liveArrivals(p)
            }
        case "get_stop_info":
            if let p = try? decoder.decode(StopInfoPayload.self, from: data) {
                return .stopInfo(p)
            }
        case "get_equipment_outages":
            if let p = try? decoder.decode(EquipmentOutagesPayload.self, from: data) {
                return .equipmentOutages(p)
            }
        case "get_service_alerts":
            if let p = try? decoder.decode(ServiceAlertsPayload.self, from: data) {
                return .serviceAlerts(p)
            }
        default:
            return nil
        }
        return nil
    }
}
