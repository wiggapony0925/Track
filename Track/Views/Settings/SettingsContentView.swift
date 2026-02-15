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
    
    let sheetNavigator: SheetNavigator
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Appearance Section
                settingsSection(title: "Appearance") {
                    VStack(spacing: 0) {
                        HStack {
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
                        .padding(.vertical, 12)
                    }
                }
                
                // Widget Section
                settingsSection(title: "Live Near Me Widget") {
                    VStack(spacing: 0) {
                        Button {
                            sheetNavigator.navigate(to: .widgetSchedules)
                        } label: {
                            HStack {
                                Image(systemName: "calendar.badge.clock")
                                    .foregroundColor(AppTheme.Colors.mtaBlue)
                                Text("Widget Schedules")
                                    .font(.custom("Helvetica", size: 16))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 12)
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
                                Text("Sign Out")
                                    .font(.custom("Helvetica", size: 16))
                            }
                            .foregroundColor(AppTheme.Colors.alertRed)
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // Developer Section
                settingsSection(title: "Developer Settings") {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Use Simulator (Localhost)")
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
                                .padding(.leading, AppTheme.Layout.cardPadding)
                            
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
                            .padding(.leading, AppTheme.Layout.cardPadding)
                        
                        HStack {
                            Text("Active: \(TrackAPI.baseURL)")
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, AppTheme.Layout.cardPadding)
                        .padding(.vertical, 8)
                    }
                }
                
                Spacer()
                    .frame(height: 40)
            }
            .padding(.top, 8)
        }
        .background(AppTheme.Colors.background)
    }
    
    // MARK: - Section Builder
    
    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.custom("Helvetica-Bold", size: 12))
                .foregroundColor(AppTheme.Colors.textSecondary)
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
