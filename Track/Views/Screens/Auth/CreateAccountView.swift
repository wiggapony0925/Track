// Account-creation destination pushed from `LoginView` or `SignInView`.
// A real screen, not a sheet, so it gets its own toolbar and back stack.

import SwiftUI

struct CreateAccountView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var fullName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    @FocusState private var focused: Field?
    private enum Field: Hashable { case name, email, password }

    var body: some View {
        ZStack {
            AuthBackground(haloOffset: .init(width: 80, height: -300))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                        .padding(.top, 4)

                    VStack(spacing: 12) {
                        AuthFieldRow(
                            icon: "person.fill",
                            placeholder: "Full name (optional)",
                            text: $fullName,
                            contentType: .name,
                            submitLabel: .next,
                            onSubmit: { focused = .email },
                            field: .name,
                            focusBinding: $focused
                        )

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
                            placeholder: "Password (8+ characters)",
                            text: $password,
                            contentType: .newPassword,
                            autocap: .never,
                            isSecure: true,
                            revealable: true,
                            submitLabel: .go,
                            onSubmit: { Task { await submit() } },
                            field: .password,
                            focusBinding: $focused
                        )

                        if !password.isEmpty {
                            PasswordStrengthMeter(
                                strength: AuthValidator.strength(of: password)
                            )
                            .transition(.opacity)
                        }
                    }

                    if let errorMessage {
                        AuthErrorBanner(message: errorMessage)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if let infoMessage {
                        AuthInfoBanner(message: infoMessage)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    AuthPrimaryButton(
                        label: "Create Account",
                        icon: "sparkles",
                        isWorking: isWorking,
                        isEnabled: canSubmit,
                        action: { Task { await submit() } }
                    )
                    .padding(.top, 4)

                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Already have an account?")
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                            Text("Sign in")
                                .foregroundStyle(AppTheme.Colors.accent)
                        }
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                    .buttonStyle(.plain)

                    legalFooter
                        .padding(.top, 4)
                }
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(AppTheme.Animation.gentle, value: errorMessage)
        .animation(AppTheme.Animation.gentle, value: infoMessage)
        .animation(AppTheme.Animation.gentle, value: password.isEmpty)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Create Account")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "person.badge.plus.fill")
                .font(.system(size: 20, weight: .heavy))
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

            Text("Create your account")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("We'll sync your places, trips and alerts across every device — privately and instantly.")
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var legalFooter: some View {
        Text("By creating an account you agree to Track's terms of service and acknowledge that arrival data is provided as-is.")
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(AppTheme.Colors.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
    }

    private var canSubmit: Bool {
        AuthValidator.isValidEmail(email)
            && AuthValidator.isAcceptableForSignUp(password)
    }

    @MainActor
    private func submit() async {
        focused = nil
        errorMessage = nil
        infoMessage = nil
        guard canSubmit else {
            errorMessage = "Enter a valid email and a password (8+ characters)."
            return
        }

        isWorking = true
        defer { isWorking = false }

        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await SupabaseManager.shared.signUpWithEmail(
                email: trimmed,
                password: password,
                fullName: fullName
            )
            await SyncManager.shared.performFullSync()
            dismiss()
        } catch SupabaseError.authFailed(let message)
            where message.lowercased().contains("inbox")
        {
            // Confirmation-required flow — no session yet.
            infoMessage = message
        } catch {
            errorMessage = AuthErrorMapper.friendly(error)
        }
    }
}

#Preview {
    NavigationStack { CreateAccountView() }
}
