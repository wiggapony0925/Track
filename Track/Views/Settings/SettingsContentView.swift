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
    @AppStorage("near_you_radius_meters") private var nearYouRadius: Double = 400
    @AppStorage("farther_away_radius_meters") private var fartherAwayRadius: Double = 1200
    
    let sheetNavigator: SheetNavigator
    
    /// Convert meters to miles for display
    private func metersToMiles(_ meters: Double) -> Double {
        meters / 1609.344
    }
    
    /// Convert miles to meters
    private func milesToMeters(_ miles: Double) -> Double {
        miles * 1609.344
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header with Back Button
            sheetHeader
            
            // MARK: - Scrollable Content
            ScrollView {
                VStack(spacing: 20) {
                    // Appearance Section
                    settingsSection(title: "Appearance") {
                        VStack(spacing: 0) {
                            HStack {
                                Image(systemName: "paintbrush.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(AppTheme.Colors.mtaBlue)
                                    .frame(width: 28)
                                Text("Theme")
                                    .font(.custom("Helvetica", size: 16))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                Spacer()
                                Picker("", selection: $appTheme) {
                                    Text("System").tag("system")
                                    Text("Dark").tag("dark")
                                    Text("Light").tag("light")
                                }
                                .pickerStyle(.menu)
                                .tint(AppTheme.Colors.mtaBlue)
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 14)
                        }
                    }
                    
                    // Nearby Search Section
                    settingsSection(title: "Nearby Search") {
                        VStack(spacing: 0) {
                            // "Near You" radius slider
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "location.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(AppTheme.Colors.successGreen)
                                        .frame(width: 28)
                                    Text("Near You Radius")
                                        .font(.custom("Helvetica", size: 16))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                    Spacer()
                                    Text(String(format: "%.1f mi", metersToMiles(nearYouRadius)))
                                        .font(.custom("Helvetica-Bold", size: 14))
                                        .foregroundColor(AppTheme.Colors.mtaBlue)
                                }
                                
                                Slider(
                                    value: $nearYouRadius,
                                    in: 100...800,
                                    step: 50
                                )
                                .tint(AppTheme.Colors.successGreen)
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 14)
                            
                            Divider()
                                .padding(.leading, AppTheme.Layout.cardPadding + 28 + 8)
                            
                            // "Farther Away" radius slider
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "figure.walk")
                                        .font(.system(size: 18))
                                        .foregroundColor(AppTheme.Colors.mtaBlue)
                                        .frame(width: 28)
                                    Text("Farther Away Radius")
                                        .font(.custom("Helvetica", size: 16))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                    Spacer()
                                    Text(String(format: "%.1f mi", metersToMiles(fartherAwayRadius)))
                                        .font(.custom("Helvetica-Bold", size: 14))
                                        .foregroundColor(AppTheme.Colors.mtaBlue)
                                }
                                
                                Slider(
                                    value: $fartherAwayRadius,
                                    in: 400...2400,
                                    step: 100
                                )
                                .tint(AppTheme.Colors.mtaBlue)
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 14)
                            
                            Divider()
                                .padding(.leading, AppTheme.Layout.cardPadding + 28 + 8)
                            
                            // Info text
                            HStack {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                                Text("Controls how arrivals are grouped in the 'Near You' and 'A Little Farther Away' sections")
                                    .font(.system(size: 12))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 10)
                        }
                    }
                    
                    // Widget Section
                    settingsSection(title: "Widgets") {
                        VStack(spacing: 0) {
                            Button {
                                sheetNavigator.navigate(to: .widgetSchedules)
                            } label: {
                                HStack {
                                    Image(systemName: "calendar.badge.clock")
                                        .font(.system(size: 18))
                                        .foregroundColor(AppTheme.Colors.mtaBlue)
                                        .frame(width: 28)
                                    Text("Widget Schedules")
                                        .font(.custom("Helvetica", size: 16))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                                }
                                .padding(.horizontal, AppTheme.Layout.cardPadding)
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    // Account Section
                    settingsSection(title: "Account") {
                        VStack(spacing: 0) {
                            Button {
                                isLoggedIn = false
                                sheetNavigator.popToRoot()
                            } label: {
                                HStack {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                        .font(.system(size: 18))
                                        .foregroundColor(AppTheme.Colors.alertRed)
                                        .frame(width: 28)
                                    Text("Sign Out")
                                        .font(.custom("Helvetica", size: 16))
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
                    settingsSection(title: "Developer") {
                        VStack(spacing: 0) {
                            HStack {
                                Image(systemName: "hammer.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(AppTheme.Colors.mtaBlue)
                                    .frame(width: 28)
                                Text("Use Localhost")
                                    .font(.custom("Helvetica", size: 16))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                Spacer()
                                Toggle("", isOn: $useLocalhost)
                                    .tint(AppTheme.Colors.mtaBlue)
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 12)
                            
                            if !useLocalhost {
                                Divider()
                                    .padding(.leading, AppTheme.Layout.cardPadding + 28 + 8)
                                
                                HStack {
                                    Text("http://")
                                        .font(.custom("Helvetica", size: 14))
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                    TextField("192.168.1.X", text: $customIP)
                                        .font(.custom("Helvetica", size: 14))
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                        .keyboardType(.numbersAndPunctuation)
                                    Text(":8000")
                                        .font(.custom("Helvetica", size: 14))
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                }
                                .padding(.horizontal, AppTheme.Layout.cardPadding)
                                .padding(.vertical, 12)
                            }
                            
                            Divider()
                                .padding(.leading, AppTheme.Layout.cardPadding + 28 + 8)
                            
                            HStack {
                                Text("Active: \(TrackAPI.baseURL)")
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                                Spacer()
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 10)
                        }
                    }
                    
                    Spacer()
                        .frame(height: 40)
                }
                .padding(.top, 12)
            }
        }
        .background(AppTheme.Colors.background)
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
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.vertical, 16)
        .background(AppTheme.Colors.background)
    }
    
    // MARK: - Section Builder
    
    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                .tracking(0.5)
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
