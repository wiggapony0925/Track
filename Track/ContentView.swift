//
//  ContentView.swift
//  Track
//
//  Created by Jeffrey Fernandez on 2/10/26.
//
//  Root view of the Track NYC Transit app.
//  Hosts onboarding, location gate, and the tab-based dashboard.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appTheme") private var appTheme = "system"
    @State private var selectedTab: Tab = .home
    @State private var locationManager = LocationManager()

    enum Tab: String {
        case home
        case history
    }

    /// True when the user has granted location access.
    private var locationGranted: Bool {
        locationManager.authorizationStatus == .authorizedWhenInUse ||
        locationManager.authorizationStatus == .authorizedAlways
    }

    /// Maps the appTheme string to a ColorScheme.
    private var colorScheme: ColorScheme? {
        switch appTheme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                OnboardingView()
            } else if locationGranted {
                TabView(selection: $selectedTab) {
                    HomeView()
                        .tabItem {
                            Label("Home", systemImage: "tram.fill")
                        }
                        .tag(Tab.home)

                    TripHistoryView()
                        .tabItem {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .tag(Tab.history)
                }
                .tint(AppTheme.Colors.mtaBlue)
            } else {
                LocationPermissionView(
                    authorizationStatus: $locationManager.authorizationStatus,
                    onRequestPermission: {
                        locationManager.requestPermission()
                    }
                )
            }
        }
        .preferredColorScheme(colorScheme)
        .onAppear {
            // Trigger the system prompt on first launch if not yet determined
            if hasCompletedOnboarding && locationManager.authorizationStatus == .notDetermined {
                locationManager.requestPermission()
            }
        }
    }
}

// MARK: - Trip History View

/// Displays past trip logs so the user can review their commute history.
struct TripHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TripLog.tripDate, order: .reverse) private var tripLogs: [TripLog]

    var body: some View {
        NavigationStack {
            Group {
                if tripLogs.isEmpty {
                    emptyState
                } else {
                    tripList
                }
            }
            .navigationTitle("Trip History")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tram")
                .font(.system(size: 48))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .accessibilityHidden(true)
            Text("No trips yet")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Text("Your trip history will appear here after you start tracking rides.")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Colors.background)
    }

    private var tripList: some View {
        List {
            ForEach(tripLogs) { log in
                TripLogRow(log: log)
            }
            .onDelete(perform: deleteLogs)
        }
        .listStyle(.plain)
    }

    private func deleteLogs(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(tripLogs[index])
            }
        }
    }
}

// MARK: - Trip Log Row

struct TripLogRow: View {
    let log: TripLog

    var body: some View {
        HStack(spacing: 12) {
            RouteBadge(routeID: log.routeID, size: .medium)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(log.originStationID) → \(log.destinationStationID)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(log.tripDate, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Delay indicator
            if log.delaySeconds != 0 {
                delayLabel
            }
        }
        .padding(.vertical, 4)
    }

    private var delayLabel: some View {
        let minutes = log.delaySeconds / 60
        let isLate = log.delaySeconds > 0
        let text = isLate ? "+\(minutes)m" : "\(minutes)m"
        let color = isLate ? AppTheme.Colors.alertRed : AppTheme.Colors.successGreen

        return Text(text)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundColor(color)
            .lineLimit(1)
            .accessibilityLabel(isLate ? "\(minutes) minutes late" : "\(abs(minutes)) minutes early")
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            Item.self,
            Station.self,
            Route.self,
            TripLog.self,
            CommutePattern.self,
        ], inMemory: true)
}
