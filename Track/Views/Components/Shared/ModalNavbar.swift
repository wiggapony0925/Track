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
    var locationName: String? = nil
    var isDragSearchActive: Bool = false

    /// Shared across renders — avoids re-allocating every body evaluation.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    
    @State private var speechManager = SpeechRecognitionManager()
    
    var body: some View {
        VStack(spacing: 0) {
            // ── Location header + weather + settings ──
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    if isDragSearchActive {
                        Text("Options near")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .textCase(.uppercase)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: isDragSearchActive ? "mappin.and.ellipse" : "location.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(isDragSearchActive ? AppTheme.Colors.mtaBlue : AppTheme.Colors.accent)
                        Text(locationName ?? "Locating…")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    statusInline
                }
                Spacer(minLength: 4)
                if let weather = weatherSnapshot {
                    WeatherChipView(snapshot: weather, style: .compact)
                }
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                        .frame(width: 36, height: 36)
                        .background {
                            Circle()
                                .fill(AppTheme.Colors.cardInset.opacity(0.5))
                        }
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // ── Search bar ──
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                TextField("Search trains, buses, stations…", text: $searchText)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                    }
                }
                micButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background {
                Capsule()
                    .fill(AppTheme.Colors.cardInset.opacity(0.5))
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.bottom, 12)

            // ── Mode chips ──
            ModeFilterStrip(selectedMode: $selectedMode)
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

    // MARK: - Status Inline

    @ViewBuilder
    private var statusInline: some View {
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
                let formatter = Self.relativeFormatter
                Text("Updated \(formatter.localizedString(for: lastUpdated, relativeTo: .now))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
        }
    }
}

// MARK: - Mode Filter Strip

struct ModeFilterStrip: View {
    @Binding var selectedMode: TransportMode
    @Namespace private var modeNamespace
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TransportMode.allCases, id: \.self) { mode in
                    modeChip(for: mode)
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
        }
    }

    private func modeChip(for mode: TransportMode) -> some View {
        let isActive = selectedMode == mode
        return Button {
            // Animate only the pill highlight — NOT the model mutation.
            // wrapping selectedMode = mode in withAnimation propagated
            // the animation to every @Observable property change triggered
            // downstream (clearRoute, refresh, etc.), causing lag.
            selectedMode = mode
            HapticManager.impact(.light)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isActive ? .white : AppTheme.Colors.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    if isActive {
                        Capsule()
                            .fill(AppTheme.Colors.accent)
                            .matchedGeometryEffect(id: "modeHighlight", in: modeNamespace)
                    } else {
                        Capsule()
                            .strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 1)
                            .background(Capsule().fill(AppTheme.Colors.cardInset.opacity(0.3)))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        // Animate only the pill highlight slide — scoped so it doesn't
        // propagate to downstream model mutations.
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selectedMode)
    }
}

#Preview {
    ModalNavbar(
        searchText: .constant(""),
        showSettings: .constant(false),
        selectedMode: .constant(.nearby),
        lastUpdated: Date(),
        weatherSnapshot: .preview(.clear),
        locationName: "Chelsea"
    )
    .background(AppTheme.Colors.background)
}
