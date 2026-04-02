// Reusable search bar component for filtering transit results.
// Styled to match Apple Maps with glassmorphism navbar design.
// Includes magnifying glass icon, text field, and microphone button
// for speech-to-text input via the shared SpeechRecognitionManager.

import SwiftUI

struct TrainSearchBar: View {
    /// Binding to the search query text managed by the parent view.
    @Binding var text: String

    /// Placeholder string shown when the search field is empty.
    var placeholder: String = "Search trains, buses, stations…"

    @State private var speechManager = SpeechRecognitionManager()

    var body: some View {
        HStack(spacing: 12) {
            searchGlyph

            TextField(placeholder, text: $text)
                .font(AppTheme.Typography.searchInput)
                .foregroundColor(AppTheme.Colors.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            // Clear button — shown only when there is text to clear
            if !text.isEmpty {
                clearButton
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }

            // Microphone button for speech-to-text
            microphoneButton
            .accessibilityLabel(
                speechManager.isRecording
                    ? "Stop voice input"
                    : "Start voice input"
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .trackFloatingChrome(cornerRadius: AppTheme.Layout.searchBarCornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
        .onAppear {
            speechManager.onTranscription = { text in
                self.text = text
            }
        }
    }

    private var searchGlyph: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Gradients.controlSurface)
                .overlay {
                    Circle()
                        .stroke(AppTheme.Colors.borderSubtle, lineWidth: 1)
                }

            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.Colors.mtaBlue)
        }
        .frame(width: 32, height: 32)
    }

    private var clearButton: some View {
        Button {
            text = ""
        } label: {
            ZStack {
                Circle()
                    .fill(AppTheme.Gradients.controlSurface)
                    .overlay {
                        Circle()
                            .stroke(AppTheme.Colors.borderSubtle, lineWidth: 1)
                    }

                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            .frame(width: 28, height: 28)
        }
    }

    private var microphoneButton: some View {
        let isRecording = speechManager.isRecording

        return Button {
            speechManager.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(
                        isRecording
                            ? AnyShapeStyle(AppTheme.Gradients.accent)
                            : AnyShapeStyle(AppTheme.Gradients.controlSurface)
                    )
                    .overlay {
                        Circle()
                            .stroke(
                                isRecording
                                    ? AppTheme.Colors.textOnColor.opacity(0.16)
                                    : AppTheme.Colors.borderSubtle,
                                lineWidth: 1
                            )
                    }

                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isRecording ? .white : AppTheme.Colors.mtaBlue)
            }
            .frame(width: 32, height: 32)
        }
    }
}

#Preview {
    TrainSearchBar(text: .constant(""))
        .padding(.top, 20)
        .background(AppTheme.Colors.background)
}
