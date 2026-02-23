//
//  SettingsContentView.swift
//  Track
//
//  Settings content that can be displayed within the universal bottom sheet.
//  This view contains the same settings functionality as SettingsView but
//  without the NavigationStack wrapper, allowing it to work within the
//  sheet's own navigation system.
//

import SwiftUI

/// Settings content for display within the universal bottom sheet.
///
/// Settings that affect the API or transit data (radius, toggles) use
/// local `@State` drafts.  Changes are only committed to `@AppStorage`
/// (and synced to the cloud) when the user taps the **Apply** button.
/// Purely visual settings (theme, distance unit) take effect immediately.
struct SettingsContentView: View {
    @ObservedObject private var supabase = SupabaseManager.shared

    // MARK: - Instant-apply settings (visual only, no API impact)
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("distance_unit") private var distanceUnit = "mi"
    @AppStorage("haptics_enabled") private var hapticsEnabled = true
    
    // MARK: - Persisted values (source of truth, written on Apply)
    @AppStorage("near_you_radius_meters") private var nearYouRadius: Double = 2414
    @AppStorage("farther_away_radius_meters") private var fartherAwayRadius: Double = 4023
    @AppStorage("much_farther_away_radius_meters") private var muchFartherAwayRadius: Double = 8047
    @AppStorage("show_search_radius") private var showSearchRadius = false
    @AppStorage("drag_to_search") private var dragToSearch = true
    @AppStorage("subway_line_offset_meters") private var subwayLineOffset: Double = AppSettings.shared.subwayLineOffsetMeters
    
    // MARK: - Draft state (edited in the UI, committed on Apply)
    @State private var draftRadius: Double = 8047
    @State private var draftShowSearchRadius = false
    @State private var draftDragToSearch = true
    @State private var draftSubwayLineOffset: Double = 10
    
    /// Tracks whether any draft value differs from the persisted value.
    @State private var hasUnappliedChanges = false
    /// Brief confirmation after applying.
    @State private var showAppliedConfirmation = false
    
    let sheetNavigator: SheetNavigator

    private var currentProfile: UserProfile? { supabase.currentUser }

