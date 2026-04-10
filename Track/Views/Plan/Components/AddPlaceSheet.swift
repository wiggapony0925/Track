// Premium "Add Place" sheet — lets users save a custom location
// with a custom label and icon. Glassmorphic design with the app's
// accent palette. Supports preset categories and fully custom places.

import SwiftUI

struct AddPlaceSheet: View {
    @Bindable var viewModel: PlanViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false
    @FocusState private var isLabelFocused: Bool

    private let presetCategories: [(category: SavedLocationCategory, icon: String, color: Color)] = [
        (.home, "house.fill", AppTheme.Colors.accent),
        (.work, "briefcase.fill", AppTheme.Colors.warningYellow),
        (.school, "graduationcap.fill", AppTheme.Colors.successGreen),
        (.partner, "heart.fill", AppTheme.Colors.alertRed),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                AppTheme.Colors.background.ignoresSafeArea()
                RadialGradient(
                    colors: [AppTheme.Colors.accent.opacity(0.06), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 500
                )
                .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                        // Header illustration
                        headerIllustration
                            .padding(.top, 8)

                        // Preset categories
                        presetSection

                        // Divider with "or"
                        orDivider

                        // Custom place form
                        customPlaceSection

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationBarHidden(true)
            .overlay(alignment: .top) {
                sheetHeader
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.5).delay(0.1)) {
                    appeared = true
                }
            }
        }
    }

    // MARK: - Sheet Header

    private var sheetHeader: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(AppTheme.Colors.textTertiary.opacity(0.25))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a Place")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("Save locations you visit often")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
                Spacer()
                Button {
                    viewModel.cancelSavedPlaceFlow()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(AppTheme.Colors.cardInset)
                                .overlay(
                                    Circle()
                                        .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.3), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Rectangle()
                .fill(AppTheme.Colors.borderSubtle.opacity(0.1))
                .frame(height: 1)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Header Illustration

    private var headerIllustration: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Colors.accent.opacity(0.06))
                .frame(width: 110, height: 110)
            Circle()
                .fill(AppTheme.Colors.accent.opacity(0.1))
                .frame(width: 80, height: 80)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [AppTheme.Colors.accent.opacity(0.2), AppTheme.Colors.accentDeep.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
        .padding(.top, 80)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
    }

    // MARK: - Preset Categories

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("QUICK ADD")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textTertiary)
                .tracking(1.2)

            VStack(spacing: 8) {
                ForEach(presetCategories, id: \.category) { preset in
                    let existing = viewModel.savedLocation(for: preset.category)
                    presetRow(
                        category: preset.category,
                        icon: preset.icon,
                        color: preset.color,
                        existingPlace: existing
                    )
                }
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
    }

    private func presetRow(
        category: SavedLocationCategory,
        icon: String,
        color: Color,
        existingPlace: SavedLocation?
    ) -> some View {
        Button {
            if existingPlace != nil {
                // Tap to use as destination
                viewModel.cancelSavedPlaceFlow()
                dismiss()
                if let place = existingPlace {
                    viewModel.selectDestination(.saved(place))
                }
            } else {
                viewModel.showAddPlaceSheet = false
                viewModel.beginSavedPlaceFlow(category)
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(existingPlace != nil ? 0.18 : 0.08), color.opacity(0.04)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 46, height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(color.opacity(0.15), lineWidth: 0.5)
                        )
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(category.label)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)

                    if let place = existingPlace {
                        Text(place.address.isEmpty ? place.name : place.address)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                            .lineLimit(1)
                    } else {
                        Text("Tap to set your \(category.label.lowercased())")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textTertiary)
                    }
                }

                Spacer(minLength: 0)

                if existingPlace != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(color)
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .heavy))
                        Text("Set")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(color.opacity(0.1)))
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.04), location: 0),
                                        .init(color: .clear, location: 0.35),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                existingPlace != nil
                                    ? color.opacity(0.12)
                                    : AppTheme.Colors.borderSubtle.opacity(0.15),
                                lineWidth: 0.5
                            )
                    )
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
            )
        }
        .buttonStyle(AddPlaceButtonStyle())
    }

    // MARK: - Or Divider

    private var orDivider: some View {
        HStack(spacing: 14) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, AppTheme.Colors.borderSubtle.opacity(0.25)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 0.5)

            Text("OR")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textTertiary.opacity(0.5))
                .tracking(2)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [AppTheme.Colors.borderSubtle.opacity(0.25), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
        }
        .opacity(appeared ? 1 : 0)
    }

    // MARK: - Custom Place Section

    private var customPlaceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CUSTOM PLACE")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textTertiary)
                .tracking(1.2)

            // Name input
            VStack(alignment: .leading, spacing: 8) {
                Text("Label")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)

                HStack(spacing: 10) {
                    Image(systemName: viewModel.customPlaceIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.accent)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(AppTheme.Colors.accent.opacity(0.12)))

                    TextField("e.g. Gym, Mom's House, Coffee Shop...", text: $viewModel.customPlaceLabel)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .autocorrectionDisabled()
                        .focused($isLabelFocused)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    isLabelFocused
                                        ? AppTheme.Colors.accent.opacity(0.35)
                                        : AppTheme.Colors.borderSubtle.opacity(0.2),
                                    lineWidth: isLabelFocused ? 1.5 : 0.5
                                )
                        )
                        .shadow(
                            color: isLabelFocused ? AppTheme.Colors.accent.opacity(0.08) : .clear,
                            radius: 12
                        )
                )
            }

            // Icon picker
            VStack(alignment: .leading, spacing: 10) {
                Text("Icon")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                    ForEach(PlanViewModel.customPlaceIcons, id: \.icon) { item in
                        let isSelected = viewModel.customPlaceIcon == item.icon
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                viewModel.customPlaceIcon = item.icon
                            }
                        } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(
                                            isSelected
                                                ? AppTheme.Colors.accent.opacity(0.15)
                                                : AppTheme.Colors.cardInset
                                        )
                                        .frame(width: 46, height: 46)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .strokeBorder(
                                                    isSelected
                                                        ? AppTheme.Colors.accent.opacity(0.4)
                                                        : AppTheme.Colors.borderSubtle.opacity(0.15),
                                                    lineWidth: isSelected ? 1.5 : 0.5
                                                )
                                        )
                                    Image(systemName: item.icon)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundColor(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
                                }
                                Text(item.label)
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundColor(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Save custom button
            Button {
                viewModel.showAddPlaceSheet = false
                viewModel.pendingSavedPlaceCategory = .custom
                viewModel.searchText = ""
                viewModel.searchResults = []
                viewModel.showDestinationSearch = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .bold))
                    Text("Search for Location")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    ZStack {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                        Capsule()
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.15), location: 0),
                                        .init(color: .clear, location: 0.45),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }
                    .shadow(color: AppTheme.Colors.accent.opacity(0.35), radius: 14, y: 5)
                )
            }
            .buttonStyle(AddPlaceButtonStyle())
            .padding(.top, 4)

            // Existing custom places
            if !viewModel.customSavedLocations.isEmpty {
                existingCustomPlaces
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
    }

    // MARK: - Existing Custom Places

    private var existingCustomPlaces: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("YOUR PLACES")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .tracking(1.2)
                Rectangle()
                    .fill(AppTheme.Colors.borderSubtle.opacity(0.15))
                    .frame(height: 0.5)
            }
            .padding(.top, 8)

            ForEach(viewModel.customSavedLocations) { place in
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.Colors.accent.opacity(0.1))
                            .frame(width: 40, height: 40)
                        Image(systemName: place.iconName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                        if !place.address.isEmpty {
                            Text(place.address)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await viewModel.deleteSavedLocation(place) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.alertRed.opacity(0.7))
                            .frame(width: 30, height: 30)
                            .background(
                                Circle()
                                    .fill(AppTheme.Colors.alertRed.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground.opacity(0.5))
                )
            }
        }
    }
}

// MARK: - Button Style

private struct AddPlaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    AddPlaceSheet(viewModel: PlanViewModel())
        .preferredColorScheme(.dark)
}
