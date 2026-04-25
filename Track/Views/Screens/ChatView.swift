// AI Transit Assistant chat UI.
//
// UI-only implementation. Mock data + visual surface only — drop in a
// real backend by swapping `ChatViewModel.messages` for a published
// stream and wiring `send()` to your network layer.
//
// Markdown: assistant text bubbles render full GitHub-flavored markdown
// (bold, italics, lists, inline code, links) via `MarkdownText`.

import AVFoundation
import CoreLocation
import PhotosUI
import SwiftUI

// MARK: - Models

nonisolated enum ChatRole: Equatable, Sendable {
    case user
    case assistant
}

enum ChatMessageContent {
    case text(String)
    case voice(durationSeconds: Int)
    case file(name: String, sizeLabel: String, kind: FileKind)

    enum FileKind {
        case pdf
        case image
        case other

        var iconName: String {
            switch self {
            case .pdf: return "doc.richtext.fill"
            case .image: return "photo.fill"
            case .other: return "doc.fill"
            }
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: ChatRole
    var content: ChatMessageContent
    var showActions: Bool = true
    var timestamp: Date = .now
    /// Optional status line shown above streaming assistant bubbles
    /// (e.g. "Checking alerts…"). Cleared once the reply text arrives.
    var toolStatus: String? = nil
    /// Optional structured route payload — when set, an itinerary card
    /// is rendered beneath the markdown bubble.
    var routePayload: RoutePlanPayload? = nil
    /// Optional structured station-search payload — renders a compact
    /// list of matching stops beneath the bubble.
    var stationsPayload: StationSearchPayload? = nil
    /// Optional live-arrivals payload (Batch 6 — M) — renders a colored
    /// route badge with upcoming arrivals.
    var liveArrivalsPayload: LiveArrivalsPayload? = nil
    /// Optional stop-info payload — renders accessibility + departures card.
    var stopInfoPayload: StopInfoPayload? = nil
    /// Optional equipment-outages payload — renders broken elevator/escalator list.
    var equipmentOutagesPayload: EquipmentOutagesPayload? = nil
    /// Optional service-alerts payload — renders alert summary card.
    var serviceAlertsPayload: ServiceAlertsPayload? = nil
    /// Optional follow-up suggestion chips from the backend (Batch 2 — D).
    var suggestedChips: [SuggestedActionChip]? = nil
    /// Optional image attached by the user (data URL). Renders a small
    /// thumbnail under user bubbles.
    var imageDataURL: String? = nil
    /// The user prompt that produced this assistant reply — used for
    /// regenerate + feedback context.
    var promptedBy: String? = nil
    /// Model id reported by the backend on `.done` (e.g. `gpt-4o-mini`).
    var modelUsed: String? = nil
    /// Local user feedback state: `1` = thumbs up, `-1` = thumbs down,
    /// `nil` = not rated.
    var rating: Int? = nil

    static let mockConversation: [ChatMessage] = [
        .init(role: .assistant, content: .text(
            "Hey, I'm **MetroMind** \u{1F9E0}\u{1F687} — your NYC transit brain. Ask me about routes, delays, or the smartest way to get anywhere."
        )),
    ]
}

// MARK: - View Model

@Observable
@MainActor
final class ChatViewModel {
    var messages: [ChatMessage] = ChatMessage.mockConversation
    var draft: String = ""
    var isRecording: Bool = false
    var isAssistantTyping: Bool = false

    /// Active streaming task — cancelled if the user sends another
    /// message before the previous one completes.
    private var streamTask: Task<Void, Never>?

    let suggestedPrompts: [String] = [
        "Next train at Union Sq",
        "Fastest to JFK",
    ]

    /// Strip the GTFS agency prefix off a route id ("MTA NYCT_L" → "L")
    /// so chip text reads naturally to riders.
    static func shortRouteLabel(_ id: String) -> String {
        for prefix in ["MTA NYCT_", "MTA BUS_", "MTABC_"] {
            if id.uppercased().hasPrefix(prefix) {
                return String(id.dropFirst(prefix.count))
            }
        }
        return id
    }

    /// Optional device coordinate forwarded to MetroMind so it can
    /// resolve "current location" planning queries.
    var currentLocation: CLLocationCoordinate2D?

    /// Effective bias point used for "near me" queries. Set by ChatView
    /// from either the device GPS or a drag-search pin lifted from the
    /// Home tab. Forwarded to MetroMind on every turn.
    var biasLat: Double?
    var biasLon: Double?
    /// `"gps"` or `"map_pin"`.
    var biasSource: String?
    var biasLabel: String?

    /// User's first name ("Jeff") for friendly addressing.
    var userName: String?

    /// User's saved places (Home, Work, custom) loaded from the
    /// Plan tab's cache. Forwarded to MetroMind every turn so it can
    /// answer "how do I get home" without asking.
    var savedPlaces: [MetroMindAPI.SavedPlaceContext] = []

    /// User's recent trips (newest first). Lets MetroMind suggest
    /// follow-ups like "replan your last trip".
    var recentTrips: [MetroMindAPI.RecentTripContext] = []

    /// Server-side thread id (Batch 2 — J). Persisted in UserDefaults
    /// so the conversation survives app restarts.
    var threadId: String? = UserDefaults.standard.string(forKey: "metromind.thread_id")

    /// Image the user is about to attach to their next message (Batch 2 — L).
    /// Stored as a data URL so it can drop straight into the request body.
    var pendingImageDataURL: String? = nil

    // MARK: Voice (Batch 4 — G)

    /// On-device speech recognizer used by the mic button. Starts/stops
    /// when ``toggleRecording()`` is called.
    private let speechManager = SpeechRecognitionManager()

    /// Whether assistant replies should be spoken aloud after streaming
    /// completes. Persisted in UserDefaults.
    var speakReplies: Bool = UserDefaults.standard.bool(forKey: "metromind.speak_replies") {
        didSet { UserDefaults.standard.set(speakReplies, forKey: "metromind.speak_replies") }
    }

    /// Shared TTS synthesizer.
    private let tts = AVSpeechSynthesizer()

    /// Last message id we've spoken — prevents re-speaking on view re-renders.
    private var spokenMessageIds: Set<UUID> = []

    init() {
        // Wire the recognizer's transcription back into the composer draft.
        speechManager.onTranscription = { [weak self] text in
            guard let self else { return }
            self.draft = text
        }
    }

    func send(_ overrideText: String? = nil) {
        let raw = overrideText ?? draft
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Snapshot + clear the pending image so the next message doesn't
        // re-send it.
        let attachedImage = pendingImageDataURL
        pendingImageDataURL = nil

        // Record the user turn + clear the input.
        var userMsg = ChatMessage(role: .user, content: .text(trimmed), showActions: false)
        userMsg.imageDataURL = attachedImage
        messages.append(userMsg)
        draft = ""
        isAssistantTyping = true

        Analytics.shared.event("chat_message_sent",
                               properties: [
                                "char_count": trimmed.count,
                                "has_image": attachedImage != nil,
                                "history_turns": messages.count - 1,
                               ],
                               screen: "ChatView")

        // Snapshot history (excluding the just-added user turn — the
        // backend appends `message` itself).
        let history: [(role: String, content: String)] = messages
            .dropLast()
            .compactMap { msg in
                guard case .text(let body) = msg.content else { return nil }
                let role = msg.role == .user ? "user" : "assistant"
                return (role, body)
            }

        // Append a placeholder assistant bubble we'll mutate as tokens
        // stream in.
        var placeholder = ChatMessage(
            role: .assistant,
            content: .text(""),
            showActions: false
        )
        placeholder.promptedBy = trimmed
        messages.append(placeholder)
        let assistantId = placeholder.id

        // Snapshot the user's most-interacted routes from local analytics
        // so the backend can personalise default chips ("Any 7 delays?"
        // instead of always defaulting to L). RouteAnalyticsManager
        // returns full GTFS ids ("MTA NYCT_L") — the backend strips the
        // agency prefix before rendering, so we forward as-is.
        let topRoutes: [String] = RouteAnalyticsManager.shared
            .getTopRoutes(limit: 5)
            .map { $0.routeId }

        // Cancel any in-flight stream before starting a new one.
        streamTask?.cancel()
        streamTask = Task { [weak self,
                             location = currentLocation,
                             biasLat = biasLat,
                             biasLon = biasLon,
                             biasSource = biasSource,
                             biasLabel = biasLabel,
                             userName = userName,
                             savedPlaces = savedPlaces,
                             recentTrips = recentTrips,
                             topRoutes = topRoutes,
                             threadId = threadId,
                             imageDataURL = attachedImage] in
            guard let self else { return }
            var receivedAnyToken = false
            do {
                let stream = MetroMindAPI.chatStream(
                    message: trimmed,
                    history: history,
                    location: location,
                    biasLat: biasLat,
                    biasLon: biasLon,
                    biasSource: biasSource,
                    biasLabel: biasLabel,
                    userName: userName,
                    savedPlaces: savedPlaces,
                    recentTrips: recentTrips,
                    topRoutes: topRoutes,
                    threadId: threadId,
                    imageDataURL: imageDataURL
                )
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .token(let chunk):
                        if !chunk.isEmpty {
                            receivedAnyToken = true
                            self.appendToken(chunk, to: assistantId)
                        }
                    case .toolCall(_, let label):
                        self.setToolStatus(label, on: assistantId)
                    case .toolResult(let name, let ok, let payload):
                        if ok, let payload = payload {
                            switch payload {
                            case .route(let p):
                                self.setRoutePayload(p, on: assistantId)
                            case .stations(let p):
                                self.setStationsPayload(p, on: assistantId)
                            case .liveArrivals(let p):
                                self.setLiveArrivalsPayload(p, on: assistantId)
                            case .stopInfo(let p):
                                self.setStopInfoPayload(p, on: assistantId)
                            case .equipmentOutages(let p):
                                self.setEquipmentOutagesPayload(p, on: assistantId)
                            case .serviceAlerts(let p):
                                self.setServiceAlertsPayload(p, on: assistantId)
                            }
                        }
                        _ = name
                    case .suggestions(let chips):
                        self.setChips(chips, on: assistantId)
                    case .done(_, let model, let tid):
                        self.setToolStatus(nil, on: assistantId)
                        if let m = model, !m.isEmpty {
                            self.setModelUsed(m, on: assistantId)
                        }
                        if let tid = tid, !tid.isEmpty {
                            self.persistThreadId(tid)
                        }
                        self.markActionable(assistantId)
                        self.speakIfNeeded(messageId: assistantId)
                    case .error(let msg):
                        self.replaceText(
                            "_⚠️ \(msg)_",
                            on: assistantId
                        )
                    }
                }
                if !receivedAnyToken {
                    self.replaceText(
                        "_(No reply received.)_",
                        on: assistantId
                    )
                }
            } catch {
                self.replaceText(
                    "_⚠️ Couldn't reach MetroMind: \(error.localizedDescription)_",
                    on: assistantId
                )
            }
            self.isAssistantTyping = false
            self.setToolStatus(nil, on: assistantId)
        }
    }

