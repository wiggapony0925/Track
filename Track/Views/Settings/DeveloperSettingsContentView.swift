//
//  DeveloperSettingsContentView.swift
//  Track
//
//  Dedicated developer settings page for local backend controls and connectivity
//  diagnostics. This page is only reachable in debug builds.
//

import SwiftUI

struct DeveloperSettingsContentView: View {
    @AppStorage("dev_use_localhost") private var useLocalhost = false
    @AppStorage("dev_custom_ip") private var customIP = AppSettings.shared.defaultDeviceIP

    @State private var isPingingBackend = false
    @State private var backendPingText: String = "Not checked"
    @State private var backendPingIsHealthy: Bool? = nil

    let sheetNavigator: SheetNavigator

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 24) {
                    section(title: "Local Backend", icon: "network", iconColor: .orange) {
                        VStack(spacing: 0) {
                            row(icon: "desktopcomputer", iconColor: .mint, title: "Use Local Server") {
                                Toggle("", isOn: $useLocalhost)
                                    .tint(AppTheme.Colors.mtaBlue)
                                    .onChange(of: useLocalhost) { _, _ in
                                        TrackAPI.invalidateBaseURL()
                                    }
                            }

                            if useLocalhost {
                                divider

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

                            divider

                            HStack {
                                Image(systemName: "link")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                                Text(useLocalhost
                                    ? "http://\(customIP.isEmpty ? "127.0.0.1" : customIP):8000"
                                    : AppSettings.shared.prodBaseURL)
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, AppTheme.Layout.cardPadding)
                            .padding(.vertical, 8)

                            divider

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
                                    Task {
                                        await pingBackend()
                                    }
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

                            if !useLocalhost {
                                Text("Connected to production server")
                                    .font(.caption2)
                                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                                    .padding(.bottom, 8)
                            }
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

    private var header: some View {
        ZStack {
            Text("Developer")
                .font(.custom("Helvetica-Bold", size: 18))
                .foregroundColor(AppTheme.Colors.textPrimary)

            HStack {
                Button {
                    sheetNavigator.goBack()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Settings")
                            .font(.custom("Helvetica", size: 16))
                    }
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                }

                Spacer()

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

    private var divider: some View {
        Divider()
            .padding(.leading, AppTheme.Layout.cardPadding + 36)
    }

    private func row<Trailing: View>(
        icon: String,
        iconColor: Color,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            iconView(icon, color: iconColor)
            Text(title)
                .font(.custom("Helvetica", size: 15))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 12)
    }

    private func iconView(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func section<Content: View>(
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
    DeveloperSettingsContentView(sheetNavigator: SheetNavigator())
}
