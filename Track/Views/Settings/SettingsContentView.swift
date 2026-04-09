// Settings content displayed within the universal bottom sheet.
// Uses the Track design system: grouped card sections, tinted icons,
// glassmorphic surfaces, and the accent purple palette.
//
// API-affecting settings (radius, map toggles) use local @State drafts.
// Changes are committed to @AppStorage only when the user taps Apply.
// Visual-only settings (theme, unit, haptics) take effect immediately.

import SwiftUI

struct SettingsContentView: View {
    @ObservedObject private var supabase = SupabaseManager.shared

    // MARK: - Instant-Apply (visual only)
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("distance_unit") private var distanceUnit = "mi"
    @AppStorage("haptics_enabled") private var hapticsEnabled = true

    // MARK: - Persisted (written on Apply)
    @AppStorage("near_you_radius_meters") private var nearYouRadius: Double = 2414
    @AppStorage("farther_away_radius_meters") private var fartherAwayRadius: Double = 4023
    @AppStorage("much_farther_away_radius_meters") private var muchFartherAwayRadius: Double = 8047
    @AppStorage("show_search_radius") private var showSearchRadius = false
    @AppStorage("drag_to_search") private var dragToSearch = true

    // MARK: - Draft State
    @State private var draftRadius: Double = 8047
    @State private var draftShowSearchRadius = false
    @State private var draftDragToSearch = true
    @State private var hasUnappliedChanges = false
    @State private var showAppliedConfirmation = false

    let sheetNavigator: SheetNavigator

    // MARK: - Computed

    private var currentProfile: UserProfile? { supabase.currentUser }

    private var displayName: String {
        if let n = currentProfile?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty { return n }
        if let n = currentProfile?.givenName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty { return n }
        if let n = currentProfile?.username?.trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty { return n }
        if let e = currentProfile?.email, !e.isEmpty {
            return e.components(separatedBy: "@").first ?? "there"
        }
        return "there"
    }