    // MARK: - Streaming mutators

    private func appendToken(_ token: String, to id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        if case .text(let current) = messages[idx].content {
            messages[idx].content = .text(current + token)
        }
    }

    private func replaceText(_ text: String, on id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content = .text(text)
    }

    private func setToolStatus(_ status: String?, on id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].toolStatus = status
    }

    private func setRoutePayload(_ payload: RoutePlanPayload, on id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].routePayload = payload
    }

    private func setStationsPayload(_ payload: StationSearchPayload, on id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].stationsPayload = payload
    }

    private func setLiveArrivalsPayload(_ payload: LiveArrivalsPayload, on id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].liveArrivalsPayload = payload
    }

    private func setStopInfoPayload(_ payload: StopInfoPayload, on id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].stopInfoPayload = payload
    }

    private func setEquipmentOutagesPayload(_ payload: EquipmentOutagesPayload, on id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].equipmentOutagesPayload = payload
    }

    private func setServiceAlertsPayload(_ payload: ServiceAlertsPayload, on id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].serviceAlertsPayload = payload
    }

    private func setChips(_ chips: [SuggestedActionChip], on id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].suggestedChips = chips
    }

    private func setModelUsed(_ model: String, on id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].modelUsed = model
    }

    /// Reveal the action row (thumbs / share / copy / regenerate / speaker)
    /// once the reply is fully streamed in.
    private func markActionable(_ id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        if case .text(let body) = messages[idx].content,
           !body.isEmpty, !body.hasPrefix("_\u{26A0}\u{FE0F}") {
            messages[idx].showActions = true
        }
    }

    private func persistThreadId(_ tid: String) {
        threadId = tid
        UserDefaults.standard.set(tid, forKey: "metromind.thread_id")
    }

    /// Called when the user taps a suggestion chip. Behaviour depends
    /// on `chip.kind`:
    ///
    /// * `save_trip` → persist origin/destination as a saved-trip template
    ///   via the same `/engine/trips/saved` endpoint the Plan tab uses,
    ///   then drop a confirmation bubble in the conversation.
    /// * `open_alerts` → switch to the Home tab (where alerts surface)
    ///   in addition to re-prompting so the LLM context is updated.
    /// * Everything else → just resend the chip's prompt text as a new
    ///   user turn (lets the LLM handle alternatives, place lookups, etc.).
    func tapChip(_ chip: SuggestedActionChip) {
        switch chip.kind {
        case "save_trip":
            persistSavedTrip(
                origin: chip.originLabel,
                destination: chip.destinationLabel,
                summary: chip.tripSummary
            )
        case "open_alerts":
            NotificationCenter.default.post(name: .switchToTab, object: AppTab.home)
            if let text = chip.promptText, !text.isEmpty { send(text) }
        case "open_plan":
            // Empty-itinerary recovery chip — switch the user to the
            // Trips tab so they can edit origin/destination directly.
            NotificationCenter.default.post(name: .switchToTab, object: AppTab.trips)
            appendInlineNotice("Opened the Trips tab — tweak the trip there.")
        case "start_tracking":
            // If the chip carried concrete arrival data (came from a
            // get_live_arrivals call), launch a Live Activity directly
            // so the user immediately gets a trackable widget on their
            // Lock Screen / Dynamic Island. Without arrival data the
            // best we can do is re-prompt the LLM.
            if let route = chip.routeId,
               let minutes = chip.arrivalMinutesAway,
               let ts = chip.arrivalTimestamp, ts > 0
            {
                let arrival = Date(timeIntervalSince1970: ts)
                let dest = chip.arrivalDestination ?? "—"
                let upcoming = chip.upcomingMinutes ?? []
                let stationId = chip.arrivalStationName ?? ""
                Task {
                    await LiveActivityManager.shared.startActivity(
                        lineId: route,
                        destination: dest,
                        arrivalTime: arrival,
                        isBus: false,
                        stationId: stationId,
                        minutesAway: minutes,
                        nextArrivals: upcoming
                    )
                }
                appendInlineNotice("Tracking the \(route) — check your Lock Screen.")
            } else if let text = chip.promptText, !text.isEmpty {
                send(text)
            }
        case "send_prompt", "generate_alternatives", "open_place":
            if let text = chip.promptText, !text.isEmpty {
                send(text)
            }
        default:
            if let text = chip.promptText, !text.isEmpty {
                send(text)
            }
        }
    }

    /// Persist a chat-suggested trip template. Mirrors `PlanViewModel.saveTripTemplate`
    /// but works with just origin/destination labels (no resolved coordinates yet —
    /// the engine will geocode on next plan).
    private func persistSavedTrip(origin: String?, destination: String?, summary: String?) {
        guard let userID = SupabaseManager.shared.currentUser?.id.uuidString.lowercased(),
              let originLabel = origin,
              let destinationLabel = destination else {
            appendInlineNotice("⚠️ Couldn't save — missing trip details.")
            return
        }
        let name = (summary?.isEmpty == false) ? summary! : "\(originLabel) → \(destinationLabel)"

        let request = EngineSavedTripUpsertRequest(
            userID: userID,
            name: name,
            origin: EngineLocationPayloadRequest(
                label: originLabel, lat: nil, lon: nil, stopID: nil, address: nil
            ),
            destination: EngineLocationPayloadRequest(
                label: destinationLabel, lat: nil, lon: nil, stopID: nil, address: nil
            ),
            preferredDepartureHour: nil,
            preferredArrivalHour: nil,
            preferredModes: ["subway", "bus", "walk"],
            tripID: nil
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await TrackAPI.upsertEngineSavedTrip(request: request)
                self.appendInlineNotice("✅ Saved **\(name)** to your trips.")
                Analytics.shared.event(
                    "chat_trip_saved",
                    properties: ["origin": originLabel, "destination": destinationLabel],
                    screen: "ChatView"
                )
            } catch {
                self.appendInlineNotice(
                    "⚠️ Couldn't save trip: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Insert a non-actionable assistant bubble into the transcript.
    /// Used for inline confirmations (e.g. "Saved trip ✓").
    private func appendInlineNotice(_ markdown: String) {
        var msg = ChatMessage(
            role: .assistant,
            content: .text(markdown),
            showActions: false
        )
        msg.modelUsed = nil
        messages.append(msg)
    }

    /// Save the route attached to a specific assistant message — invoked
    /// from the itinerary detail sheet's "Save this trip" button.
    func saveItinerary(forMessageId id: UUID) {
        guard let msg = messages.first(where: { $0.id == id }),
              let payload = msg.routePayload else {
            appendInlineNotice("⚠️ Couldn't save — trip details unavailable.")
            return
        }
        persistSavedTrip(
            origin: payload.origin,
            destination: payload.destination,
            summary: payload.itineraries.first?.summary
        )
    }

    /// Re-prompt MetroMind with a "plan from this station" query when
    /// the user taps a row in a `StationListCard`.
    func planFromStation(_ stop: StationSearchPayload.Stop) {
        guard let name = stop.stop_name, !name.isEmpty else { return }
        send("How do I get home from \(name)?")
    }

    /// Attach an image picked from the photo library to the next message.
    func attachImage(_ data: Data, mime: String = "image/jpeg") {
        let b64 = data.base64EncodedString()
        pendingImageDataURL = "data:\(mime);base64,\(b64)"
    }

    // MARK: Voice (Batch 4 — G)

    /// Mic-button action — toggle on-device speech recognition.
    /// While active, partial transcriptions stream into ``draft``.
    func toggleRecording() {
        speechManager.toggle()
        isRecording = speechManager.isRecording
    }

    /// Toggle whether assistant replies should be spoken aloud.
    func toggleSpeakReplies() {
        speakReplies.toggle()
        if !speakReplies {
            tts.stopSpeaking(at: .immediate)
        }
    }

    /// Speak the final reply for the assistant message, once.
    private func speakIfNeeded(messageId: UUID) {
        guard speakReplies, !spokenMessageIds.contains(messageId) else { return }
        guard let msg = messages.first(where: { $0.id == messageId }),
              case .text(let body) = msg.content,
              !body.isEmpty,
              !body.hasPrefix("_⚠️") else { return }
        spokenMessageIds.insert(messageId)
        let utterance = AVSpeechUtterance(string: stripMarkdown(body))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        // Make sure playback isn't blocked by the recording session.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        tts.speak(utterance)
    }

    /// Strip basic markdown tokens before passing to TTS.
    private func stripMarkdown(_ s: String) -> String {
        var out = s
        for token in ["**", "*", "_", "`", "#"] {
            out = out.replacingOccurrences(of: token, with: "")
        }
        return out
    }

    /// Currently-speaking message id (if any), so the per-message
    /// speaker button can render a "stop" state.
    var speakingMessageId: UUID?

    /// Speak (or stop speaking) a specific assistant message on demand.
    /// Independent of the global ``speakReplies`` toggle so the user
    /// can hear any single reply by tapping its speaker icon.
    func speakMessage(id: UUID) {
        if speakingMessageId == id {
            tts.stopSpeaking(at: .immediate)
            speakingMessageId = nil
            return
        }
        guard let msg = messages.first(where: { $0.id == id }),
              case .text(let body) = msg.content,
              !body.isEmpty else { return }
        tts.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: stripMarkdown(body))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        speakingMessageId = id
        tts.speak(utterance)
        // Auto-clear the highlight when playback finishes — poll briefly
        // since AVSpeechSynthesizer's delegate plumbing isn't worth the
        // weight for a single boolean.
        Task { @MainActor [weak self] in
            while let self, self.tts.isSpeaking, self.speakingMessageId == id {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if self?.speakingMessageId == id {
                self?.speakingMessageId = nil
            }
        }
    }

    /// Re-run the prompt that produced this assistant reply. Removes
    /// the existing reply (and any payload cards) so the new stream
    /// starts from a clean slate.
    func regenerate(messageId: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let prompt = messages[idx].promptedBy ?? {
            // Fallback: nearest user turn before this assistant message.
            for j in stride(from: idx - 1, through: 0, by: -1) where messages[j].role == .user {
                if case .text(let t) = messages[j].content { return t }
            }
            return nil
        }()
        guard let prompt, !prompt.isEmpty else { return }

        // Drop the assistant turn AND the user turn that produced it
        // (send() will re-append the user turn).
        var removalIdx = idx
        if idx > 0, messages[idx - 1].role == .user {
            removalIdx = idx - 1
        }
        messages.removeSubrange(removalIdx..<messages.count)
        send(prompt)
    }

    /// Submit a thumbs rating to the backend and reflect it locally.
    func setRating(_ rating: Int, on messageId: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        // Toggle off when re-tapping the same rating.
        let newRating: Int? = (messages[idx].rating == rating) ? nil : rating
        messages[idx].rating = newRating
        guard let r = newRating else { return }

        let assistantText: String? = {
            if case .text(let body) = messages[idx].content { return body }
            return nil
        }()
        let prompt = messages[idx].promptedBy
        let model = messages[idx].modelUsed
        let tid = threadId
        let mid = messages[idx].id.uuidString

        Task.detached(priority: .utility) {
            _ = await MetroMindAPI.submitFeedback(
                rating: r,
                threadId: tid,
                clientMessageId: mid,
                userPrompt: prompt,
                assistantText: assistantText,
                modelUsed: model
            )
        }
    }

    /// Rich plain-text payload for share sheets / clipboard.
    /// Includes (when available): the user's original prompt, the
    /// markdown-stripped reply, a one-line itinerary summary, live
    /// arrivals, station hits, and a MetroMind branding footer.
    func shareText(for messageId: UUID) -> String {
        guard let msg = messages.first(where: { $0.id == messageId }) else { return "" }

        var sections: [String] = []

        if let prompt = msg.promptedBy?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            sections.append("Q: \(prompt)")
        }

        if case .text(let body) = msg.content {
            let stripped = stripMarkdown(body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                sections.append("A: \(stripped)")
            }
        }

        if let route = msg.routePayload, let summary = renderRouteForShare(route) {
            sections.append(summary)
        }

        if let arrivals = msg.liveArrivalsPayload, let summary = renderArrivalsForShare(arrivals) {
            sections.append(summary)
        }

        if let stations = msg.stationsPayload, let summary = renderStationsForShare(stations) {
            sections.append(summary)
        }

        if let alerts = msg.serviceAlertsPayload, let summary = renderAlertsForShare(alerts) {
            sections.append(summary)
        }

        sections.append("— Sent from MetroMind 🚇")

        return sections.joined(separator: "\n\n")
    }

    private func renderRouteForShare(_ route: RoutePlanPayload) -> String? {
        guard let first = route.itineraries.first else { return nil }
        var lines: [String] = ["🗺️ Trip"]
        if let origin = route.origin, let destination = route.destination {
            lines.append("\(origin) → \(destination)")
        }
        var stats: [String] = []
        if let total = first.total_minutes { stats.append("\(Int(total.rounded())) min") }
        if let xfer = first.transfer_count {
            stats.append("\(xfer) transfer\(xfer == 1 ? "" : "s")")
        }
        if let walk = first.walk_minutes, walk > 0 {
            stats.append("\(Int(walk.rounded())) min walk")
        }
        if !stats.isEmpty { lines.append(stats.joined(separator: " · ")) }
        if let dep = first.departure_time, let arr = first.arrival_time {
            lines.append("Depart \(formatShareTime(dep)) → Arrive \(formatShareTime(arr))")
        }
        if let legs = first.legs, !legs.isEmpty {
            let badges = legs.compactMap { leg -> String? in
                if let label = leg.route_label, !label.isEmpty { return label }
                if let id = leg.route_id, !id.isEmpty { return id }
                if (leg.mode ?? "").lowercased().contains("walk") { return "🚶" }
                return nil
            }
            if !badges.isEmpty {
                lines.append("Route: " + badges.joined(separator: " → "))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func renderArrivalsForShare(_ payload: LiveArrivalsPayload) -> String? {
        guard !payload.arrivals.isEmpty else { return nil }
        let dir = (payload.direction_filter ?? "both").lowercased()
        let header: String
        switch dir {
        case "north": header = "🚇 Northbound \(payload.route_id) — next trains"
        case "south": header = "🚇 Southbound \(payload.route_id) — next trains"
        default:      header = "🚇 \(payload.route_id) — next trains"
        }
        let rows = payload.arrivals.prefix(4).compactMap { arr -> String? in
            let stop = arr.station_name ?? "—"
            let eta: String
            if let m = arr.minutes_away {
                eta = m <= 0 ? "Now" : "\(m) min"
            } else {
                eta = arr.status ?? "—"
            }
            let dest = arr.destination.map { " → \($0)" } ?? ""
            return "• \(stop): \(eta)\(dest)"
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private func renderStationsForShare(_ payload: StationSearchPayload) -> String? {
        let names = payload.stops.prefix(5).compactMap { $0.stop_name }
        guard !names.isEmpty else { return nil }
        return "📍 Stations\n" + names.map { "• \($0)" }.joined(separator: "\n")
    }

    private func renderAlertsForShare(_ payload: ServiceAlertsPayload) -> String? {
        guard !payload.alerts.isEmpty else { return nil }
        let rows = payload.alerts.prefix(3).compactMap { alert -> String? in
            let title = alert.title ?? alert.effect ?? "Alert"
            let routes = alert.affected_routes?.prefix(4).joined(separator: ", ")
            if let routes, !routes.isEmpty {
                return "• [\(routes)] \(title)"
            }
            return "• \(title)"
        }
        return ("⚠️ Service alerts\n" + rows.joined(separator: "\n"))
    }

    private func formatShareTime(_ iso: String) -> String {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = isoFmt.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date = date else { return iso }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// Wipe the conversation back to the opening greeting.
    func resetConversation() {
        streamTask?.cancel()
        messages = ChatMessage.mockConversation.prefix(1).map { $0 }
        draft = ""
        isAssistantTyping = false
    }
}

// MARK: - ChatView

struct ChatView: View {
    var locationManager: LocationManager? = nil
    /// Optional drop-pin location lifted from the Home tab's drag-search.
    /// When non-nil, MetroMind biases "near me" answers to this pin instead
    /// of device GPS.
    @Binding var biasPin: CLLocationCoordinate2D?

    init(locationManager: LocationManager? = nil, biasPin: Binding<CLLocationCoordinate2D?> = .constant(nil)) {
        self.locationManager = locationManager
        self._biasPin = biasPin
    }

    @State private var viewModel = ChatViewModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            AppTheme.Gradients.screen.ignoresSafeArea()

            // Subtle ambient blobs for depth.
            ambientBackground
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                ChatHeader(
                    placesCount: viewModel.savedPlaces.count,
                    recentTripsCount: viewModel.recentTrips.count,
                    biasSource: viewModel.biasSource,
                    biasLabel: viewModel.biasLabel,
                    onClear: { withAnimation(.easeInOut(duration: 0.25)) { viewModel.resetConversation() } }
                )

                messagesList

                if viewModel.messages.count <= 1 {
                    SuggestionChipsRow(
                        prompts: dynamicSuggestions,
                        onTap: { prompt in viewModel.send(prompt) }
                    )
                }

                ChatComposer(
                    text: $viewModel.draft,
                    isRecording: $viewModel.isRecording,
                    isFocused: $inputFocused,
                    pendingImageDataURL: viewModel.pendingImageDataURL,
                    speakReplies: viewModel.speakReplies,
                    onSend: { viewModel.send() },
                    onAttachImage: { data in viewModel.attachImage(data) },
                    onClearImage: { viewModel.pendingImageDataURL = nil },
                    onToggleMic: { viewModel.toggleRecording() },
                    onToggleSpeak: { viewModel.toggleSpeakReplies() }
                )
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            Analytics.shared.screenView("ChatView", reachedVia: "tab")
            // Make sure we always have the freshest possible fix when the
            // user opens the chat tab — chat answers "near me" questions
            // and a stale GPS would route them to the wrong neighborhood.
            locationManager?.requestImmediateFix()
            syncLocation()
            syncUserData()
            syncBias()
        }
        .onChange(of: locationManager?.currentLocation) { _, _ in syncLocation() }
        .onChange(of: biasPin?.latitude) { _, _ in syncBias() }
    }

    private func syncLocation() {
        // Prefer the live CoreLocation fix; fall back to the App Group
        // cached coordinate so the chat is never "location-blind" right
        // after launch (before the first GPS fix lands).
        if let coord = locationManager?.currentLocation?.coordinate {
            viewModel.currentLocation = coord
        } else {
            let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
            if defaults.bool(forKey: "hasLastLocation") {
                let lat = defaults.double(forKey: "lastLatitude")
                let lon = defaults.double(forKey: "lastLongitude")
                if lat != 0 || lon != 0 {
                    viewModel.currentLocation = CLLocationCoordinate2D(
                        latitude: lat, longitude: lon
                    )
                }
            }
        }
        syncBias()
    }

    private func syncBias() {
        if let pin = biasPin {
            viewModel.biasLat = pin.latitude
            viewModel.biasLon = pin.longitude
            viewModel.biasSource = "map_pin"
            viewModel.biasLabel = "dropped pin"
        } else if let coord = viewModel.currentLocation {
            viewModel.biasLat = coord.latitude
            viewModel.biasLon = coord.longitude
            viewModel.biasSource = "gps"
            viewModel.biasLabel = "current location"
        } else {
            viewModel.biasLat = nil
            viewModel.biasLon = nil
            viewModel.biasSource = nil
            viewModel.biasLabel = nil
        }
    }

    /// Pull the user's profile + saved places + recent trips from the
    /// app caches and push them into the view-model so every chat turn
    /// carries them along.
    private func syncUserData() {
        let user = SupabaseManager.shared.currentUser
        viewModel.userName = user?.givenName
            ?? user?.fullName?.split(separator: " ").first.map(String.init)

        guard let uid = user?.id.uuidString.lowercased() else {
            viewModel.savedPlaces = []
            viewModel.recentTrips = []
            return
        }
        let snap = PlannerDataCache.shared.snapshot(for: uid)
        viewModel.savedPlaces = snap.savedPlaces.map { p in
            MetroMindAPI.SavedPlaceContext(
                label: p.label,
                kind: p.kind,
                lat: p.lat,
                lon: p.lon,
                address: p.address
            )
        }
        viewModel.recentTrips = snap.recentTrips.prefix(8).map { t in
            MetroMindAPI.RecentTripContext(
                originLabel: t.originLabel,
                destinationLabel: t.destinationLabel,
                summary: t.summary,
                requestedAt: t.requestedAt
            )
        }
    }

    /// Surface user-specific shortcuts in the empty-state suggestion strip.
    /// Falls back to generic prompts when the user has no saved places yet.
    private var dynamicSuggestions: [String] {
        var out: [String] = []
        if viewModel.savedPlaces.contains(where: { $0.kind == "home" }) {
            out.append("How do I get home?")
        }
        if viewModel.savedPlaces.contains(where: { $0.kind == "work" }) {
            out.append("How long to work?")
        }
        if let last = viewModel.recentTrips.first {
            out.append("Replan: \(last.destinationLabel)")
        }
        // Surface the user's most-tracked line as a quick "delays?" chip.
        // This replaces the old hardcoded "Any L delays?" with whichever
        // route the user actually rides most.
        if let topRoute = RouteAnalyticsManager.shared
            .getTopRoutes(limit: 1)
            .first?.routeId
        {
            let short = ChatViewModel.shortRouteLabel(topRoute)
            out.append("Any \(short) delays?")
        } else {
            out.append("Any delays nearby?")
        }
        out.append(contentsOf: viewModel.suggestedPrompts)
        return Array(out.prefix(6))
    }

    // MARK: - Ambient Background

    private var ambientBackground: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Colors.accent.opacity(0.18))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: -140, y: -260)

            Circle()
                .fill(AppTheme.Colors.accentSecondary.opacity(0.14))
                .frame(width: 280, height: 280)
                .blur(radius: 90)
                .offset(x: 160, y: 240)
        }
    }

    // MARK: - Messages List

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                        if !isEmptyAssistantPlaceholder(message) {
                            ChatMessageRow(
                                message: message,
                                isFirstInGroup: isFirstInGroup(at: index),
                                isLastInGroup: isLastInGroup(at: index),
                                isSpeaking: viewModel.speakingMessageId == message.id,
                                onChipTap: { chip in viewModel.tapChip(chip) },
                                onLike: { viewModel.setRating(1, on: message.id) },
                                onDislike: { viewModel.setRating(-1, on: message.id) },
                                onSpeak: { viewModel.speakMessage(id: message.id) },
                                onRegenerate: { viewModel.regenerate(messageId: message.id) },
                                onCopy: {
                                    UIPasteboard.general.string = viewModel.shareText(for: message.id)
                                },
                                onSaveItinerary: {
                                    viewModel.saveItinerary(forMessageId: message.id)
                                },
                                onTapStation: { stop in
                                    viewModel.planFromStation(stop)
                                },
                                shareText: viewModel.shareText(for: message.id)
                            )
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.96, anchor: message.role == .user ? .bottomTrailing : .bottomLeading)
                                    .combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                    }

                    if viewModel.isAssistantTyping {
                        TypingIndicatorRow()
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .id("typing-indicator")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.isAssistantTyping) { _, typing in
                if typing { withAnimation { proxy.scrollTo("typing-indicator", anchor: .bottom) } }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = viewModel.messages.last else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func isEmptyAssistantPlaceholder(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        guard case .text(let body) = message.content else { return false }
        guard body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Treat as a placeholder only when there's no payload to render either.
        return message.routePayload == nil
            && message.stationsPayload == nil
            && message.liveArrivalsPayload == nil
            && message.stopInfoPayload == nil
            && message.equipmentOutagesPayload == nil
            && message.serviceAlertsPayload == nil
            && (message.suggestedChips?.isEmpty ?? true)
            && (message.toolStatus?.isEmpty ?? true)
    }

    private func isFirstInGroup(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return viewModel.messages[index - 1].role != viewModel.messages[index].role
    }

    private func isLastInGroup(at index: Int) -> Bool {
        let next = index + 1
        guard next < viewModel.messages.count else { return true }
        return viewModel.messages[next].role != viewModel.messages[index].role
    }
}

// MARK: - Header

private struct ChatHeader: View {
    let placesCount: Int
    let recentTripsCount: Int
    let biasSource: String?
    let biasLabel: String?
    let onClear: () -> Void

    @State private var avatarPulse: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                AIAvatar(size: 30)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("MetroMind")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(AppTheme.Gradients.accentVibrant)
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppTheme.Gradients.accentVibrant)
                    }
                    statusLine
                }

                Spacer(minLength: 4)

                CircleIconButton(systemName: "square.and.pencil", action: onClear)
            }
            biasChip
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        // Transparent — blend with `AppTheme.Gradients.screen` from
        // ChatView. Removed the ultraThinMaterial + double gradient
        // so the header reads as one continuous surface with the
        // messages list and composer.
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [
                    AppTheme.Colors.borderSubtle.opacity(0.55),
                    AppTheme.Colors.borderSubtle.opacity(0.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.6)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if placesCount > 0 || recentTripsCount > 0 {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(personalisedStatus)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        } else {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Online · Ask me anything transit")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var biasChip: some View {
        if let source = biasSource {
            let isPin = source == "map_pin"
            HStack(spacing: 6) {
                Image(systemName: isPin ? "mappin.circle.fill" : "location.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isPin ? .orange : AppTheme.Colors.accent)
                Text("Bias to: \(biasLabel ?? (isPin ? "dropped pin" : "current location"))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill((isPin ? Color.orange : AppTheme.Colors.accent).opacity(0.12))
            )
            .overlay(
                Capsule().stroke(
                    (isPin ? Color.orange : AppTheme.Colors.accent).opacity(0.35),
                    lineWidth: 0.6
                )
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var personalisedStatus: String {
        var bits: [String] = []
        if placesCount > 0 { bits.append("\(placesCount) place\(placesCount == 1 ? "" : "s")") }
        if recentTripsCount > 0 { bits.append("\(recentTripsCount) recent trip\(recentTripsCount == 1 ? "" : "s")") }
        return "Online · knows " + bits.joined(separator: ", ")
    }
}

private struct AIAvatar: View {
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Gradients.accentVibrant)
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: AppTheme.Colors.accent.opacity(0.35), radius: 6, x: 0, y: 3)
    }
}

private struct CircleIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(AppTheme.Colors.cardBackground))
                .overlay(Circle().strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 0.6))
                .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Message Row

