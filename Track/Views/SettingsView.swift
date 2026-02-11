//
//  SettingsView.swift
//  Track
//
//  User-facing settings for managing smart features, data, and appearance.
//  Allows clearing commute history and resetting reliability scores.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage("predictCommuteEnabled") private var predictCommuteEnabled = true
    @AppStorage("backgroundLearningEnabled") private var backgroundLearningEnabled = true
    @AppStorage("appTheme") private var appTheme = "system"

    @AppStorage("dev_use_localhost") private var useLocalhost = true
    @AppStorage("dev_custom_ip") private var customIP = "192.168.1.X"

    @State private var showClearHistoryConfirmation = false
    @State private var showResetScoresConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                smartFeaturesSection
                dataManagementSection
                appearanceSection
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

    // MARK: - Smart Features

    private var smartFeaturesSection: some View {
        Section {
            Toggle("Predict Commute", isOn: $predictCommuteEnabled)
                .tint(AppTheme.Colors.mtaBlue)

            Toggle("Background Learning", isOn: $backgroundLearningEnabled)
                .tint(AppTheme.Colors.mtaBlue)
        } header: {
            Text("Smart Features")
        } footer: {
            Text("Predict Commute shows smart suggestions based on your habits. Background Learning records trip patterns to improve predictions.")
        }
    }

    // MARK: - Data Management

    private var dataManagementSection: some View {
        Section {
            Button(role: .destructive) {
                showClearHistoryConfirmation = true
            } label: {
                Label("Clear Commute History", systemImage: "trash")
            }
            .confirmationDialog(
                "Clear all commute patterns?",
                isPresented: $showClearHistoryConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    clearCommuteHistory()
                }
            } message: {
                Text("This will reset all learned commute patterns. Smart suggestions will start fresh.")
            }

            Button(role: .destructive) {
                showResetScoresConfirmation = true
            } label: {
                Label("Reset Reliability Scores", systemImage: "arrow.counterclockwise")
            }
            .confirmationDialog(
                "Reset all reliability data?",
                isPresented: $showResetScoresConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset Scores", role: .destructive) {
                    resetReliabilityScores()
                }
            } message: {
                Text("This will delete all trip logs used to calculate delay warnings.")
            }
        } header: {
            Text("Data Management")
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
        } header: {
            Text("Developer Settings")
        }
    }

    // MARK: - Actions

    private func clearCommuteHistory() {
        do {
            try modelContext.delete(model: CommutePattern.self)
            try modelContext.save()
        } catch {
            print("Failed to clear commute history: \(error)")
        }
    }

    private func resetReliabilityScores() {
        do {
            try modelContext.delete(model: TripLog.self)
            try modelContext.save()
        } catch {
            print("Failed to reset reliability scores: \(error)")
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [
            CommutePattern.self,
            TripLog.self,
        ], inMemory: true)
}
