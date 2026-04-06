// Modal navbar component displayed at the top of the dashboard sheet.
// Contains search bar, transport mode filter icons, and settings button.
// Styled to match Apple Maps modal design.

import SwiftUI
import CoreLocation

struct ModalNavbar: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var selectedMode: TransportMode
    var lastUpdated: Date?
    var isRefreshing: Bool = false
    var weatherSnapshot: WeatherSnapshot? = nil
    
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
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .frame(width: 40, height: 40)
                        .trackInsetBackground(cornerRadius: 14)
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 16)
            .padding(.bottom, 10)
            
            // MARK: - Transport Mode Filter Icons
            ModeFilterStrip(selectedMode: $selectedMode)
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.bottom, 12)

            if isRefreshing {
                HStack(spacing: 6) {
                    refreshingBadge
                    Spacer()
                    if let weather = weatherSnapshot {
                        WeatherChipView(snapshot: weather, style: .compact)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.bottom, 12)
                .transition(.opacity)
            } else if let lastUpdated {
                HStack(spacing: 6) {
                    updateBadge(for: lastUpdated)
                    Spacer()
                    if let weather = weatherSnapshot {
                        WeatherChipView(snapshot: weather, style: .compact)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.bottom, 12)
                .transition(.opacity)
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
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(AppTheme.Colors.accent)
            .padding(.leading, 2)
    }

    private var clearGlyph: some View {
        Image(systemName: "xmark.circle.fill")
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(AppTheme.Colors.textTertiary)
    }

    private var micGlyph: some View {
        let isRecording = speechManager.isRecording

        return Button {
            speechManager.toggle()
        } label: {
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(isRecording ? AppTheme.Colors.alertRed : AppTheme.Colors.accent)
                .padding(.trailing, 2)
        }
    }

    private func updateBadge(for date: Date) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(AppTheme.Colors.successGreen)
                .frame(width: 6, height: 6)

            let formatter = RelativeDateTimeFormatter()
            let relative = formatter.localizedString(
                for: date, relativeTo: .now
            )
            Text("Updated \(relative)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.Colors.textTertiary)
        }
    }

    private var refreshingBadge: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
                .tint(AppTheme.Colors.accent)

            Text("Updating\u{2026}")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.Colors.textTertiary)
        }
    }
}

// MARK: - Mode Filter Strip

/// Compact icon-only transport mode filter strip
struct ModeFilterStrip: View {
    @Binding var selectedMode: TransportMode
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(TransportMode.allCases, id: \.self) { mode in
                modeButton(for: mode)
            }
        }
        .padding(.horizontal, 4)
    }

    private func modeButton(for mode: TransportMode) -> some View {
        let isActive: Bool = selectedMode == mode
        let traits: AccessibilityTraits = isActive ? .isSelected : []
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                selectedMode = mode
            }
            HapticManager.impact(.light)
        } label: {
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.Colors.accent)
                        .matchedGeometryEffect(id: "modeHighlight", in: modeNamespace)
                }

                Image(systemName: mode.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isActive ? .white : AppTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
        }
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(traits)
    }

    @Namespace private var modeNamespace
}

#Preview {
    ModalNavbar(
        searchText: .constant(""),
        showSettings: .constant(false),
        selectedMode: .constant(.nearby),
        lastUpdated: Date(),
        weatherSnapshot: .preview(.clear)
    )
    .background(AppTheme.Colors.background)
}