private struct ChatMessageRow: View {
    let message: ChatMessage
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
    var isSpeaking: Bool = false
    var onChipTap: (SuggestedActionChip) -> Void = { _ in }
    var onLike: () -> Void = { }
    var onDislike: () -> Void = { }
    var onSpeak: () -> Void = { }
    var onRegenerate: () -> Void = { }
    var onCopy: () -> Void = { }
    var onSaveItinerary: () -> Void = { }
    var onTapStation: (StationSearchPayload.Stop) -> Void = { _ in }
    var shareText: String = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .assistant {
                // Avatar gutter — render once per group, keep gutter for alignment.
                if isLastInGroup {
                    AIAvatar(size: 28)
                } else {
                    Color.clear.frame(width: 28, height: 28)
                }
            } else {
                Spacer(minLength: 48)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if let status = message.toolStatus, message.role == .assistant {
                    ToolStatusPill(label: status)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                if !isEmptyAssistantTextBubble {
                    bubble
                }

                if let dataURL = message.imageDataURL,
                   message.role == .user,
                   let img = decodeDataURL(dataURL) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 0.6)
                        )
                }

                if let payload = message.routePayload, message.role == .assistant {
                    ItineraryCardList(payload: payload, onSave: onSaveItinerary)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let payload = message.stationsPayload, message.role == .assistant {
                    StationListCard(payload: payload, onTap: onTapStation)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let payload = message.liveArrivalsPayload, message.role == .assistant {
                    LiveArrivalsCard(payload: payload)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let payload = message.stopInfoPayload, message.role == .assistant {
                    StopInfoCard(payload: payload)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let payload = message.equipmentOutagesPayload, message.role == .assistant {
                    EquipmentOutagesCard(payload: payload)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let payload = message.serviceAlertsPayload, message.role == .assistant {
                    ServiceAlertsCard(payload: payload)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let chips = message.suggestedChips,
                   !chips.isEmpty,
                   message.role == .assistant {
                    SuggestionChipStrip(chips: chips, onTap: onChipTap)
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if message.role == .assistant && message.showActions && isLastInGroup {
                    AssistantActionRow(
                        rating: message.rating,
                        isSpeaking: isSpeaking,
                        shareText: shareText,
                        onLike: onLike,
                        onDislike: onDislike,
                        onSpeak: onSpeak,
                        onCopy: onCopy,
                        onRegenerate: onRegenerate
                    )
                    .padding(.top, 2)
                }
            }

            if message.role == .assistant {
                Spacer(minLength: 48)
            }
        }
        .padding(.top, isFirstInGroup ? 6 : 0)
    }

    private func decodeDataURL(_ s: String) -> UIImage? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let b64 = String(s[s.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.content {
        case .text(let text):
            TextBubble(text: text, role: message.role, isLastInGroup: isLastInGroup)
        case .voice(let duration):
            VoiceBubble(durationSeconds: duration, role: message.role, isLastInGroup: isLastInGroup)
        case .file(let name, let sizeLabel, let kind):
            FileBubble(
                name: name,
                sizeLabel: sizeLabel,
                kind: kind,
                role: message.role,
                isLastInGroup: isLastInGroup
            )
        }
    }

    /// True when this is an assistant message whose only content is an empty
    /// placeholder text body — the tool status pill / typing indicator already
    /// conveys progress, so the blank white bubble is just visual noise.
    private var isEmptyAssistantTextBubble: Bool {
        guard message.role == .assistant else { return false }
        guard case .text(let body) = message.content else { return false }
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Markdown Text

/// Renders multi-line markdown text with sensible block handling:
/// paragraphs, bullet lists (`- ` / `* `), numbered lists (`1. `),
/// headings (`# ` / `## ` / `### `), and inline emphasis. Inline
/// formatting in each line is parsed via SwiftUI's built-in
/// `AttributedString(markdown:)`.
private struct MarkdownText: View {
    let text: String
    let textColor: Color
    var accentColor: Color = AppTheme.Colors.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    // MARK: Block model

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case ordered([String])
    }

    private func parseBlocks() -> [Block] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [Block] = []
        var paraBuf: [String] = []
        var bulletBuf: [String] = []
        var orderedBuf: [String] = []

        func flushParagraph() {
            if !paraBuf.isEmpty {
                let body = paraBuf.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !body.isEmpty { blocks.append(.paragraph(body)) }
                paraBuf.removeAll()
            }
        }
        func flushBullets() {
            if !bulletBuf.isEmpty {
                blocks.append(.bullets(bulletBuf))
                bulletBuf.removeAll()
            }
        }
        func flushOrdered() {
            if !orderedBuf.isEmpty {
                blocks.append(.ordered(orderedBuf))
                orderedBuf.removeAll()
            }
        }
        func flushAll() { flushParagraph(); flushBullets(); flushOrdered() }

        for raw in lines {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushAll()
                continue
            }

            // Headings
            if trimmed.hasPrefix("### ") {
                flushAll()
                blocks.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
                continue
            }
            if trimmed.hasPrefix("## ") {
                flushAll()
                blocks.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
                continue
            }
            if trimmed.hasPrefix("# ") {
                flushAll()
                blocks.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
                continue
            }

            // Bullets — accept `- `, `* `, or `• `
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph(); flushOrdered()
                bulletBuf.append(String(trimmed.dropFirst(2)))
                continue
            }

            // Numbered lists — `1. `, `2. `, etc.
            if let dot = trimmed.firstIndex(of: "."),
               trimmed.distance(from: trimmed.startIndex, to: dot) <= 2,
               Int(trimmed[..<dot]) != nil,
               trimmed.index(after: dot) < trimmed.endIndex,
               trimmed[trimmed.index(after: dot)] == " " {
                flushParagraph(); flushBullets()
                orderedBuf.append(
                    String(trimmed[trimmed.index(dot, offsetBy: 2)...])
                )
                continue
            }

            flushBullets(); flushOrdered()
            paraBuf.append(trimmed)
        }
        flushAll()
        return blocks
    }

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineMarkdown(text)
                .font(.system(
                    size: level == 1 ? 19 : level == 2 ? 17 : 15,
                    weight: .bold,
                    design: .rounded
                ))
                .foregroundColor(textColor)
                .padding(.top, 2)
        case .paragraph(let text):
            inlineMarkdown(text)
                .font(.system(size: 15))
                .foregroundColor(textColor)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(accentColor)
                            .frame(width: 12, alignment: .center)
                        inlineMarkdown(item)
                            .font(.system(size: 15))
                            .foregroundColor(textColor)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1).")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(accentColor)
                            .frame(width: 18, alignment: .trailing)
                        inlineMarkdown(item)
                            .font(.system(size: 15))
                            .foregroundColor(textColor)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func inlineMarkdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            return Text(styled(attributed))
        }
        return Text(text)
    }

    private func styled(_ input: AttributedString) -> AttributedString {
        var s = input
        for run in s.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                s[run.range].font = .system(size: 14, weight: .medium, design: .monospaced)
            }
        }
        return s
    }
}

