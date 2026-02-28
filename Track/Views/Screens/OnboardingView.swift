//
//  OnboardingView.swift
//  Track
//
//  A 3-page swipeable onboarding flow shown on first launch.
//  Requests Location and Live Activity permissions gracefully.
//

import SwiftUI
import ActivityKit

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0
    @State private var locationManager = LocationManager()

    var body: some View {
        ZStack {
            AppTheme.Colors.background
                .ignoresSafeArea()

            TabView(selection: $currentPage) {
                locationPage.tag(0)
                activitiesPage.tag(1)
                readyPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
    }

    // MARK: - Page 1: Location

    private var locationPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "location.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(AppTheme.Colors.mtaBlue)
                .accessibilityHidden(true)

            Text("Find Your Station")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text("Track uses your location to find the nearest station instantly.")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                locationManager.requestPermission()
                withAnimation { currentPage = 1 }
            } label: {
                Text("Allow Location")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppTheme.Colors.mtaBlue)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Page 2: Live Activities

    private var activitiesPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 80))
                .foregroundColor(AppTheme.Colors.successGreen)
                .accessibilityHidden(true)

            Text("Stay Updated")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text("Track uses Live Activities to keep your train on your Lock Screen.")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                withAnimation { currentPage = 2 }
            } label: {
                Text("Enable Activities")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppTheme.Colors.successGreen)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Page 3: Ready

    private var readyPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(AppTheme.Colors.successGreen)
                .accessibilityHidden(true)

            Text("Ready.")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)

            Text("Track will learn your commute and get smarter over time.")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                hasCompletedOnboarding = true
            } label: {
                Text("Get Started")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppTheme.Colors.mtaBlue)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }
}

#Preview {
    OnboardingView()
}
