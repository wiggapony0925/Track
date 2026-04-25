// Authentication entry point shown before onboarding.
//
// Hosts a `NavigationStack` so Sign-In and Create-Account are real
// pushed destinations rather than modal sheets. Sign-in-with-Apple
// remains the primary CTA; the email path is two distinct routes.

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var appleSignInDelegate: AppleSignInDelegate?
    /// Plaintext nonce for the in-flight Apple Sign-In request.
    /// We hash this with SHA-256 and hand the hash to Apple, then
    /// forward the plaintext to Supabase so it can verify the
    /// `nonce` claim baked into the returned id_token.
    @State private var currentNonceRaw: String?

    // Staggered entrance.
    @State private var heroAppeared = false
    @State private var actionsAppeared = false

    var body: some View {
        NavigationStack {
            ZStack {
                AuthBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        Spacer(minLength: 28)

                        hero
                            .opacity(heroAppeared ? 1 : 0)
                            .offset(y: heroAppeared ? 0 : 18)

                        Spacer(minLength: 16)

                        actions
                            .opacity(actionsAppeared ? 1 : 0)
                            .offset(y: actionsAppeared ? 0 : 18)

                        if let errorMessage {
                            AuthErrorBanner(message: errorMessage)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .padding(.horizontal, 24)
                        }

                        trustRow
                            .padding(.top, 2)
                            .opacity(actionsAppeared ? 1 : 0)
                    }
                    .padding(.bottom, 28)
                    // Use the available container height instead of
                    // `UIScreen.main`, which is deprecated in iOS 26.
                    // `containerRelativeFrame` resolves against the
                    // ScrollView's clip bounds.
                    .containerRelativeFrame(.vertical) { height, _ in
                        max(0, height - 80)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .animation(AppTheme.Animation.gentle, value: errorMessage)
            .onAppear { animateEntrance() }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(AppTheme.Colors.accent)
    }

    // MARK: - Entrance

    private func animateEntrance() {
        withAnimation(AppTheme.Animation.smooth.delay(0.10)) { heroAppeared = true }
        withAnimation(AppTheme.Animation.smooth.delay(0.35)) { actionsAppeared = true }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.20))
                    .frame(width: 140, height: 140)
                    .blur(radius: 26)

                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.40), .white.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.85
                            )
                    )
                    .shadow(color: AppTheme.Colors.shadow.opacity(0.45), radius: 18, y: 10)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 4) {
                Text("Track")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .kerning(-0.5)

                Text("NYC transit, alive in your pocket.")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            // Apple's official SwiftUI button — handles HIG sizing,
            // localization, light/dark, accessibility, and the locked
            // visual treatment Apple requires for the SIWA flow.
            SignInWithAppleButton(.signIn) { request in
                let nonce = AuthNonce.make()
                currentNonceRaw = nonce.raw
                request.requestedScopes = [.fullName, .email]
                request.nonce = nonce.sha256
            } onCompletion: { result in
                handleAppleSignIn(
                    result: result.mapError { $0 as Error }
                )
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.22), radius: 12, y: 6)
            .overlay(alignment: .center) {
                if isLoading {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                        .overlay(
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.85)
                        )
                        .allowsHitTesting(true)
                }
            }
            .disabled(isLoading)
            .accessibilityLabel(isLoading ? "Signing in" : "Sign in with Apple")

            // Divider with "or"
            HStack(spacing: 10) {
                Rectangle()
                    .fill(AppTheme.Colors.textPrimary.opacity(0.10))
                    .frame(height: 0.75)
                Text("or")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .textCase(.uppercase)
                    .tracking(1.2)
                Rectangle()
                    .fill(AppTheme.Colors.textPrimary.opacity(0.10))
                    .frame(height: 0.75)
            }
            .padding(.vertical, 2)

            // Email sign-in route — pushed, not presented.
            NavigationLink {
                SignInView()
            } label: {
                authRow(
                    icon: "envelope.fill",
                    iconColor: AppTheme.Colors.textPrimary,
                    label: "Sign in with email"
                )
            }
            .buttonStyle(.plain)

            // Create-account route — quieter visual weight, but still
            // a real, full-bleed row rather than buried link text.
            NavigationLink {
                CreateAccountView()
            } label: {
                authRow(
                    icon: "person.badge.plus.fill",
                    iconColor: AppTheme.Colors.accent,
                    label: "Create a new account"
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 340)
        .padding(.horizontal, 22)
    }

    private func authRow(icon: String, iconColor: Color, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(iconColor)
            Text(label)
                .font(.system(size: 14.5, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(AppTheme.Colors.textTertiary)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.Colors.cardElevated.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            AppTheme.Colors.borderSubtle.opacity(0.6),
                            lineWidth: 0.75
                        )
                )
        )
    }

    // MARK: - Trust row

    private var trustRow: some View {
        HStack(spacing: 8) {
            trustChip(icon: "lock.shield.fill", label: "Private")
            trustChip(icon: "icloud.fill", label: "Synced")
            trustChip(icon: "bolt.fill", label: "Live")
        }
    }

    private func trustChip(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .heavy))
            Text(label)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
        }
        .foregroundColor(AppTheme.Colors.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(AppTheme.Colors.textPrimary.opacity(0.06))
                .overlay(
                    Capsule()
                        .strokeBorder(
                            AppTheme.Colors.textPrimary.opacity(0.08),
                            lineWidth: 0.5
                        )
                )
        )
    }

    // MARK: - Apple Sign-In

    private func handleAppleSignIn(result: Result<ASAuthorization, Error>) {
        isLoading = true
        errorMessage = nil

        switch result {
        case .success(let authorization):
            if let appleIDCredential = authorization.credential
                as? ASAuthorizationAppleIDCredential {
                let credentials = AppleSignInCredentials(
                    userId: appleIDCredential.user,
                    email: appleIDCredential.email,
                    fullName: appleIDCredential.fullName,
                    identityToken: appleIDCredential.identityToken,
                    authorizationCode: appleIDCredential.authorizationCode,
                    rawNonce: currentNonceRaw
                )
                // Burn the nonce after a single use.
                currentNonceRaw = nil

                Task { @MainActor in
                    do {
                        try await SupabaseManager.shared.signInWithApple(credentials: credentials)
                        await SyncManager.shared.performFullSync()
                        isLoading = false
                    } catch {
                        isLoading = false
                        #if DEBUG
                        print("[LoginView] Supabase sign-in error: \(error)")
                        #endif
                        errorMessage = AuthErrorMapper.friendly(error)
                    }
                }
            } else {
                isLoading = false
                currentNonceRaw = nil
                errorMessage = "Apple returned an unsupported credential type."
            }

        case .failure(let error):
            isLoading = false
            currentNonceRaw = nil
            let nsError = error as NSError

            if nsError.code == ASAuthorizationError.canceled.rawValue {
                return
            }

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
