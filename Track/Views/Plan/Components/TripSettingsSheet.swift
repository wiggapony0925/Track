// Trip settings — bottom sheet matching the app's theme.
// Presented via .sheet from TripResultsView with an "Apply"
// button that re-plans trips and dismisses.

import SwiftUI

struct TripSettingsSheet: View {
    @Binding var config: CloudTripConfiguration
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    // Local editing state so we can animate smoothly
    @State private var priority: TripPriority = .quick
    @State private var modeSubway = true
    @State private var modeBus = true
    @State private var modeLirr = false
    @State private var modeMnr = false
    @State private var accessibility = false
    @State private var walkSlider: Float = 0.5

    var body: some View {
        VStack(spacing: 0) {
            dragHandle

            // Title bar
            HStack {
                Text("Trip Settings")
                    .font(AppTheme.Typography.sheetTitle)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 18)

            Divider()
                .overlay(AppTheme.Colors.borderSubtle.opacity(0.4))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 24) {
                    // ── Priority ──
                    settingsSection("Priority") {
                        priorityPicker
                    }

                    // ── Transportation ──
                    settingsSection("Transportation") {
                        modeToggles
                    }

                    // ── Walking ──
                    settingsSection("Walking Distance") {
                        walkingSlider
                    }

                    // ── Accessibility ──
                    settingsSection("Accessibility") {
                        accessibilityToggle
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)
            }

            Spacer(minLength: 0)

            applyButton
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
        }
        .background(AppTheme.Colors.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(32)
        .onAppear {
            // Seed local state from binding
            priority = config.resolvedPriority
            modeSubway = config.modeSubway
            modeBus = config.modeBus
            modeLirr = config.modeLirr
            modeMnr = config.modeMnr
            accessibility = config.accessibilityPriority
            walkSlider = config.walkPreference
        }
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        Capsule()
            .fill(AppTheme.Colors.textTertiary.opacity(0.25))
            .frame(width: 36, height: 5)
            .padding(.top, 10)
    }

    // MARK: - Apply Button

