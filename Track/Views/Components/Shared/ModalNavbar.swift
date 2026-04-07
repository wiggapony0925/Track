// Modal navbar component displayed at the top of the dashboard sheet.
// Contains search bar, transport mode filter icons, and settings button.
// Design: clean, Apple-native feel with generous whitespace.

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
            // ── Search bar + settings ──
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                    
                    TextField("Search trains, buses, stations…", text: $searchText)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(AppTheme.Colors.textTertiary)
                        }
                    }
                    
                    micButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.Colors.cardInset.opacity(0.5))
                }
                
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                        .frame(width: 38, height: 38)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(AppTheme.Colors.cardInset.opacity(0.5))
                        }
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 14)
            .padding(.bottom, 10)
            
            // ── Transport mode strip ──
            ModeFilterStrip(selectedMode: $selectedMode)
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.bottom, 10)

            // ── Status row ──
            statusRow
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.bottom, 10)
        }
        .onAppear {
            speechManager.onTranscription = { text in
                searchText = text
            }
        }
    }

    // MARK: - Mic Button

    private var micButton: some View {
        let isRecording = speechManager.isRecording
        return Button {
            speechManager.toggle()
        } label: {
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(
                    isRecording
                        ? AppTheme.Colors.alertRed
                        : AppTheme.Colors.textTertiary
                )
        }
    }

    // MARK: - Status Row

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 0) {
            if isRefreshing {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(AppTheme.Colors.textTertiary)
                    Text("Updating…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
            } else if let lastUpdated {
                HStack(spacing: 5) {
                    Circle()
                        .fill(AppTheme.Colors.successGreen)
                        .frame(width: 5, height: 5)
                    let formatter = RelativeDateTimeFormatter()
                    Text("Updated \(formatter.localizedString(for: lastUpdated, relativeTo: .now))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
            }
            Spacer()
            if let weather = weatherSnapshot {
                WeatherChipView(snapshot: weather, style: .compact)
            }
        }
    }
}

// MARK: - Mode Filter Strip

struct ModeFilterStrip: View {
    @Binding var selectedMode: TransportMode
    @Namespace private var modeNamespace
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(TransportMode.allCases, id: \.self) { mode in
                modeButton(for: mode)
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.Colors.cardInset.opacity(0.4))
        }
    }

    private func modeButton(for mode: TransportMode) -> some View {
        let isActive = selectedMode == mode
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedMode = mode
            }
            HapticManager.impact(.light)
        } label: {
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(AppTheme.Colors.accent)
                        .matchedGeometryEffect(id: "modeHighlight", in: modeNamespace)
                }

                Image(systemName: mode.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isActive ? .white : AppTheme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
        }
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
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
