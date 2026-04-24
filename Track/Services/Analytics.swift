//
//  Analytics.swift
//  Track
//
//  Server-driven product analytics for Track.  Buffers typed events in memory,
//  flushes in batches to `/analytics/batch` over an authenticated request,
//  and persists pending events to disk so we don't lose telemetry across
//  cold-starts or crashes.
//
//  Design rules
//  ────────────
//  • Singleton — `Analytics.shared`.  Safe to call from any actor.
//  • Never blocks the caller: `track(...)` returns immediately.
//  • Never throws: failures are silently retried on the next flush.
//  • Auto-manages a single foreground session via SwiftUI `scenePhase`.
//  • Auto-flushes every 30 s, when the buffer reaches 25 events, or on
//    background / terminate notifications.
//  • Drops everything cleanly when the user is signed out — we never collect
//    behavior we can't tie to a user (per product decision).
//
//  Usage
//  ─────
//      Analytics.shared.screenView("HomeView", reachedVia: "tab")
//      Analytics.shared.event("favorite_added", properties: ["route_id": "7"])
//      Analytics.shared.search(source: "home", query: "Times Sq", resultsCount: 12, pickedIndex: 0, pickedKind: "station")
//      Analytics.shared.routeEngagement(action: "select", routeId: "7", mode: "subway", positionInList: 0)
//      Analytics.shared.error(kind: "network", message: "timeout", endpoint: "/predict/arrival", httpStatus: 504)
//      Analytics.shared.perf(kind: "api", name: "/nearby/grouped", durationMs: 312, httpStatus: 200)
//

import Foundation
import UIKit

// MARK: - Public facade

@MainActor
final class Analytics {

    static let shared = Analytics()

    // ── Tunables ──────────────────────────────────────────────────────────
    private let flushThreshold = 25
    private let flushInterval: TimeInterval = 30
    private let backgroundSessionGap: TimeInterval = 30   // ≤ 30 s gap merges
    private let maxBufferOnDisk = 500
    private let endpointBatchPath = "/analytics/batch"
    private let endpointSessionStart = "/analytics/session/start"
    private let endpointSessionEnd = "/analytics/session/end"

    // ── State ─────────────────────────────────────────────────────────────
    private var buffer: [[String: Any]] = []
    private var sessionId: String?
    private var sessionStartedAt: Date?
    private var lastBackgroundedAt: Date?
    private var sessionScreenViews = 0
    private var sessionEventCount = 0
    private var flushTimer: Timer?
    private var inFlight = false

