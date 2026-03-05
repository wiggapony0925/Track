//
//  SplashLoadingView.swift
//  Track
//
//  Branded splash screen shown while restoring the user session.
//  Uses AppTheme colors exclusively — no hardcoded values.
//

import SwiftUI

struct SplashLoadingView: View {

    // MARK: – Animation State

    @State private var iconScale: CGFloat = 0.6
    @State private var iconOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var subtitleOpacity: Double = 0
    @State private var dotsOpacity: Double = 0
    @State private var activeDot: Int = 0
    @State private var glowPhase: Bool = false

    /// MTA subway-line accent colors for the loading dots.
    /// Pulled from AppTheme.SubwayColors so they match the rest of the app.
    private let lineColors: [Color] = [
        AppTheme.SubwayColors.color(for: "1"),   // IRT Red
        AppTheme.SubwayColors.color(for: "4"),   // IRT Green
        AppTheme.SubwayColors.color(for: "A"),   // IND Blue
        AppTheme.SubwayColors.color(for: "B"),   // IND Orange
    ]

    // MARK: – Body

    var body: some View {
        ZStack {
            // Background — uses the themed AppBackground (light grey / dark near-black)
            AppTheme.Colors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // App icon with MTA Blue ambient glow
                ZStack {
                    RoundedRectangle(cornerRadius: 32)
                        .fill(AppTheme.Colors.mtaBlue.opacity(glowPhase ? 0.25 : 0.08))
                        .frame(width: 130, height: 130)
                        .blur(radius: 30)

                    Image("AppIconImage")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 110, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: AppTheme.Colors.subwayBlack.opacity(0.35),
                                radius: 20, y: 10)
                }
                .scaleEffect(iconScale)
                .opacity(iconOpacity)

                // Title — primary text color
                Text("Track")
                    .font(AppTheme.Typography.headerLarge)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .padding(.top, 24)
                    .opacity(titleOpacity)

                // Subtitle — MTA Blue accent
                Text("NYC Transit, Live")
                    .font(AppTheme.Typography.cardSubtitle)
                    .fontWeight(.medium)
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                    .padding(.top, 6)
                    .opacity(subtitleOpacity)

                // Animated subway-colored loading dots
                HStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(lineColors[index])
                            .frame(width: 8, height: 8)
                            .scaleEffect(activeDot == index ? 1.5 : 1.0)
                            .opacity(activeDot == index ? 1.0 : 0.35)
                            .animation(
                                .easeInOut(duration: 0.35),
                                value: activeDot
                            )
                    }
                }
                .padding(.top, 32)
                .opacity(dotsOpacity)

                Spacer()
                Spacer()
            }
        }
        .onAppear {
            // Staggered entrance
            withAnimation(.easeOut(duration: 0.5)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.2)) {
                titleOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.35)) {
                subtitleOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.5)) {
                dotsOpacity = 1.0
            }

            // Icon ambient glow pulse
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(0.6)) {
                glowPhase = true
            }

            // Cycling loading dots
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
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
