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
                    searchGlyph
                    
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
                            clearGlyph
                        }
                    }
                    
                    // Mic button (inside search bar)
                    micGlyph
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .trackFloatingChrome(cornerRadius: AppTheme.Layout.searchBarCornerRadius)
                
                // Settings button
                Button {
                    showSettings = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.Gradients.controlSurface)
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(AppTheme.Colors.borderSubtle, lineWidth: 1)
                            }

                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                    }
                    .frame(width: 40, height: 40)
                }
                .trackInsetBackground(cornerRadius: 18)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 16)
            .padding(.bottom, 10)
            
            // MARK: - Transport Mode Filter Icons
            ModeFilterStrip(selectedMode: $selectedMode)
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.bottom, 12)

            if let lastUpdated {
                updateBadge(for: lastUpdated)
                    .padding(.horizontal, AppTheme.Layout.margin)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            speechManager.onTranscription = { text in
                searchText = text
            }
        }
    }

    private var searchGlyph: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(AppTheme.Colors.mtaBlue)
            .padding(.leading, 2)
    }

    private var clearGlyph: some View {
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

    private var micGlyph: some View {
        let isRecording = speechManager.isRecording

        return Button {
            speechManager.toggle()
        } label: {
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isRecording ? AppTheme.Colors.alertRed : AppTheme.Colors.mtaBlue)
                .padding(.trailing, 2)
        }
    }

    private func updateBadge(for date: Date) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(AppTheme.Colors.successGreen)
                .frame(width: 7, height: 7)

            Text("Updated \(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .trackInsetBackground(cornerRadius: 999)
    }
}

// MARK: - Mode Filter Strip

/// Compact icon-only transport mode filter strip
struct ModeFilterStrip: View {
    @Binding var selectedMode: TransportMode
    
    var body: some View {
        HStack(spacing: 6) {
            ForEach(TransportMode.allCases, id: \.self) { mode in
                modeButton(for: mode)
            }
        }
        .padding(6)
        .trackFloatingChrome(cornerRadius: 18)
    }

    private func modeButton(for mode: TransportMode) -> some View {
        let isActive: Bool = selectedMode == mode
        let traits: AccessibilityTraits = isActive ? .isSelected : []
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedMode = mode
            }
            HapticManager.impact(.light)
        } label: {
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.Gradients.accent)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(AppTheme.Colors.textOnColor.opacity(0.18), lineWidth: 1)
                        }
                        .shadow(
                            color: AppTheme.Colors.accentGlow.opacity(0.26),
                            radius: 10,
                            x: 0,
                            y: 4
                        )
                }

                Image(systemName: mode.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isActive ? .white : AppTheme.Colors.accent)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
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
