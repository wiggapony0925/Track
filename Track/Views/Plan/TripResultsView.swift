// Full-screen trip results — Transit-style layout with compact
// gradient header, clean route summary, staggered animated cards,
// and polished loading/error states.

import SwiftUI

struct TripResultsView: View {
    @Bindable var viewModel: PlanViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTrip: TripPlan?
    @State private var appeared = false
    @State private var headerPulse = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppTheme.Gradients.screen.ignoresSafeArea()
                AppTheme.Gradients.screenSheen.ignoresSafeArea()

                VStack(spacing: 0) {
                    resultsHeader

                    if viewModel.isLoading {
                        loadingState
                    } else if let error = viewModel.errorMessage, viewModel.tripResults.isEmpty {
                        errorState(error)
                    } else {
                        if viewModel.isUsingAppleFallback {
                            appleFallbackBanner
                        }
                        if let note = viewModel.scheduleNote {
                            scheduleNoteBanner(note)
                        }
                        resultsList
                    }
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $selectedTrip) { trip in
                TripDetailSheet(trip: trip)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
                    appeared = true
                }
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                    headerPulse = true
                }
            }
        }
    }

    // MARK: - Header

    private var resultsHeader: some View {
        VStack(spacing: 0) {
            // Origin / Destination pill fields + swap button
            HStack(alignment: .center, spacing: 10) {
                // Dots column
                VStack(spacing: 4) {
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                    Rectangle()
                        .fill(.white.opacity(0.35))
                        .frame(width: 2, height: 18)
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                }

                // Pill fields
                VStack(spacing: 6) {
                    // Origin pill
                    HStack(spacing: 8) {
                        Image(systemName: originIcon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(viewModel.origin.displayName)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                            )
                    )

                    // Destination pill
                    HStack(spacing: 8) {
                        Image(systemName: "mappin")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(viewModel.destination?.displayName ?? "Destination")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                            )
                    )
                }

                // Swap button
                Button {
                    withAnimation(AppTheme.Animation.snappy) {
                        viewModel.swapOriginDestination()
                        Task { await viewModel.planTrip() }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(.white.opacity(0.15))
                                .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                        )
                }
                .buttonStyle(ResultsButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 30) // extra space for overlap
        }
        .background(
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: AppTheme.Colors.accent, location: 0),
                        .init(color: AppTheme.Colors.accentDeep, location: 0.65),
                        .init(color: AppTheme.Colors.accentDeep.opacity(0.95), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.06), .clear],
                            center: .center, startRadius: 0, endRadius: 100
                        )
                    )
                    .frame(width: 200, height: 200)
                    .offset(x: 130, y: -70)
                    .scaleEffect(headerPulse ? 1.03 : 0.97)
            }
            .ignoresSafeArea(edges: .top)
        )
        // Control bar overlapping the header/content boundary
        .overlay(alignment: .bottom) {
            departureControlBar
                .offset(y: 18)
        }
    }

    // Floating control bar: Leave now + refresh + X
    private var departureControlBar: some View {
        HStack(spacing: 10) {
            // Leave now / departure chip
            Button {
                viewModel.showTimePicker = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(viewModel.departureTimeLabel)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(AppTheme.Colors.cardBackground)
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                )
            }
            .buttonStyle(.plain)

            // Refresh
            Button {
                Task { await viewModel.planTrip() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(AppTheme.Colors.cardBackground)
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    )
            }
            .buttonStyle(ResultsButtonStyle())

            Spacer()

            // Close button (red X like Transit)
            Button {
                viewModel.clearResults()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(AppTheme.Colors.alertRed)
                            .shadow(color: AppTheme.Colors.alertRed.opacity(0.3), radius: 6, y: 2)
                    )
            }
            .buttonStyle(ResultsButtonStyle())
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Space for the floating departure control bar
                Spacer().frame(height: 24)

                // Transit-style card rows
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.tripResults.enumerated()), id: \.element.id) { index, trip in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 16)
                        }

                        TripResultCard(
                            trip: trip,
                            onTap: { selectedTrip = trip },
                            isRecommended: index == 0
                        )
                    }
                }

                // Show more trips button (not available in Apple Maps fallback)
                if !viewModel.tripResults.isEmpty && !viewModel.isUsingAppleFallback {
                    showMoreTripsButton
                        .padding(.top, 12)
                        .disabled(viewModel.isLoadingMore)
                }

                otherOptionsSection

                Spacer(minLength: 80)
            }
        }
    }

    // MARK: - Show More Trips

    private var showMoreTripsButton: some View {
        Button {
            Task { await viewModel.loadMoreTrips() }
        } label: {
            HStack {
                if viewModel.isLoadingMore {
                    ProgressView()
                        .tint(AppTheme.Colors.textTertiary)
                        .scaleEffect(0.8)
                } else {
                    Text("Show more trips")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                Spacer()
                if !viewModel.isLoadingMore {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
            )
        }
        .buttonStyle(ResultsButtonStyle())
        .padding(.horizontal, 16)
    }

    // MARK: - Other Options

    private var otherOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Other Options")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.Colors.borderSubtle.opacity(0.25), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(height: 0.5)
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)

            otherOptionRow(
                icon: "figure.walk",
                iconColor: AppTheme.Colors.successGreen,
                title: "Walk the entire way",
                subtitle: !estimatedWalkTime.isEmpty ? "Estimated \(estimatedWalkTime)" : nil
            )

            otherOptionRow(
                icon: "bicycle",
                iconColor: AppTheme.Colors.accent,
                title: "Bike (Citi Bike)",
                subtitle: "Check nearby stations"
            )
        }
    }

    private func otherOptionRow(
        icon: String, iconColor: Color,
        title: String, subtitle: String?
    ) -> some View {
        Button {} label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [iconColor.opacity(0.15), iconColor.opacity(0.06)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 46, height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(iconColor.opacity(0.12), lineWidth: 0.5)
                        )
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.35))
            }
            .padding(14)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.03), location: 0),
                                    .init(color: .clear, location: 0.4),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.2), lineWidth: 0.5)
                }
            )
        }
        .buttonStyle(ResultsButtonStyle())
        .padding(.horizontal, 16)
    }

    // MARK: - Loading State

    @State private var shimmerPhase: CGFloat = 0

    private var loadingState: some View {
        VStack(spacing: 28) {
            Spacer()

            // Animated indicator
            ZStack {
                Circle()
                    .stroke(AppTheme.Colors.accent.opacity(0.1), lineWidth: 3)
                    .frame(width: 94, height: 94)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [AppTheme.Colors.accent.opacity(0.08), .clear],
                            center: .center, startRadius: 0, endRadius: 48
                        )
                    )
                    .frame(width: 80, height: 80)

                Circle()
                    .fill(AppTheme.Colors.cardBackground)
                    .frame(width: 60, height: 60)
                    .overlay(
                        Circle().strokeBorder(AppTheme.Colors.accent.opacity(0.08), lineWidth: 1)
                    )

                ProgressView()
                    .tint(AppTheme.Colors.accent)
                    .scaleEffect(1.4)
            }

            VStack(spacing: 8) {
                Text("Finding routes")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Checking subway, bus & rail options...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
            }

            // Skeleton cards with shimmer
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    skeletonCard
                        .opacity(Double(3 - i) / 3.0 * 0.7)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()
        }
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.Colors.cardInset)
                    .frame(width: 130, height: 14)
                Spacer()
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.Colors.cardInset)
                    .frame(width: 55, height: 14)
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.Colors.cardInset)
                .frame(height: 38)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.Colors.cardInset)
                        .frame(width: 28, height: 28)
                }
                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Apple Maps Fallback Banner

    private var appleFallbackBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.10))
                    .frame(width: 36, height: 36)
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Rerouted with Apple Maps")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Our servers are updating — we'll be back shortly.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            AppTheme.Colors.accent.opacity(0.06),
                            AppTheme.Colors.accent.opacity(0.02),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AppTheme.Colors.accent.opacity(0.18), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.top, 26)
        .padding(.bottom, 4)
    }

    // MARK: - Schedule Note Banner

    private func scheduleNoteBanner(_ note: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.warningYellow)

            Text(note)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.Colors.warningYellow.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppTheme.Colors.warningYellow.opacity(0.2), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Error State

    private var errorTitle: String {
        switch viewModel.errorKind {
        case .engineUnavailable:
            return "Temporarily unavailable"
        case .noResults:
            return "Couldn't find routes"
        case .general:
            return "Something went wrong"
        }
    }

    private var errorIcon: String {
        switch viewModel.errorKind {
        case .engineUnavailable:
            return "arrow.trianglehead.2.clockwise"
        case .noResults:
            return "exclamationmark.triangle.fill"
        case .general:
            return "wifi.exclamationmark"
        }
    }

    private var errorIconColor: Color {
        switch viewModel.errorKind {
        case .engineUnavailable:
            return AppTheme.Colors.accent
        case .noResults:
            return AppTheme.Colors.warningYellow
        case .general:
            return AppTheme.Colors.alertRed
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(errorIconColor.opacity(0.06))
                    .frame(width: 100, height: 100)

                Circle()
                    .fill(AppTheme.Colors.cardBackground)
                    .frame(width: 72, height: 72)
                    .overlay(
                        Circle()
                            .strokeBorder(errorIconColor.opacity(0.15), lineWidth: 1)
                    )

                Image(systemName: errorIcon)
                    .font(.system(size: 30))
                    .foregroundStyle(errorIconColor)
            }

            VStack(spacing: 8) {
                Text(errorTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            Button {
                Task { await viewModel.planTrip() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                    Text("Try Again")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 40)
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
                                        .init(color: .white.opacity(0.12), location: 0),
                                        .init(color: .clear, location: 0.45),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }
                    .shadow(color: AppTheme.Colors.accent.opacity(0.35), radius: 12, y: 4)
                )
            }
            .buttonStyle(ResultsButtonStyle())

            VStack(alignment: .leading, spacing: 14) {
                Text("Quick Setup")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.8)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ],
                    spacing: 10
                ) {
                    savePlaceAction(.home, color: AppTheme.Colors.accent)
                    savePlaceAction(.work, color: AppTheme.Colors.warningYellow)
                    savePlaceAction(.school, color: AppTheme.Colors.successGreen)
                    savePlaceAction(.partner, color: AppTheme.Colors.alertRed)
                }
            }
            .frame(maxWidth: 360)

            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Helpers

    private var originIcon: String {
        switch viewModel.origin {
        case .currentLocation: return "location.fill"
        case .saved: return "star.fill"
        case .recent: return "clock.fill"
        case .custom: return "mappin.circle.fill"
        }
    }

    private var estimatedWalkTime: String {
        if let first = viewModel.tripResults.first {
            let totalMinutes = Int(first.totalWalkMeters / 83.0)
            let hours = totalMinutes / 60
            if hours > 0 { return "\(hours) h \(totalMinutes % 60) min" }
            return "\(totalMinutes) min walk"
        }
        return ""
    }

    private func savePlaceAction(_ category: SavedLocationCategory, color: Color) -> some View {
        let existing = viewModel.savedLocation(for: category)
        let title = existing == nil ? "Set \(category.label)" : "Update \(category.label)"

        return Button {
            viewModel.clearResults()
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                viewModel.beginSavedPlaceFlow(category)
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: category.defaultIcon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(existing?.address.isEmpty == false ? existing?.address ?? "" : "Save it for one-tap planning")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(color.opacity(0.12), lineWidth: 0.8)
                    )
            )
        }
        .buttonStyle(ResultsButtonStyle())
    }
}

// MARK: - Button Style

private struct ResultsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    TripResultsView(viewModel: PlanViewModel())
        .preferredColorScheme(.dark)
}