// MARK: - Tool Status Pill

private struct ToolStatusPill: View {
    let label: String
    @State private var pulse: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(AppTheme.Colors.accent)
                .scaleEffect(pulse ? 1.15 : 0.95)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(AppTheme.Colors.accentTint.opacity(0.85))
        )
        .overlay(
            Capsule().strokeBorder(
                AppTheme.Colors.accent.opacity(0.25), lineWidth: 0.6
            )
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever()) {
                pulse = true
            }
        }
    }
}

// MARK: - Suggestion Chip Strip

private struct SuggestionChipStrip: View {
    let chips: [SuggestedActionChip]
    let onTap: (SuggestedActionChip) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    Button { onTap(chip) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: iconName(for: chip.kind))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AppTheme.Colors.accent)
                            Text(chip.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(AppTheme.Colors.cardBackground)
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                AppTheme.Colors.borderSubtle, lineWidth: 0.6
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func iconName(for kind: String) -> String {
        switch kind {
        case "save_trip":             return "bookmark"
        case "start_tracking":        return "location.fill"
        case "open_alerts":           return "exclamationmark.triangle"
        case "open_place":            return "mappin.circle"
        case "open_plan":             return "map"
        case "generate_alternatives": return "arrow.triangle.2.circlepath"
        default:                      return "sparkles"
        }
    }
}

