// Branded launch loading screen shown while restoring the user session.

import SwiftUI

struct SplashLoadingView: View {
    @State private var appeared = true
    @State private var pulse = false

    private let routeColors: [Color] = [
        AppTheme.SubwayColors.color(for: "1"),
        AppTheme.SubwayColors.color(for: "4"),
        AppTheme.SubwayColors.color(for: "A"),
        AppTheme.SubwayColors.color(for: "B"),
    ]

    var body: some View {
        ZStack {
            AuthBackground(haloOffset: CGSize(width: -36, height: -250))
                .environment(\.colorScheme, .dark)

            LoadingRouteMesh()
                .opacity(appeared ? 1 : 0.72)
                .scaleEffect(appeared ? 1 : 0.98)

            VStack(spacing: 22) {
                Spacer()

                iconLockup
                    .offset(y: appeared ? 0 : 16)

                loadingIndicator
                    .offset(y: appeared ? 0 : 10)

                Spacer()
                Spacer(minLength: 54)
            }
            .padding(.horizontal, 28)
        }
        .background(SplashColors.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear(perform: animateIn)
    }

    private var iconLockup: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(SplashColors.accent.opacity(pulse ? 0.30 : 0.18))
                    .frame(width: 168, height: 168)
                    .blur(radius: pulse ? 34 : 24)

                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(SplashColors.card.opacity(0.82))
                    .frame(width: 106, height: 106)
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.34), .white.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.9
                            )
                    )
                    .shadow(color: Color.black.opacity(0.42), radius: 22, y: 12)

                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 82, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityHidden(true)
            }
            .scaleEffect(pulse ? 1.02 : 0.98)

            VStack(spacing: 4) {
                Text("Track")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(SplashColors.textPrimary)
                    .kerning(-0.5)

                Text("Getting live transit ready")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(SplashColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var loadingIndicator: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(routeColors.indices, id: \.self) { index in
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                        let scale = dotScale(phase: phase, index: index)

                        Circle()
                            .fill(routeColors[index])
                            .frame(width: 8, height: 8)
                            .scaleEffect(scale)
                            .opacity(scale > 1.08 ? 1 : 0.46)
                    }
                    .frame(width: 14, height: 14)
                }
            }

            Text("Loading")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(SplashColors.textTertiary)
                .textCase(.uppercase)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Track")
    }

    private func dotScale(phase: TimeInterval, index: Int) -> CGFloat {
        let wave = sin((phase * 3.2) + Double(index) * 0.72)
        return 1 + max(0, wave) * 0.58
    }

    private func animateIn() {
        appeared = false
        withAnimation(.spring(response: 0.7, dampingFraction: 0.78)) {
            appeared = true
        }
        withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

private enum SplashColors {
    static let background = Color(red: 0.008, green: 0.016, blue: 0.047)
    static let card = Color(red: 0.078, green: 0.106, blue: 0.173)
    static let accent = Color(red: 0.784, green: 0.471, blue: 1.0)
    static let textPrimary = Color(red: 0.972, green: 0.972, blue: 1.0)
    static let textSecondary = Color(red: 0.608, green: 0.643, blue: 0.761)
    static let textTertiary = Color(red: 0.392, green: 0.439, blue: 0.557)
}

private struct LoadingRouteMesh: View {
    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation) { context in
                Canvas { canvas, size in
                    drawLocalStreets(in: &canvas, size: size)
                    drawExpressRoutes(in: &canvas, size: size, date: context.date)
                    drawStationPulses(in: &canvas, size: size, date: context.date)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .allowsHitTesting(false)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .black, location: 0.16),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1.00),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func drawLocalStreets(in canvas: inout GraphicsContext, size: CGSize) {
        let stroke = StrokeStyle(lineWidth: 0.7, lineCap: .round)
        let color = SplashColors.textPrimary.opacity(0.06)
        let spacing: CGFloat = 38

        var y: CGFloat = -20
        while y < size.height + 20 {
            var path = Path()
            path.move(to: CGPoint(x: -30, y: y))
            path.addLine(to: CGPoint(x: size.width + 30, y: y + size.width * 0.22))
            canvas.stroke(path, with: .color(color), style: stroke)
            y += spacing
        }

        var x: CGFloat = -60
        while x < size.width + 60 {
            var path = Path()
            path.move(to: CGPoint(x: x, y: -20))
            path.addLine(to: CGPoint(x: x + size.height * 0.18, y: size.height + 20))
            canvas.stroke(path, with: .color(color.opacity(0.8)), style: stroke)
            x += spacing + 18
        }
    }

    private func drawExpressRoutes(
        in canvas: inout GraphicsContext,
        size: CGSize,
        date: Date
    ) {
        let phase = date.timeIntervalSinceReferenceDate
        let routes: [(Color, CGFloat, CGFloat, CGFloat, Double)] = [
            (AppTheme.SubwayColors.color(for: "1"), 0.08, 0.40, 0.76, 0.42),
            (AppTheme.SubwayColors.color(for: "4"), 0.16, 0.62, 0.88, 0.36),
            (AppTheme.SubwayColors.color(for: "A"), 0.33, 0.20, 0.67, 0.38),
            (AppTheme.SubwayColors.color(for: "B"), 0.48, 0.78, 1.04, 0.34),
            (AppTheme.SubwayColors.color(for: "N"), 0.62, 0.30, 1.15, 0.30),
        ]

        for (index, route) in routes.enumerated() {
            let path = routePath(size: size, startY: route.1, bend: route.2, endY: route.3)
            let glowWidth = 10 + CGFloat(sin(phase * 1.15 + Double(index)) * 1.4)

            canvas.stroke(
                path,
                with: .color(route.0.opacity(route.4 * 0.42)),
                style: StrokeStyle(lineWidth: glowWidth, lineCap: .round, lineJoin: .round)
            )
            canvas.stroke(
                path,
                with: .color(route.0.opacity(route.4)),
                style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func drawStationPulses(
        in canvas: inout GraphicsContext,
        size: CGSize,
        date: Date
    ) {
        let phase = date.timeIntervalSinceReferenceDate
        let stations: [(CGFloat, CGFloat, Color)] = [
            (0.23, 0.31, AppTheme.SubwayColors.color(for: "1")),
            (0.44, 0.43, AppTheme.SubwayColors.color(for: "4")),
            (0.62, 0.52, AppTheme.SubwayColors.color(for: "A")),
            (0.74, 0.66, AppTheme.SubwayColors.color(for: "B")),
            (0.36, 0.72, AppTheme.SubwayColors.color(for: "N")),
        ]

        for (index, station) in stations.enumerated() {
            let wave = max(0, sin(phase * 1.8 + Double(index) * 0.75))
            let center = CGPoint(x: size.width * station.0, y: size.height * station.1)
            let ring = CGRect(
                x: center.x - 9 - wave * 7,
                y: center.y - 9 - wave * 7,
                width: 18 + wave * 14,
                height: 18 + wave * 14
            )
            let dot = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)

            canvas.stroke(
                Path(ellipseIn: ring),
                with: .color(station.2.opacity(0.16 * (1 - wave))),
                lineWidth: 1.1
            )
            canvas.fill(Path(ellipseIn: dot), with: .color(Color.white.opacity(0.70)))
            canvas.stroke(Path(ellipseIn: dot), with: .color(station.2.opacity(0.75)), lineWidth: 1)
        }
    }

    private func routePath(size: CGSize, startY: CGFloat, bend: CGFloat, endY: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -28, y: size.height * startY))
        path.addCurve(
            to: CGPoint(x: size.width + 28, y: size.height * endY),
            control1: CGPoint(x: size.width * 0.22, y: size.height * bend),
            control2: CGPoint(x: size.width * 0.78, y: size.height * (bend + 0.16))
        )
        return path
    }
}

#Preview {
    SplashLoadingView()
}
