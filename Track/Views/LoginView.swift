//
//  LoginView.swift
//  Track
//
//  Authentication screen shown before onboarding.
//  Uses Sign in with Apple as the primary login method.
//  Currently a visual placeholder — backend auth integration
//  will be connected when the database layer is added.
//

import SwiftUI

struct LoginView: View {
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @State private var isLoading = false

    var body: some View {
        ZStack {
            AppTheme.Colors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // App Identity
                appHeader

                Spacer()

                // Login Actions
                loginActions

                // Footer
                footerText
            }
            .padding(.horizontal, AppTheme.Layout.margin * 2)
        }
    }

    // MARK: - App Header

    private var appHeader: some View {
        VStack(spacing: 16) {
            // App icon
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(AppTheme.Colors.subwayBlack)
                    .frame(width: 100, height: 100)
                    .shadow(color: AppTheme.Colors.subwayBlack.opacity(0.3), radius: 12, y: 6)
                Image(systemName: "tram.fill")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textOnColor)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Track")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text("NYC Transit, Live")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
    }

    // MARK: - Login Actions

    private var loginActions: some View {
        VStack(spacing: 12) {
            // Sign in with Apple button
            Button {
                handleSignIn()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Sign in with Apple")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundColor(AppTheme.Colors.textOnColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(AppTheme.Colors.subwayBlack)
                .cornerRadius(AppTheme.Layout.cornerRadius)
            }
            .disabled(isLoading)
            .accessibilityLabel("Sign in with Apple")
            .accessibilityHint("Uses your Apple ID to sign in securely")

            // Continue without account
            Button {
                isLoggedIn = true
            } label: {
                Text("Continue without account")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .padding(.vertical, 12)
            }
            .accessibilityLabel("Continue without account")
            .accessibilityHint("Skip sign in and use Track without saving data to the cloud")

            if isLoading {
                ProgressView()
                    .tint(AppTheme.Colors.mtaBlue)
                    .padding(.top, 8)
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: - Footer

    private var footerText: some View {
        Text("Your data stays on your device.\nSign in to sync across devices later.")
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(AppTheme.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 32)
    }

    // MARK: - Actions

    private func handleSignIn() {
        isLoading = true
        // Placeholder: Apple Sign-In will be integrated here
        // when the database backend is connected.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            isLoading = false
            isLoggedIn = true
        }
    }
}

#Preview {
    LoginView()
}
