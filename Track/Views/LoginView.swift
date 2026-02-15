//
//  LoginView.swift
//  Track
//
//  Authentication screen shown before onboarding.
//  Uses Sign in with Apple as the primary login method.
//  Integrates with Supabase for cloud sync and user management.
//

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @State private var isLoading = false
    @State private var errorMessage: String?

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
                
                // Error message
                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.Colors.alertRed)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 16)
                }

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
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handleAppleSignIn(result: result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .cornerRadius(AppTheme.Layout.cornerRadius)
            .disabled(isLoading)

            // Continue without account
            Button {
                continueWithoutAccount()
            } label: {
                Text("Continue without account")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .padding(.vertical, 12)
            }
            .accessibilityLabel("Continue without account")
            .accessibilityHint("Skip sign in and use Track without an account")

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
        Text("Your data stays on your device.\nSign in to sync across devices.")
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(AppTheme.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 32)
    }

    // MARK: - Actions
    
    private func handleAppleSignIn(result: Result<ASAuthorization, Error>) {
        isLoading = true
        errorMessage = nil
        
        switch result {
        case .success(let authorization):
            if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
                // Extract credentials
                let credentials = AppleSignInCredentials(
                    userId: appleIDCredential.user,
                    email: appleIDCredential.email,
                    fullName: appleIDCredential.fullName,
                    identityToken: appleIDCredential.identityToken,
                    authorizationCode: appleIDCredential.authorizationCode
                )
                
                // Sign in with Supabase
                Task { @MainActor in
                    do {
                        try await SupabaseManager.shared.signInWithApple(credentials: credentials)
                        isLoading = false
                        isLoggedIn = true
                    } catch {
                        isLoading = false
                        errorMessage = error.localizedDescription
                        
                        // Fallback: still allow login even if cloud sync fails
                        // User data will be stored locally
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isLoggedIn = true
                        }
                    }
                }
            }
            
        case .failure(let error):
            isLoading = false
            // User cancelled or error occurred
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMessage = "Sign in failed. Please try again."
            }
        }
    }
    
    private func continueWithoutAccount() {
        isLoading = true
        
        // Optionally create anonymous Supabase session for basic features
        Task { @MainActor in
            do {
                try await SupabaseManager.shared.signInAnonymously()
            } catch {
                // Continue anyway - local-only mode
                print("Anonymous sign-in failed: \(error)")
            }
            isLoading = false
            isLoggedIn = true
        }
    }
}

#Preview {
    LoginView()
}