// MARK: - Itinerary Card

private struct ItineraryCardList: View {
    let payload: RoutePlanPayload
    var onSave: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(payload.itineraries.prefix(3).enumerated()), id: \.element.id) { idx, itin in
                ItineraryCard(
                    itinerary: itin,
                    index: idx + 1,
                    origin: payload.origin,
                    destination: payload.destination,
                    onSave: onSave
                )
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
    }
}

private struct ItineraryCard: View {
    let itinerary: RoutePlanPayload.Itinerary
    let index: Int
    var origin: String? = nil
    var destination: String? = nil
    var onSave: (() -> Void)? = nil

    @State private var showDetail = false

    var body: some View {
        Button(action: { showDetail = true }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Option \(index)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AppTheme.Gradients.accentVibrant))

                    if let total = itinerary.total_minutes {
                        Label("\(Int(total.rounded())) min", systemImage: "clock")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                    }

                    Spacer(minLength: 0)

                    if let xfer = itinerary.transfer_count, xfer > 0 {
                        Label("\(xfer)", systemImage: "arrow.triangle.swap")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                }

                if let legs = itinerary.legs, !legs.isEmpty {
                    LegStrip(legs: legs)
                } else if let summary = itinerary.summary {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(3)
                }

                if let dep = itinerary.departure_time, let arr = itinerary.arrival_time {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.Colors.accent)
                        Text("Depart \(formatTime(dep)) · Arrive \(formatTime(arr))")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                    }
                }

                Divider().opacity(0.4)

                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Tap for full details")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(AppTheme.Colors.accent)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.55), lineWidth: 0.6)
            )
            .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 10, x: 0, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            ItineraryDetailSheet(
                itinerary: itinerary,
                index: index,
                origin: origin,
                destination: destination,
                onSave: onSave
            )
        }
    }

    private func formatTime(_ iso: String) -> String {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = isoFmt.date(from: iso)
            ?? ISO8601DateFormatter().date(from: iso)
        guard let date = date else { return iso }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Itinerary Detail Sheet

/// Full-screen breakdown of a chat-suggested itinerary. Renders every
/// leg with route badges, stop counts, departure/arrival times, plus
/// quick "Save trip" / "Open in Plan" actions at the bottom.
private struct ItineraryDetailSheet: View {
    let itinerary: RoutePlanPayload.Itinerary
    let index: Int
    var origin: String? = nil
    var destination: String? = nil
    var onSave: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var didSave = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    summaryRow
                    if let legs = itinerary.legs, !legs.isEmpty {
                        legsSection(legs)
                    }
                    actions
                }
                .padding(20)
            }
            .background(AppTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Trip Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Option \(index)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(AppTheme.Gradients.accentVibrant))
            if let origin = origin, let destination = destination {
                Text("\(origin) → \(destination)")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(2)
            } else if let summary = itinerary.summary {
                Text(summary)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
            }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            if let total = itinerary.total_minutes {
                detailStat(icon: "clock.fill", value: "\(Int(total.rounded())) min", label: "Total")
            }
            if let xfer = itinerary.transfer_count {
                detailStat(icon: "arrow.triangle.swap", value: "\(xfer)", label: xfer == 1 ? "Transfer" : "Transfers")
            }
            if let walk = itinerary.walk_minutes, walk > 0 {
                detailStat(icon: "figure.walk", value: "\(Int(walk.rounded())) min", label: "Walking")
            }
        }
    }

    private func detailStat(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(AppTheme.Colors.accent)
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.4), lineWidth: 0.6)
        )
    }

    @ViewBuilder
    private func legsSection(_ legs: [RoutePlanPayload.Leg]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Step by step")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .textCase(.uppercase)
            VStack(spacing: 0) {
                ForEach(Array(legs.enumerated()), id: \.element.id) { idx, leg in
                    LegDetailRow(leg: leg, isLast: idx == legs.count - 1)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.4), lineWidth: 0.6)
            )
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if let save = onSave {
                Button {
                    save()
                    didSave = true
                    dismiss()
                } label: {
                    Label(didSave ? "Saved" : "Save this trip",
                          systemImage: didSave ? "checkmark.circle.fill" : "bookmark.fill")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(AppTheme.Gradients.accentVibrant)
                        )
                }
                .disabled(didSave)
            }

            if let origin = origin, let destination = destination {
                Button {
                    NotificationCenter.default.post(name: .switchToTab, object: AppTab.trips)
                    dismiss()
                } label: {
                    Label("Open in Trip Planner", systemImage: "arrow.triangle.swap")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(AppTheme.Colors.accent, lineWidth: 1)
                        )
                }
                .accessibilityLabel("Open \(origin) to \(destination) in trip planner")
            }
        }
        .padding(.top, 6)
    }
}

