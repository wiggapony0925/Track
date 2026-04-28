// Settings — bold purple-themed redesign with hero profile card,
// visual theme tiles, concentric-ring radius preview, and a
// 2-column toggle grid. Each section has a distinct visual treatment
// so the screen no longer feels like a uniform list.

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
    @AppStorage("drag_to_search") private var dragToSearch = false

    // MARK: - Draft State
    @State private var draftRadius: Double = 8047
    @State private var draftShowSearchRadius = false
    @State private var draftDragToSearch = false
    @State private var hasUnappliedChanges = false
    @State private var showAppliedConfirmation = false
    @State private var scrollOffset: CGFloat = 0

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
        ZStack(alignment: .top) {
            AppTheme.Gradients.screen
                .ignoresSafeArea()

            // Soft purple radial wash behind the hero
            RadialGradient(
                colors: [
                    AppTheme.Colors.accent.opacity(0.22),
                    AppTheme.Colors.accentSecondary.opacity(0.06),
                    Color.clear,
                ],
                center: .topTrailing, startRadius: 20, endRadius: 380
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                scrollBody
            }
        }
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

    // MARK: - Top bar (compact)

    private var topBar: some View {
        HStack {
            Button {
                sheetNavigator.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(AppTheme.Colors.accent)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(AppTheme.Colors.cardBackground)
                            .overlay(Circle().stroke(AppTheme.Colors.borderSubtle, lineWidth: 1))
                    )
            }

            Spacer()

            Button {
                sheetNavigator.popToRoot()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(AppTheme.Colors.cardBackground)
                            .overlay(Circle().stroke(AppTheme.Colors.borderSubtle, lineWidth: 1))
                    )
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Scroll body

    private var scrollBody: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 22) {
                titleBlock
                profileHeroCard
                lookAndFeelCard
                radiusCard
                quickToggleGrid
                navList
                #if DEBUG
                developerCard
                #endif
                signOutButton
                aboutFooter
                Spacer().frame(height: 80)
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 4)
        }
    }

    // MARK: - Title block

    private var titleBlock: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text("Tune your experience")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
            Spacer()
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    // ============================================================
    // MARK: - Profile Hero (full purple gradient card)
    // ============================================================

    private var profileHeroCard: some View {
        Button {
            sheetNavigator.navigate(to: .profileSettings)
        } label: {
            HStack(spacing: 16) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 64, height: 64)
                    Circle()
                        .stroke(.white.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 64, height: 64)
                    Text(String(displayName.prefix(1)).uppercased())
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(currentProfile?.email ?? "Signed in with Apple")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Image(systemName: "person.text.rectangle.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("Manage Profile")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.22)))
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    AppTheme.Gradients.accentVibrant
                    // sheen
                    LinearGradient(
                        colors: [.white.opacity(0.18), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    // soft circles for depth
                    Circle()
                        .fill(.white.opacity(0.07))
                        .frame(width: 220, height: 220)
                        .offset(x: 140, y: -90)
                    Circle()
                        .fill(.white.opacity(0.05))
                        .frame(width: 140, height: 140)
                        .offset(x: -90, y: 70)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: AppTheme.Colors.accent.opacity(0.35), radius: 20, y: 10)
        }
        .buttonStyle(.plain)
    }

    // ============================================================
    // MARK: - Look & Feel (theme tiles + unit + haptics)
    // ============================================================

    private var lookAndFeelCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardLabel(icon: "paintbrush.pointed.fill", text: "LOOK & FEEL")

            // Theme tiles
            HStack(spacing: 10) {
                themeTile(value: "system", title: "Auto", colors: [.gray.opacity(0.6), .black])
                themeTile(value: "light", title: "Light", colors: [.white, Color(white: 0.92)])
                themeTile(value: "dark", title: "Dark", colors: [Color(white: 0.18), .black])
            }

            divider

            // Distance unit
            HStack(spacing: 12) {
                miniIcon("ruler", color: AppTheme.Colors.accentSecondary)
                Text("Distance")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Spacer()
                miniSegmented(
                    selection: $distanceUnit,
                    options: [("mi", "mi"), ("km", "km")]
                )
            }

            divider

            // Haptics
            HStack(spacing: 12) {
                miniIcon("waveform", color: AppTheme.Colors.accentDeep)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Haptics")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("Feedback on key actions")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
                Spacer()
                Toggle("", isOn: $hapticsEnabled)
                    .tint(AppTheme.Colors.accent)
                    .labelsHidden()
            }
        }
        .padding(18)
        .glassCard()
    }

    private func themeTile(value: String, title: String, colors: [Color]) -> some View {
        let active = appTheme == value
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                appTheme = value
            }
            if hapticsEnabled { HapticManager.impact(.light) }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 70)
                    // mock UI inside
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(.white.opacity(0.5))
                            .frame(width: 26, height: 4)
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .frame(width: 36, height: 3)
                        Spacer()
                        HStack(spacing: 3) {
                            Circle().fill(AppTheme.Colors.accent).frame(width: 8, height: 8)
                            Capsule().fill(.white.opacity(0.4)).frame(width: 18, height: 3)
                        }
                    }
                    .padding(8)
                    .frame(height: 70)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            active ? AppTheme.Colors.accent : Color.white.opacity(0.08),
                            lineWidth: active ? 2.5 : 1
                        )
                )
                .shadow(color: active ? AppTheme.Colors.accent.opacity(0.35) : .clear,
                        radius: active ? 10 : 0, y: 4)

                HStack(spacing: 4) {
                    if active {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundColor(AppTheme.Colors.accent)
                    }
                    Text(title)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundColor(active ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // ============================================================
    // MARK: - Radius (concentric rings preview + slider)
    // ============================================================

    private var radiusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                cardLabel(icon: "scope", text: "SEARCH DISTANCE")
                Spacer()
                Text(formatDistanceMiles(draftRadius))
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(AppTheme.Gradients.accent)
                            .shadow(color: AppTheme.Colors.accent.opacity(0.4), radius: 6, y: 2)
                    )
            }

            // Concentric rings preview
            ringsPreview
                .frame(height: 150)
                .frame(maxWidth: .infinity)

            // Slider
            VStack(spacing: 6) {
                Slider(value: $draftRadius, in: 2400...16093, step: 200)
                    .tint(AppTheme.Colors.accent)
                HStack {
                    Text("1.5 mi").font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text("10 mi").font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(AppTheme.Colors.textTertiary)
            }

            // Tier chips
            HStack(spacing: 8) {
                tierChip(label: "Near", value: draftDerivedNearRadius, color: AppTheme.Colors.successGreen)
                tierChip(label: "Farther", value: draftDerivedFartherRadius, color: AppTheme.Colors.accent)
                tierChip(label: "Max", value: draftRadius, color: AppTheme.Colors.warningYellow)
            }

            divider

            // Presets
            HStack(spacing: 8) {
                presetPill(label: "Walk", icon: "figure.walk", much: 3200)
                presetPill(label: "Default", icon: "target",
                           much: AppSettings.shared.defaultMuchFartherAwayRadiusMeters)
                presetPill(label: "Wide", icon: "car.fill", much: 16093)
            }
        }
        .padding(18)
        .glassCard()
    }

    private var ringsPreview: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let maxR = size / 2 - 4

            let nearFrac = CGFloat(draftDerivedNearRadius / draftRadius)
            let farFrac = CGFloat(draftDerivedFartherRadius / draftRadius)

            ZStack {
                // Outer ring (Max)
                Circle()
                    .stroke(AppTheme.Colors.warningYellow.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    .frame(width: maxR * 2, height: maxR * 2)
                Circle()
                    .fill(AppTheme.Colors.warningYellow.opacity(0.05))
                    .frame(width: maxR * 2, height: maxR * 2)

                // Mid ring (Farther)
                Circle()
                    .stroke(AppTheme.Colors.accent.opacity(0.55), lineWidth: 2)
                    .frame(width: maxR * 2 * farFrac, height: maxR * 2 * farFrac)
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.10))
                    .frame(width: maxR * 2 * farFrac, height: maxR * 2 * farFrac)

                // Inner ring (Near)
                Circle()
                    .stroke(AppTheme.Colors.successGreen.opacity(0.65), lineWidth: 2)
                    .frame(width: maxR * 2 * nearFrac, height: maxR * 2 * nearFrac)
                Circle()
                    .fill(AppTheme.Colors.successGreen.opacity(0.18))
                    .frame(width: maxR * 2 * nearFrac, height: maxR * 2 * nearFrac)

                // Center pin
                ZStack {
                    Circle()
                        .fill(AppTheme.Gradients.accent)
                        .frame(width: 18, height: 18)
                        .shadow(color: AppTheme.Colors.accent.opacity(0.6), radius: 6)
                    Circle()
                        .fill(.white)
                        .frame(width: 6, height: 6)
                }
            }
            .position(center)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: draftRadius)
        }
    }

    private func tierChip(label: String, value: Double, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundColor(color.opacity(0.85))
                .tracking(0.5)
            Text(formatDistanceMiles(value))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(color.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func presetPill(label: String, icon: String, much: Double) -> some View {
        let active = abs(draftRadius - much) < 1
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                draftRadius = much
            }
            if hapticsEnabled { HapticManager.impact(.medium) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .heavy))
                Text(label)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
            }
            .foregroundColor(active ? .white : AppTheme.Colors.accent)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? AnyShapeStyle(AppTheme.Gradients.accent)
                                 : AnyShapeStyle(AppTheme.Colors.accent.opacity(0.10)))
            )
            .shadow(color: active ? AppTheme.Colors.accent.opacity(0.35) : .clear,
                    radius: active ? 8 : 0, y: 3)
        }
        .buttonStyle(.plain)
    }

    // ============================================================
    // MARK: - Quick toggle grid (Map options)
    // ============================================================

    private var quickToggleGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardLabel(icon: "map.fill", text: "MAP")
            HStack(spacing: 12) {
                toggleCard(
                    icon: "circle.dashed",
                    title: "Radius Rings",
                    subtitle: "Show on map",
                    isOn: $draftShowSearchRadius
                )
                toggleCard(
                    icon: "hand.draw.fill",
                    title: "Drag Search",
                    subtitle: "Pan to explore",
                    isOn: $draftDragToSearch
                )
            }
        }
    }

    private func toggleCard(
        icon: String, title: String, subtitle: String, isOn: Binding<Bool>
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            if hapticsEnabled { HapticManager.impact(.light) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                isOn.wrappedValue
                                    ? AnyShapeStyle(AppTheme.Gradients.accent)
                                    : AnyShapeStyle(AppTheme.Colors.cardInset)
                            )
                            .frame(width: 36, height: 36)
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundColor(isOn.wrappedValue ? .white : AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Circle()
                        .fill(isOn.wrappedValue ? AppTheme.Colors.successGreen : AppTheme.Colors.borderSubtle)
                        .frame(width: 10, height: 10)
                }
                Text(title)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        isOn.wrappedValue ? AppTheme.Colors.accent.opacity(0.4) : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // ============================================================
    // MARK: - Nav list (Widgets, etc.)
    // ============================================================

    private var navList: some View {
        VStack(spacing: 10) {
            navRow(
                icon: "mappin.and.ellipse",
                tint: AppTheme.Colors.successGreen,
                title: "Saved Addresses",
                subtitle: "Home, work, and map places"
            ) {
                sheetNavigator.navigate(to: .savedAddresses)
            }

            navRow(
                icon: "calendar.badge.clock",
                tint: AppTheme.Colors.accent,
                title: "Widget Schedules",
                subtitle: "Activate widgets at certain times"
            ) {
                sheetNavigator.navigate(to: .widgetSchedules)
            }
        }
    }

    private func navRow(
        icon: String, tint: Color,
        title: String, subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundColor(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.6))
            }
            .padding(14)
            .glassCard()
        }
        .buttonStyle(.plain)
    }

    // ============================================================
    // MARK: - Developer (DEBUG)
    // ============================================================

    #if DEBUG
    private var developerCard: some View {
        navRow(
            icon: "wrench.and.screwdriver.fill",
            tint: AppTheme.Colors.warningYellow,
            title: "Developer",
            subtitle: "Local backend, diagnostics"
        ) {
            sheetNavigator.navigate(to: .developerSettings)
        }
    }
    #endif

    // ============================================================
    // MARK: - Sign Out
    // ============================================================

    private var signOutButton: some View {
        Button {
            SupabaseManager.shared.signOut()
            sheetNavigator.popToRoot()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 15, weight: .heavy))
                Text("Sign Out")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
            }
            .foregroundColor(AppTheme.Colors.alertRed)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.Colors.alertRed.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(AppTheme.Colors.alertRed.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // ============================================================
    // MARK: - About footer
    // ============================================================

    private var aboutFooter: some View {
        VStack(spacing: 10) {
            // Mode chips
            HStack(spacing: 6) {
                modePill(icon: "tram.fill", color: AppTheme.Colors.accent)
                modePill(icon: "bus.fill", color: AppTheme.BusColors.localBlue)
                modePill(icon: "train.side.front.car",
                         color: AppTheme.CommuterRailColors.lirrBlue)
                modePill(icon: "train.side.front.car",
                         color: AppTheme.CommuterRailColors.mnrBlue)
            }

            HStack(spacing: 16) {
                aboutLink("Privacy", "hand.raised.fill") {
                    if let url = URL(string: "https://tracknyc.app/privacy") {
                        UIApplication.shared.open(url)
                    }
                }
                aboutLink("Terms", "doc.text.fill") {
                    if let url = URL(string: "https://tracknyc.app/terms") {
                        UIApplication.shared.open(url)
                    }
                }
                aboutLink("Rate", "star.fill") {
                    if let url = URL(string: "itms-apps://itunes.apple.com/app/id6743892498?action=write-review") {
                        UIApplication.shared.open(url)
                    }
                }
            }

            VStack(spacing: 3) {
                Text("Track")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Text("v\(v) · Build \(b)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
                Text("Made in NYC · Independent of the MTA")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.7))
            }
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    private func modePill(icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .heavy))
            .foregroundColor(color)
            .frame(width: 30, height: 30)
            .background(
                Circle()
                    .fill(color.opacity(0.12))
                    .overlay(Circle().stroke(color.opacity(0.25), lineWidth: 1))
            )
    }

    private func aboutLink(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .heavy))
                Text(title)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
            }
            .foregroundColor(AppTheme.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(AppTheme.Colors.cardBackground.opacity(0.7))
                    .overlay(Capsule().stroke(AppTheme.Colors.borderSubtle, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    // ============================================================
    // MARK: - Apply / Confirm Overlays
    // ============================================================

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

    private var applyButton: some View {
        Button { applyChanges() } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .heavy))
                Text("Apply Changes")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.Gradients.accent)
                    .shadow(color: AppTheme.Colors.accent.opacity(0.45), radius: 16, y: 8)
            )
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.bottom, 24)
    }

    private var appliedBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .heavy))
            Text("Settings Applied")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.Colors.successGreen.gradient)
        .clipShape(Capsule())
        .shadow(color: AppTheme.Colors.successGreen.opacity(0.4), radius: 10, y: 4)
        .padding(.bottom, 24)
    }

    // ============================================================
    // MARK: - Reusable Pieces
    // ============================================================

    private func cardLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(AppTheme.Colors.accent)
            Text(text)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textTertiary)
                .tracking(0.8)
        }
    }

    private func miniIcon(_ name: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.15))
                .frame(width: 30, height: 30)
            Image(systemName: name)
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(color)
        }
    }

    private func miniSegmented(
        selection: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { opt in
                let active = selection.wrappedValue == opt.0
                Button {
                    selection.wrappedValue = opt.0
                    if hapticsEnabled { HapticManager.impact(.light) }
                } label: {
                    Text(opt.1)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundColor(active ? .white : AppTheme.Colors.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(
                                active ? AnyShapeStyle(AppTheme.Gradients.accent)
                                       : AnyShapeStyle(Color.clear)
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule().fill(AppTheme.Colors.cardInset)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(AppTheme.Colors.borderSubtle.opacity(0.6))
            .frame(height: 1)
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

// MARK: - Glass card modifier (local to settings)

private struct GlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(AppTheme.Colors.borderSubtle.opacity(0.6), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private extension View {
    func glassCard() -> some View { modifier(GlassCardModifier()) }
}

// MARK: - Preview

#Preview {
    SettingsContentView(sheetNavigator: SheetNavigator())
}
