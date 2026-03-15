//
//  TrainSearchBar.swift
//  Track
//
//  Reusable search bar component for filtering transit results.
//  Styled to match Apple Maps with glassmorphism navbar design.
//  Includes magnifying glass icon, text field, and microphone button
//  for speech-to-text input via the shared SpeechRecognitionManager.
//

import SwiftUI

struct TrainSearchBar: View {
    /// Binding to the search query text managed by the parent view.
    @Binding var text: String

    /// Placeholder string shown when the search field is empty.
    var placeholder: String = "Search trains, buses, stations…"

    @State private var speechManager = SpeechRecognitionManager()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)

            TextField(placeholder, text: $text)
                .font(AppTheme.Typography.searchInput)
                .foregroundColor(AppTheme.Colors.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            // Clear button — shown only when there is text to clear
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }

            // Microphone button for speech-to-text
            Button {
                speechManager.toggle()
            } label: {
                Image(systemName: speechManager.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(speechManager.isRecording ? AppTheme.Colors.alertRed : AppTheme.Colors.textSecondary)
            }
            .accessibilityLabel(speechManager.isRecording ? "Stop voice input" : "Start voice input")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .trackFloatingChrome(cornerRadius: AppTheme.Layout.searchBarCornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
        .onAppear {
            speechManager.onTranscription = { text in
                self.text = text
            }
        }
    }
}

#Preview {
    TrainSearchBar(text: .constant(""))
        .padding(.top, 20)
        .background(AppTheme.Colors.background)
}
