import SwiftUI

struct SettingsView: View {
    @ObservedObject private var supabase = SupabaseManager.shared

    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("distance_unit") private var distanceUnit = "mi"
    @AppStorage("dev_use_localhost") private var useLocalhost = false
    @AppStorage("dev_custom_ip") private var customIP = AppSettings.shared.defaultDeviceIP

    @State private var isPingingBackend = false
    @State private var backendPingText: String = "Not checked"
    @State private var backendPingIsHealthy: Bool? = nil

    private var currentProfile: UserProfile? { supabase.currentUser }

    private var displayName: String {
        if let fullName = currentProfile?.fullName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fullName.isEmpty {
            return fullName
        }
        if let givenName = currentProfile?.givenName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !givenName.isEmpty {
            return givenName
        }
        if let username = currentProfile?.username?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !username.isEmpty {
            return username
        }
        if let email = currentProfile?.email, !email.isEmpty {
            return email.components(separatedBy: "@").first ?? "there"
        }
        return "there"
    }

    private var backendStatusColor: Color {
        if backendPingIsHealthy == true { return AppTheme.Colors.successGreen }
        if backendPingIsHealthy == false { return AppTheme.Colors.alertRed }
        return AppTheme.Colors.textTertiary.opacity(0.55)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Colors.background
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        profileCard
                        preferencesSection
                        accountSection
                        #if DEBUG
                        backendSection
                        #endif
                        aboutSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 104)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: appTheme) { _, _ in syncSettings() }
            .onChange(of: distanceUnit) { _, _ in syncSettings() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Text("Account, appearance, and app controls")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var profileCard: some View {
        NavigationLink {
            ProfileSettingsView()
        } label: {
            HStack(spacing: 14) {
                avatar

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(currentProfile?.email ?? "Signed in with Apple")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                    Text("Manage profile")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundColor(AppTheme.Colors.accent)
                        .padding(.top, 4)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
            .padding(16)
            .settingsPanel()
        }
        .buttonStyle(.plain)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Colors.accent.opacity(0.14))
                .frame(width: 58, height: 58)
            Circle()
                .stroke(AppTheme.Colors.accent.opacity(0.22), lineWidth: 1)
                .frame(width: 58, height: 58)
            Text(String(displayName.prefix(1)).uppercased())
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.accent)
        }
    }

    private var preferencesSection: some View {
        settingsSection(title: "Preferences", icon: "slider.horizontal.3") {
            VStack(spacing: 16) {
                preferenceControlBlock(
                    icon: "circle.lefthalf.filled",
                    tint: AppTheme.Colors.accent,
                    title: "Theme",
                    subtitle: "Choose how Track follows your display"
                ) {
                    segmentedPicker(
                        selection: $appTheme,
                        options: [
                            ("system", "System"),
                            ("light", "Light"),
                            ("dark", "Dark"),
                        ]
                    )
                }

                preferenceControlBlock(
                    icon: "ruler",
                    tint: AppTheme.Colors.warningYellow,
                    title: "Distance",
                    subtitle: "Sets every distance label in the app"
                ) {
                    segmentedPicker(
                        selection: $distanceUnit,
                        options: [("mi", "Miles"), ("km", "Km")]
                    )
                }
            }
        }
    }

    private var accountSection: some View {
        settingsSection(title: "Account", icon: "person.crop.circle") {
            Button {
                SupabaseManager.shared.signOut()
            } label: {
                HStack(spacing: 12) {
                    iconTile("rectangle.portrait.and.arrow.right", color: AppTheme.Colors.alertRed)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign Out")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundColor(AppTheme.Colors.alertRed)
                        Text("End the current account session")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .settingsPanel()
            }
            .buttonStyle(.plain)
        }
    }

    #if DEBUG
    private var backendSection: some View {
        settingsSection(title: "Developer", icon: "hammer.fill") {
            VStack(spacing: 14) {
                settingBlock(
                    icon: "desktopcomputer",
                    tint: AppTheme.Colors.successGreen,
                    title: "Local Server",
                    subtitle: useLocalhost ? "Requests target your dev backend" : "Requests target production"
                ) {
                    Toggle("", isOn: $useLocalhost)
                        .labelsHidden()
                        .tint(AppTheme.Colors.accent)
                        .onChange(of: useLocalhost) { _, _ in
                            TrackAPI.invalidateBaseURL()
                        }
                }

                if useLocalhost {
                    HStack(spacing: 6) {
                        Text("http://")
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        TextField("127.0.0.1", text: $customIP)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .onChange(of: customIP) { _, _ in
                                TrackAPI.invalidateBaseURL()
                            }
                        Text(":8000")
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.Colors.cardInset.opacity(0.78))
                    )
                }

                HStack(spacing: 10) {
                    Circle()
                        .fill(backendStatusColor)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TrackAPI.baseURL)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                        Text(backendPingText)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Button { Task { await pingBackend() } } label: {
                        if isPingingBackend {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Ping")
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                        }
                    }
                    .disabled(isPingingBackend)
                    .foregroundColor(AppTheme.Colors.accent)
                }
                .padding(.horizontal, 2)
            }
            .padding(14)
            .settingsPanel()
        }
    }
    #endif

    private var aboutSection: some View {
        settingsSection(title: "About", icon: "info.circle.fill") {
            VStack(spacing: 14) {
                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 66, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: AppTheme.Colors.shadow.opacity(0.18), radius: 12, y: 5)

                VStack(spacing: 4) {
                    Text("Track")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("NYC Transit, Live")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }

                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Text("v\(version) (\(build))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(AppTheme.Colors.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .settingsPanel()
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AppTheme.Colors.accent.opacity(0.85))
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .tracking(0.8)
            }
            .padding(.horizontal, 4)

            content()
        }
    }

    private func settingBlock<Trailing: View>(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            iconTile(icon, color: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(14)
        .settingsPanel()
    }

    private func preferenceControlBlock<Trailing: View>(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                iconTile(icon, color: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer(minLength: 0)
            }

            trailing()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .settingsPanel()
    }

    private func iconTile(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(color)
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.13))
            )
    }

    private func segmentedPicker(
        selection: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selection.wrappedValue = value
                } label: {
                    Text(label)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundColor(selection.wrappedValue == value ? .white : AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(minWidth: 54)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(selection.wrappedValue == value ? AppTheme.Colors.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(AppTheme.Colors.cardInset.opacity(0.9))
        )
    }

    private func pingBackend() async {
        isPingingBackend = true
        let result = await TrackAPI.pingBackend()
        isPingingBackend = false

        if result.ok {
            backendPingIsHealthy = true
            let ms = Int((result.latencyMs ?? 0).rounded())
            backendPingText = "Connected (\(result.statusCode ?? 200), \(ms)ms)"
        } else {
            backendPingIsHealthy = false
            if let status = result.statusCode {
                backendPingText = "Failed (HTTP \(status))"
            } else {
                backendPingText = "Failed (\(result.error ?? "unknown"))"
            }
        }
    }

    private func syncSettings() {
        Task { await SyncManager.shared.pushUserSettings() }
    }
}

private struct SettingsPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(AppTheme.Colors.borderSubtle.opacity(0.5), lineWidth: 1)
                    )
                    .shadow(color: AppTheme.Colors.shadow.opacity(0.08), radius: 14, y: 5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private extension View {
    func settingsPanel() -> some View {
        modifier(SettingsPanelModifier())
    }
}

#Preview {
    SettingsView()
}