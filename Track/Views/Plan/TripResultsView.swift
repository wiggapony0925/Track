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
    @State private var showSettings = false
    @State private var showSaveRouteAlert = false
    @State private var saveRouteName = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppTheme.Gradients.screen.ignoresSafeArea()
                AppTheme.Gradients.screenSheen.ignoresSafeArea()

                VStack(spacing: 0) {
                    resultsHeader

                    ZStack {
                        if viewModel.isLoading {
                            loadingState
                                .transition(.opacity)
                        } else if let error = viewModel.errorMessage, viewModel.tripResults.isEmpty {
                            errorState(error)
                                .transition(.opacity)
                        } else {
                            VStack(spacing: 0) {
                                if viewModel.isUsingAppleFallback {
                                    appleFallbackBanner
                                }
                                if let note = viewModel.scheduleNote {
                                    scheduleNoteBanner(note)
                                }
                                resultsList
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: viewModel.isLoading)
                }


            }
        }
            .animation(AppTheme.Animation.snappy, value: showSettings)
            .navigationBarHidden(true)
            .sheet(item: $selectedTrip) { trip in
                TripDetailSheet(trip: trip)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSettings) {
                TripSettingsSheet(
                    config: $viewModel.tripConfiguration,
                    onApply: {
                        viewModel.saveTripConfigurationDebounced()
                        Task { await viewModel.planTrip() }
                    }
                )
            }
            .alert("Save Route", isPresented: $showSaveRouteAlert) {
                TextField("Route name", text: $saveRouteName)
                Button("Save") {
                    Task { await viewModel.saveTripTemplate(name: saveRouteName) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Save this route for quick access in your Plan tab.")
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
                    appeared = true
                }
                headerPulse = true
            }
    }

    // MARK: - Header

    private var resultsHeader: some View {
        VStack(spacing: 0) {
            // Origin / Destination pill fields + swap button
            HStack(alignment: .center, spacing: 12) {
                // Dots column
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.12))
                        .frame(width: 42)

                    VStack(spacing: 6) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.white.opacity(0.3))
                            .frame(width: 3, height: 24)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.white.opacity(0.9))
                            .frame(width: 14, height: 14)
                    }
                }
                .frame(height: 114)

                // Pill fields
                VStack(spacing: 8) {
                    // Origin pill
                    HStack(spacing: 8) {
                        Text(viewModel.origin.displayName)
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                            )
                    )

                    // Destination pill
                    HStack(spacing: 8) {
                        Text(viewModel.destination?.displayName ?? "Destination")
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                }

                // Swap button
                Button {
                    let didSwap = withAnimation(AppTheme.Animation.snappy) {
                        viewModel.swapOriginDestination()
                    }
                    if didSwap {
                        Task { await viewModel.planTrip() }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.14))
                                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                        )
                }
                .buttonStyle(ResultsButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 36) // extra space for overlap
        }
        .background(
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: AppTheme.Colors.accent, location: 0),
                        .init(color: AppTheme.Colors.accentDeep, location: 0.55),
                        .init(color: AppTheme.Colors.accentDeep.opacity(0.95), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.0),
                        Color.black.opacity(0.08),
                        Color.black.opacity(0.16),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
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
                    .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: headerPulse)
            }
            .ignoresSafeArea(edges: .top)
        )
        // Control bar overlapping the header/content boundary
        .overlay(alignment: .bottom) {
            departureControlBar
                .offset(y: 16)
        }
        .zIndex(1) // Keep control bar above scrolled trip cards
    }

    // Floating control bar: Leave now + settings + refresh + X
    private var departureControlBar: some View {
        HStack(spacing: 10) {
            // Leave now / departure chip
            Button {
                viewModel.showTimePicker = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(viewModel.departureTimeLabel)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    Capsule()
                        .fill(AppTheme.Colors.cardFloating)
                        .overlay(
                            Capsule()
                                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                )
            }
            .buttonStyle(.plain)

            // Save route
            Button {
                saveRouteName = "\(viewModel.origin.displayName) → \(viewModel.destination?.displayName ?? "")"
                showSaveRouteAlert = true
            } label: {
                Image(systemName: "star")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(AppTheme.Colors.cardFloating)
                            .overlay(Circle().strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.2), lineWidth: 1))
                            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                    )
            }
            .buttonStyle(ResultsButtonStyle())

            // Refresh — always bypass cache
            Button {
                Task { await viewModel.planTrip(forceRefresh: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(AppTheme.Colors.cardFloating)
                            .overlay(Circle().strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.2), lineWidth: 1))
                            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                    )
            }
            .buttonStyle(ResultsButtonStyle())

            // Filter / trip settings
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(AppTheme.Colors.cardFloating)
                            .overlay(Circle().strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.2), lineWidth: 1))
                            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
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
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        Circle()
                            .fill(AppTheme.Colors.alertRed)
                            .overlay(Circle().strokeBorder(AppTheme.Colors.alertRed.opacity(0.3), lineWidth: 1))
                            .shadow(color: AppTheme.Colors.alertRed.opacity(0.34), radius: 10, y: 4)
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
                Spacer().frame(height: 48)

                // Timeline grid — Transit-style horizontal Gantt chart
                TripTimelineGridView(
                    trips: viewModel.tripResults,
                    onTripTap: { trip in selectedTrip = trip },
                    recommendedIndex: 0,
                    departureOption: viewModel.departureOption,
                    onDepartureTimeChange: { date in
                        if let date {
                            viewModel.setDepartAt(date)
                        } else {
                            viewModel.setLeaveNow()
                        }
                        Task { await viewModel.planTrip(forceRefresh: true) }
                    }
                )

                // Show more trips button — one-shot; disappears after use
                if !viewModel.tripResults.isEmpty && !viewModel.isUsingAppleFallback && !viewModel.didLoadMore {
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
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppTheme.Colors.cardElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.15), lineWidth: 1)
                    )
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
        ZStack {
            // Background: skeleton timeline rows (visible behind the loader)
            VStack(spacing: 0) {
                // Fake time axis header
                skeletonTimeAxis
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // Skeleton candle rows — mimic real trip timeline
                ForEach(0..<4, id: \.self) { i in
                    if i > 0 {
                        Divider()
                            .overlay(AppTheme.Colors.borderSubtle.opacity(0.08))
                            .padding(.vertical, 8)
                    }
                    skeletonCandleRow(variant: i)
                        .padding(.vertical, 6)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .opacity(0.55)

            // Foreground: centered loader on a soft frosted card
            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppTheme.Colors.accent)

                VStack(spacing: 6) {
                    Text("Finding routes")
                        .font(.system(size: 21, weight: .black, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text("Checking subway, bus & rail options...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: AppTheme.Colors.shadow.opacity(0.12), radius: 20, y: 8)
            )
        }
        .onAppear {
            // Set value without withAnimation — scoped .animation() on each
            // shimmer element prevents the repeating transaction from leaking
            // into the entire view tree (which was pushing the header up/down).
            shimmerPhase = 1.0
        }
    }

    // MARK: - Skeleton Time Axis

    private var skeletonTimeAxis: some View {
        HStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { i in
                VStack(spacing: 4) {
                    shimmerRect(width: 38, height: 10, radius: 4)
                    Rectangle()
                        .fill(AppTheme.Colors.borderSubtle.opacity(0.12))
                        .frame(width: i % 2 == 0 ? 1 : 0.5, height: i % 2 == 0 ? 8 : 5)
                }
                if i < 5 { Spacer() }
            }
        }
        .frame(height: 28)
    }

    // MARK: - Skeleton Candle Row

    /// Each variant mimics a different trip shape so the skeleton looks realistic.
    private func skeletonCandleRow(variant: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Candle bars — ZStack with connector line behind the bars,
            // exactly like the real TripTimelineGridView candleRow.
            ZStack(alignment: .leading) {
                // Thin horizontal connector line behind bars
                connectorLine(variant: variant)

                // Bars + walk dots
                HStack(spacing: 0) {
                    switch variant {
                    case 0:
                        // Walk → long subway → short bus
                        skeletonWalkDots(count: 3)
                        skeletonTransitBar(width: 160)
                        skeletonTransferDots()
                        skeletonTransitBar(width: 72)
                        Spacer(minLength: 4)
                    case 1:
                        // Walk → medium subway → walk → medium subway
                        skeletonWalkDots(count: 2)
                        skeletonTransitBar(width: 100)
                        skeletonTransferDots()
                        skeletonTransitBar(width: 120)
                        skeletonWalkDots(count: 2)
                        Spacer(minLength: 4)
                    case 2:
                        // Single long express train
                        skeletonWalkDots(count: 3)
                        skeletonTransitBar(width: 220)
                        skeletonWalkDots(count: 2)
                        Spacer(minLength: 4)
                    default:
                        // Walk → 3-seat ride
                        skeletonWalkDots(count: 2)
                        skeletonTransitBar(width: 80)
                        skeletonTransferDots()
                        skeletonTransitBar(width: 60)
                        skeletonTransferDots()
                        skeletonTransitBar(width: 68)
                        Spacer(minLength: 4)
                    }
                }
            }
            .frame(height: 38)

            // Info row — "Go in X min" + duration placeholders
            HStack {
                shimmerRect(width: 90, height: 12, radius: 5)
                Spacer()
                shimmerRect(width: 44, height: 12, radius: 5)
            }
        }
    }

    /// Connector line spanning between the first and last transit bars.
    private func connectorLine(variant: Int) -> some View {
        // Approximate leading offset and total width of the transit bars
        let (leadingPad, lineWidth): (CGFloat, CGFloat) = {
            switch variant {
            case 0:  return (26, 160 + 20 + 72)       // walk(26) to end of bar2
            case 1:  return (18, 100 + 20 + 120)      // walk(18) to end of bar2
            case 2:  return (26, 220)                  // single bar
            default: return (18, 80 + 20 + 60 + 20 + 68) // 3-seat
            }
        }()
        return RoundedRectangle(cornerRadius: 2)
            .fill(AppTheme.Colors.textTertiary.opacity(0.14))
            .frame(width: lineWidth, height: 4)
            .padding(.leading, leadingPad)
    }

    // MARK: - Skeleton Components

    private func skeletonWalkDots(count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { _ in
                Circle()
                    .fill(AppTheme.Colors.cardInset)
                    .frame(width: 5, height: 5)
                    .overlay(
                        Circle().fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: max(0, shimmerPhase - 0.3)),
                                    .init(color: AppTheme.Colors.accent.opacity(0.08), location: shimmerPhase),
                                    .init(color: .clear, location: min(1, shimmerPhase + 0.3)),
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                    )
                    .animation(.linear(duration: 2.0).repeatForever(autoreverses: false), value: shimmerPhase)
            }
        }
        .padding(.horizontal, 4)
    }

    private func skeletonTransferDots() -> some View {
        HStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { _ in
                Circle()
                    .fill(AppTheme.Colors.cardInset.opacity(0.6))
                    .frame(width: 4, height: 4)
            }
        }
        .padding(.horizontal, 3)
    }

    private func skeletonTransitBar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(AppTheme.Colors.cardInset)
            .frame(width: width, height: 38)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: max(0, shimmerPhase - 0.3)),
                                .init(color: AppTheme.Colors.accent.opacity(0.06), location: shimmerPhase),
                                .init(color: .clear, location: min(1, shimmerPhase + 0.3)),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: AppTheme.Colors.shadow.opacity(0.06), radius: 3, y: 1)
            .animation(.linear(duration: 2.0).repeatForever(autoreverses: false), value: shimmerPhase)
    }

    private func shimmerRect(width: CGFloat?, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(AppTheme.Colors.cardInset)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: max(0, shimmerPhase - 0.3)),
                                .init(color: AppTheme.Colors.accent.opacity(0.06), location: shimmerPhase),
                                .init(color: .clear, location: min(1, shimmerPhase + 0.3)),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .animation(.linear(duration: 2.0).repeatForever(autoreverses: false), value: shimmerPhase)
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
                Task { await viewModel.planTrip(forceRefresh: true) }
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
