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
    
    /// Delay before allowing offline fallback login after cloud sync failure
    private let cloudSyncFallbackDelay: TimeInterval = 2.0

    var body: some View {
        ZStack {
            AppTheme.Colors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // App Identity
                appHeader

                Spacer()

                // Feature highlights
                featureHighlights
                    .padding(.bottom, 32)

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
        VStack(spacing: 20) {
            // App icon
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(AppTheme.Colors.subwayBlack)
                    .frame(width: 110, height: 110)
                    .shadow(color: AppTheme.Colors.subwayBlack.opacity(0.3), radius: 16, y: 8)
                Image(systemName: "tram.fill")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(.white)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Track")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text("NYC Transit, Live")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
            }
        }
    }

    // MARK: - Feature Highlights

    private var featureHighlights: some View {
        VStack(spacing: 12) {
            featureRow(icon: "location.fill", color: AppTheme.Colors.mtaBlue, text: "Real-time subway, bus & rail arrivals")
            featureRow(icon: "bell.badge.fill", color: AppTheme.Colors.warningYellow, text: "Live service alerts & delay notifications")
            featureRow(icon: "map.fill", color: AppTheme.Colors.successGreen, text: "Transit map with live vehicle tracking")
        }
        .padding(.horizontal, 8)
    }

    private func featureRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
            
            Spacer()
        }
    }

    // MARK: - Login Actions

    private var loginActions: some View {
        VStack(spacing: 14) {
            // Sign in with Apple button
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handleAppleSignIn(result: result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 54)
            .cornerRadius(14)
            .shadow(color: AppTheme.Colors.subwayBlack.opacity(0.15), radius: 8, y: 4)
            .disabled(isLoading)

            // Continue without account
            Button {
                continueWithoutAccount()
            } label: {
                Text("Continue without account")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.mtaBlue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        VStack(spacing: 6) {
            Text("Your data stays on your device.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
            Text("Sign in to sync across devices.")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
        }
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
                        
                        // Sync user data immediately after login
                        await SyncManager.shared.performFullSync()
                    } catch {
                        isLoading = false
                        errorMessage = error.localizedDescription
                        
                        // Fallback: still allow login even if cloud sync fails
                        // User data will be stored locally
                        DispatchQueue.main.asyncAfter(deadline: .now() + cloudSyncFallbackDelay) {
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
                // Initial sync for anonymous user
                await SyncManager.shared.performFullSync()
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