    private var displayNameForWelcome: String {
        if let fullName = currentProfile?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines), !fullName.isEmpty {
            return fullName
        }
        if let givenName = currentProfile?.givenName?.trimmingCharacters(in: .whitespacesAndNewlines), !givenName.isEmpty {
            return givenName
        }
        if let username = currentProfile?.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            return username
        }
        if let email = currentProfile?.email, !email.isEmpty {
            return email.components(separatedBy: "@").first ?? "there"
        }
        return "there"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header with Back Button
            sheetHeader
            
            // MARK: - Scrollable Content
            ScrollView {
                VStack(spacing: 24) {
                    settingsSection(title: "Profile", icon: "person.crop.circle.fill", iconColor: AppTheme.Colors.mtaBlue) {
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

                            Button {
                                sheetNavigator.navigate(to: .profileSettings)
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
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Appearance Section
                    settingsSection(title: "Appearance", icon: "paintbrush.fill", iconColor: .purple) {
                        VStack(spacing: 0) {
                            // Theme picker
                            settingsRow(
                                icon: "circle.lefthalf.filled",
                                iconColor: .indigo,
                                title: "Theme"
                            ) {
                                Picker("", selection: $appTheme) {
                                    Label("System", systemImage: "iphone").tag("system")
                                    Label("Light", systemImage: "sun.max.fill").tag("light")
                                    Label("Dark", systemImage: "moon.fill").tag("dark")
                                }
                                .pickerStyle(.menu)
                                .tint(AppTheme.Colors.mtaBlue)
                            }
                            
                            settingsDivider
                            
                            // Distance unit picker
                            settingsRow(
                                icon: "ruler",
                                iconColor: .orange,
                                title: "Distance"
                            ) {
                                Picker("", selection: $distanceUnit) {
                                    Text("Miles").tag("mi")
                                    Text("Kilometers").tag("km")
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 160)
                            }
                        }
                    }
                    
                    // Widgets Section — quick access
                    settingsSection(title: "Widgets", icon: "rectangle.3.group.fill", iconColor: .cyan) {
                        VStack(spacing: 0) {
                            Button {
                                sheetNavigator.navigate(to: .widgetSchedules)
                            } label: {
                                HStack {
                                    settingsIcon("calendar.badge.clock", color: AppTheme.Colors.mtaBlue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Widget Schedules")
                                            .font(.custom("Helvetica", size: 15))
                                            .foregroundColor(AppTheme.Colors.textPrimary)
                                        Text("Configure home screen widgets")
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
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    
                    // Transit Preferences Section — single search radius
                    settingsSection(title: "Search Radius", icon: "scope", iconColor: AppTheme.Colors.mtaBlue) {
                        VStack(spacing: 0) {
                            // Main radius slider
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    settingsIcon("scope", color: AppTheme.Colors.mtaBlue)
                                    Text("Search Radius")
                                        .font(.custom("Helvetica", size: 15))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                    Spacer()
                                    Text(formatDistanceMiles(draftRadius))
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundColor(AppTheme.Colors.mtaBlue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(AppTheme.Colors.mtaBlue.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                                
                                Slider(value: $draftRadius, in: 1600...16093, step: 200)
                                    .tint(AppTheme.Colors.mtaBlue)
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 14)
                            
                            settingsDivider
                            
                            // Distance tier breakdown (read-only, auto-derived)
                            VStack(alignment: .leading, spacing: 10) {
                                Text("DISTANCE TIERS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                                    .tracking(0.6)
                                
                                tierIndicator(
                                    icon: "location.fill",
                                    label: "Near You",
                                    meters: draftDerivedNearRadius,
                                    color: AppTheme.Colors.successGreen
                                )
                                tierIndicator(
                                    icon: "figure.walk",
                                    label: "A Bit Farther",
                                    meters: draftDerivedFartherRadius,
                                    color: AppTheme.Colors.mtaBlue
                                )
                                tierIndicator(
                                    icon: "car.fill",
                                    label: "Much Farther",
                                    meters: draftRadius,
                                    color: AppTheme.Colors.warningYellow
                                )
                                
                                // Tier bar visualization
                                GeometryReader { geo in
                                    let total = geo.size.width
                                    let nearFrac = CGFloat(draftDerivedNearRadius / draftRadius)
                                    let farFrac = CGFloat(draftDerivedFartherRadius / draftRadius)
                                    
                                    ZStack(alignment: .leading) {
                                        // Much Farther (full width)
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(AppTheme.Colors.warningYellow.opacity(0.25))
                                            .frame(width: total, height: 8)
                                        
                                        // Farther
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(AppTheme.Colors.mtaBlue.opacity(0.35))
                                            .frame(width: total * farFrac, height: 8)
                                        
                                        // Near
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(AppTheme.Colors.successGreen.opacity(0.5))
                                            .frame(width: total * nearFrac, height: 8)
                                    }
                                }
                                .frame(height: 8)
                                .padding(.top, 4)
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 12)
                            
                            settingsDivider
                            
                            // Quick preset buttons
                            VStack(alignment: .leading, spacing: 10) {
                                Text("PRESETS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                                    .tracking(0.6)
                                
                                HStack(spacing: 8) {
                                    radiusPresetButton(
                                        label: "Walking",
                                        icon: "figure.walk",
                                        near: 800, farther: 1600, much: 3200,
                                        color: AppTheme.Colors.successGreen
                                    )
                                    radiusPresetButton(
                                        label: "Default",
                                        icon: "target",
                                        near: AppSettings.shared.defaultNearYouRadiusMeters,
                                        farther: AppSettings.shared.defaultFartherAwayRadiusMeters,
                                        much: AppSettings.shared.defaultMuchFartherAwayRadiusMeters,
                                        color: AppTheme.Colors.mtaBlue
                                    )
                                    radiusPresetButton(
                                        label: "Wide",
                                        icon: "car.fill",
                                        near: 3200, farther: 6400, much: 16093,
                                        color: AppTheme.Colors.warningYellow
                                    )
                                }
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 12)
                            
                            settingsDivider
                            
                            // Info text
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 13))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                                Text("Drag the slider to set how far out to search. Arrivals are automatically grouped into three distance tiers in the Nearby tab.")
                                    .font(.system(size: 12))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 10)
                        }
                    }
                    
                    // Map & Display Section
                    settingsSection(title: "Map & Display", icon: "map.fill", iconColor: .green) {
                        VStack(spacing: 0) {
                            // Show search radius circles on map
                            settingsRow(
                                icon: "circle.dashed",
                                iconColor: .orange,
                                title: "Search Radius"
                            ) {
                                Toggle("", isOn: $draftShowSearchRadius)
                                    .tint(AppTheme.Colors.mtaBlue)
                            }
                            
                            if draftShowSearchRadius {
                                // Color legend for the 3 radius tiers
                                HStack(spacing: 16) {
                                    radiusLegendDot(color: AppTheme.Colors.successGreen, label: "Near")
                                    radiusLegendDot(color: AppTheme.Colors.mtaBlue, label: "Farther")
                                    radiusLegendDot(color: AppTheme.Colors.warningYellow, label: "Much Farther")
                                }
                                .padding(.horizontal, AppTheme.Layout.cardPadding)
                                .padding(.bottom, 10)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            
                            settingsDivider
                            
                            // Drag-to-search — pan the map to explore transit elsewhere
                            settingsRow(
                                icon: "hand.draw.fill",
                                iconColor: AppTheme.Colors.mtaBlue,
                                title: "Drag to Search"
                            ) {
                                Toggle("", isOn: $draftDragToSearch)
                                    .tint(AppTheme.Colors.mtaBlue)
                            }
                            
                            if draftDragToSearch {
                                Text("Pan the map to explore transit at a different location")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                                    .padding(.horizontal, AppTheme.Layout.cardPadding)
                                    .padding(.bottom, 10)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            
                            settingsDivider
                            
                            // Subway line offset slider
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    settingsIcon("arrow.left.and.right", color: AppTheme.Colors.mtaBlue)
                                    Text("Line Spread")
                                        .font(.custom("Helvetica", size: 15))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                    Spacer()
                                    Text("\(Int(draftSubwayLineOffset))m")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundColor(AppTheme.Colors.mtaBlue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(AppTheme.Colors.mtaBlue.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                                
                                Slider(value: $draftSubwayLineOffset, in: 4...30, step: 1)
                                    .tint(AppTheme.Colors.mtaBlue)
                                
                                Text("Controls how thick subway lines appear on the map overview (thinner at low values, bolder at high values)")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 14)
                        }
                    }
                    
                    
                    // Account Section
                    settingsSection(title: "Account", icon: "person.crop.circle.fill", iconColor: AppTheme.Colors.mtaBlue) {
                        VStack(spacing: 0) {
                            Button {
                                SupabaseManager.shared.signOut()
                                sheetNavigator.popToRoot()
                            } label: {
                                HStack {
                                    settingsIcon("rectangle.portrait.and.arrow.right", color: AppTheme.Colors.alertRed)
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
                    // Developer Navigation (debug only)
                    settingsSection(title: "Developer", icon: "hammer.fill", iconColor: .orange) {
                        Button {
                            sheetNavigator.navigate(to: .developerSettings)
                        } label: {
                            HStack {
                                settingsIcon("wrench.and.screwdriver.fill", color: .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Developer Settings")
                                        .font(.custom("Helvetica", size: 15))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                    Text("Local backend, connectivity checks")
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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
#endif
                    
                    // About Section
                    aboutSection
                    
                    Spacer()
                        .frame(height: 40)
                }
                .padding(.top, 12)
            }
        }
        .background(AppTheme.Colors.background)
        // Initialize drafts from persisted values on appear
        .onAppear {
            loadDrafts()
        }
        // Track whether any draft differs from the persisted value
        .onChange(of: draftRadius) { _, _ in checkForChanges() }
        .onChange(of: draftShowSearchRadius) { _, _ in checkForChanges() }
        .onChange(of: draftDragToSearch) { _, _ in checkForChanges() }
        .onChange(of: draftSubwayLineOffset) { _, _ in checkForChanges() }
        // Auto-push instant-apply settings to cloud when they change
        .onChange(of: appTheme) { _, _ in
            Task { await SyncManager.shared.pushUserSettings() }
        }
        .onChange(of: hapticsEnabled) { _, _ in
            Task { await SyncManager.shared.pushUserSettings() }
        }
        .onChange(of: distanceUnit) { _, _ in
            Task { await SyncManager.shared.pushUserSettings() }
        }
        // Floating Apply button
        .overlay(alignment: .bottom) {
            if hasUnappliedChanges {
                applyButton
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showAppliedConfirmation {
                appliedConfirmation
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: hasUnappliedChanges)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showAppliedConfirmation)
    }
    
    // MARK: - Draft Helpers
    
    /// Derived tier thresholds from the draft radius (live preview)
    private var draftDerivedNearRadius: Double {
        let derived = (draftRadius * 0.40 / 100).rounded() * 100
        return max(400, derived)
    }
    
    private var draftDerivedFartherRadius: Double {
        let derived = (draftRadius * 0.65 / 100).rounded() * 100
        return max(draftDerivedNearRadius + 400, derived)
    }
    
    /// Load persisted @AppStorage values into draft state.
    private func loadDrafts() {
        draftRadius = muchFartherAwayRadius
        draftShowSearchRadius = showSearchRadius
        draftDragToSearch = dragToSearch
        draftSubwayLineOffset = subwayLineOffset
    }
    
    /// Check if any draft value differs from the persisted value.
    private func checkForChanges() {
        hasUnappliedChanges =
            draftRadius != muchFartherAwayRadius ||
            draftShowSearchRadius != showSearchRadius ||
            draftDragToSearch != dragToSearch ||
            draftSubwayLineOffset != subwayLineOffset
    }
    
    /// Commit all drafts to @AppStorage in one shot and sync once.
    private func applyChanges() {
        // Radius + derived tiers
        muchFartherAwayRadius = draftRadius
        nearYouRadius = draftDerivedNearRadius
        fartherAwayRadius = draftDerivedFartherRadius
        
        // Map & Display
        showSearchRadius = draftShowSearchRadius
        dragToSearch = draftDragToSearch
        subwayLineOffset = draftSubwayLineOffset
        
        hasUnappliedChanges = false
        
        // Haptic confirmation
        if hapticsEnabled {
            HapticManager.notification(.success)
        }
        
        // Show brief confirmation badge
        showAppliedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            showAppliedConfirmation = false
        }
        
        // Single cloud sync
        Task {
            await SyncManager.shared.pushUserSettings()
        }
        
        // Notify the rest of the app to re-fetch with the new radius
        NotificationCenter.default.post(name: .radiusSettingsChanged, object: nil)
    }
    
    // MARK: - Apply Button
    
    private var applyButton: some View {
        Button {
            applyChanges()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Apply Changes")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppTheme.Colors.mtaBlue)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: AppTheme.Colors.mtaBlue.opacity(0.4), radius: 8, y: 4)
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.bottom, 24)
    }
    
    private var appliedConfirmation: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
            Text("Settings Applied")
                .font(.system(size: 13, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.Colors.successGreen)
        .clipShape(Capsule())
        .shadow(radius: 6, y: 2)
        .padding(.bottom, 24)
    }
    
    // MARK: - Sheet Header
    
    private var sheetHeader: some View {
        ZStack {
            // Centred title — always exactly centred regardless of side-button widths
            Text("Settings")
                .font(.custom("Helvetica-Bold", size: 18))
                .foregroundColor(AppTheme.Colors.textPrimary)

            HStack {
                // Back button — left-aligned
                Button {
                    sheetNavigator.goBack()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Home")
                            .font(.custom("Helvetica", size: 16))
                    }
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                }

                Spacer()

                // Close button — right-aligned
                Button {
                    sheetNavigator.popToRoot()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.vertical, 16)
        .background(AppTheme.Colors.background)
    }
    
    // MARK: - Reusable Components
    
    /// Standard divider aligned with text content
    private var settingsDivider: some View {
        Divider()
            .padding(.leading, AppTheme.Layout.cardPadding + 36)
    }
    
    /// Compact settings icon in a tinted rounded square
    private func settingsIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    /// Standard settings row with icon, title, and trailing content
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
    
    /// Radius slider row
    ///
    /// Contains a safety clamp so Slider never receives a range where
    /// `lowerBound >= upperBound` (which causes "max stride must be positive" crash).
    private func radiusRow(
        icon: String,
        iconColor: Color,
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        color: Color
    ) -> some View {
        // Safety: guarantee lowerBound < upperBound and step fits within span
        let lo = range.lowerBound
        let hi = max(range.upperBound, lo + step)
        let safeRange = lo...hi
        let safeStep  = min(step, hi - lo)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                settingsIcon(icon, color: iconColor)
                Text(title)
                    .font(.custom("Helvetica", size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Spacer()
                Text(formatDistanceMiles(value.wrappedValue))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())
            }
            
            Slider(value: value, in: safeRange, step: safeStep)
                .tint(color)
                .padding(.leading, 36)
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 14)
    }
    
    /// Whether the current draft radius matches a given preset.
    private func isPresetActive(near: Double, farther: Double, much: Double) -> Bool {
        draftRadius == much
    }
    
    /// Read-only tier indicator row showing icon, label, and distance
    private func tierIndicator(icon: String, label: String, meters: Double, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            Text(formatDistanceMiles(meters))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(color.opacity(0.8))
        }
    }
    
    /// A compact pill button that applies a radius preset.
    private func radiusPresetButton(
        label: String,
        icon: String,
        near: Double,
        farther: Double,
        much: Double,
        color: Color
    ) -> some View {
        let active = isPresetActive(near: near, farther: farther, much: much)
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                draftRadius = much
            }
            if hapticsEnabled {
                HapticManager.impact(.medium)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.custom("Helvetica-Bold", size: 11))
            }
            .foregroundColor(active ? .white : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? color : color.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(active ? Color.clear : color.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - About Section
    
    /// Color dot + label for the radius legend
    private func radiusLegendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color.opacity(0.25))
                .overlay(Circle().stroke(color, lineWidth: 1.5))
                .frame(width: 12, height: 12)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
    }
    
    private var aboutSection: some View {
        settingsSection(title: "About", icon: "info.circle.fill", iconColor: AppTheme.Colors.mtaBlue) {
            VStack(spacing: 0) {
                // App identity card
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
                    
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                       let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
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
                
                // Transport modes
                VStack(spacing: 10) {
                    Text("SUPPORTED TRANSIT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                        .tracking(0.6)
                    
                    HStack(spacing: 0) {
                        transitModeBadge("🚇", "Subway", AppTheme.Colors.mtaBlue)
                        transitModeBadge("🚌", "Bus", Color(red: 0/255, green: 57/255, blue: 166/255))
                        transitModeBadge("🚂", "LIRR", Color(red: 0/255, green: 115/255, blue: 191/255))
                        transitModeBadge("🚆", "MNR", Color(red: 0/255, green: 90/255, blue: 140/255))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                
                settingsDivider
                
                // Data sources
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
                
                // Credits
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
    
    // MARK: - Section Builder
    
    private func settingsSection<Content: View>(
        title: String,
        icon: String = "",
        iconColor: Color = .gray,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(iconColor.opacity(0.7))
                }
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                    .tracking(0.5)
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            
            content()
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
        }
    }
}

#Preview {
    SettingsContentView(sheetNavigator: SheetNavigator())
}
