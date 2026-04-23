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
    case done(toolCalls: [String])
    case error(String)
}

// MARK: - Tool result payloads (decoded into rich UI cards)

enum ToolPayload: Sendable {
    case route(RoutePlanPayload)
    case stations(StationSearchPayload)
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

    /// Streams a chat turn. Yields events in order until the server
    /// closes the connection. Throws on transport / HTTP errors; soft
    /// errors from the model are surfaced as `.error(msg)` events.
    static func chatStream(
        message: String,
        history: [(role: String, content: String)] = [],
        location: CLLocationCoordinate2D? = nil
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
                    if let loc = location {
                        body["context"] = [
                            "lat": loc.latitude,
                            "lon": loc.longitude,
                            "timezone": "America/New_York",
                        ]
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
                            continuation.yield(.done(toolCalls: env.tool_calls ?? []))
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
        default:
            return nil
        }
        return nil
    }
}
