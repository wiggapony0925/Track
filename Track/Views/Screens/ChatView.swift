// AI Transit Assistant chat UI.
//
// UI-only implementation. Mock data + visual surface only — drop in a
// real backend by swapping `ChatViewModel.messages` for a published
// stream and wiring `send()` to your network layer.
//
// Markdown: assistant text bubbles render full GitHub-flavored markdown
// (bold, italics, lists, inline code, links) via `MarkdownText`.

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
    let content: ChatMessageContent
    var showActions: Bool = true
    var timestamp: Date = .now

    static let mockConversation: [ChatMessage] = [
        .init(role: .assistant, content: .text(
            "Hey, I'm **MetroMind** \u{1F9E0}\u{1F687} — your NYC transit brain. Ask me about routes, delays, or the smartest way to get anywhere."
        )),
        .init(role: .user, content: .text(
            "What's the fastest way from Times Square to Brooklyn Bridge right now?"
        ), showActions: false),
        .init(role: .assistant, content: .text(
            """
            Here are your **best options** right now:

            1. **N/Q/R/W** from Times Sq–42 St → City Hall · *2 stops, ~12 min*
            2. **4/5** from 42 St–Grand Central → Brooklyn Bridge · *~14 min*
            3. **2/3** from Times Sq–42 St → Park Pl, then walk 5 min

            Service is running on schedule. Want me to start a live trip?
            """
        )),
        .init(role: .user, content: .voice(durationSeconds: 19), showActions: false),
        .init(role: .assistant, content: .file(
            name: "MTA_Service_Alerts_April.pdf",
            sizeLabel: "PDF · 2 MB",
            kind: .pdf
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

    let suggestedPrompts: [String] = [
        "Next train at Union Sq",
        "Fastest to JFK",
        "Any L delays?",
    ]

    func send(_ overrideText: String? = nil) {
        let raw = overrideText ?? draft
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(.init(role: .user, content: .text(trimmed), showActions: false))
        draft = ""
        isAssistantTyping = true

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self else { return }
            self.isAssistantTyping = false
            self.messages.append(.init(
                role: .assistant,
                content: .text("Got it — looking into that for you. *(Backend coming soon.)*")
            ))
        }
    }
}

// MARK: - ChatView

struct ChatView: View {
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
                ChatHeader()

                messagesList

                if viewModel.messages.count <= 1 {
                    SuggestionChipsRow(prompts: viewModel.suggestedPrompts) { prompt in
                        viewModel.send(prompt)
                    }
                }

                ChatComposer(
                    text: $viewModel.draft,
                    isRecording: $viewModel.isRecording,
                    isFocused: $inputFocused,
                    onSend: { viewModel.send() }
                )
            }
        }
        .navigationBarHidden(true)
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
                        ChatMessageRow(
                            message: message,
                            isFirstInGroup: isFirstInGroup(at: index),
                            isLastInGroup: isLastInGroup(at: index)
                        )
                        .id(message.id)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.96, anchor: message.role == .user ? .bottomTrailing : .bottomLeading)
                                .combined(with: .opacity),
                            removal: .opacity
                        ))
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 12) {
            CircleIconButton(systemName: "chevron.left") { dismiss() }

            Spacer()

            HStack(spacing: 10) {
                AIAvatar(size: 32)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("MetroMind")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Gradients.accentVibrant)
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Online · Ready to help")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                    }
                }
            }

            Spacer()

            CircleIconButton(systemName: "ellipsis") { }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.85))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.Colors.borderSubtle.opacity(0.5))
                .frame(height: 0.5)
        }
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
                bubble

                if message.role == .assistant && message.showActions && isLastInGroup {
                    AssistantActionRow()
                        .padding(.top, 2)
                }
            }

            if message.role == .assistant {
                Spacer(minLength: 48)
            }
        }
        .padding(.top, isFirstInGroup ? 6 : 0)
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
}

// MARK: - Markdown Text

/// Renders a string as markdown with sensible inline-style attributes.
/// Falls back to plain text if parsing fails.
private struct MarkdownText: View {
    let text: String
    let textColor: Color
    var accentColor: Color = AppTheme.Colors.accent

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(styled(attributed))
                .font(.system(size: 15))
                .foregroundColor(textColor)
                .tint(accentColor)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(textColor)
                .lineSpacing(3)
        }
    }

    private func styled(_ input: AttributedString) -> AttributedString {
        var s = input
        // Style code spans with a monospaced font.
        for run in s.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                s[run.range].font = .system(size: 14, weight: .medium, design: .monospaced)
            }
        }
        return s
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
    @State private var liked: Bool? = nil

    var body: some View {
        HStack(spacing: 2) {
            actionButton(
                systemName: liked == true ? "hand.thumbsup.fill" : "hand.thumbsup",
                tinted: liked == true
            ) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    liked = liked == true ? nil : true
                }
            }
            actionButton(
                systemName: liked == false ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                tinted: liked == false
            ) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    liked = liked == false ? nil : false
                }
            }
            actionButton(systemName: "square.and.arrow.up") { }
            actionButton(systemName: "arrow.clockwise") { }
        }
        .padding(.leading, 2)
    }

    private func actionButton(
        systemName: String,
        tinted: Bool = false,
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
    let onSend: () -> Void

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(AppTheme.Colors.borderSubtle.opacity(0.4))
                .frame(height: 0.5)

            HStack(spacing: 10) {
                attachmentButton
                inputField
                trailingButton
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .background(.ultraThinMaterial.opacity(0.85))
    }

    private var attachmentButton: some View {
        Button { } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(AppTheme.Colors.cardBackground))
                .overlay(Circle().strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 0.6))
                .shadow(color: AppTheme.Colors.shadow.opacity(0.06),
                        radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var inputField: some View {
        HStack(spacing: 8) {
            TextField("Type a message…", text: $text, axis: .vertical)
                .font(.system(size: 15))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .tint(AppTheme.Colors.accent)
                .focused(isFocused)
                .lineLimit(1...4)
                .submitLabel(.send)
                .onSubmit { onSend() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous).fill(AppTheme.Colors.cardBackground)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    hasText
                        ? AppTheme.Colors.accent.opacity(0.5)
                        : AppTheme.Colors.borderSubtle,
                    lineWidth: hasText ? 1 : 0.6
                )
        )
        .animation(.easeInOut(duration: 0.18), value: hasText)
    }

    @ViewBuilder
    private var trailingButton: some View {
        if hasText {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.Gradients.accentVibrant))
                    .shadow(color: AppTheme.Colors.accent.opacity(0.5),
                            radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
        } else {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isRecording.toggle()
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
