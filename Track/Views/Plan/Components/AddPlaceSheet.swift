// Add Place sheet — custom place builder. Matches TripSettingsSheet
// card style and uses the same adaptive AppTheme tokens throughout.

import SwiftUI

struct AddPlaceSheet: View {
    @Bindable var viewModel: PlanViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false
    @FocusState private var isLabelFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()
                AppTheme.Gradients.screenSheen.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: AppTheme.Spacing.section) {
                        nameCard
                        iconCard
                        existingPlaces
                        Spacer(minLength: 120)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                .scrollContentBackground(.hidden)

                // Floating search button pinned to bottom
                VStack {
                    Spacer()
                    searchButton
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                        .background(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: AppTheme.Colors.background.opacity(0.85), location: 0.25),
                                    .init(color: AppTheme.Colors.background, location: 1.0),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                            .frame(height: 120)
                            .allowsHitTesting(false)
                        )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(AppTheme.Colors.cardElevated)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.3), lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.accent)
                        Text("New Place")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) {
                appeared = true
            }
        }
    }

    // MARK: - Name Card

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Name", icon: "character.cursor.ibeam")

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.Colors.accent.opacity(0.15), AppTheme.Colors.accent.opacity(0.06)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)
                        .overlay(
                            Circle()
                                .strokeBorder(AppTheme.Colors.accent.opacity(0.18), lineWidth: 0.75)
                        )
                    Image(systemName: viewModel.customPlaceIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.accent)
                }

                TextField("", text: $viewModel.customPlaceLabel, prompt:
                    Text("e.g. Gym, Coffee Shop...")
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                )
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .autocorrectionDisabled()
                .focused($isLabelFocused)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.Colors.cardInset)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isLabelFocused
                                    ? AppTheme.Colors.accent.opacity(0.40)
                                    : AppTheme.Colors.borderSubtle.opacity(0.20),
                                lineWidth: isLabelFocused ? 1.5 : 0.5
                            )
                    )
            )
        }
        .padding(16)
        .background(cardBackground)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
    }

    // MARK: - Icon Card

    private var iconCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Choose Icon", icon: "square.grid.2x2")

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6),
                spacing: 12
            ) {
                ForEach(PlanViewModel.customPlaceIcons, id: \.icon) { item in
                    let isSelected = viewModel.customPlaceIcon == item.icon
                    Button {
                        withAnimation(AppTheme.Animation.snappy) {
                            viewModel.customPlaceIcon = item.icon
                        }
                    } label: {
                        VStack(spacing: 6) {
                            iconTile(item: item, isSelected: isSelected)

                            Text(item.label)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(
                                    isSelected
                                        ? AppTheme.Colors.accent
                                        : AppTheme.Colors.textTertiary
                                )
                        }
                    }
                    .buttonStyle(PlaceButtonStyle())
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
    }

    private func iconTile(item: (icon: String, label: String), isSelected: Bool) -> some View {
        let gradient: LinearGradient = isSelected
            ? LinearGradient(
                colors: [AppTheme.Colors.accent.opacity(0.18), AppTheme.Colors.accent.opacity(0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
              )
            : LinearGradient(
                colors: [AppTheme.Colors.cardElevated, AppTheme.Colors.cardInset],
                startPoint: .top, endPoint: .bottom
              )
        let borderColor = isSelected
            ? AppTheme.Colors.accent.opacity(0.35)
            : AppTheme.Colors.borderSubtle.opacity(0.20)
        let shadowColor = isSelected
            ? AppTheme.Colors.accent.opacity(0.20)
            : Color.clear

        return ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(gradient)
                .frame(width: 46, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 0.5)
                )
                .shadow(color: shadowColor, radius: 8, y: 3)

            Image(systemName: item.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(
                    isSelected
                        ? AppTheme.Colors.accent
                        : AppTheme.Colors.textTertiary
                )
        }
    }

    // MARK: - Search Button (Floating)

    private var searchButton: some View {
        Button {
            viewModel.showAddPlaceSheet = false
            viewModel.pendingSavedPlaceCategory = .custom
            viewModel.searchText = ""
            viewModel.searchResults = []
            viewModel.showDestinationSearch = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                    .symbolEffect(.pulse, options: .repeating, isActive: !viewModel.customPlaceLabel.isEmpty)
                Text("Search for Location")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.Gradients.accent)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.22), location: 0.0),
                                .init(color: .white.opacity(0.06), location: 1.0),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: AppTheme.Colors.accent.opacity(0.4), radius: 16, y: 8)
            .shadow(color: AppTheme.Colors.accentDeep.opacity(0.2), radius: 6, y: 3)
        }
        .buttonStyle(PlaceButtonStyle())
    }

    // MARK: - Existing Places

    @ViewBuilder
    private var existingPlaces: some View {
        if !viewModel.customSavedLocations.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader(title: "Your Places", icon: "bookmark.fill")

                ForEach(viewModel.customSavedLocations) { place in
                    existingPlaceRow(place)
                }
            }
            .padding(16)
            .background(cardBackground)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
        }
    }

    private func existingPlaceRow(_ place: SavedLocation) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.Colors.accentSecondary.opacity(0.15), AppTheme.Colors.accentSecondary.opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 42, height: 42)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AppTheme.Colors.accentSecondary.opacity(0.12), lineWidth: 0.5)
                    )
                Image(systemName: place.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accentSecondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                if !place.address.isEmpty {
                    Text(place.address)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button {
                Task { await viewModel.deleteSavedLocation(place) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.alertRed.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(AppTheme.Colors.alertRed.opacity(0.06))
                            .overlay(
                                Circle()
                                    .strokeBorder(AppTheme.Colors.alertRed.opacity(0.10), lineWidth: 0.5)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Colors.cardInset)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Shared Card Components

    private func cardHeader(title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppTheme.Colors.accent)
            SectionHeader(title: title, tracking: 1.0)
        }
        .padding(.leading, 4)
    }

    private var cardBackground: some View {
        let borderGradient = LinearGradient(
            stops: [
                .init(color: AppTheme.Colors.glassHighlight.opacity(0.12), location: 0.0),
                .init(color: AppTheme.Colors.borderSubtle.opacity(0.08), location: 1.0),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )

        return RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.Gradients.chromeHighlight)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(borderGradient, lineWidth: 0.75)
            )
            .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 8, y: 4)
            .shadow(color: AppTheme.Colors.shadowStrong.opacity(0.03), radius: 16, y: 8)
    }
}

// MARK: - Button Style

private struct PlaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    ZStack {
        AppTheme.Gradients.screen.ignoresSafeArea()
        Color.clear
            .sheet(isPresented: .constant(true)) {
                AddPlaceSheet(viewModel: PlanViewModel())
            }
    }
}
