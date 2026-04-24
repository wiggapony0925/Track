// Sign-in destination pushed from `LoginView`. Owns its own
// NavigationStack-style toolbar and full-screen background; not a sheet.

import SwiftUI

struct SignInView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    @FocusState private var focused: Field?
    private enum Field: Hashable { case email, password }

    var body: some View {
        ZStack {
            AuthBackground(haloOffset: .init(width: -60, height: -300))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                        .padding(.top, 4)

                    VStack(spacing: 12) {
                        AuthFieldRow(
                            icon: "envelope.fill",
                            placeholder: "Email",
                            text: $email,
                            keyboard: .emailAddress,
                            contentType: .emailAddress,
                            autocap: .never,
                            submitLabel: .next,
                            onSubmit: { focused = .password },
                            field: .email,
                            focusBinding: $focused
                        )

                        AuthFieldRow(
                            icon: "lock.fill",
                            placeholder: "Password",
                            text: $password,
                            contentType: .password,
                            autocap: .never,
                            isSecure: true,
                            revealable: true,
                            submitLabel: .go,
                            onSubmit: { Task { await submit() } },
                            field: .password,
                            focusBinding: $focused
                        )
                    }

                    if let errorMessage {
                        AuthErrorBanner(message: errorMessage)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    AuthPrimaryButton(
                        label: "Sign In",
                        icon: "arrow.right",
                        isWorking: isWorking,
                        isEnabled: canSubmit,
                        action: { Task { await submit() } }
                    )
                    .padding(.top, 4)

                    NavigationLink {
                        CreateAccountView()
                    } label: {
                        HStack(spacing: 4) {
                            Text("New to Track?")
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                            Text("Create an account")
                                .foregroundStyle(AppTheme.Colors.accent)
                        }
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(AppTheme.Animation.gentle, value: errorMessage)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Sign In")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "person.fill")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 52, height: 52)
                .background(
                    Circle()
                        .fill(AppTheme.Colors.accent.opacity(0.14))
                        .overlay(
                            Circle().strokeBorder(
                                AppTheme.Colors.accent.opacity(0.30),
                                lineWidth: 1
                            )
                        )
                )
                .padding(.bottom, 2)

            Text("Welcome back")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("Sign in to sync your places, trips and saved routes across every device.")
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canSubmit: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && password.count >= 6
    }

    @MainActor
    private func submit() async {
        focused = nil
        errorMessage = nil
        guard canSubmit else {
            errorMessage = "Enter a valid email and a password (6+ characters)."
            return
        }

        isWorking = true
        defer { isWorking = false }

        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await SupabaseManager.shared.signInWithEmail(
                email: trimmed,
                password: password
            )
            await SyncManager.shared.performFullSync()
            // ContentView will switch off the auth gate automatically;
            // dismissing here keeps the back stack clean if it lingers.
            dismiss()
        } catch {
            errorMessage = AuthErrorMapper.friendly(error)
        }
    }
}

#Preview {
    NavigationStack { SignInView() }
}
