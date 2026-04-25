import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var supabase = SupabaseManager.shared

    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("distance_unit") private var distanceUnit = "mi"
    @AppStorage("dev_use_localhost") private var useLocalhost = false
    @AppStorage("dev_custom_ip") private var customIP = AppSettings.shared.defaultDeviceIP

    @State private var isPingingBackend = false
    @State private var backendPingText: String = "Not checked"
    @State private var backendPingIsHealthy: Bool? = nil

    private var currentProfile: UserProfile? { supabase.currentUser }

    private var displayNameForWelcome: String {
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

    var body: some View {
        NavigationStack {
            ZStack {
                ZStack {
                    AppTheme.Gradients.screen
                    AppTheme.Gradients.screenGlow
                }
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        profileSection
                        appearanceSection
                        accountSection
#if DEBUG
                        developerSection
#endif
                        aboutSection

                        Spacer()
                            .frame(height: 24)
                    }
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                }
            }
            // Auto-push settings to cloud when instant-apply values change
            .onChange(of: appTheme) { _, _ in
                Task { await SyncManager.shared.pushUserSettings() }
            }
            .onChange(of: distanceUnit) { _, _ in
                Task { await SyncManager.shared.pushUserSettings() }
            }
        }
    }

    private var profileSection: some View {
        settingsSection(
            title: "Profile",
            icon: "person.crop.circle.fill",
            iconColor: AppTheme.Colors.mtaBlue
        ) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(AppTheme.Colors.mtaBlue.opacity(0.14))
                            .frame(width: 38, height: 38)
                        Image(systemName: "person.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome, \(displayNameForWelcome)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Text(currentProfile?.email ?? "Signed in with Apple")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, AppTheme.Layout.cardPadding)
                .padding(.vertical, 14)

                settingsDivider

                NavigationLink {
                    ProfileSettingsView()
                } label: {
                    HStack {
                        settingsIcon("person.text.rectangle.fill", color: .indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Manage Profile")
                                .font(.custom("Helvetica", size: 15))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                            Text("Name, username, account details")
                                .font(.system(size: 11))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                    }
                    .padding(.horizontal, AppTheme.Layout.cardPadding)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var appearanceSection: some View {
        settingsSection(title: "Appearance", icon: "paintbrush.fill", iconColor: .purple) {
            VStack(spacing: 0) {
                settingsRow(icon: "circle.lefthalf.filled", iconColor: .indigo, title: "Theme") {
                    Picker("", selection: $appTheme) {
                        Text("System").tag("system")
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                    }
                    .pickerStyle(.menu)
                    .tint(AppTheme.Colors.mtaBlue)
                }

                settingsDivider

                settingsRow(icon: "ruler", iconColor: .orange, title: "Distance") {
                    Picker("", selection: $distanceUnit) {
                        Text("Miles").tag("mi")
                        Text("Kilometers").tag("km")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
            }
        }
    }

    private var accountSection: some View {
        settingsSection(title: "Account", icon: "person.fill", iconColor: AppTheme.Colors.mtaBlue) {
            Button {
                SupabaseManager.shared.signOut()
            } label: {
                HStack {
                    settingsIcon(
                        "rectangle.portrait.and.arrow.right",
                        color: AppTheme.Colors.alertRed
                    )
                    Text("Sign Out")
                        .font(.custom("Helvetica", size: 15))
                        .foregroundColor(AppTheme.Colors.alertRed)
                    Spacer()
                }
                .padding(.horizontal, AppTheme.Layout.cardPadding)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
        }
    }

#if DEBUG
    private var developerSection: some View {
        settingsSection(title: "Developer", icon: "hammer.fill", iconColor: .orange) {
            VStack(spacing: 0) {
                settingsRow(icon: "desktopcomputer", iconColor: .mint, title: "Use Local Server") {
                    Toggle("", isOn: $useLocalhost)
                        .tint(AppTheme.Colors.mtaBlue)
                        .onChange(of: useLocalhost) { _, _ in
                            TrackAPI.invalidateBaseURL()
                        }
                }

                if useLocalhost {
                    settingsDivider
                    HStack {
                        Text("http://")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        TextField("192.168.1.X", text: $customIP)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .keyboardType(.numbersAndPunctuation)
                            .onChange(of: customIP) { _, _ in
                                TrackAPI.invalidateBaseURL()
                            }
                        Text(":8000")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .padding(.horizontal, AppTheme.Layout.cardPadding)
                    .padding(.vertical, 12)
                }

                settingsDivider

                HStack {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                    Text("Active: \(TrackAPI.baseURL)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, AppTheme.Layout.cardPadding)
                .padding(.vertical, 8)

                settingsDivider

                HStack(spacing: 10) {
                    Circle()
                        .fill(
                            backendPingIsHealthy == nil
                                ? AppTheme.Colors.textSecondary.opacity(0.4)
                                : (backendPingIsHealthy == true
                                    ? AppTheme.Colors.successGreen
                                    : AppTheme.Colors.alertRed)
                        )
                        .frame(width: 8, height: 8)

                    Text(backendPingText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        Task { await pingBackend() }
                    } label: {
                        if isPingingBackend {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Ping")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .disabled(isPingingBackend)
                }
                .padding(.horizontal, AppTheme.Layout.cardPadding)
                .padding(.vertical, 10)
            }
        }
    }
#endif

    private var aboutSection: some View {
        settingsSection(
            title: "About",
            icon: "info.circle.fill",
            iconColor: AppTheme.Colors.mtaBlue
        ) {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Image("AppIconImage")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: AppTheme.Colors.subwayBlack.opacity(0.25), radius: 10, y: 4)

                    VStack(spacing: 4) {
                        Text("Track")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textPrimary)

                        Text("NYC Transit, Live")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }

                    if let info = Bundle.main.infoDictionary,
                       let version = info["CFBundleShortVersionString"] as? String,
                       let build = info["CFBundleVersion"] as? String {
                        Text("v\(version) (\(build))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(AppTheme.Colors.mtaBlue.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)

                settingsDivider

                VStack(spacing: 10) {
                    Text("SUPPORTED TRANSIT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                        .tracking(0.6)

                    HStack(spacing: 0) {
                        transitModeBadge("🚇", "Subway", AppTheme.Colors.mtaBlue)
                        transitModeBadge("🚌", "Bus",
                            Color(red: 0/255, green: 57/255, blue: 166/255))
                        transitModeBadge("🚂", "LIRR",
                            Color(red: 0/255, green: 115/255, blue: 191/255))
                        transitModeBadge("🚆", "MNR",
                            Color(red: 0/255, green: 90/255, blue: 140/255))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)

                settingsDivider

                VStack(spacing: 8) {
                    Text("POWERED BY")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                        .tracking(0.6)

                    HStack(spacing: 16) {
                        dataSourcePill("MTA GTFS")
                        dataSourcePill("Real-Time Feeds")
                        dataSourcePill("Apple Maps")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)

                settingsDivider

                VStack(spacing: 6) {
                    Text("Made with ❤️ in NYC")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)

                    Text("© \(Calendar.current.component(.year, from: Date())) Track NYC Transit")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
        }
    }

    private func transitModeBadge(_ emoji: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Text(emoji)
                .font(.system(size: 26))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
    }

    private func dataSourcePill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppTheme.Colors.textSecondary.opacity(0.08))
            .clipShape(Capsule())
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

    private var settingsDivider: some View {
        Divider()
            .padding(.leading, AppTheme.Layout.cardPadding + 36)
    }

    private func settingsIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func settingsRow<Trailing: View>(
        icon: String,
        iconColor: Color,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            settingsIcon(icon, color: iconColor)
            Text(title)
                .font(.custom("Helvetica", size: 15))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 12)
    }

    private func settingsSection<Content: View>(
        title: String,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(iconColor.opacity(0.7))
                SectionHeader(title: title, weight: .bold, tracking: 0.5)
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            content()
                .padding(.horizontal, AppTheme.Layout.margin)
                .trackCardBackground()
        }
    }
}

#Preview {
    SettingsView()
}
