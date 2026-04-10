// Main "Plan" tab — ultra-premium trip planning entry.
// Cinematic hero header, layered glassmorphic route card,
// pill quick-actions, saved-places gallery with accent top-bars,
// and staggered recent-trip cards.

import SwiftUI
import SwiftData

struct PlanView: View {
    @Environment(\.modelContext) private var modelContext
    let locationManager: LocationManager
    @State private var viewModel = PlanViewModel()
    @State private var animatePulse = false
    @State private var appeared = false

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Late night ride?"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                AppTheme.Gradients.screen.ignoresSafeArea()
                AppTheme.Gradients.screenSheen.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        heroHeader
                        bodyContent
                    }
                }

                if viewModel.destination != nil {
                    searchRoutesButton
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                viewModel.configure(
                    modelContext: modelContext,
                    locationManager: locationManager
                )
                withAnimation(.easeOut(duration: 0.6).delay(0.2)) {
                    appeared = true
                }
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    animatePulse = true
                }
            }
            .sheet(isPresented: $viewModel.showDestinationSearch) {
                DestinationSearchView(viewModel: viewModel, isOrigin: false)
            }
            .sheet(isPresented: $viewModel.showOriginSearch) {
                DestinationSearchView(viewModel: viewModel, isOrigin: true)
            }
            .sheet(isPresented: $viewModel.showTimePicker) {
                DepartureTimePickerSheet(viewModel: viewModel)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $viewModel.showResults) {
                TripResultsView(viewModel: viewModel)
            }
            .fullScreenCover(isPresented: $viewModel.showMapPicker) {
                MapLocationPickerView(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showAddPlaceSheet) {
                AddPlaceSheet(viewModel: viewModel)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .overlay(alignment: .top) {
                if !viewModel.showResults, let message = viewModel.errorMessage {
                    plannerErrorBanner(message)
                        .padding(.top, 12)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        ZStack(alignment: .bottom) {
            // Rich gradient backdrop with layered decorative orbs
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: AppTheme.Colors.accent, location: 0),
                        .init(color: AppTheme.Colors.accentDeep.opacity(0.95), location: 0.55),
                        .init(color: AppTheme.Colors.accentDeep, location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                // Large diffused orb top-left
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.12), .clear],
                            center: .center, startRadius: 0, endRadius: 130
                        )
                    )
                    .frame(width: 260, height: 260)
                    .offset(x: -90, y: -70)

                // Mid accent orb top-right with breathing
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [AppTheme.Colors.accentSecondary.opacity(0.18), .clear],
                            center: .center, startRadius: 0, endRadius: 90
                        )
                    )
                    .frame(width: 180, height: 180)
                    .offset(x: 150, y: -30)
                    .scaleEffect(animatePulse ? 1.1 : 0.92)

                // Subtle bottom-right warm blob
                Circle()
                    .fill(.white.opacity(0.04))
                    .frame(width: 120, height: 120)
                    .offset(x: 60, y: 60)

                // Noise texture illusion — very faint dots
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.02), .clear],
                            center: .center, startRadius: 0, endRadius: 60
                        )
                    )
                    .frame(width: 80, height: 80)
                    .offset(x: -30, y: 70)
            }
            .frame(height: 280)
            .clipShape(Rectangle())
            .ignoresSafeArea(edges: .top)

            // Title area overlay
            VStack(alignment: .leading, spacing: 8) {
                Text(greeting)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .tracking(0.3)

                Text("Where are you\nheaded?")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(3)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .frame(height: 280)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)

            // Floating route input card
            routeInputCard
                .offset(y: 76)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 24)
        }
        .padding(.bottom, 84)
    }

    // MARK: - Route Input Card

    private var routeInputCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Vertical connector — dot → gradient line → pin
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(AppTheme.Colors.accent.opacity(0.18))
                            .frame(width: 22, height: 22)
                            .scaleEffect(animatePulse ? 1.25 : 0.85)
                        Circle()
                            .fill(AppTheme.Colors.accent)
                            .frame(width: 10, height: 10)
                            .shadow(color: AppTheme.Colors.accent.opacity(0.4), radius: 4)
                    }

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppTheme.Colors.accent.opacity(0.8),
                                    AppTheme.Colors.accent.opacity(0.25),
                                    AppTheme.Colors.alertRed.opacity(0.55),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: 2.5, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 2))

                    ZStack {
                        Circle()
                            .fill(AppTheme.Colors.alertRed.opacity(0.12))
                            .frame(width: 20, height: 20)
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.alertRed)
                    }
                }
                .padding(.leading, 2)

                VStack(spacing: 8) {
                    planFieldButton(
                        label: viewModel.origin.displayName,
                        placeholder: "My location",
                        hasValue: true,
                        leadingIcon: "location.fill",
                        isOrigin: true
                    ) {
                        viewModel.showOriginSearch = true
                    }

                    planFieldButton(
                        label: viewModel.destination?.displayName,
                        placeholder: "Search destination...",
                        hasValue: viewModel.destination != nil,
                        leadingIcon: viewModel.destination != nil ? "mappin" : "magnifyingglass",
                        isOrigin: false
                    ) {
                        viewModel.showDestinationSearch = true
                    }
                }

                // Swap button with layered glass
                Button {
                    withAnimation(AppTheme.Animation.snappy) {
                        viewModel.swapOriginDestination()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(AppTheme.Colors.accent.opacity(0.08))
                            .frame(width: 42, height: 42)
                        Circle()
                            .strokeBorder(AppTheme.Colors.accent.opacity(0.2), lineWidth: 1)
                            .frame(width: 42, height: 42)
                        Circle()
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.06), location: 0),
                                        .init(color: .clear, location: 0.5),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .frame(width: 42, height: 42)
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                }
                .buttonStyle(PlanCardButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Separator
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            AppTheme.Colors.borderSubtle.opacity(0.05),
                            AppTheme.Colors.borderSubtle.opacity(0.2),
                            AppTheme.Colors.borderSubtle.opacity(0.05),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .padding(.horizontal, 20)

            DepartureTimeControl(
                departureOption: $viewModel.departureOption,
                onPickerTap: { viewModel.showTimePicker = true },
                onStep: { viewModel.stepTime(forward: $0) }
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)

                // Glass top-edge shimmer
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.07), location: 0),
                                .init(color: .clear, location: 0.35),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.1), location: 0),
                                .init(color: AppTheme.Colors.borderSubtle.opacity(0.15), location: 0.5),
                                .init(color: .white.opacity(0.05), location: 1),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .shadow(color: AppTheme.Colors.accent.opacity(0.07), radius: 40, y: 16)
        )
        .padding(.horizontal, 16)
    }

    private func planFieldButton(
        label: String?,
        placeholder: String,
        hasValue: Bool,
        leadingIcon: String?,
        isOrigin: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                if let icon = leadingIcon {
                    ZStack {
                        Circle()
                            .fill(
                                hasValue
                                    ? (isOrigin ? AppTheme.Colors.accent.opacity(0.1) : AppTheme.Colors.accent.opacity(0.08))
                                    : AppTheme.Colors.cardInset
                            )
                            .frame(width: isOrigin ? 24 : 28, height: isOrigin ? 24 : 28)
                        Image(systemName: icon)
                            .font(.system(size: isOrigin ? 10 : 12, weight: .semibold))
                            .foregroundStyle(
                                hasValue
                                    ? (isOrigin ? AppTheme.Colors.accent : AppTheme.Colors.textPrimary)
                                    : AppTheme.Colors.textTertiary
                            )
                    }
                }

                Text(label ?? placeholder)
                    .font(
                        isOrigin
                            ? .system(size: 14, weight: hasValue ? .semibold : .regular, design: .rounded)
                            : .system(size: 16, weight: hasValue ? .bold : .medium, design: .rounded)
                    )
                    .foregroundStyle(hasValue ? AppTheme.Colors.textPrimary : AppTheme.Colors.textTertiary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if hasValue && !isOrigin {
                    Button {
                        withAnimation(AppTheme.Animation.snappy) {
                            viewModel.destination = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, isOrigin ? 11 : 14)
            .background(
                RoundedRectangle(cornerRadius: isOrigin ? 12 : 14, style: .continuous)
                    .fill(AppTheme.Colors.cardInset)
                    .overlay(
                        RoundedRectangle(cornerRadius: isOrigin ? 12 : 14, style: .continuous)
                            .strokeBorder(
                                !isOrigin && !hasValue
                                    ? AppTheme.Colors.accent.opacity(animatePulse ? 0.3 : 0.08)
                                    : AppTheme.Colors.borderSubtle.opacity(0.08),
                                lineWidth: !isOrigin && !hasValue ? 1.5 : 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Floating Search Button

    private var searchRoutesButton: some View {
        Button {
            Task { await viewModel.planTrip() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                Text("Search Routes")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                    // Glass shimmer
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
                .shadow(color: AppTheme.Colors.accent.opacity(0.45), radius: 18, y: 6)
            )
        }
        .buttonStyle(PlanCardButtonStyle())
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    // MARK: - Body Content

    private var bodyContent: some View {
        VStack(spacing: 30) {
            savedLocationsGallery
            quickActionsRow
            recommendationsSection
            recentTripsSection
            Spacer(minLength: viewModel.destination != nil ? 120 : 100)
        }
        .padding(.top, 10)
    }

    private func plannerErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.Colors.alertRed)

            Text(message)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            Button {
                viewModel.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(AppTheme.Colors.cardInset))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(AppTheme.Colors.alertRed.opacity(0.12), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        )
    }

    // MARK: - Quick Actions

    private var quickActionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                quickActionChip(
                    icon: "location.fill",
                    label: "Use My Location",
                    color: AppTheme.Colors.accent
                ) {
                    viewModel.origin = .currentLocation
                    Task { await viewModel.refreshPlannerData() }
                }
                quickActionChip(
                    icon: "arrow.clockwise",
                    label: "Refresh",
                    color: AppTheme.Colors.successGreen
                ) {
                    Task { await viewModel.refreshPlannerData() }
                }
                quickActionChip(
                    icon: "arrow.up.arrow.down",
                    label: "Swap",
                    color: AppTheme.Colors.warningYellow
                ) {
                    withAnimation(AppTheme.Animation.snappy) {
                        viewModel.swapOriginDestination()
                    }
                }
                if let suggestion = viewModel.recommendations.first {
                    quickActionChip(
                        icon: "sparkles",
                        label: "Best Guess",
                        color: AppTheme.Colors.accentSecondary
                    ) {
                        viewModel.selectRecommendation(suggestion)
                        Task { await viewModel.planTrip() }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func quickActionChip(
        icon: String,
        label: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color)
                }
                Text(label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.04), location: 0),
                                        .init(color: .clear, location: 0.5),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(color.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            )
        }
        .buttonStyle(PlanCardButtonStyle())
    }

    // MARK: - Recommendations

    @ViewBuilder
    private var recommendationsSection: some View {
        if !viewModel.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(title: "Suggested Right Now")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.recommendations) { recommendation in
                            recommendationCard(recommendation)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private func recommendationCard(_ recommendation: PlannerRecommendation) -> some View {
        let accent = recommendationColor(for: recommendation.source)

        return Button {
            viewModel.selectRecommendation(recommendation)
            Task { await viewModel.planTrip() }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(recommendation.label)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(2)

                        Text(recommendation.reason)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(accent)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: recommendationIcon(for: recommendation.source))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(accent.opacity(0.12))
                        )
                }

                Text(recommendation.subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let upcoming = recommendation.upcomingDate {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(recommendationTimeString(upcoming))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(AppTheme.Colors.cardInset.opacity(0.55))
                        )
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        Text("Go")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(accent)
                }
            }
            .frame(width: 250, alignment: .leading)
            .padding(16)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground)

                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: accent.opacity(0.18), location: 0),
                                    .init(color: .clear, location: 0.4),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(accent.opacity(0.15), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            )
        }
        .buttonStyle(PlanCardButtonStyle())
    }

    // MARK: - Saved Locations Gallery

    private var savedLocationsGallery: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader(title: "Saved Places")
                Spacer()
                Button {
                    viewModel.beginCustomPlaceFlow()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .heavy))
                        Text("Add")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(AppTheme.Colors.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(AppTheme.Colors.accent.opacity(0.1))
                            .overlay(
                                Capsule()
                                    .strokeBorder(AppTheme.Colors.accent.opacity(0.15), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // Preset: Home
                    if let home = viewModel.savedLocation(for: .home) {
                        savedPlaceCard(
                            icon: "house.fill", label: "Home",
                            subtitle: home.address,
                            color: AppTheme.Colors.accent
                        ) {
                            viewModel.selectDestination(.saved(home))
                            Task { await viewModel.planTrip() }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteSavedLocation(home) }
                            } label: {
                                Label("Remove Home", systemImage: "trash")
                            }
                        }
                    } else {
                        addPlaceCard(
                            icon: "house.fill",
                            label: "Set Home",
                            color: AppTheme.Colors.accent
                        ) {
                            viewModel.beginSavedPlaceFlow(.home)
                        }
                    }

                    // Preset: Work
                    if let work = viewModel.savedLocation(for: .work) {
                        savedPlaceCard(
                            icon: "briefcase.fill", label: "Work",
                            subtitle: work.address,
                            color: AppTheme.Colors.warningYellow
                        ) {
                            viewModel.selectDestination(.saved(work))
                            Task { await viewModel.planTrip() }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteSavedLocation(work) }
                            } label: {
                                Label("Remove Work", systemImage: "trash")
                            }
                        }
                    } else {
                        addPlaceCard(
                            icon: "briefcase.fill",
                            label: "Set Work",
                            color: AppTheme.Colors.warningYellow
                        ) {
                            viewModel.beginSavedPlaceFlow(.work)
                        }
                    }

                    // Preset: School
                    if let school = viewModel.savedLocation(for: .school) {
                        savedPlaceCard(
                            icon: "graduationcap.fill", label: "School",
                            subtitle: school.address,
                            color: AppTheme.Colors.successGreen
                        ) {
                            viewModel.selectDestination(.saved(school))
                            Task { await viewModel.planTrip() }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteSavedLocation(school) }
                            } label: {
                                Label("Remove School", systemImage: "trash")
                            }
                        }
                    } else {
                        addPlaceCard(
                            icon: "graduationcap.fill",
                            label: "Set School",
                            color: AppTheme.Colors.successGreen
                        ) {
                            viewModel.beginSavedPlaceFlow(.school)
                        }
                    }

                    // Preset: Partner
                    if let partner = viewModel.savedLocation(for: .partner) {
                        savedPlaceCard(
                            icon: "heart.fill", label: partner.name,
                            subtitle: partner.address,
                            color: AppTheme.Colors.alertRed
                        ) {
                            viewModel.selectDestination(.saved(partner))
                            Task { await viewModel.planTrip() }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteSavedLocation(partner) }
                            } label: {
                                Label("Remove Partner", systemImage: "trash")
                            }
                        }
                    } else {
                        addPlaceCard(
                            icon: "heart.fill",
                            label: "Set Partner",
                            color: AppTheme.Colors.alertRed
                        ) {
                            viewModel.beginSavedPlaceFlow(.partner)
                        }
                    }

                    // Custom saved places
                    ForEach(viewModel.customSavedLocations) { place in
                        savedPlaceCard(
                            icon: place.iconName,
                            label: place.name,
                            subtitle: place.address,
                            color: AppTheme.Colors.accentSecondary
                        ) {
                            viewModel.selectDestination(.saved(place))
                            Task { await viewModel.planTrip() }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteSavedLocation(place) }
                            } label: {
                                Label("Remove \(place.name)", systemImage: "trash")
                            }
                        }
                    }

                    // "Add custom place" tile
                    addPlaceCard(
                        icon: "plus",
                        label: "Custom Place",
                        color: AppTheme.Colors.accentSecondary
                    ) {
                        viewModel.beginCustomPlaceFlow()
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
    private func savedPlaceCard(
        icon: String, label: String, subtitle: String,
        color: Color, onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.18), color.opacity(0.06)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(color.opacity(0.15), lineWidth: 0.5)
                        )
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 128, alignment: .leading)
            .padding(14)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground)
                    // Accent bar at top
                    VStack {
                        LinearGradient(
                            colors: [color.opacity(0.35), color.opacity(0.08)],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(height: 2.5)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
                        Spacer()
                    }
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.04), location: 0),
                                    .init(color: .clear, location: 0.3),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(color.opacity(0.1), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            )
        }
        .buttonStyle(PlanCardButtonStyle())
    }

    private func addPlaceCard(
        icon: String,
        label: String,
        color: Color,
        onTap: @escaping () -> Void
    ) -> some View {
        Button {
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            AppTheme.Colors.borderSubtle.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("Add")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(AppTheme.Colors.accent)
                }
            }
            .frame(width: 128, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        AppTheme.Colors.borderSubtle.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: [8, 5])
                    )
            )
        }
        .buttonStyle(PlanCardButtonStyle())
    }

    // MARK: - Recent Trips Section

    private var recentTripsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader(title: "Recent Trips")
                Spacer()
                if !viewModel.savedTrips.isEmpty {
                    Text("See All")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.accent)
                }
            }
            .padding(.trailing, 20)

            if viewModel.savedTrips.isEmpty {
                emptyRecentState
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.savedTrips) { trip in
                        RecentTripCard(trip: trip) {
                            viewModel.origin = .custom(
                                name: trip.originName,
                                address: trip.originAddress,
                                lat: trip.originLat,
                                lon: trip.originLon
                            )
                            viewModel.destination = .custom(
                                name: trip.destinationName,
                                address: trip.destinationAddress,
                                lat: trip.destinationLat,
                                lon: trip.destinationLon
                            )
                            Task { await viewModel.planTrip() }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    // MARK: - Section Header Helper

    private func sectionHeader(title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.Colors.textTertiary)
                .textCase(.uppercase)
                .tracking(1.0)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [AppTheme.Colors.borderSubtle.opacity(0.25), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Empty State

    private var emptyRecentState: some View {
        VStack(spacing: 20) {
            ZStack {
                // Outer glow
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.04))
                    .frame(width: 120, height: 120)

                Circle()
                    .fill(AppTheme.Colors.accentTint.opacity(0.5))
                    .frame(width: 80, height: 80)

                Circle()
                    .fill(AppTheme.Colors.cardBackground)
                    .frame(width: 64, height: 64)
                    .overlay(
                        Circle()
                            .strokeBorder(AppTheme.Colors.accent.opacity(0.1), lineWidth: 1)
                    )

                ZStack {
                    Image(systemName: "tram.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.accent)
                        .offset(x: -6, y: -3)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(AppTheme.Colors.accent.opacity(0.5))
                        .offset(x: 10, y: 6)
                }
            }

            VStack(spacing: 6) {
                Text("No recent trips")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text("Plan your first trip using the\nsearch bar above")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 40)
    }

    private func recommendationColor(for source: String) -> Color {
        switch source {
        case "calendar":
            return AppTheme.Colors.warningYellow
        case "saved_place":
            return AppTheme.Colors.accent
        case "recent_trip":
            return AppTheme.Colors.successGreen
        case "saved_trip":
            return AppTheme.Colors.accentSecondary
        default:
            return AppTheme.Colors.accent
        }
    }

    private func recommendationIcon(for source: String) -> String {
        switch source {
        case "calendar":
            return "calendar"
        case "saved_place":
            return "house.fill"
        case "recent_trip":
            return "clock.arrow.circlepath"
        case "saved_trip":
            return "star.fill"
        default:
            return "sparkles"
        }
    }

    private func recommendationTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
            return "Today \(formatter.string(from: date))"
        }
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Button Style

private struct PlanCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    PlanView(locationManager: LocationManager())
        .preferredColorScheme(.dark)
}