private struct LegDetailRow: View {
    let leg: RoutePlanPayload.Leg
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(routeColor))
                if !isLast {
                    Rectangle()
                        .fill(AppTheme.Colors.borderSubtle.opacity(0.5))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    if let stops = leg.num_stops, stops > 0 {
                        Text("· \(stops) stop\(stops == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                    }
                }
                if let from = leg.from_name {
                    Text("From **\(from)**")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                if let to = leg.to_name {
                    Text("To **\(to)**")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                if let head = leg.headsign, !head.isEmpty {
                    Text("→ \(head)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
                if let duration = leg.duration_minutes {
                    Text("\(Int(duration.rounded())) min")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, isLast ? 0 : 14)
    }

    private var label: String {
        if let r = leg.route_label, !r.isEmpty { return r }
        if let r = leg.route_id, !r.isEmpty { return r }
        return (leg.mode ?? "walk").capitalized
    }

    private var iconName: String {
        switch (leg.mode ?? "").lowercased() {
        case "walk", "walking": return "figure.walk"
        case "subway", "transit", "rail", "train": return "tram.fill"
        case "bus": return "bus.fill"
        default: return "arrow.right"
        }
    }

    private var routeColor: Color {
        switch (leg.mode ?? "").lowercased() {
        case "walk", "walking": return AppTheme.Colors.textSecondary
        case "bus": return .blue
        default:
            if let id = leg.route_id, !id.isEmpty {
                return AppTheme.SubwayColors.color(for: id)
            }
            return AppTheme.Colors.accent
        }
    }
}

private struct LegStrip: View {
    let legs: [RoutePlanPayload.Leg]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(legs.enumerated()), id: \.element.id) { idx, leg in
                    LegChip(leg: leg)
                    if idx < legs.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                    }
                }
            }
        }
    }
}

private struct LegChip: View {
    let leg: RoutePlanPayload.Leg

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(routeColor))

            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                if let duration = leg.duration_minutes {
                    Text("\(Int(duration.rounded())) min")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(routeColor.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(routeColor.opacity(0.3), lineWidth: 0.6)
        )
    }

    private var label: String {
        if let r = leg.route_label, !r.isEmpty { return r }
        if let r = leg.route_id, !r.isEmpty { return r }
        return (leg.mode ?? "walk").capitalized
    }

    private var iconName: String {
        switch (leg.mode ?? "").lowercased() {
        case "walk", "walking": return "figure.walk"
        case "subway", "transit", "rail", "train": return "tram.fill"
        case "bus": return "bus.fill"
        default: return "arrow.right"
        }
    }

    private var routeColor: Color {
        switch (leg.mode ?? "").lowercased() {
        case "walk", "walking": return AppTheme.Colors.textSecondary
        case "bus": return .blue
        default: return AppTheme.Colors.accent
        }
    }
}

// MARK: - Station List Card

private struct StationListCard: View {
    let payload: StationSearchPayload
    var onTap: (StationSearchPayload.Stop) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(payload.stops.prefix(5)) { stop in
                Button {
                    onTap(stop)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "tram.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(AppTheme.Gradients.accentVibrant))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(stop.stop_name ?? "Unknown")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                            if let id = stop.stop_id {
                                Text(id)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(AppTheme.Colors.textTertiary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.Colors.cardBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.5), lineWidth: 0.6)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
    }
}

// MARK: - Live Arrivals Card

private struct LiveArrivalsCard: View {
    let payload: LiveArrivalsPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — colored route bullet + caption
            HStack(spacing: 8) {
                ChatRouteBullet(routeId: payload.route_id)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text(headerCaption)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
                Spacer(minLength: 0)
                if let n = payload.vehicle_count, n > 0 {
                    Label("\(n)", systemImage: "tram.fill")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }

            if payload.arrivals.isEmpty {
                Text("No upcoming trains right now.")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 4) {
                    ForEach(payload.arrivals.prefix(6)) { arr in
                        ChatArrivalRow(arrival: arr, routeId: payload.route_id)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.55), lineWidth: 0.6)
        )
        .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 10, x: 0, y: 4)
    }

    private var headerTitle: String {
        let route = payload.route_id
        let dir = (payload.direction_filter ?? "both").lowercased()
        switch dir {
        case "north": return "Northbound \(route)"
        case "south": return "Southbound \(route)"
        default:      return "\(route) train arrivals"
        }
    }

    private var headerCaption: String {
        if let f = payload.station_filter, !f.isEmpty {
            return "Live · filtered by \"\(f)\""
        }
        return "Live · GTFS-RT"
    }
}

private struct ChatRouteBullet: View {
    let routeId: String

    var body: some View {
        Text(routeId)
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundColor(AppTheme.SubwayColors.textColor(for: routeId))
            .frame(width: 28, height: 28)
            .background(Circle().fill(AppTheme.SubwayColors.color(for: routeId)))
    }
}

private struct ChatArrivalRow: View {
    let arrival: LiveArrivalsPayload.Arrival
    let routeId: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(arrival.station_name ?? "Unknown stop")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                if let dest = arrival.destination, !dest.isEmpty {
                    Text("→ \(dest)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 1) {
                Text(etaText)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(statusColor)
                if let label = statusLabel {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.SubwayColors.color(for: routeId).opacity(0.06))
        )
    }

    private var etaText: String {
        if arrival.is_cancelled == true { return "—" }
        guard let m = arrival.minutes_away else { return "—" }
        if m <= 0 { return "Now" }
        return "\(m) min"
    }

    private var statusColor: Color {
        if arrival.is_cancelled == true || arrival.is_skipped == true {
            return .red
        }
        if let d = arrival.delay_seconds, d >= 120 {
            return .orange
        }
        return AppTheme.Colors.accent
    }

    private var statusLabel: String? {
        if arrival.is_cancelled == true { return "Cancelled" }
        if arrival.is_skipped == true { return "Skipped" }
        if let d = arrival.delay_seconds, d >= 120 {
            return "+\(d / 60) min late"
        }
        if let s = arrival.status, s.lowercased() != "on time" {
            return s
        }
        return nil
    }
}

// MARK: - Stop Info Card

private struct StopInfoCard: View {
    let payload: StopInfoPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: adaIcon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(adaColor))
                VStack(alignment: .leading, spacing: 1) {
                    Text(payload.station_name ?? "Stop")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(adaCaption)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
                Spacer(minLength: 0)
            }

            if let acc = payload.accessibility {
                if let outages = acc.out_of_service_equipment, !outages.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(outages.prefix(4)) { eq in
                            HStack(spacing: 6) {
                                Image(systemName: eq.type == "elevator"
                                      ? "figure.roll"
                                      : "stairs")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.orange)
                                Text(eq.description ?? eq.equipment_id ?? "Equipment")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text("OUT")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.orange))
                            }
                        }
                    }
                }
            }

            if let deps = payload.next_departures, !deps.isEmpty {
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(deps.prefix(5)) { d in
                        HStack(spacing: 8) {
                            ChatRouteBullet(routeId: d.route_id ?? "?")
                                .scaleEffect(0.75)
                                .frame(width: 22, height: 22)
                            Text(d.destination ?? "")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(etaLabel(d))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(d.is_cancelled == true
                                                 ? .red
                                                 : AppTheme.Colors.accent)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.55), lineWidth: 0.6)
        )
        .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 10, x: 0, y: 4)
    }

    private var adaIcon: String {
        switch payload.accessibility?.ada_status_code {
        case 1: return "figure.roll"
        case 2: return "exclamationmark.triangle.fill"
        default: return "tram.fill"
        }
    }

    private var adaColor: Color {
        switch payload.accessibility?.ada_status_code {
        case 1: return .green
        case 2: return .orange
        case 0: return .gray
        default: return AppTheme.Colors.accent
        }
    }

    private var adaCaption: String {
        guard let acc = payload.accessibility else { return "Stop info" }
        var bits: [String] = []
        if let s = acc.ada_status { bits.append(s.capitalized) }
        if let n = acc.out_of_service_count, n > 0 {
            bits.append("\(n) out of service")
        }
        return bits.joined(separator: " · ")
    }

    private func etaLabel(_ d: StopInfoPayload.Departure) -> String {
        if d.is_cancelled == true { return "—" }
        guard let m = d.minutes_away else { return "—" }
        if m <= 0 { return "Now" }
        return "\(m)m"
    }
}

