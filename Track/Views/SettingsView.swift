//
//  SettingsView.swift
//  Track
//
//  User-facing settings for appearance, developer configuration, and account.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("isLoggedIn") private var isLoggedIn = false

    @AppStorage("dev_use_localhost") private var useLocalhost = false
    @AppStorage("dev_custom_ip") private var customIP = AppSettings.shared.defaultDeviceIP

    var body: some View {
        NavigationStack {
            List {
                appearanceSection
                accountSection
                developerSettingsSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                }
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Theme", selection: $appTheme) {
                Text("System").tag("system")
                Text("Dark").tag("dark")
                Text("Light").tag("light")
            }
        } header: {
            Text("Appearance")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            Button(role: .destructive) {
                isLoggedIn = false
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Sign Out")
                }
                .foregroundColor(AppTheme.Colors.alertRed)
            }
        } header: {
            Text("Account")
        }
    }

    // MARK: - Developer Settings

    private var developerSettingsSection: some View {
        Section {
            Toggle("Use Simulator (Localhost)", isOn: $useLocalhost)
                .tint(AppTheme.Colors.mtaBlue)

            if !useLocalhost {
                HStack {
                    Text("http://")
                    TextField("192.168.1.X", text: $customIP)
                        .keyboardType(.numbersAndPunctuation)
                    Text(":8000")
                }
            }

            // Show current base URL for debugging
            Text("Active: \(TrackAPI.baseURL)")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(AppTheme.Colors.textSecondary)
        } header: {
            Text("Developer Settings")
        }
    }
}

#Preview {
    SettingsView()
}
