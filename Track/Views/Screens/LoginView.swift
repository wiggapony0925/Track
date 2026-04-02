// Authentication screen shown before onboarding.
// Uses Sign in with Apple as the primary login method.
// Integrates with Supabase for cloud sync and user management.

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var appleSignInDelegate: AppleSignInDelegate?

    var body: some View {
        ZStack {
            ZStack {
                AppTheme.Gradients.screen
                AppTheme.Gradients.screenGlow
            }
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
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.accentGlow)
                    .frame(width: 156, height: 156)
                    .blur(radius: 24)

                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 110, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                    .shadow(color: AppTheme.Colors.shadow.opacity(0.4), radius: 16, y: 8)
                    .accessibilityHidden(true)
            }

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
            featureRow(
                icon: "location.fill",
                color: AppTheme.Colors.mtaBlue,
                text: "Real-time subway, bus & rail arrivals"
            )
            featureRow(
                icon: "bell.badge.fill",
                color: AppTheme.Colors.warningYellow,
                text: "Live service alerts & delay notifications"
            )
            featureRow(
                icon: "map.fill",
                color: AppTheme.Colors.successGreen,
                text: "Transit map with live vehicle tracking"
            )
        }
        .padding(18)
        .trackCardBackground(cornerRadius: 24)
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
                .foregroundColor(AppTheme.Colors.textPrimary)
            
            Spacer()
        }
    }

    // MARK: - Login Actions

    private var loginActions: some View {
        VStack(spacing: 14) {
            // Sign in with Apple button
            Button(action: startAppleSignIn) {
                HStack(spacing: 8) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Sign in with Apple")
                        .font(.system(size: 18, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.black)
                .cornerRadius(14)
            }
            .shadow(color: AppTheme.Colors.subwayBlack.opacity(0.15), radius: 8, y: 4)
            .disabled(isLoading)

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
                .foregroundColor(AppTheme.Colors.textTertiary)
        }
        .multilineTextAlignment(.center)
        .padding(.bottom, 32)
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