// MARK: - Equipment Outages Card

private struct EquipmentOutagesCard: View {
    let payload: EquipmentOutagesPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.orange))
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text(headerCaption)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
                Spacer(minLength: 0)
            }

            if payload.outages.isEmpty {
                Text("No outages reported.")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 4) {
                    ForEach(payload.outages.prefix(6)) { o in
                        HStack(spacing: 8) {
                            Image(systemName: o.type == "elevator"
                                  ? "figure.roll"
                                  : "stairs")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.orange)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.orange.opacity(0.15)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(o.station ?? "Unknown station")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .lineLimit(1)
                                Text(o.description ?? "")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(AppTheme.Colors.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.orange.opacity(0.06))
                        )
                    }
                }
                if payload.truncated == true,
                   let total = payload.total_outages,
                   let returned = payload.returned {
                    Text("Showing \(returned) of \(total)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.55), lineWidth: 0.6)
        )
        .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 10, x: 0, y: 4)
    }

    private var headerTitle: String {
        let kind = (payload.filters?.equipment_type ?? "equipment").capitalized
        return "\(kind) Outages"
    }

    private var headerCaption: String {
        if let f = payload.filters?.station_filter, !f.isEmpty {
            return "Filtered by \"\(f)\""
        }
        if let total = payload.total_outages {
            return "\(total) total system-wide"
        }
        return "MTA equipment feed"
    }
}

// MARK: - Service Alerts Card

private struct ServiceAlertsCard: View {
    let payload: ServiceAlertsPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.red))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Service Alerts")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("\(payload.total_matching ?? payload.alerts.count) total")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
                Spacer(minLength: 0)
            }

            if payload.alerts.isEmpty {
                Text("No active alerts.")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(payload.alerts.prefix(4)) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                ForEach(routeBadges(for: a), id: \.self) { rid in
                                    ChatRouteBullet(routeId: rid)
                                        .scaleEffect(0.7)
                                        .frame(width: 20, height: 20)
                                }
                                Text(severityLabel(a.severity))
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(severityColor(a.severity)))
                                Spacer(minLength: 0)
                            }
                            Text(a.title ?? "Alert")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                                .lineLimit(2)
                            if let desc = a.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 10))
                                    .foregroundColor(AppTheme.Colors.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(severityColor(a.severity).opacity(0.07))
                        )
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.55), lineWidth: 0.6)
        )
        .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 10, x: 0, y: 4)
    }

    private func routeBadges(for a: ServiceAlertsPayload.Alert) -> [String] {
        var ids: [String] = []
        if let r = a.route_id, !r.isEmpty { ids.append(r) }
        for r in (a.affected_routes ?? []) where !ids.contains(r) {
            ids.append(r)
        }
        return Array(ids.prefix(4))
    }

    private func severityLabel(_ sev: String?) -> String {
        switch (sev ?? "").lowercased() {
        case "severe", "high":   return "MAJOR"
        case "moderate":         return "DELAY"
        case "info", "low":      return "INFO"
        default:                 return "ALERT"
        }
    }

    private func severityColor(_ sev: String?) -> Color {
        switch (sev ?? "").lowercased() {
        case "severe", "high":   return .red
        case "moderate":         return .orange
        case "info", "low":      return .blue
        default:                 return AppTheme.Colors.accent
        }
    }
}


// MARK: - Text Bubble

private struct TextBubble: View {
    let text: String
    let role: ChatRole
    let isLastInGroup: Bool

    var body: some View {
        Group {
            if role == .user {
                MarkdownText(
                    text: text,
                    textColor: AppTheme.Colors.textOnColor,
                    accentColor: .white
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(AppTheme.Gradients.accentVibrant)
                .clipShape(BubbleShape(role: .user, hasTail: isLastInGroup))
                .shadow(color: AppTheme.Colors.accent.opacity(0.32),
                        radius: 16, x: 0, y: 8)
                .shadow(color: AppTheme.Colors.accent.opacity(0.18),
                        radius: 4, x: 0, y: 2)
            } else {
                MarkdownText(
                    text: text,
                    textColor: AppTheme.Colors.textPrimary
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    BubbleShape(role: .assistant, hasTail: isLastInGroup)
                        .fill(AppTheme.Colors.cardBackground)
                )
                .overlay(
                    BubbleShape(role: .assistant, hasTail: isLastInGroup)
                        .stroke(AppTheme.Colors.borderSubtle.opacity(0.55), lineWidth: 0.6)
                )
                .shadow(color: AppTheme.Colors.shadow.opacity(0.06),
                        radius: 10, x: 0, y: 4)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 290, alignment: role == .user ? .trailing : .leading)
    }
}

// MARK: - Bubble Shape

/// Asymmetric rounded rect — small "tail" corner only on the most recent
/// message in a group, so streak bubbles read as one conversation block.
private struct BubbleShape: Shape {
    let role: ChatRole
    var hasTail: Bool = true

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 22
        let small: CGFloat = 6
        let topLeft: CGFloat = big
        let topRight: CGFloat = big

        let userTail = hasTail
        let bottomLeft: CGFloat = role == .user ? big : (userTail ? big : small)
        let bottomRight: CGFloat = role == .user ? (userTail ? small : big) : big
        // Adjust: tail is on bottom-right for user, bottom-left for assistant.
        let bl: CGFloat = role == .assistant && hasTail ? small : (role == .user ? big : big)
        let br: CGFloat = role == .user && hasTail ? small : big
        _ = bottomLeft; _ = bottomRight

        return Path { p in
            p.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
            p.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + topRight),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
            p.addQuadCurve(
                to: CGPoint(x: rect.maxX - br, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
            p.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - bl),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
            p.addQuadCurve(
                to: CGPoint(x: rect.minX + topLeft, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        }
    }
}

// MARK: - Voice Bubble

private struct VoiceBubble: View {
    let durationSeconds: Int
    let role: ChatRole
    let isLastInGroup: Bool
    @State private var isPlaying = false
    @State private var progress: CGFloat = 0.35

    private var durationLabel: String {
        let mins = durationSeconds / 60
        let secs = durationSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isPlaying.toggle()
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundColor(role == .user
                                     ? AppTheme.Colors.accent
                                     : .white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(
                            role == .user
                                ? Color.white
                                : AppTheme.Colors.accent
                        )
                    )
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)

            WaveformView(
                barCount: 30,
                progress: progress,
                isActive: isPlaying,
                role: role
            )
            .frame(width: 130, height: 28)

            Text(durationLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(role == .user
                                 ? AppTheme.Colors.textOnColor.opacity(0.9)
                                 : AppTheme.Colors.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            BubbleShape(role: role, hasTail: isLastInGroup)
                .fill(role == .user
                      ? AnyShapeStyle(AppTheme.Gradients.accentVibrant)
                      : AnyShapeStyle(AppTheme.Colors.cardBackground))
        )
        .overlay(
            BubbleShape(role: role, hasTail: isLastInGroup)
                .stroke(
                    role == .user ? Color.clear : AppTheme.Colors.borderSubtle.opacity(0.55),
                    lineWidth: 0.6
                )
        )
        .shadow(
            color: role == .user
                ? AppTheme.Colors.accent.opacity(0.32)
                : AppTheme.Colors.shadow.opacity(0.06),
            radius: role == .user ? 16 : 10,
            x: 0,
            y: role == .user ? 8 : 4
        )
    }
}

private struct WaveformView: View {
    let barCount: Int
    let progress: CGFloat
    let isActive: Bool
    let role: ChatRole

    private var heights: [CGFloat] {
        (0..<barCount).map { i in
            let t = Double(i) / Double(barCount)
            let base = sin(t * .pi * 3.5) * 0.45 + 0.55
            let jitter = sin(Double(i) * 1.7) * 0.18
            return CGFloat(max(0.22, min(1.0, base + jitter)))
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(barColor(at: i))
                        .frame(width: 2.5, height: geo.size.height * heights[i])
                        .scaleEffect(y: isActive ? 1.06 : 1.0, anchor: .center)
                        .animation(
                            isActive
                                ? .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.018)
                                : .default,
                            value: isActive
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func barColor(at index: Int) -> Color {
        let isPlayed = CGFloat(index) / CGFloat(barCount) <= progress
        if role == .user {
            return isPlayed
                ? AppTheme.Colors.textOnColor
                : AppTheme.Colors.textOnColor.opacity(0.45)
        } else {
            return isPlayed
                ? AppTheme.Colors.accent
                : AppTheme.Colors.accent.opacity(0.35)
        }
    }
}

// MARK: - File Bubble

private struct FileBubble: View {
    let name: String
    let sizeLabel: String
    let kind: ChatMessageContent.FileKind
    let role: ChatRole
    let isLastInGroup: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.Colors.accentTint)
                    .frame(width: 44, height: 44)

                Image(systemName: kind.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizeLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }

            Spacer(minLength: 6)

            Button { } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(AppTheme.Gradients.accentVibrant))
                    .shadow(color: AppTheme.Colors.accent.opacity(0.35),
                            radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: 290)
        .background(
            BubbleShape(role: role, hasTail: isLastInGroup)
                .fill(AppTheme.Colors.cardBackground)
        )
        .overlay(
            BubbleShape(role: role, hasTail: isLastInGroup)
                .stroke(AppTheme.Colors.borderSubtle.opacity(0.55), lineWidth: 0.6)
        )
        .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Action Row

private struct AssistantActionRow: View {
    var rating: Int? = nil
    var isSpeaking: Bool = false
    var shareText: String = ""
    var onLike: () -> Void = { }
    var onDislike: () -> Void = { }
    var onSpeak: () -> Void = { }
    var onCopy: () -> Void = { }
    var onRegenerate: () -> Void = { }

    @State private var copiedFlash: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            actionButton(
                systemName: rating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup",
                tinted: rating == 1,
                accessibilityLabel: "Good response"
            ) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    onLike()
                }
            }
            actionButton(
                systemName: rating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                tinted: rating == -1,
                accessibilityLabel: "Bad response"
            ) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    onDislike()
                }
            }
            actionButton(
                systemName: isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill",
                tinted: isSpeaking,
                accessibilityLabel: isSpeaking ? "Stop speaking" : "Read aloud"
            ) {
                onSpeak()
            }
            actionButton(
                systemName: copiedFlash ? "checkmark" : "doc.on.doc",
                tinted: copiedFlash,
                accessibilityLabel: "Copy reply"
            ) {
                onCopy()
                withAnimation(.easeOut(duration: 0.2)) { copiedFlash = true }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    withAnimation(.easeIn(duration: 0.2)) { copiedFlash = false }
                }
            }
            if !shareText.isEmpty {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share reply")
            }
            actionButton(
                systemName: "arrow.clockwise",
                accessibilityLabel: "Regenerate response"
            ) {
                onRegenerate()
            }
        }
        .padding(.leading, 2)
    }

    private func actionButton(
        systemName: String,
        tinted: Bool = false,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tinted
                                 ? AppTheme.Colors.accent
                                 : AppTheme.Colors.textTertiary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Typing Indicator

private struct TypingIndicatorRow: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            AIAvatar(size: 28)

            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(AppTheme.Colors.textTertiary)
                        .frame(width: 7, height: 7)
                        .scaleEffect(scale(for: i))
                        .opacity(opacity(for: i))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                BubbleShape(role: .assistant)
                    .fill(AppTheme.Colors.cardBackground)
            )
            .overlay(
                BubbleShape(role: .assistant)
                    .stroke(AppTheme.Colors.borderSubtle.opacity(0.55), lineWidth: 0.6)
            )
            .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 10, x: 0, y: 4)

            Spacer(minLength: 48)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) {
                phase = 1
            }
        }
    }

    private func scale(for i: Int) -> CGFloat {
        let offset = CGFloat(i) * 0.25
        let v = sin((phase + offset) * .pi * 2)
        return 0.85 + 0.25 * (v * 0.5 + 0.5)
    }

    private func opacity(for i: Int) -> Double {
        let offset = CGFloat(i) * 0.25
        let v = sin((phase + offset) * .pi * 2)
        return 0.5 + 0.5 * Double(v * 0.5 + 0.5)
    }
}