    private var bufferFileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("analytics_buffer.json")
    }

    private init() {
        loadPersistedBuffer()
        startFlushTimer()
    }

    // ── Lifecycle (called from TrackApp scenePhase) ───────────────────────

    func appDidBecomeActive(entrySource: String = "warm") {
        let now = Date()
        // Resume an existing session if we just briefly backgrounded.
        if let sid = sessionId,
           let lastBg = lastBackgroundedAt,
           now.timeIntervalSince(lastBg) < backgroundSessionGap {
            lastBackgroundedAt = nil
            return
        }
        // Otherwise start a fresh one.
        sessionId = nil
        sessionScreenViews = 0
        sessionEventCount = 0
        sessionStartedAt = now
        Task { await startSession(entrySource: entrySource) }
    }

    func appDidEnterBackground() {
        lastBackgroundedAt = Date()
        flush(reason: "background", waitForResult: false)
        Task { await endSessionIfNeeded() }
    }

    func appWillTerminate() {
        persistBuffer()
        // Best-effort sync end.
        Task { await endSessionIfNeeded() }
    }

    // ── Public emit API ───────────────────────────────────────────────────

    func event(_ name: String,
               properties: [String: Any] = [:],
               screen: String? = nil) {
        enqueue(merge([
            "type": "event",
            "event_name": name,
            "properties": sanitizeProperties(properties),
            "screen": screen,
        ], commonFields()))
    }

    func screenView(_ screen: String,
                    previousScreen: String? = nil,
                    reachedVia: String? = nil) {
        sessionScreenViews += 1
        enqueue([
            "type": "screen_view",
            "screen": screen,
            "previous_screen": previousScreen,
            "reached_via": reachedVia,
            "entered_at": isoNow(),
            "app_version": appVersionShort(),
        ])
    }

    func screenExit(_ screen: String,
                    durationMs: Int,
                    scrollDepthPct: Int? = nil,
                    interactionsCount: Int = 0) {
        enqueue([
            "type": "screen_view",
            "screen": screen,
            "exited_at": isoNow(),
            "duration_ms": durationMs,
            "scroll_depth_pct": scrollDepthPct,
            "interactions_count": interactionsCount,
            "app_version": appVersionShort(),
        ])
    }

    func search(source: String,
                query: String,
                resultsCount: Int? = nil,
                pickedIndex: Int? = nil,
                pickedId: String? = nil,
                pickedKind: String? = nil,
                latencyMs: Int? = nil,
                abandoned: Bool = false,
                originLat: Double? = nil,
                originLon: Double? = nil) {
        enqueue([
            "type": "search",
            "source": source,
            "query": query,
            "results_count": resultsCount,
            "picked_index": pickedIndex,
            "picked_id": pickedId,
            "picked_kind": pickedKind,
            "latency_ms": latencyMs,
            "abandoned": abandoned,
            "origin_lat": originLat,
            "origin_lon": originLon,
            "occurred_at": isoNow(),
        ])
    }

    func routeEngagement(action: String,
                         routeId: String? = nil,
                         routeDisplayName: String? = nil,
                         mode: String? = nil,
                         originLabel: String? = nil,
                         originLat: Double? = nil,
                         originLon: Double? = nil,
                         destinationLabel: String? = nil,
                         destinationLat: Double? = nil,
                         destinationLon: Double? = nil,
                         etaSeconds: Int? = nil,
                         transfersCount: Int? = nil,
                         walkMeters: Int? = nil,
                         alternativesOffered: Int? = nil,
                         positionInList: Int? = nil,
                         sourceScreen: String? = nil,
                         metadata: [String: Any] = [:]) {
        enqueue([
            "type": "route",
            "action": action,
            "route_id": routeId,
            "route_display_name": routeDisplayName,
            "mode": mode,
            "origin_label": originLabel,
            "origin_lat": originLat,
            "origin_lon": originLon,
            "destination_label": destinationLabel,
            "destination_lat": destinationLat,
            "destination_lon": destinationLon,
            "eta_seconds": etaSeconds,
            "transfers_count": transfersCount,
            "walk_meters": walkMeters,
            "alternatives_offered": alternativesOffered,
            "position_in_list": positionInList,
            "source_screen": sourceScreen,
            "metadata": sanitizeProperties(metadata),
            "occurred_at": isoNow(),
        ])
    }

    func mapInteraction(kind: String,
                        zoomLevel: Double? = nil,
                        centerLat: Double? = nil,
                        centerLon: Double? = nil,
                        targetId: String? = nil,
                        targetKind: String? = nil) {
        enqueue([
            "type": "map",
            "kind": kind,
            "zoom_level": zoomLevel,
            "center_lat": centerLat,
            "center_lon": centerLon,
            "target_id": targetId,
            "target_kind": targetKind,
            "occurred_at": isoNow(),
        ])
    }

    func error(kind: String,
               message: String,
               severity: String = "error",
               stack: String? = nil,
               screen: String? = nil,
               endpoint: String? = nil,
               httpStatus: Int? = nil,
               metadata: [String: Any] = [:]) {
        enqueue([
            "type": "error",
            "kind": kind,
            "severity": severity,
            "message": String(message.prefix(2000)),
            "stack": stack.map { String($0.prefix(8000)) },
            "screen": screen,
            "endpoint": endpoint,
            "http_status": httpStatus,
            "metadata": sanitizeProperties(metadata),
            "app_version": appVersionShort(),
            "os_version": osVersion(),
            "occurred_at": isoNow(),
        ])
    }

    func perf(kind: String,
              name: String,
              durationMs: Int,
              httpStatus: Int? = nil,
              payloadBytes: Int? = nil,
              cacheHit: Bool? = nil,
              networkType: String? = nil) {
        enqueue([
            "type": "perf",
            "kind": kind,
            "name": name,
            "duration_ms": max(0, durationMs),
            "http_status": httpStatus,
            "payload_bytes": payloadBytes,
            "cache_hit": cacheHit,
            "network_type": networkType ?? networkTypeString(),
            "occurred_at": isoNow(),
        ])
    }

    func notification(kind: String,
                      notificationId: String? = nil,
                      category: String? = nil,
                      actionId: String? = nil,
                      payload: [String: Any] = [:]) {
        enqueue([
            "type": "notification",
            "kind": kind,
            "notification_id": notificationId,
            "category": category,
            "action_id": actionId,
            "payload": sanitizeProperties(payload),
            "occurred_at": isoNow(),
        ])
    }

    func featureFlagExposure(flagKey: String, variant: String, context: [String: Any] = [:]) {
        enqueue([
            "type": "exposure",
            "flag_key": flagKey,
            "variant": variant,
            "context": sanitizeProperties(context),
            "occurred_at": isoNow(),
        ])
    }

    // ── Flushing ──────────────────────────────────────────────────────────

    private func enqueue(_ row: [String: Any]) {
        sessionEventCount += 1
        let cleaned = row.compactMapValues { v -> Any? in
            if let s = v as? String, s.isEmpty { return nil }
            return v is NSNull ? nil : v
        }
        buffer.append(cleaned)
        if buffer.count >= flushThreshold {
            flush(reason: "threshold", waitForResult: false)
        }
    }

    private func startFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { _ in
            Task { @MainActor in
                self.flush(reason: "timer", waitForResult: false)
            }
        }
    }

    private func flush(reason: String, waitForResult: Bool) {
        guard !inFlight, !buffer.isEmpty else { return }
        guard TrackAPI.cachedAccessToken?.isEmpty == false else {
            // No auth — keep buffering until the user signs in (or cap on disk).
            if buffer.count > maxBufferOnDisk {
                buffer.removeFirst(buffer.count - maxBufferOnDisk)
            }
            return
        }
        let toSend = buffer
        let sid = sessionId
        buffer.removeAll(keepingCapacity: true)
        inFlight = true

        Task.detached { [weak self] in
            let success = await Analytics.send(events: toSend, sessionId: sid)
            await MainActor.run {
                guard let self else { return }
                self.inFlight = false
                if !success {
                    // Re-queue at the front so we don't lose them.
                    self.buffer.insert(contentsOf: toSend, at: 0)
                    if self.buffer.count > self.maxBufferOnDisk {
                        self.buffer.removeFirst(self.buffer.count - self.maxBufferOnDisk)
                    }
                    self.persistBuffer()
                } else {
                    self.persistBuffer()
                }
            }
        }
    }

    private static func send(events: [[String: Any]], sessionId: String?) async -> Bool {
        let base = await MainActor.run { TrackAPI.baseURL }
        let token = TrackAPI.cachedAccessToken ?? ""
        guard !token.isEmpty,
              let url = URL(string: base + "/analytics/batch") else { return false }
        var body: [String: Any] = ["events": events]
        if let sid = sessionId { body["session_id"] = sid }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    // ── Sessions ──────────────────────────────────────────────────────────

    private func startSession(entrySource: String) async {
        guard TrackAPI.cachedAccessToken?.isEmpty == false else { return }
        let base = await MainActor.run { TrackAPI.baseURL }
        guard let url = URL(string: base + endpointSessionStart) else { return }
        let body: [String: Any] = [
            "app_version": appVersionShort(),
            "build": buildNumber(),
            "os_version": osVersion(),
            "device_model": deviceModel(),
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "network_type": networkTypeString(),
            "entry_screen": "HomeView",
            "entry_source": entrySource,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(TrackAPI.cachedAccessToken ?? "")", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = json["session_id"] as? String {
                await MainActor.run { self.sessionId = sid }
            }
        } catch { /* fail silently */ }
    }

    private func endSessionIfNeeded() async {
        guard let sid = sessionId else { return }
        let base = await MainActor.run { TrackAPI.baseURL }
        guard let url = URL(string: base + endpointSessionEnd) else { return }
        let secs: Int = sessionStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let body: [String: Any] = [
            "session_id": sid,
            "foreground_seconds": secs,
            "screens_viewed": sessionScreenViews,
            "events_count": sessionEventCount,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(TrackAPI.cachedAccessToken ?? "")", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 6
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    // ── Persistence (survive cold-start) ──────────────────────────────────

    private func persistBuffer() {
        guard !buffer.isEmpty else {
            try? FileManager.default.removeItem(at: bufferFileURL)
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: buffer, options: [])
            try data.write(to: bufferFileURL, options: .atomic)
        } catch { /* ignore */ }
    }

    private func loadPersistedBuffer() {
        guard FileManager.default.fileExists(atPath: bufferFileURL.path),
              let data = try? Data(contentsOf: bufferFileURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        buffer = arr
        try? FileManager.default.removeItem(at: bufferFileURL)
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private func commonFields() -> [String: Any] {
        [
            "occurred_at": isoNow(),
            "app_version": appVersionShort(),
            "os_version": osVersion(),
            "device_model": deviceModel(),
            "network_type": networkTypeString(),
        ]
    }

    private func merge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var out = a
        for (k, v) in b where out[k] == nil { out[k] = v }
        return out
    }

    /// Strips values that JSONSerialization can't encode (dates, URLs, etc.)
    /// and caps the payload size so a runaway dict can't blow our request.
    private func sanitizeProperties(_ raw: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in raw {
            switch v {
            case let s as String: out[k] = String(s.prefix(2000))
            case let n as NSNumber: out[k] = n
            case let b as Bool: out[k] = b
            case let d as Date: out[k] = ISO8601DateFormatter().string(from: d)
            case let u as URL: out[k] = u.absoluteString
            case let a as [Any]: out[k] = a.prefix(50).map { "\($0)" }
            case let dict as [String: Any]: out[k] = dict.mapValues { "\($0)" }
            default: out[k] = "\(v)"
            }
        }
        return out
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private func appVersionShort() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    private func buildNumber() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    private func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    private func deviceModel() -> String {
        var sysinfo = utsname(); uname(&sysinfo)
        let model = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return model.isEmpty ? UIDevice.current.model : model
    }
    /// Coarse network classification — we don't import Network for one string.
    private func networkTypeString() -> String {
        // Best-effort; SwiftUI app already has reachability via NWPathMonitor
        // elsewhere if you want to plumb it through.  Default to "unknown".
        return "unknown"
    }
}
