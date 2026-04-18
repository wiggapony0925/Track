import SwiftUI
import UIKit

struct ProfileSettingsView: View {
    @ObservedObject private var supabase = SupabaseManager.shared

    @State private var fullNameDraft: String = ""
    @State private var usernameDraft: String = ""
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saveMessageIsError = false

    private var currentProfile: UserProfile? { supabase.currentUser }

    var body: some View {
        ZStack {
            AppTheme.Colors.background
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    profileFieldsSection
                    saveProfileButton
                    saveMessageLabel
                    Spacer()
                        .frame(height: 24)
                }
                .padding(.top, 12)
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hydrateDrafts()
        }
    }

    // MARK: - Extracted Sub-Views

    private var profileFieldsSection: some View {
        settingsSection(title: "Profile", icon: "person.fill", iconColor: AppTheme.Colors.mtaBlue) {
            VStack(spacing: 0) {
                rowLabel(
                    icon: "envelope.fill",
                    iconColor: .mint,
                    title: "Email",
                    value: currentProfile?.email
                        ?? "Not available"
                )

                settingsDivider

                editableField(
                    icon: "textformat",
                    iconColor: .purple,
                    title: "Full Name",
                    placeholder: "Add your full name",
                    text: $fullNameDraft,
                    capitalization: .words
                )

                settingsDivider

                editableField(
                    icon: "at",
                    iconColor: .indigo,
                    title: "Username",
                    placeholder: "Optional display username",
                    text: $usernameDraft,
                    capitalization: .none
                )
            }
        }
    }

    private var saveProfileButton: some View {
        Button {
            Task { await saveProfile() }
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
                let buttonTitle: String = isSaving ? "Saving..." : "Save Profile"
                Text(buttonTitle)
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppTheme.Colors.mtaBlue)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: AppTheme.Colors.mtaBlue.opacity(0.35), radius: 8, y: 4)
        }
        .disabled(isSaving || currentProfile == nil)
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    @ViewBuilder
    private var saveMessageLabel: some View {
        if let saveMessage {
            let messageColor: Color = saveMessageIsError
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

    private var settingsDivider: some View {
        Divider()
            .padding(.leading, AppTheme.Layout.cardPadding + 36)
    }

    private func settingsIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func rowLabel(
        icon: String,
        iconColor: Color,
        title: String,
        value: String
    ) -> some View {
        HStack {
            settingsIcon(icon, color: iconColor)
            Text(title)
                .font(.custom("Helvetica", size: 15))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 12)
    }

    private func editableField(
        icon: String,
        iconColor: Color,
        title: String,
        placeholder: String,
        text: Binding<String>,
        capitalization: TextInputAutocapitalization?
    ) -> some View {
        HStack {
            settingsIcon(icon, color: iconColor)
            Text(title)
                .font(.custom("Helvetica", size: 15))
                .foregroundColor(AppTheme.Colors.textPrimary)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 14))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .textInputAutocapitalization(capitalization)
                .disableAutocorrection(true)
                .frame(maxWidth: 180)
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 12)
    }

    private func settingsSection<Content: View>(
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
                SectionHeader(title: title, weight: .bold, tracking: 0.5, color: AppTheme.Colors.textSecondary.opacity(0.6))
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
    NavigationStack {
        ProfileSettingsView()
    }
}