// MARK: - Suggestion Chips

private struct SuggestionChipsRow: View {
    let prompts: [String]
    let onTap: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(prompts, id: \.self) { prompt in
                    Button { onTap(prompt) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AppTheme.Colors.accent)
                            Text(prompt)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Capsule().fill(AppTheme.Colors.cardBackground)
                        )
                        .overlay(
                            Capsule().strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 0.6)
                        )
                        .shadow(color: AppTheme.Colors.shadow.opacity(0.05),
                                radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Composer

private struct ChatComposer: View {
    @Binding var text: String
    @Binding var isRecording: Bool
    var isFocused: FocusState<Bool>.Binding
    var pendingImageDataURL: String? = nil
    var speakReplies: Bool = false
    let onSend: () -> Void
    var onAttachImage: (Data) -> Void = { _ in }
    var onClearImage: () -> Void = { }
    var onToggleMic: () -> Void = { }
    var onToggleSpeak: () -> Void = { }

    @State private var photoSelection: PhotosPickerItem? = nil

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(AppTheme.Colors.borderSubtle.opacity(0.4))
                .frame(height: 0.5)

            if pendingImageDataURL != nil {
                pendingImagePreview
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }

            HStack(spacing: 10) {
                attachmentButton
                speakerToggleButton
                inputField
                trailingButton
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        // Transparent so the screen's `AppTheme.Gradients.screen` shows
        // through. Previously used `.ultraThinMaterial` which rendered
        // as a frosted gray bar that didn't match the chat background.
        .background(Color.clear)
        .onChange(of: photoSelection) { _, newItem in
            guard let item = newItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run { onAttachImage(data) }
                }
                await MainActor.run { photoSelection = nil }
            }
        }
    }

    @ViewBuilder
    private var pendingImagePreview: some View {
        HStack(spacing: 10) {
            if let url = pendingImageDataURL,
               let comma = url.firstIndex(of: ","),
               let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
               let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("Image attached")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Spacer()
            Button(action: onClearImage) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var attachmentButton: some View {
        PhotosPicker(
            selection: $photoSelection,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(AppTheme.Colors.cardBackground))
                .overlay(Circle().strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 0.6))
                .shadow(color: AppTheme.Colors.shadow.opacity(0.06),
                        radius: 4, x: 0, y: 2)
        }
    }

    private var speakerToggleButton: some View {
        Button(action: onToggleSpeak) {
            Image(systemName: speakReplies
                  ? "speaker.wave.2.fill"
                  : "speaker.slash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(speakReplies
                                 ? AppTheme.Colors.accent
                                 : AppTheme.Colors.textSecondary)
                .frame(width: 32, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speakReplies
                            ? "Mute spoken replies"
                            : "Speak replies aloud")
    }

    /// Soft character cap. Mirrors Claude.ai / ChatGPT behaviour:
    /// no hard block, but a quiet counter appears when the user crosses
    /// the warning threshold so they know the message is getting long.
    private static let softCharLimit = 4000
    private static let counterThreshold = 3000

    /// Twitter / X-style highlighting: characters past the limit stay
    /// visible but render in a dimmed red so the user can see exactly
    /// what won't be sent and edit it down.
    private var attributedDraft: AttributedString {
        var attr = AttributedString(text)
        attr.font = .system(size: 15)
        attr.foregroundColor = AppTheme.Colors.textPrimary

        if text.count > Self.softCharLimit {
            let cutoff = text.index(text.startIndex, offsetBy: Self.softCharLimit)
            if let overflowRange = attr.range(of: String(text[cutoff...])) {
                attr[overflowRange].foregroundColor =
                    AppTheme.Colors.alertRed.opacity(0.55)
            }
        }
        return attr
    }

    private var isOverLimit: Bool { text.count > Self.softCharLimit }

    private var inputField: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // Switch to a Capsule when the field is short, but morph to a
            // rounded rectangle once it grows multi-line so corners don't
            // fight the now-rectangular text block.
            let multiline = text.count > 60 || text.contains("\n")
            let shape = RoundedRectangle(
                cornerRadius: multiline ? 18 : 22,
                style: .continuous
            )

            ZStack(alignment: .topLeading) {
                // Styled overlay — first `softCharLimit` chars in normal
                // text colour, anything past the cap dimmed in red so the
                // user sees exactly what won't be sent (Twitter / X pattern).
                // Sits *behind* the real TextField, which renders its own
                // glyphs as `.clear` so they don't double up.
                Text(attributedDraft)
                    .font(.system(size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)

                TextField("Type a message…", text: $text, axis: .vertical)
                    .font(.system(size: 15))
                    // Hide the field's own glyphs so only the styled
                    // overlay shows. Cursor (`tint`) stays visible.
                    .foregroundColor(.clear)
                    .tint(AppTheme.Colors.accent)
                    .focused(isFocused)
                    .lineLimit(1...10)
                    .submitLabel(.return)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(shape.fill(AppTheme.Colors.cardBackground))
            .overlay(
                shape.strokeBorder(
                    isOverLimit
                        ? AppTheme.Colors.alertRed.opacity(0.7)
                        : (hasText
                           ? AppTheme.Colors.accent.opacity(0.5)
                           : AppTheme.Colors.borderSubtle),
                    lineWidth: (isOverLimit || hasText) ? 1 : 0.6
                )
            )

            if text.count >= Self.counterThreshold {
                Text("\(text.count) / \(Self.softCharLimit)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        isOverLimit
                            ? AppTheme.Colors.alertRed
                            : AppTheme.Colors.textTertiary
                    )
                    .padding(.trailing, 6)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: hasText)
        .animation(.easeInOut(duration: 0.18), value: isOverLimit)
        .animation(.easeInOut(duration: 0.18), value: text.count >= Self.counterThreshold)
    }

    @ViewBuilder
    private var trailingButton: some View {
        if hasText {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(
                            isOverLimit
                                ? AnyShapeStyle(AppTheme.Colors.textTertiary)
                                : AnyShapeStyle(AppTheme.Gradients.accentVibrant)
                        )
                    )
                    .shadow(
                        color: isOverLimit
                            ? .clear
                            : AppTheme.Colors.accent.opacity(0.5),
                        radius: 10, x: 0, y: 4
                    )
            }
            .buttonStyle(.plain)
            .disabled(isOverLimit)
            .transition(.scale.combined(with: .opacity))
        } else {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    onToggleMic()
                }
            } label: {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isRecording
                                     ? .white
                                     : AppTheme.Colors.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(
                            isRecording
                                ? AnyShapeStyle(AppTheme.Gradients.accentVibrant)
                                : AnyShapeStyle(AppTheme.Colors.cardBackground)
                        )
                    )
                    .overlay(
                        Circle().strokeBorder(
                            isRecording ? Color.clear : AppTheme.Colors.borderSubtle,
                            lineWidth: 0.6
                        )
                    )
                    .shadow(
                        color: isRecording
                            ? AppTheme.Colors.accent.opacity(0.45)
                            : AppTheme.Colors.shadow.opacity(0.06),
                        radius: isRecording ? 10 : 4,
                        x: 0,
                        y: isRecording ? 4 : 2
                    )
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
        }
    }
}

#Preview("Light") {
    ChatView()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    ChatView()
        .preferredColorScheme(.dark)
}