    private var applyButton: some View {
        Button {
            commit()
            onApply()
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .bold))
                Text("Apply & Search")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: AppTheme.Colors.accent.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(SettingsButtonStyle())
        .disabled(!modeSubway && !modeBus && !modeLirr && !modeMnr)
        .opacity(!modeSubway && !modeBus && !modeLirr && !modeMnr ? 0.4 : 1)
    }

    // MARK: - Priority Picker

    private var priorityPicker: some View {
        HStack(spacing: 8) {
            ForEach(TripPriority.allCases) { p in
                Button {
                    withAnimation(AppTheme.Animation.snappy) {
                        priority = p
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: p.icon)
                            .font(.system(size: 11, weight: .bold))
                        Text(p.label)
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(priority == p ? .white : AppTheme.Colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                priority == p
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        )
                                    )
                                    : AnyShapeStyle(AppTheme.Colors.cardInset)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                priority == p
                                    ? .white.opacity(0.15)
                                    : AppTheme.Colors.borderSubtle.opacity(0.2),
                                lineWidth: 0.5
                            )
                    )
                }
                .buttonStyle(SettingsButtonStyle())
            }
        }
    }

    // MARK: - Mode Toggles

    private var modeToggles: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                modeChip(
                    label: "Subway",
                    icon: "tram.fill",
                    color: AppTheme.Colors.accent,
                    isOn: $modeSubway
                )
                modeChip(
                    label: "Bus",
                    icon: "bus.fill",
                    color: Color(red: 0, green: 0.47, blue: 0.78),
                    isOn: $modeBus
                )
            }
            HStack(spacing: 8) {
                modeChip(
                    label: "LIRR",
                    icon: "train.side.front.car",
                    color: AppTheme.Colors.successGreen,
                    isOn: $modeLirr
                )
                modeChip(
                    label: "Metro-North",
                    icon: "train.side.front.car",
                    color: Color(red: 0, green: 0.33, blue: 0.58),
                    isOn: $modeMnr
                )
            }

            // Warn if nothing is selected
            if !modeSubway && !modeBus && !modeLirr && !modeMnr {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("Select at least one mode")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundStyle(AppTheme.Colors.warningYellow)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func modeChip(
        label: String, icon: String, color: Color, isOn: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(AppTheme.Animation.snappy) {
                isOn.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isOn.wrappedValue ? color : AppTheme.Colors.textTertiary)

                Text(label)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(isOn.wrappedValue ? AppTheme.Colors.textPrimary : AppTheme.Colors.textTertiary)

                Spacer()

                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn.wrappedValue ? color : AppTheme.Colors.cardInset)
                        .frame(width: 22, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    isOn.wrappedValue ? color.opacity(0.6) : AppTheme.Colors.borderSubtle.opacity(0.3),
                                    lineWidth: 1
                                )
                        )

                    if isOn.wrappedValue {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isOn.wrappedValue
                            ? color.opacity(0.08)
                            : AppTheme.Colors.cardInset.opacity(0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isOn.wrappedValue
                                    ? color.opacity(0.2)
                                    : AppTheme.Colors.borderSubtle.opacity(0.15),
                                lineWidth: 0.5
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
    }

    // MARK: - Walking Slider

    private var walkingSlider: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "figure.stand")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                Text("Less")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textTertiary)

                Spacer()

                Text(walkingLabel)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .contentTransition(.numericText())

                Spacer()

                Text("More")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                Image(systemName: "figure.walk")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
            }

            Slider(value: $walkSlider, in: 0...1, step: 0.1) {
                Text("Walking")
            }
            .tint(AppTheme.Colors.accent)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Colors.cardInset.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    private var walkingLabel: String {
        if walkSlider < 0.25 {
            return "Minimal"
        } else if walkSlider < 0.45 {
            return "Short"
        } else if walkSlider < 0.65 {
            return "Balanced"
        } else if walkSlider < 0.85 {
            return "Moderate"
        } else {
            return "Long"
        }
    }

    // MARK: - Accessibility Toggle

    private var accessibilityToggle: some View {
        Button {
            withAnimation(AppTheme.Animation.snappy) {
                accessibility.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "figure.roll")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(
                        accessibility
                            ? AppTheme.Colors.accent
                            : AppTheme.Colors.textTertiary
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility Priority")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text("Prefer wheelchair-accessible stations")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }

                Spacer()

                ZStack {
                    Capsule()
                        .fill(accessibility ? AppTheme.Colors.accent : AppTheme.Colors.cardInset)
                        .frame(width: 44, height: 26)
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    accessibility
                                        ? AppTheme.Colors.accent.opacity(0.5)
                                        : AppTheme.Colors.borderSubtle.opacity(0.25),
                                    lineWidth: 1
                                )
                        )

                    Circle()
                        .fill(.white)
                        .frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .offset(x: accessibility ? 9 : -9)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        accessibility
                            ? AppTheme.Colors.accent.opacity(0.06)
                            : AppTheme.Colors.cardInset.opacity(0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                accessibility
                                    ? AppTheme.Colors.accent.opacity(0.15)
                                    : AppTheme.Colors.borderSubtle.opacity(0.15),
                                lineWidth: 0.5
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
    }

    // MARK: - Helpers

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(AppTheme.Typography.sectionHeader)
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.leading, 4)

            content()
        }
    }

    /// Push local edits back to the binding.
    private func commit() {
        config.priority = priority.rawValue
        config.modeSubway = modeSubway
        config.modeBus = modeBus
        config.modeLirr = modeLirr
        config.modeMnr = modeMnr
        config.accessibilityPriority = accessibility
        config.walkPreference = walkSlider
    }
}

// MARK: - Button Style

private struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    ZStack {
        AppTheme.Gradients.screen.ignoresSafeArea()
        Color.clear
            .sheet(isPresented: .constant(true)) {
                TripSettingsSheet(
                    config: .constant(CloudTripConfiguration.makeDefault(userId: UUID())),
                    onApply: {}
                )
            }
    }
    .preferredColorScheme(.dark)
}
