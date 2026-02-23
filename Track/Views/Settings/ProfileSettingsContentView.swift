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
        if let fullName = currentProfile?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines), !fullName.isEmpty {
            return fullName
        }
        if let givenName = currentProfile?.givenName?.trimmingCharacters(in: .whitespacesAndNewlines), !givenName.isEmpty {
            return givenName
        }
        if let username = currentProfile?.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
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
                VStack(spacing: 24) {
                    section(title: "Profile", icon: "person.fill", iconColor: AppTheme.Colors.mtaBlue) {
                        VStack(spacing: 0) {
                            row(icon: "hand.wave.fill", iconColor: .orange, title: "Welcome") {
                                Text(fallbackDisplayName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                            }

                            divider

                            editableField(
                                icon: "textformat",
                                iconColor: .purple,
                                title: "Full Name",
                                text: $fullNameDraft,
                                placeholder: "Add your full name"
                            )

                            divider

                            editableField(
                                icon: "at",
                                iconColor: .indigo,
                                title: "Username",
                                text: $usernameDraft,
                                placeholder: "Optional display username"
                            )

                            divider

                            row(icon: "envelope.fill", iconColor: .mint, title: "Email") {
                                Text(currentProfile?.email ?? "Not available")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }

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
                        .background(AppTheme.Colors.mtaBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(isSaving || currentProfile == nil)
                    .padding(.horizontal, AppTheme.Layout.margin)

                    if let saveMessage {
                        Text(saveMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(saveMessageIsError ? AppTheme.Colors.alertRed : AppTheme.Colors.successGreen)
                            .padding(.horizontal, AppTheme.Layout.margin)
                    }

                    Spacer()
                        .frame(height: 40)
                }
                .padding(.top, 12)
            }
        }
        .background(AppTheme.Colors.background)
        .onAppear {
            hydrateDrafts()
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
        ZStack {
            Text("Profile")
                .font(.custom("Helvetica-Bold", size: 18))
                .foregroundColor(AppTheme.Colors.textPrimary)

            HStack {
                Button {
                    sheetNavigator.goBack()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Settings")
                            .font(.custom("Helvetica", size: 16))
                    }
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                }

                Spacer()

                Button {
                    sheetNavigator.popToRoot()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.vertical, 16)
        .background(AppTheme.Colors.background)
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
        HStack {
            iconView(icon, color: iconColor)
            Text(title)
                .font(.custom("Helvetica", size: 15))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 12)
    }

    private func editableField(
        icon: String,
        iconColor: Color,
        title: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        HStack {
            iconView(icon, color: iconColor)
            Text(title)
                .font(.custom("Helvetica", size: 15))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 14))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .frame(maxWidth: 180)
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 12)
    }

    private func iconView(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func section<Content: View>(
        title: String,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(iconColor.opacity(0.7))
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.6))
                    .tracking(0.5)
            }
            .padding(.horizontal, AppTheme.Layout.margin)

            content()
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
                .padding(.horizontal, AppTheme.Layout.margin)
        }
    }
}

#Preview {
    ProfileSettingsContentView(sheetNavigator: SheetNavigator())
}
