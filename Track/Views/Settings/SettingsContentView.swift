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
struct SettingsContentView: View {
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @AppStorage("dev_use_localhost") private var useLocalhost = false
    @AppStorage("dev_custom_ip") private var customIP = AppSettings.shared.defaultDeviceIP
    @AppStorage("near_you_radius_meters") private var nearYouRadius: Double = 2414
    @AppStorage("farther_away_radius_meters") private var fartherAwayRadius: Double = 4023
    @AppStorage("much_farther_away_radius_meters") private var muchFartherAwayRadius: Double = 8047
    @AppStorage("haptics_enabled") private var hapticsEnabled = true
    @AppStorage("auto_refresh_enabled") private var autoRefreshEnabled = true
    @AppStorage("show_search_radius") private var showSearchRadius = false
    @AppStorage("drag_to_search") private var dragToSearch = true
    @AppStorage("subway_line_offset_meters") private var subwayLineOffset: Double = AppSettings.shared.subwayLineOffsetMeters
    
    let sheetNavigator: SheetNavigator
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header with Back Button
            sheetHeader
            
            // MARK: - Scrollable Content
            ScrollView {
                VStack(spacing: 24) {
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
                        }
                    }
                    
                    // Transit Preferences Section
                    settingsSection(title: "Transit Preferences", icon: "slider.horizontal.3", iconColor: AppTheme.Colors.mtaBlue) {
                        VStack(spacing: 0) {
                            // "Near You" radius slider
                            radiusRow(
                                icon: "location.fill",
                                iconColor: AppTheme.Colors.successGreen,
                                title: "Near You",
                                value: $nearYouRadius,
                                range: 400...4023,
                                step: 100,
                                color: AppTheme.Colors.successGreen
                            )
                            
                            settingsDivider
                            
                            // "Farther Away" radius slider
                            radiusRow(
                                icon: "figure.walk",
                                iconColor: AppTheme.Colors.mtaBlue,
                                title: "A Bit Farther",
                                value: $fartherAwayRadius,
                                range: 1600...8047,
                                step: 200,
                                color: AppTheme.Colors.mtaBlue
                            )
                            
                            settingsDivider
                            
                            // "Much Farther Away" radius slider
                            radiusRow(
                                icon: "car.fill",
                                iconColor: AppTheme.Colors.warningYellow,
                                title: "Much Farther",
                                value: $muchFartherAwayRadius,
                                range: 4000...16093,
                                step: 500,
                                color: AppTheme.Colors.warningYellow
                            )
                            
                            settingsDivider
                            
                            // Info text
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 13))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                                Text("Controls how arrivals are grouped by distance in the Nearby tab.")
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
                                Toggle("", isOn: $showSearchRadius)
                                    .tint(AppTheme.Colors.mtaBlue)
                            }
                            
                            if showSearchRadius {
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
                                Toggle("", isOn: $dragToSearch)
                                    .tint(AppTheme.Colors.mtaBlue)
                            }
                            
                            if dragToSearch {
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
                                    Text("\(Int(subwayLineOffset))m")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundColor(AppTheme.Colors.mtaBlue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(AppTheme.Colors.mtaBlue.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                                
                                Slider(value: $subwayLineOffset, in: 4...30, step: 1)
                                    .tint(AppTheme.Colors.mtaBlue)
                                
                                Text("How far apart subway lines spread in shared tunnels")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 14)
                        }
                    }
                    
                    // General Section
                    settingsSection(title: "General", icon: "gearshape.fill", iconColor: .gray) {
                        VStack(spacing: 0) {
                            // Auto-refresh toggle
                            settingsRow(
                                icon: "arrow.clockwise",
                                iconColor: AppTheme.Colors.successGreen,
                                title: "Auto-Refresh"
                            ) {
                                Toggle("", isOn: $autoRefreshEnabled)
                                    .tint(AppTheme.Colors.mtaBlue)
                            }
                            
                            settingsDivider
                            
                            // Haptic feedback toggle
                            settingsRow(
                                icon: "waveform",
                                iconColor: .orange,
                                title: "Haptic Feedback"
                            ) {
                                Toggle("", isOn: $hapticsEnabled)
                                    .tint(AppTheme.Colors.mtaBlue)
                            }
                        }
                    }
                    
                    // Widget Section
                    settingsSection(title: "Widgets", icon: "rectangle.3.group.fill", iconColor: .cyan) {
                        VStack(spacing: 0) {
                            Button {
                                sheetNavigator.navigate(to: .widgetSchedules)
                            } label: {
                                HStack {
                                    settingsIcon("calendar.badge.clock", color: AppTheme.Colors.mtaBlue)
                                    Text("Widget Schedules")
                                        .font(.custom("Helvetica", size: 15))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
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
                    
                    // Account Section
                    settingsSection(title: "Account", icon: "person.crop.circle.fill", iconColor: AppTheme.Colors.mtaBlue) {
                        VStack(spacing: 0) {
                            Button {
                                SupabaseManager.shared.signOut()
                                isLoggedIn = false
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
                    
                    // Developer Section
                    settingsSection(title: "Developer", icon: "hammer.fill", iconColor: .orange) {
                        VStack(spacing: 0) {
                            settingsRow(
                                icon: "desktopcomputer",
                                iconColor: .mint,
                                title: "Use Localhost"
                            ) {
                                Toggle("", isOn: $useLocalhost)
                                    .tint(AppTheme.Colors.mtaBlue)
                            }
                            
                            if !useLocalhost {
                                settingsDivider
                                
                                HStack {
                                    Text("http://")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                    TextField("192.168.1.X", text: $customIP)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                        .keyboardType(.numbersAndPunctuation)
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
                                Text(TrackAPI.baseURL)
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 8)
                        }
                    }
                    
                    // About Section
                    aboutSection
                    
                    Spacer()
                        .frame(height: 40)
                }
                .padding(.top, 12)
            }
        }
        .background(AppTheme.Colors.background)
        .onChange(of: settingsHash) { _, _ in
            // Push settings to cloud whenever any setting changes
            Task {
                await SyncManager.shared.pushUserSettings()
            }
        }
    }
    
    /// A combined hash of all synced settings so we can detect any change
    private var settingsHash: String {
        "\(appTheme)-\(nearYouRadius)-\(fartherAwayRadius)-\(muchFartherAwayRadius)-\(hapticsEnabled)-\(autoRefreshEnabled)-\(showSearchRadius)-\(dragToSearch)-\(subwayLineOffset)-\(useLocalhost)-\(customIP)"
    }
    
    // MARK: - Sheet Header
    
    private var sheetHeader: some View {
        HStack(spacing: 12) {
            // Back button
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
            
            // Title
            Text("Settings")
                .font(.custom("Helvetica-Bold", size: 18))
                .foregroundColor(AppTheme.Colors.textPrimary)
            
            Spacer()
            
            // Close button
            Button {
                sheetNavigator.popToRoot()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
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
    private func radiusRow(
        icon: String,
        iconColor: Color,
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                settingsIcon(icon, color: iconColor)
                Text(title)
                    .font(.custom("Helvetica", size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Spacer()
                Text(String(format: "%.1f mi", metersToMiles(value.wrappedValue)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())
            }
            
            Slider(value: value, in: range, step: step)
                .tint(color)
                .padding(.leading, 36)
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 14)
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
        settingsSection(title: "About", icon: "info.circle.fill", iconColor: .blue) {
            VStack(spacing: 0) {
                // App logo + name
                VStack(spacing: 8) {
                    Image(systemName: "tram.fill")
                        .font(.system(size: 32))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                    
                    Text("Track NYC")
                        .font(.custom("Helvetica-Bold", size: 18))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    
                    Text("Real-time NYC transit at your fingertips")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                       let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                        Text("Version \(version) (\(build))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                
                settingsDivider
                
                // Transport modes supported
                HStack(spacing: 16) {
                    transitBadge("🚇", "Subway")
                    transitBadge("🚌", "Bus")
                    transitBadge("🚂", "LIRR")
                    transitBadge("🚆", "MNR")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
    }
    
    private func transitBadge(_ emoji: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(emoji)
                .font(.system(size: 24))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
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
