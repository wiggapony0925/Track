// Trip settings — premium bottom sheet matching the TripResultsView
// design language. Accent gradient header, frosted glass cards,
// animated selections, and seamless visual continuity.

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
    @State private var appeared = false

    private var noModeSelected: Bool {
        !modeSubway && !modeBus && !modeLirr && !modeMnr
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Background
            AppTheme.Gradients.screen.ignoresSafeArea()
            AppTheme.Gradients.screenSheen.ignoresSafeArea()

            VStack(spacing: 0) {
                settingsHeader
                settingsScroll
            }

            // Floating apply button at bottom
            floatingApply
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(32)
        .onAppear { seedLocalState() }
    }

    // MARK: - Header (matches TripResultsView accent gradient)

    private var settingsHeader: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trip Settings")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Customize your route search")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }

                Spacer()

                // Close button — matches resultsView control bar style
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.14))
                                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                        )
                }
                .buttonStyle(SettingsButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: AppTheme.Colors.accent, location: 0),
                        .init(color: AppTheme.Colors.accentDeep, location: 0.55),
                        .init(color: AppTheme.Colors.accentDeep.opacity(0.95), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.0),
                        Color.black.opacity(0.08),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
    }

    // MARK: - Scrollable Content

    private var settingsScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                settingsCard("Route Priority", icon: "arrow.triangle.branch") {
                    priorityPicker
                }
                settingsCard("Transportation", icon: "tram.fill") {
                    modeToggles
                }
                settingsCard("Walking Distance", icon: "figure.walk") {
                    walkingSlider
                }
                settingsCard("Accessibility", icon: "figure.roll") {
                    accessibilityToggle
                }
                Spacer(minLength: 120)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Floating Apply

    private var floatingApply: some View {
        VStack {
            Spacer()
            applyButton
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
                .background(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: AppTheme.Colors.background.opacity(0.85), location: 0.25),
                            .init(color: AppTheme.Colors.background, location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)
                    .allowsHitTesting(false)
                )
        }
    }

    private func seedLocalState() {
        priority = config.resolvedPriority
        modeSubway = config.modeSubway
        modeBus = config.modeBus
        modeLirr = config.modeLirr
        modeMnr = config.modeMnr
        accessibility = config.accessibilityPriority
        walkSlider = config.walkPreference
        withAnimation(.easeOut(duration: 0.5).delay(0.1)) {
            appeared = true
        }
    }

    // MARK: - Apply Button

    private var applyButton: some View {
        Button {
            commit()
            onApply()
            dismiss()
        } label: {
            applyButtonLabel
        }
        .buttonStyle(SettingsButtonStyle())
        .disabled(noModeSelected)
        .opacity(noModeSelected ? 0.35 : 1)
        .animation(AppTheme.Animation.snappy, value: noModeSelected)
    }

    private var applyButtonLabel: some View {
        let borderGradient = LinearGradient(
            stops: [
                .init(color: .white.opacity(0.22), location: 0.0),
                .init(color: .white.opacity(0.06), location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .bold))
                .symbolEffect(.pulse, options: .repeating, isActive: !noModeSelected)
            Text("Apply & Search")
                .font(.system(size: 17, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 17)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.Gradients.accent)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderGradient, lineWidth: 0.75)
        )
        .shadow(color: AppTheme.Colors.accent.opacity(0.4), radius: 16, y: 8)
        .shadow(color: AppTheme.Colors.accentDeep.opacity(0.2), radius: 6, y: 3)
    }

    // MARK: - Priority Picker

    private var priorityPicker: some View {
        HStack(spacing: 8) {
            ForEach(TripPriority.allCases) { p in
                priorityButton(for: p, isSelected: priority == p)
            }
        }
    }

    private func priorityButton(for p: TripPriority, isSelected: Bool) -> some View {
        Button {
            withAnimation(AppTheme.Animation.snappy) {
                priority = p
            }
        } label: {
            priorityButtonLabel(p: p, isSelected: isSelected)
        }
        .buttonStyle(SettingsButtonStyle())
    }

    private func priorityButtonLabel(p: TripPriority, isSelected: Bool) -> some View {
        VStack(spacing: 7) {
            priorityIconCircle(p: p, isSelected: isSelected)

            Text(p.label)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    isSelected ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary
                )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? AppTheme.Colors.accentTint.opacity(0.6) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? AppTheme.Colors.accent.opacity(0.18) : Color.clear,
                    lineWidth: 0.75
                )
        )
    }

    private func priorityIconCircle(p: TripPriority, isSelected: Bool) -> some View {
        let gradient: LinearGradient = isSelected
            ? AppTheme.Gradients.accent
            : LinearGradient(
                colors: [AppTheme.Colors.cardElevated, AppTheme.Colors.cardInset],
                startPoint: .top, endPoint: .bottom
            )
        let borderColor = isSelected ? Color.white.opacity(0.2) : AppTheme.Colors.borderSubtle.opacity(0.3)
        let shadowColor = isSelected ? AppTheme.Colors.accent.opacity(0.35) : Color.clear

        return ZStack {
            Circle()
                .fill(gradient)
                .frame(width: 40, height: 40)
                .overlay(Circle().strokeBorder(borderColor, lineWidth: 0.75))
                .shadow(color: shadowColor, radius: 8, y: 3)

            Image(systemName: p.icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isSelected ? .white : AppTheme.Colors.textTertiary)
        }
    }

    // MARK: - Mode Toggles

    private var modeToggles: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                modeChip(
                    label: "Subway",
                    icon: "tram.fill",
                    color: AppTheme.Colors.accent,
                    isOn: $modeSubway
                )
                modeChip(
                    label: "Bus",
                    icon: "bus.fill",
                    color: AppTheme.BusColors.localBlue,
                    isOn: $modeBus
                )
            }
            HStack(spacing: 10) {
                modeChip(
                    label: "LIRR",
                    icon: "train.side.front.car",
                    color: AppTheme.CommuterRailColors.lirrBlue,
                    isOn: $modeLirr
                )
                modeChip(
                    label: "Metro-North",
                    icon: "train.side.front.car",
                    color: AppTheme.CommuterRailColors.mnrBlue,
                    isOn: $modeMnr
                )
            }

            // Warn if nothing is selected
            if noModeSelected {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("Select at least one mode")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                }
                .foregroundStyle(AppTheme.Colors.warningYellow)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.Colors.warningYellow.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(AppTheme.Colors.warningYellow.opacity(0.15), lineWidth: 0.5)
                        )
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)).combined(with: .move(edge: .top)))
            }
        }
    }

    private func modeChip(
        label: String, icon: String, color: Color, isOn: Binding<Bool>
    ) -> some View {
        let active = isOn.wrappedValue
        return Button {
            withAnimation(AppTheme.Animation.snappy) {
                isOn.wrappedValue.toggle()
            }
        } label: {
            modeChipLabel(label: label, icon: icon, color: color, active: active)
        }
        .buttonStyle(SettingsButtonStyle())
    }

    private func modeChipLabel(label: String, icon: String, color: Color, active: Bool) -> some View {
        let badgeFill = active ? color : AppTheme.Colors.cardInset
        let badgeBorder = active ? Color.white.opacity(0.15) : AppTheme.Colors.borderSubtle.opacity(0.2)
        let badgeShadow = active ? color.opacity(0.3) : Color.clear
        let checkFill = active ? color : AppTheme.Colors.cardInset
        let checkBorder = active ? color.opacity(0.5) : AppTheme.Colors.borderSubtle.opacity(0.3)
        let chipTint = active ? color.opacity(0.06) : Color.clear
        let chipBorder = active ? color.opacity(0.18) : AppTheme.Colors.borderSubtle.opacity(0.12)

        return HStack(spacing: 10) {
            // Mode icon badge
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(badgeFill)
                    .frame(width: 30, height: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(badgeBorder, lineWidth: 0.5)
                    )
                    .shadow(color: badgeShadow, radius: 4, y: 2)

                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(active ? .white : AppTheme.Colors.textTertiary)
            }

            Text(label)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(active ? AppTheme.Colors.textPrimary : AppTheme.Colors.textTertiary)
                .lineLimit(1)

            Spacer()

            // Checkmark indicator
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(checkFill)
                    .frame(width: 24, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(checkBorder, lineWidth: 1)
                    )

                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Colors.cardElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(chipTint)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(chipBorder, lineWidth: 0.75)
                )
        )
        .shadow(color: AppTheme.Colors.shadow.opacity(0.04), radius: 4, y: 2)
    }

    // MARK: - Walking Slider

    private var walkingSlider: some View {
        VStack(spacing: 14) {
            // Walking label pill
            HStack(spacing: 8) {
                Image(systemName: walkingIcon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .contentTransition(.symbolEffect(.replace))

                Text(walkingLabel)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .contentTransition(.numericText())

                Spacer()

                Text(walkingDistance)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .contentTransition(.numericText())
            }

            // Slider with end labels
            VStack(spacing: 6) {
                Slider(value: $walkSlider, in: 0...1, step: 0.1) {
                    Text("Walking")
                }
                .tint(AppTheme.Colors.accent)

                HStack {
                    Text("Less walking")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                    Spacer()
                    Text("More walking")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
            }
        }
    }

    private var walkingIcon: String {
        if walkSlider < 0.25 { return "figure.stand" }
        if walkSlider < 0.65 { return "figure.walk" }
        return "figure.run"
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

    private var walkingDistance: String {
        let meters = Int(400 + (walkSlider * 2100))
        let blocks = Int(round(Double(meters) / 80.0))
        return "~\(blocks) blocks"
    }

    // MARK: - Accessibility Toggle

    private var accessibilityToggle: some View {
        Button {
            withAnimation(AppTheme.Animation.snappy) {
                accessibility.toggle()
            }
        } label: {
            accessibilityButtonContent
        }
        .buttonStyle(SettingsButtonStyle())
    }

    private var accessibilityButtonContent: some View {
        HStack(spacing: 12) {
            accessibilityIconBadge
            accessibilityLabels
            Spacer()
            accessibilitySwitch
        }
    }

    private var accessibilityIconBadge: some View {
        let gradient: LinearGradient = accessibility
            ? AppTheme.Gradients.accent
            : LinearGradient(
                colors: [AppTheme.Colors.cardElevated, AppTheme.Colors.cardInset],
                startPoint: .top, endPoint: .bottom
            )
        let borderColor = accessibility ? Color.white.opacity(0.18) : AppTheme.Colors.borderSubtle.opacity(0.25)
        let shadowColor = accessibility ? AppTheme.Colors.accent.opacity(0.3) : Color.clear

        return ZStack {
            Circle()
                .fill(gradient)
                .frame(width: 38, height: 38)
                .overlay(Circle().strokeBorder(borderColor, lineWidth: 0.75))
                .shadow(color: shadowColor, radius: 6, y: 3)

            Image(systemName: "figure.roll")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(accessibility ? .white : AppTheme.Colors.textTertiary)
        }
    }

    private var accessibilityLabels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Wheelchair Accessible")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Text("Prefer accessible stations & elevators")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.Colors.textTertiary)
        }
    }

    private var accessibilitySwitch: some View {
        let trackGradient: LinearGradient = accessibility
            ? AppTheme.Gradients.accent
            : LinearGradient(
                colors: [AppTheme.Colors.cardInset, AppTheme.Colors.cardInset],
                startPoint: .leading, endPoint: .trailing
            )
        let trackBorder = accessibility ? Color.white.opacity(0.15) : AppTheme.Colors.borderSubtle.opacity(0.25)

        return ZStack {
            Capsule()
                .fill(trackGradient)
                .frame(width: 48, height: 28)
                .overlay(Capsule().strokeBorder(trackBorder, lineWidth: 0.75))

            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .offset(x: accessibility ? 10 : -10)
        }
    }

    // MARK: - Settings Card Container

    private func settingsCard<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCardHeader(title: title, icon: icon)
            content()
        }
        .padding(16)
        .background(settingsCardBackground)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
    }

    private func settingsCardHeader(title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppTheme.Colors.accent)

            Text(title.uppercased())
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textTertiary)
                .tracking(1.0)
        }
        .padding(.leading, 4)
    }

    private var settingsCardBackground: some View {
        let borderGradient = LinearGradient(
            stops: [
                .init(color: AppTheme.Colors.glassHighlight.opacity(0.12), location: 0.0),
                .init(color: AppTheme.Colors.borderSubtle.opacity(0.08), location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.Gradients.chromeHighlight)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(borderGradient, lineWidth: 0.75)
            )
            .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 8, y: 4)
            .shadow(color: AppTheme.Colors.shadowStrong.opacity(0.03), radius: 16, y: 8)
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
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
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
