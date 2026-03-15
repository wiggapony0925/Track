//
//  ModalNavbar.swift
//  Track
//
//  Modal navbar component displayed at the top of the dashboard sheet.
//  Contains search bar, transport mode filter icons, and settings button.
//  Styled to match Apple Maps modal design.
//

import SwiftUI
import CoreLocation

struct ModalNavbar: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var selectedMode: TransportMode
    var lastUpdated: Date?
    
    @State private var speechManager = SpeechRecognitionManager()
    
    var body: some View {
        VStack(spacing: 0) {
            // Search bar + buttons row
            HStack(spacing: 8) {
                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    
                    TextField("Search trains, buses, stations…", text: $searchText)
                        .font(AppTheme.Typography.searchInput)
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    
                    // Clear button when text is present
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        }
                    }
                    
                    // Mic button (inside search bar)
                    Button {
                        speechManager.toggle()
                    } label: {
                        Image(systemName: speechManager.isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(speechManager.isRecording ? AppTheme.Colors.alertRed : AppTheme.Colors.textSecondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .trackFloatingChrome(cornerRadius: AppTheme.Layout.searchBarCornerRadius)
                
                // Settings button
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .trackFloatingChrome(cornerRadius: 18)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 16)
            .padding(.bottom, 10)
            
            // MARK: - Transport Mode Filter Icons
            ModeFilterStrip(selectedMode: $selectedMode)
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.bottom, 12)
        }
        .trackScreenBackground()
        .onAppear {
            speechManager.onTranscription = { text in
                searchText = text
            }
        }
    }
}

// MARK: - Mode Filter Strip

/// Compact icon-only transport mode filter strip
struct ModeFilterStrip: View {
    @Binding var selectedMode: TransportMode
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(TransportMode.allCases, id: \.self) { mode in
                modeButton(for: mode)
            }
        }
        .padding(4)
        .trackFloatingChrome(cornerRadius: 16)
    }

    private func modeButton(for mode: TransportMode) -> some View {
        let isActive: Bool = selectedMode == mode
        let fgColor: Color = isActive ? .white : AppTheme.Colors.textSecondary
        let traits: AccessibilityTraits = isActive ? .isSelected : []
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedMode = mode
            }
            HapticManager.impact(.light)
        } label: {
                Image(systemName: mode.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(fgColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppTheme.Gradients.accent)
                            .opacity(isActive ? 1 : 0)
                    }
        }
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(traits)
    }
}

#Preview {
    ModalNavbar(
        searchText: .constant(""),
        showSettings: .constant(false),
        selectedMode: .constant(.nearby),
        lastUpdated: Date()
    )
    .background(AppTheme.Colors.background)
}