    private var draftDerivedNearRadius: Double {
        max(400, (draftRadius * 0.40 / 100).rounded() * 100)
    }
    private var draftDerivedFartherRadius: Double {
        max(draftDerivedNearRadius + 400, (draftRadius * 0.65 / 100).rounded() * 100)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            scrollBody
        }
        .trackScreenBackground()
        .overlay(alignment: .bottom) { overlayContent }
        .onAppear { loadDrafts() }
        .onChange(of: draftRadius) { _, _ in checkForChanges() }
        .onChange(of: draftShowSearchRadius) { _, _ in checkForChanges() }
        .onChange(of: draftDragToSearch) { _, _ in checkForChanges() }
        .onChange(of: appTheme) { _, _ in syncSettings() }
        .onChange(of: hapticsEnabled) { _, _ in syncSettings() }
        .onChange(of: distanceUnit) { _, _ in syncSettings() }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: hasUnappliedChanges)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showAppliedConfirmation)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Settings")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                HStack {
                    Button {
                        sheetNavigator.goBack()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                            Text("Home")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(AppTheme.Colors.mtaBlue.opacity(0.1))
                        )
                    }

                    Spacer()

                    Button {
                        sheetNavigator.popToRoot()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                AppTheme.Colors.textTertiary.opacity(0.7),
                                AppTheme.Colors.textTertiary.opacity(0.12)
                            )
                    }
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 10)
            .padding(.bottom, 12)

            Rectangle()
                .fill(AppTheme.Colors.borderSubtle.opacity(0.5))
                .frame(height: 1)
        }
    }

    // MARK: - Scroll Body

    private var scrollBody: some View {
        ScrollView {
            VStack(spacing: 28) {
                profileCard
                appearanceCard
                widgetsCard
                radiusCard
                mapCard
                accountCard
                #if DEBUG
                developerCard
                #endif
                aboutCard

                // Bottom breathing room for Apply overlay
                Spacer().frame(height: 60)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Overlay

    @ViewBuilder
    private var overlayContent: some View {
        if hasUnappliedChanges {
            applyButton
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if showAppliedConfirmation {
            appliedBadge
                .transition(.scale.combined(with: .opacity))
        }
    }

    // ============================================================
    // MARK: - Profile
    // ============================================================

    private var profileCard: some View {
        section("Profile") {
            VStack(spacing: 0) {
                // Hero identity area
                VStack(spacing: 10) {
                    // Avatar with gradient ring
                    ZStack {
                        Circle()
                            .stroke(
                                AngularGradient(
                                    colors: [
                                        AppTheme.Colors.mtaBlue,
                                        AppTheme.Colors.mtaBlue.opacity(0.4),
                                        AppTheme.Colors.accentSecondary,
                                        AppTheme.Colors.mtaBlue,
                                    ],
                                    center: .center
                                ),
                                lineWidth: 2.5
                            )
                            .frame(width: 58, height: 58)

                        Circle()
                            .fill(
                                AppTheme.Gradients.tintWash(
                                    AppTheme.Colors.mtaBlue, intensity: 0.15
                                )
                            )
                            .frame(width: 52, height: 52)

                        Text(String(displayName.prefix(1)).uppercased())
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                    }

                    VStack(spacing: 3) {
                        Text(displayName)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .lineLimit(1)

                        Text(currentProfile?.email ?? "Signed in with Apple")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }

                    // Member since pill
                    if let joined = currentProfile?.createdAt {
                        Text("Member since \(joined, format: .dateTime.month(.wide).year())")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(AppTheme.Colors.textTertiary.opacity(0.08))
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)

                divider
                    .padding(.leading, 0) // full-width divider

                // Manage Profile row
                Button {
                    sheetNavigator.navigate(to: .profileSettings)
                } label: {
                    HStack(spacing: 10) {
                        iconBadge("person.text.rectangle.fill", color: .indigo)
                        Text("Manage Profile")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                        Spacer()
                        navChevron
                    }
                    .padding(.horizontal, AppTheme.Layout.cardPadding)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // ============================================================
    // MARK: - Appearance
    // ============================================================

    private var appearanceCard: some View {
        section("Appearance") {
            VStack(spacing: 0) {
                // Theme
                row(icon: "circle.lefthalf.filled", color: .indigo, title: "Theme") {
                    Picker("", selection: $appTheme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.menu)
                    .tint(AppTheme.Colors.mtaBlue)
                }

                divider

                // Distance unit
                row(icon: "ruler", color: .orange, title: "Distance") {
                    Picker("", selection: $distanceUnit) {
                        Text("Miles").tag("mi")
                        Text("Kilometers").tag("km")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                divider

                // Haptics
                row(icon: "waveform", color: .pink, title: "Haptics") {
                    Toggle("", isOn: $hapticsEnabled)
                        .tint(AppTheme.Colors.mtaBlue)
                        .labelsHidden()
                }
            }
        }
    }

    // ============================================================
    // MARK: - Widgets
    // ============================================================

    private var widgetsCard: some View {
        section("Widgets") {
            navRow(
                icon: "calendar.badge.clock",
                color: .cyan,
                title: "Widget Schedules",
                subtitle: "Configure home screen widgets"
            ) {
                sheetNavigator.navigate(to: .widgetSchedules)
            }
        }
    }

    // ============================================================
    // MARK: - Search Radius
    // ============================================================

    private var radiusCard: some View {
        section("Search Radius") {
            VStack(spacing: 0) {
                // Slider
                VStack(spacing: 10) {
                    HStack {
                        iconBadge("scope", color: AppTheme.Colors.mtaBlue)
                        Text("Max Radius")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                        Spacer()
                        Text(formatDistanceMiles(draftRadius))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(AppTheme.Colors.mtaBlue.opacity(0.12))
                            )
                    }

                    Slider(value: $draftRadius, in: 2400...16093, step: 200)
                        .tint(AppTheme.Colors.mtaBlue)
                }
                .padding(.horizontal, AppTheme.Layout.cardPadding)
                .padding(.vertical, 14)

                divider

                // Tier breakdown
                VStack(alignment: .leading, spacing: 8) {
                    tierRow(
                        icon: "location.fill",
                        label: "Near You",
                        meters: draftDerivedNearRadius,
                        color: AppTheme.Colors.successGreen
                    )
                    tierRow(
                        icon: "figure.walk",
                        label: "A Bit Farther",
                        meters: draftDerivedFartherRadius,
                        color: AppTheme.Colors.mtaBlue
                    )
                    tierRow(
                        icon: "car.fill",
                        label: "Much Farther",
                        meters: draftRadius,
                        color: AppTheme.Colors.warningYellow
                    )

                    // Stacked tier bar
                    tierBar
                        .padding(.top, 4)
                }
                .padding(.horizontal, AppTheme.Layout.cardPadding)
                .padding(.vertical, 12)

                divider

                // Presets
                HStack(spacing: 8) {
                    presetPill(
                        label: "Walking", icon: "figure.walk",
                        much: 3200, color: AppTheme.Colors.successGreen
                    )
                    presetPill(
                        label: "Default", icon: "target",
                        much: AppSettings.shared.defaultMuchFartherAwayRadiusMeters,
                        color: AppTheme.Colors.mtaBlue
                    )
                    presetPill(
                        label: "Wide", icon: "car.fill",
                        much: 16093, color: AppTheme.Colors.warningYellow
                    )
                }
                .padding(.horizontal, AppTheme.Layout.cardPadding)
                .padding(.vertical, 12)

                divider

                // Info footer
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                        .padding(.top, 1)
                    Text(
                        "Drag the slider to set how far to search."
                        + " Arrivals are grouped into three distance"
                        + " tiers in the Nearby tab."
                    )
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, AppTheme.Layout.cardPadding)
                .padding(.vertical, 10)
            }
        }
    }

    // ============================================================
    // MARK: - Map & Display
    // ============================================================

    private var mapCard: some View {
        section("Map & Display") {
            VStack(spacing: 0) {
                row(
                    icon: "circle.dashed",
                    color: .orange,
                    title: "Show Radius Rings"
                ) {
                    Toggle("", isOn: $draftShowSearchRadius)
                        .tint(AppTheme.Colors.mtaBlue)
                        .labelsHidden()
                }

                if draftShowSearchRadius {
                    HStack(spacing: 14) {
                        legendDot(color: AppTheme.Colors.successGreen, label: "Near")
                        legendDot(color: AppTheme.Colors.mtaBlue, label: "Farther")
                        legendDot(color: AppTheme.Colors.warningYellow, label: "Much Farther")
                    }
                    .padding(.horizontal, AppTheme.Layout.cardPadding)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                divider

                row(
                    icon: "hand.draw.fill",
                    color: AppTheme.Colors.mtaBlue,
                    title: "Drag to Search"
                ) {
                    Toggle("", isOn: $draftDragToSearch)
                        .tint(AppTheme.Colors.mtaBlue)
                        .labelsHidden()
                }

                if draftDragToSearch {
                    Text("Pan the map to explore transit at a different location")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                        .padding(.horizontal, AppTheme.Layout.cardPadding)
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // ============================================================
    // MARK: - Account
    // ============================================================

    private var accountCard: some View {
        section("Account") {
            Button {
                SupabaseManager.shared.signOut()
                sheetNavigator.popToRoot()
            } label: {
                HStack(spacing: 10) {
                    iconBadge("rectangle.portrait.and.arrow.right", color: AppTheme.Colors.alertRed)
                    Text("Sign Out")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppTheme.Colors.alertRed)
                    Spacer()
                }
                .padding(.horizontal, AppTheme.Layout.cardPadding)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // ============================================================
    // MARK: - Developer (DEBUG)
    // ============================================================

    #if DEBUG
    private var developerCard: some View {
        section("Developer") {
            navRow(
                icon: "wrench.and.screwdriver.fill",
                color: .orange,
                title: "Developer Settings",
                subtitle: "Local backend, connectivity"
            ) {
                sheetNavigator.navigate(to: .developerSettings)
            }
        }
    }
    #endif

    // ============================================================
    // MARK: - About
    // ============================================================

    private var aboutCard: some View {
        section("About") {
            VStack(spacing: 0) {
                aboutHero
                aboutSeparator
                aboutTransitGrid
                aboutSeparator
                aboutPoweredBy
                aboutSeparator
                aboutLinks
                aboutSeparator
                aboutDisclaimer
                aboutSeparator
                aboutFooterView
            }
        }
    }

    // MARK: About > Hero

    private var aboutHero: some View {
        VStack(spacing: 14) {
            // App icon with accent glow ring
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                AppTheme.Colors.mtaBlue.opacity(0.12),
                                AppTheme.Colors.accentSecondary.opacity(0.06),
                                Color.clear,
                            ],
                            center: .center, startRadius: 28, endRadius: 64
                        )
                    )
                    .frame(width: 110, height: 110)

                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.25),
                                        AppTheme.Colors.mtaBlue.opacity(0.15),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: AppTheme.Colors.shadow.opacity(0.16), radius: 12, y: 5)
            }

            VStack(spacing: 4) {
                Text("Track")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text("Real-time NYC transit companion")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }

            // Version pill
            if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            {
                HStack(spacing: 6) {
                    Image(systemName: "app.badge.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("v\(v)")
                    Text("·")
                        .foregroundColor(AppTheme.Colors.mtaBlue.opacity(0.4))
                    Text("Build \(b)")
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(AppTheme.Colors.mtaBlue)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(AppTheme.Colors.mtaBlue.opacity(0.08))
                        .overlay(
                            Capsule()
                                .stroke(AppTheme.Colors.mtaBlue.opacity(0.12), lineWidth: 1)
                        )
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: About > Transit Modes

    private var aboutTransitGrid: some View {
        VStack(spacing: 10) {
            miniLabel("SUPPORTED TRANSIT")
            HStack(spacing: 0) {
                modeChip(icon: "tram.fill", name: "Subway", color: AppTheme.Colors.mtaBlue)
                modeChip(icon: "bus.fill", name: "Bus", color: AppTheme.BusColors.localBlue)
                modeChip(
                    icon: "train.side.front.car", name: "LIRR",
                    color: AppTheme.CommuterRailColors.lirrBlue
                )
                modeChip(
                    icon: "train.side.front.car", name: "MNR",
                    color: AppTheme.CommuterRailColors.mnrBlue
                )
            }
            .padding(.horizontal, AppTheme.Layout.cardPadding)
        }
        .padding(.vertical, 14)
    }

    // MARK: About > Powered By

    private var aboutPoweredBy: some View {
        VStack(spacing: 10) {
            miniLabel("DATA SOURCES")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    sourceChip(icon: "antenna.radiowaves.left.and.right", text: "MTA GTFS-RT")
                    sourceChip(icon: "bolt.fill", text: "MTA Bus Time")
                    sourceChip(icon: "bell.badge.fill", text: "MTA Alerts")
                    sourceChip(icon: "clock.arrow.circlepath", text: "Live Feeds")
                }
                .padding(.horizontal, AppTheme.Layout.cardPadding)
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: About > Links

    private var aboutLinks: some View {
        VStack(spacing: 0) {
            miniLabel("LINKS")
                .padding(.top, 12)
                .padding(.bottom, 6)

            linkRow(
                icon: "star.fill", color: .orange,
                title: "Rate on the App Store",
                subtitle: "Your review helps us grow"
            ) {
                if let url = URL(
                    string: "itms-apps://itunes.apple.com/app/id6743892498?action=write-review"
                ) { UIApplication.shared.open(url) }
            }

            thinDivider

            linkRow(
                icon: "square.and.arrow.up.fill", color: AppTheme.Colors.mtaBlue,
                title: "Share Track",
                subtitle: "Send to a friend"
            ) {
                let url = URL(string: "https://apps.apple.com/app/id6743892498")!
                let av = UIActivityViewController(
                    activityItems: [url], applicationActivities: nil)
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = scene.windows.first?.rootViewController
                {
                    root.present(av, animated: true)
                }
            }

            thinDivider

            linkRow(
                icon: "hand.raised.fill", color: .indigo,
                title: "Privacy Policy",
                subtitle: "How we handle your data"
            ) {
                if let url = URL(string: "https://tracknyc.app/privacy") {
                    UIApplication.shared.open(url)
                }
            }

            thinDivider

            linkRow(
                icon: "doc.text.fill", color: .teal,
                title: "Terms of Service",
                subtitle: "Usage terms & conditions"
            ) {
                if let url = URL(string: "https://tracknyc.app/terms") {
                    UIApplication.shared.open(url)
                }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: About > Disclaimer

    private var aboutDisclaimer: some View {
        VStack(alignment: .leading, spacing: 10) {
            miniLabel("DISCLAIMER")
                .padding(.top, 2)

            disclaimerLine(
                icon: "building.2.fill",
                iconColor: AppTheme.Colors.mtaBlue.opacity(0.6),
                text: "Track uses publicly available GTFS and"
                    + " GTFS-RT feeds provided by the Metropolitan"
                    + " Transportation Authority (MTA). This app"
                    + " is independently developed and is not"
                    + " licensed by, endorsed by, or affiliated"
                    + " with the MTA or any transit agency."
            )

            disclaimerLine(
                icon: "exclamationmark.triangle.fill",
                iconColor: AppTheme.Colors.warningYellow,
                text: "Arrival times, vehicle positions, and"
                    + " service alerts are provided \"as is.\""
                    + " Data may be delayed or inaccurate due"
                    + " to feed latency, caching, or network"
                    + " conditions. Always confirm with official"
                    + " MTA sources for critical travel."
            )
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 14)
    }

    // MARK: About > Footer

    private var aboutFooterView: some View {
        VStack(spacing: 5) {
            Text("Made with ❤️ in New York City")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text("© \(Calendar.current.component(.year, from: Date())) Track NYC Transit")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    // ============================================================
    // MARK: - Apply / Confirm Overlays
    // ============================================================

    private var applyButton: some View {
        Button { applyChanges() } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Apply Changes")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .trackAccentBackground(cornerRadius: 14)
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.bottom, 24)
    }

    private var appliedBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
            Text("Settings Applied")
                .font(.system(size: 13, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.Colors.successGreen.gradient)
        .clipShape(Capsule())
        .shadow(color: AppTheme.Colors.shadow.opacity(0.14), radius: 6, y: 2)
        .padding(.bottom, 24)
    }

    // ============================================================
    // MARK: - Reusable Pieces
    // ============================================================

    // -- Section wrapper

    private func section<C: View>(
        _ title: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textTertiary)
                .tracking(0.6)
                .padding(.horizontal, AppTheme.Layout.margin)

            content()
                .padding(.horizontal, AppTheme.Layout.margin)
                .trackCardBackground(cornerRadius: AppTheme.Layout.cornerRadius)
        }
    }

    // -- Row helpers

    private func row<T: View>(
        icon: String, color: Color, title: String,
        @ViewBuilder trailing: () -> T
    ) -> some View {
        HStack(spacing: 10) {
            iconBadge(icon, color: color)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 12)
    }

    private func navRow(
        icon: String, color: Color,
        title: String, subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                iconBadge(icon, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
                Spacer()
                navChevron
            }
            .padding(.horizontal, AppTheme.Layout.cardPadding)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // -- Icon badge (28x28 tinted square)

    private func iconBadge(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // -- Dividers

    private var divider: some View {
        Rectangle()
            .fill(AppTheme.Colors.borderSubtle)
            .frame(height: 1)
            .padding(.leading, AppTheme.Layout.cardPadding + 38)
    }

    private var thinDivider: some View {
        Rectangle()
            .fill(AppTheme.Colors.borderSubtle.opacity(0.6))
            .frame(height: 1)
            .padding(.leading, AppTheme.Layout.cardPadding + 42)
    }

    private var aboutSeparator: some View {
        Rectangle()
            .fill(AppTheme.Colors.borderSubtle.opacity(0.5))
            .frame(height: 1)
            .padding(.horizontal, AppTheme.Layout.cardPadding)
    }

    // -- Nav chevron

    private var navChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.4))
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(AppTheme.Colors.textTertiary.opacity(0.07))
            )
    }

    // -- Radius helpers

    private func tierRow(
        icon: String, label: String, meters: Double, color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(color)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            Text(formatDistanceMiles(meters))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(color)
        }
    }

    private var tierBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let nearFrac = CGFloat(draftDerivedNearRadius / draftRadius)
            let farFrac = CGFloat(draftDerivedFartherRadius / draftRadius)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.Colors.warningYellow.opacity(0.22))
                    .frame(width: w, height: 6)
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.Colors.mtaBlue.opacity(0.3))
                    .frame(width: w * farFrac, height: 6)
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.Colors.successGreen.opacity(0.45))
                    .frame(width: w * nearFrac, height: 6)
            }
        }
        .frame(height: 6)
    }

    private func presetPill(
        label: String, icon: String, much: Double, color: Color
    ) -> some View {
        let active = draftRadius == much
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                draftRadius = much
            }
            if hapticsEnabled { HapticManager.impact(.medium) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(label)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .foregroundColor(active ? .white : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? color : color.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(active ? Color.clear : color.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color.opacity(0.25))
                .overlay(Circle().stroke(color, lineWidth: 1.5))
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
    }

    // -- About helpers

    private func miniLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.6))
            .tracking(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Layout.cardPadding)
    }

    private func modeChip(icon: String, name: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(name)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
    }

    private func sourceChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.65))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppTheme.Colors.textSecondary.opacity(0.07))
        .clipShape(Capsule())
    }

    private func linkRow(
        icon: String, color: Color,
        title: String, subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(color.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }

                Spacer()

                navChevron
            }
            .padding(.horizontal, AppTheme.Layout.cardPadding)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func disclaimerLine(
        icon: String, iconColor: Color, text: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(iconColor)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ============================================================
    // MARK: - Draft Logic
    // ============================================================

    private func loadDrafts() {
        draftRadius = max(2400, muchFartherAwayRadius)
        draftShowSearchRadius = showSearchRadius
        draftDragToSearch = dragToSearch
    }

    private func checkForChanges() {
        hasUnappliedChanges =
            draftRadius != muchFartherAwayRadius
            || draftShowSearchRadius != showSearchRadius
            || draftDragToSearch != dragToSearch
    }

    private func applyChanges() {
        muchFartherAwayRadius = draftRadius
        nearYouRadius = draftDerivedNearRadius
        fartherAwayRadius = draftDerivedFartherRadius
        showSearchRadius = draftShowSearchRadius
        dragToSearch = draftDragToSearch
        hasUnappliedChanges = false

        if hapticsEnabled { HapticManager.notification(.success) }

        showAppliedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            showAppliedConfirmation = false
        }

        Task { await SyncManager.shared.pushUserSettings() }
        NotificationCenter.default.post(name: .radiusSettingsChanged, object: nil)
    }

    private func syncSettings() {
        Task { await SyncManager.shared.pushUserSettings() }
    }
}

// MARK: - Preview

#Preview {
    SettingsContentView(sheetNavigator: SheetNavigator())
}
