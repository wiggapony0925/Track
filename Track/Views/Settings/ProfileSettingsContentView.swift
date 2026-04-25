import SwiftUI

struct ProfileSettingsContentView: View {
    @ObservedObject private var supabase = SupabaseManager.shared
    @State private var fullNameDraft: String = ""
    @State private var usernameDraft: String = ""
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saveMessageIsError = false

    let sheetNavigator: SheetNavigator

    private var currentProfile: UserProfile? { supabase.currentUser }

    private var fallbackDisplayName: String {
        if let fullName = currentProfile?.fullName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !fullName.isEmpty {
            return fullName
        }
        if let givenName = currentProfile?.givenName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !givenName.isEmpty {
            return givenName
        }
        if let username = currentProfile?.username?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !username.isEmpty {
            return username
        }
        if let email = currentProfile?.email, !email.isEmpty {
            return email.components(separatedBy: "@").first ?? "there"
        }
        return "there"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 20) {
                    avatarHero
                    profileSection
                    saveButton
                    saveMessageView
                    Spacer()
                        .frame(height: 40)
                }
                .padding(.top, 4)
            }
        }
        .background(AppTheme.Gradients.screen)
        .onAppear {
            hydrateDrafts()
        }
    }

    // MARK: - Profile Section (extracted to reduce body type-check)

    // MARK: - Avatar Hero

    private var avatarHero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [
                                AppTheme.Colors.accent,
                                AppTheme.Colors.accentSecondary,
                                AppTheme.Colors.accentDeep,
                                AppTheme.Colors.accent,
                            ],
                            center: .center
                        ),
                        lineWidth: 3
                    )
                    .frame(width: 84, height: 84)
                    .shadow(color: AppTheme.Colors.accent.opacity(0.35), radius: 16, y: 4)

                Circle()
                    .fill(AppTheme.Gradients.accentVibrant)
                    .frame(width: 76, height: 76)

                Text(String(fallbackDisplayName.prefix(1)).uppercased())
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
            }

            VStack(spacing: 3) {
                Text(fallbackDisplayName)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                if let email = currentProfile?.email {
                    Text(email)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Profile Fields

    private var profileSection: some View {
        section(title: "Edit Details", icon: "pencil.line", iconColor: AppTheme.Colors.accent) {
            VStack(spacing: 0) {
                editableField(
                    icon: "textformat",
                    iconColor: AppTheme.Colors.accent,
                    title: "Full Name",
                    text: $fullNameDraft,
                    placeholder: "Add your full name"
                )

                divider

                editableField(
                    icon: "at",
                    iconColor: AppTheme.Colors.accentSecondary,
                    title: "Username",
                    text: $usernameDraft,
                    placeholder: "Optional display username"
                )

                divider

                row(icon: "envelope.fill", iconColor: AppTheme.Colors.accentDeep, title: "Email") {
                    Text(currentProfile?.email ?? "Not available")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var saveButton: some View {
                    Button {
                        Task {
                            await saveProfile()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            Text(isSaving ? "Saving..." : "Save Profile")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .trackAccentBackground(cornerRadius: 14)
                    }
                    .disabled(isSaving || currentProfile == nil)
                    .padding(.horizontal, AppTheme.Layout.margin)
    }

    @ViewBuilder
    private var saveMessageView: some View {
                    if let saveMessage {
                        let messageColor: Color =
                            saveMessageIsError
                            ? AppTheme.Colors.alertRed
                            : AppTheme.Colors.successGreen
                        Text(saveMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(messageColor)
                            .padding(.horizontal, AppTheme.Layout.margin)
                    }
    }

    private func hydrateDrafts() {
        fullNameDraft = currentProfile?.fullName ?? ""
        usernameDraft = currentProfile?.username ?? ""
    }

    private func saveProfile() async {
        guard var profile = currentProfile else {
            saveMessageIsError = true
            saveMessage = "No active profile"
            return
        }

        isSaving = true
        saveMessage = nil

        let cleanedFullName = fullNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedUsername = usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        profile.fullName = cleanedFullName.isEmpty ? nil : cleanedFullName
        profile.username = cleanedUsername.isEmpty ? nil : cleanedUsername
        profile.lastLoginAt = Date()

        do {
            try await supabase.updateProfile(profile)
            saveMessageIsError = false
            saveMessage = "Profile updated"
            await SyncManager.shared.performFullSync()
        } catch {
            saveMessageIsError = true
            saveMessage = error.localizedDescription
        }

        isSaving = false
    }

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Profile")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                HStack {
                    Button {
                        sheetNavigator.goBack()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                            Text("Settings")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(AppTheme.Colors.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(AppTheme.Colors.accent.opacity(0.12))
                        )
                    }

                    Spacer()

                    Button {
                        sheetNavigator.popToRoot()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                AppTheme.Colors.textTertiary.opacity(0.7),
                                AppTheme.Colors.textTertiary.opacity(0.12)
                            )
                    }
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.top, 10)
            .padding(.bottom, 12)

            Rectangle()
                .fill(AppTheme.Colors.borderSubtle.opacity(0.5))
                .frame(height: 1)
        }
    }

    private var divider: some View {
        Divider()
            .padding(.leading, AppTheme.Layout.cardPadding + 36)
    }

    private func row<Trailing: View>(
        icon: String,
        iconColor: Color,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            iconBadge(icon, color: iconColor)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 13)
    }

    private func editableField(
        icon: String,
        iconColor: Color,
        title: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        HStack(spacing: 10) {
            iconBadge(icon, color: iconColor)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .frame(maxWidth: 180)
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 13)
    }

    private func iconBadge(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func section<Content: View>(
        title: String,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(iconColor.opacity(0.6))
                SectionHeader(title: title, size: 11, weight: .bold, tracking: 0.6)
            }
            .padding(.horizontal, AppTheme.Layout.margin + 4)

            content()
                .trackCardBackground(cornerRadius: AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
        }
    }
}

#Preview {
    ProfileSettingsContentView(sheetNavigator: SheetNavigator())
}
