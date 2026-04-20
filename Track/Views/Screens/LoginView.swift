// Authentication screen shown before onboarding.
// Uses Sign in with Apple as the primary login method.
// Integrates with Supabase for cloud sync and user management.

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var appleSignInDelegate: AppleSignInDelegate?

    // Staggered entrance animation
    @State private var showIcon = false
    @State private var showTitle = false
    @State private var showFeatures = false
    @State private var showActions = false

    var body: some View {
        ZStack {
            // Background
            ZStack {
                AppTheme.Gradients.screen
                AppTheme.Gradients.screenGlow
            }
            .ignoresSafeArea()

            // Content
            VStack(spacing: 0) {
                Spacer()
                    .frame(minHeight: 20)

                // App Identity
                appHeader
                    .padding(.bottom, 36)

                Spacer()

                // Feature highlights
                featureHighlights
                    .padding(.bottom, 40)

                // Login Actions
                loginActions

                // Error message
                if let error = errorMessage {
                    errorBanner(error)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Footer
                footerText
            }
            .padding(.horizontal, 28)
        }
        .onAppear { animateEntrance() }
    }

    // MARK: - Entrance Animation

    private func animateEntrance() {
        withAnimation(AppTheme.Animation.smooth.delay(0.1)) { showIcon = true }
        withAnimation(AppTheme.Animation.smooth.delay(0.25)) { showTitle = true }
        withAnimation(AppTheme.Animation.smooth.delay(0.4)) { showFeatures = true }
        withAnimation(AppTheme.Animation.smooth.delay(0.55)) { showActions = true }
    }

    // MARK: - App Header

    private var appHeader: some View {
        VStack(spacing: 24) {
            // Icon with glow
            ZStack {
                // Outer soft glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                AppTheme.Colors.accent.opacity(0.25),
                                AppTheme.Colors.accentSecondary.opacity(0.08),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 40,
                            endRadius: 100
                        )
                    )
                    .frame(width: 180, height: 180)

                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .shadow(color: AppTheme.Colors.shadow.opacity(0.35), radius: 20, y: 10)
                    .shadow(color: AppTheme.Colors.accent.opacity(0.15), radius: 30, y: 4)
                    .accessibilityHidden(true)
            }
            .opacity(showIcon ? 1 : 0)
            .scaleEffect(showIcon ? 1 : 0.8)

            // Title & tagline
            VStack(spacing: 10) {
                Text("Track")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text("NYC Transit, Live")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [AppTheme.Colors.accent, AppTheme.Colors.accentSecondary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .opacity(showTitle ? 1 : 0)
            .offset(y: showTitle ? 0 : 12)
        }
    }

    // MARK: - Feature Highlights

    private var featureHighlights: some View {
        VStack(spacing: 16) {
            featureRow(
                icon: "tram.fill",
                color: AppTheme.Colors.accent,
                title: "Live Arrivals",
                subtitle: "Subway, bus & rail — updated every second"
            )
            featureRow(
                icon: "bell.badge.fill",
                color: AppTheme.Colors.warningYellow,
                title: "Service Alerts",
                subtitle: "Delays, reroutes & planned work"
            )
            featureRow(
                icon: "map.fill",
                color: AppTheme.Colors.successGreen,
                title: "Live Map",
                subtitle: "Vehicle positions & station coverage"
            )
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 18)
        .trackCardBackground(cornerRadius: 20)
        .opacity(showFeatures ? 1 : 0)
        .offset(y: showFeatures ? 0 : 16)
    }

    private func featureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(color.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: color.opacity(0.3), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text(subtitle)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    // MARK: - Login Actions

    private var loginActions: some View {
        VStack(spacing: 16) {
            // Sign in with Apple button
            Button(action: startAppleSignIn) {
                HStack(spacing: 10) {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 19, weight: .semibold))
                    }
                    Text("Sign in with Apple")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [.white.opacity(0.15), .white.opacity(0.05)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .shadow(color: AppTheme.Colors.shadow.opacity(0.2), radius: 12, y: 6)
            .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)
            .disabled(isLoading)
            .opacity(isLoading ? 0.85 : 1)
            .animation(AppTheme.Animation.gentle, value: isLoading)
        }
        .padding(.bottom, 20)
        .opacity(showActions ? 1 : 0)
        .offset(y: showActions ? 0 : 16)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.Colors.alertRed)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.Colors.alertRed.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppTheme.Colors.alertRed.opacity(0.2), lineWidth: 0.5)
                )
        )
        .padding(.bottom, 16)
    }

    // MARK: - Footer

    private var footerText: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                Text("Your data stays on your device")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
            Text("Sign in to sync across devices")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.7))
        }
        .multilineTextAlignment(.center)
        .padding(.bottom, 36)
        .opacity(showActions ? 1 : 0)
    }

    // MARK: - Actions
    
    private func startAppleSignIn() {
        isLoading = true
        errorMessage = nil
        
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        
        let delegate = AppleSignInDelegate { result in
            handleAppleSignIn(result: result)
        }
        self.appleSignInDelegate = delegate
        
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = delegate
        
        // Set presentation context to the key window
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
            delegate.presentationAnchor = window
            controller.presentationContextProvider = delegate
        }
        
        controller.performRequests()
    }
    
    private func handleAppleSignIn(result: Result<ASAuthorization, Error>) {
        isLoading = true
        errorMessage = nil
        
        switch result {
        case .success(let authorization):
            if let appleIDCredential = authorization.credential
                as? ASAuthorizationAppleIDCredential {
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
                        // Cloud sync is best effort after a successful auth session.
                        await SyncManager.shared.performFullSync()
                        isLoading = false
                    } catch {
                        isLoading = false
                        #if DEBUG
                        print("[LoginView] Supabase sign-in error: \(error)")
                        #endif
                        errorMessage = "Sign-in error: \(error.localizedDescription)"
                    }
                }
            }
            
        case .failure(let error):
            isLoading = false
            let nsError = error as NSError

            // User tapped Cancel — no error to show
            if nsError.code == ASAuthorizationError.canceled.rawValue {
                return
            }

            // Dump everything Apple gives us so we can diagnose in Xcode console
            #if DEBUG
            print("╔══════════════════════════════════════════════")
            print("║ [LoginView] APPLE SIGN-IN FAILED")
            print("║ Domain : \(nsError.domain)")
            print("║ Code   : \(nsError.code)")
            print("║ Desc   : \(nsError.localizedDescription)")
            print("║ Info   : \(nsError.userInfo)")
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("║ Underlying:"
                    + " domain=\(underlying.domain)"
                    + " code=\(underlying.code)"
                    + " \(underlying.localizedDescription)")
            }
            print("╚══════════════════════════════════════════════")
            #endif

            switch ASAuthorizationError.Code(rawValue: nsError.code) {
            case .unknown:
                errorMessage = "Apple Sign-In couldn't connect."
                    + " Make sure you're signed into an Apple ID"
                    + " in Settings and try again."
            case .invalidResponse:
                errorMessage = "Apple returned an invalid response. Please try again."
            case .notHandled:
                errorMessage = "The sign-in request wasn't handled. Please try again."
            case .failed:
                errorMessage = "Apple Sign-In failed. Check your internet connection and try again."
            case .notInteractive:
                errorMessage = "Sign-in requires interaction. Please try again."
            default:
                errorMessage = "Sign in failed (code \(nsError.code)). Please try again."
            }
        }
    }
}

#Preview {
    LoginView()
}

// MARK: - Apple Sign-In Delegate

/// Handles ASAuthorizationController callbacks with proper presentation context.
class AppleSignInDelegate: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    var presentationAnchor: UIWindow?
    private let completion: (Result<ASAuthorization, Error>) -> Void
    
    init(completion: @escaping (Result<ASAuthorization, Error>) -> Void) {
        self.completion = completion
    }
    
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        if let window = scene?.windows.first(where: { $0.isKeyWindow }) {
            return window
        }
        if let anchor = presentationAnchor {
            return anchor
        }
        // scene is guaranteed non-nil on iOS — always at least one UIWindowScene
        return UIWindow(windowScene: scene!)
    }
    
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        completion(.success(authorization))
    }
    
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        completion(.failure(error))
    }
}
