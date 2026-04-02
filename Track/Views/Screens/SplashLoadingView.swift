// Branded splash screen shown while restoring the user session.
// Transit 6.0–inspired: cinematic glow, refined typography, smooth entrance.

import SwiftUI

struct SplashLoadingView: View {

    // MARK: – Animation State

    @State private var iconScale: CGFloat = 0.7
    @State private var iconOpacity: Double = 0
    @State private var titleOffset: CGFloat = 12
    @State private var titleOpacity: Double = 0
    @State private var subtitleOpacity: Double = 0
    @State private var dotsOpacity: Double = 0
    @State private var activeDot: Int = 0
    @State private var glowPhase: Bool = false
    @State private var glowRadius: CGFloat = 25

    /// MTA subway-line accent colors for the loading dots.
    private let lineColors: [Color] = [
        AppTheme.SubwayColors.color(for: "1"),   // IRT Red
        AppTheme.SubwayColors.color(for: "4"),   // IRT Green
        AppTheme.SubwayColors.color(for: "A"),   // IND Blue
        AppTheme.SubwayColors.color(for: "B"),   // IND Orange
    ]

    // MARK: – Body

    var body: some View {
        ZStack {
            splashBackground
            splashContent
        }
        .onAppear(perform: runEntranceAnimations)
    }

    // MARK: – Extracted Subviews

    private var splashBackground: some View {
        ZStack {
            AppTheme.Gradients.screen
            AppTheme.Gradients.screenGlow
                .opacity(glowPhase ? 1.0 : 0.6)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            AppTheme.Colors.accent.opacity(glowPhase ? 0.18 : 0.08),
                            AppTheme.Colors.accentSecondary.opacity(0.04),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 40,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .offset(y: -40)
                .blur(radius: 30)
        }
        .ignoresSafeArea()
    }

    private var splashContent: some View {
        VStack(spacing: 0) {
            Spacer()
            appIconGlow
            titleSection
            loadingDots
            Spacer()
            Spacer()
        }
    }

    private var appIconGlow: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36)
                .fill(AppTheme.Colors.accentGlow.opacity(glowPhase ? 0.7 : 0.25))
                .frame(width: 140, height: 140)
                .blur(radius: glowRadius)

            RoundedRectangle(cornerRadius: 30)
                .fill(AppTheme.Colors.accent.opacity(glowPhase ? 0.25 : 0.10))
                .frame(width: 120, height: 120)
                .blur(radius: 18)

            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.20),
                                    Color.white.opacity(0.05),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
                .shadow(color: AppTheme.Colors.shadow.opacity(0.30), radius: 24, y: 12)
        }
        .scaleEffect(iconScale)
        .opacity(iconOpacity)
    }

    private var titleSection: some View {
        VStack(spacing: 0) {
            Text("Track")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .padding(.top, 28)
                .opacity(titleOpacity)
                .offset(y: titleOffset)

            Text("NYC Transit, Live")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(AppTheme.Colors.accent)
                .tracking(0.8)
                .padding(.top, 8)
                .opacity(subtitleOpacity)
        }
    }

    private var loadingDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(lineColors[index])
                    .frame(width: 7, height: 7)
                    .scaleEffect(activeDot == index ? 1.6 : 1.0)
                    .opacity(activeDot == index ? 1.0 : 0.30)
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.6),
                        value: activeDot
                    )
            }
        }
        .padding(.top, 36)
        .opacity(dotsOpacity)
    }

    // MARK: – Animations

    private func runEntranceAnimations() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
            iconScale = 1.0
            iconOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
            titleOpacity = 1.0
            titleOffset = 0
        }
        withAnimation(.easeOut(duration: 0.5).delay(0.30)) {
            subtitleOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.4).delay(0.45)) {
            dotsOpacity = 1.0
        }

        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true).delay(0.5)) {
            glowPhase = true
            glowRadius = 40
        }

        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            MainActor.assumeIsolated {
                withAnimation {
                    activeDot = (activeDot + 1) % 4
                }
            }
        }
    }
}

#Preview {
    SplashLoadingView()
}
