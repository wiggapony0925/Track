// Branded launch loading screen shown while restoring the user session.

import SwiftUI

struct SplashLoadingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appTheme") private var appTheme = "system"
    @State private var appeared = true
    @State private var pulse = false

    private var resolvedColorScheme: ColorScheme {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return colorScheme
        }
    }

    private var palette: SplashPalette { .resolve(resolvedColorScheme) }

    private let routeColors: [Color] = [
        AppTheme.SubwayColors.color(for: "1"),
        AppTheme.SubwayColors.color(for: "4"),
        AppTheme.SubwayColors.color(for: "A"),
        AppTheme.SubwayColors.color(for: "B"),
    ]

    var body: some View {
        ZStack {
            AuthBackground(haloOffset: CGSize(width: -36, height: -250))

            LoadingRouteMesh(palette: palette)
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
        .background(palette.background.ignoresSafeArea())
        .onAppear(perform: animateIn)
    }

    private var iconLockup: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        palette.accent.opacity(
                            pulse ? palette.pulseHighOpacity : palette.pulseLowOpacity
                        )
                    )
                    .frame(width: 168, height: 168)
                    .blur(radius: pulse ? 34 : 24)

                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(palette.card.opacity(palette.cardOpacity))
                    .frame(width: 106, height: 106)
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [palette.cardHighlight, palette.cardBorder],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.9
                            )
                    )
                            .shadow(color: palette.cardShadow, radius: 22, y: 12)

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
                    .foregroundStyle(palette.textPrimary)
                    .kerning(-0.5)

                Text("Getting live transit ready")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var loadingIndicator: some View {
        VStack(spacing: 10) {
            LoadingProgressRail(colors: routeColors, palette: palette)
                .frame(width: 148, height: 24)

            Text("Loading")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(palette.textTertiary)
                .textCase(.uppercase)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Track")
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

private struct SplashPalette {
    let background: Color
    let card: Color
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let streetLine: Color
    let stationDot: Color
    let cardHighlight: Color
    let cardBorder: Color
    let cardShadow: Color
    let cardOpacity: Double
    let pulseLowOpacity: Double
    let pulseHighOpacity: Double

    static func resolve(_ scheme: ColorScheme) -> SplashPalette {
        switch scheme {
        case .light:
            SplashPalette(
                background: Color(red: 0.948, green: 0.944, blue: 0.984),
                card: Color.white,
                accent: AppTheme.Colors.accent,
                textPrimary: Color(red: 0.070, green: 0.078, blue: 0.145),
                textSecondary: Color(red: 0.384, green: 0.408, blue: 0.502),
                textTertiary: Color(red: 0.520, green: 0.545, blue: 0.650),
                streetLine: Color(red: 0.070, green: 0.078, blue: 0.145).opacity(0.075),
                stationDot: Color.white.opacity(0.92),
                cardHighlight: Color.white.opacity(0.96),
                cardBorder: AppTheme.Colors.accent.opacity(0.14),
                cardShadow: Color(red: 0.070, green: 0.078, blue: 0.145).opacity(0.16),
                cardOpacity: 0.90,
                pulseLowOpacity: 0.12,
                pulseHighOpacity: 0.22
            )
        default:
            SplashPalette(
                background: Color(red: 0.008, green: 0.016, blue: 0.047),
                card: Color(red: 0.078, green: 0.106, blue: 0.173),
                accent: AppTheme.Colors.accent,
                textPrimary: Color(red: 0.972, green: 0.972, blue: 1.0),
                textSecondary: Color(red: 0.608, green: 0.643, blue: 0.761),
                textTertiary: Color(red: 0.392, green: 0.439, blue: 0.557),
                streetLine: Color(red: 0.972, green: 0.972, blue: 1.0).opacity(0.06),
                stationDot: Color.white.opacity(0.70),
                cardHighlight: Color.white.opacity(0.34),
                cardBorder: Color.white.opacity(0.06),
                cardShadow: Color.black.opacity(0.42),
                cardOpacity: 0.82,
                pulseLowOpacity: 0.18,
                pulseHighOpacity: 0.30
            )
        }
    }
}

private struct LoadingRouteMesh: View {
    let palette: SplashPalette

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
                    .init(color: .black, location: 0.10),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1.00),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func drawLocalStreets(in canvas: inout GraphicsContext, size: CGSize) {
        let stroke = StrokeStyle(lineWidth: 0.55, lineCap: .round)
        let spacing: CGFloat = 34

        var y: CGFloat = -40
        while y < size.height + 40 {
            var path = Path()
            path.move(to: CGPoint(x: -36, y: y))
            path.addLine(to: CGPoint(x: size.width + 36, y: y + size.width * 0.17))
            canvas.stroke(path, with: .color(palette.streetLine), style: stroke)
            y += spacing
        }

        var x: CGFloat = -60
        while x < size.width + 60 {
            var path = Path()
            path.move(to: CGPoint(x: x, y: -20))
            path.addLine(to: CGPoint(x: x + size.height * 0.12, y: size.height + 20))
            canvas.stroke(path, with: .color(palette.streetLine.opacity(0.72)), style: stroke)
            x += spacing + 14
        }
    }

    private func drawExpressRoutes(
        in canvas: inout GraphicsContext,
        size: CGSize,
        date: Date
    ) {
        let phase = date.timeIntervalSinceReferenceDate
        let routes: [(Color, CGFloat, CGFloat, CGFloat, Double, CGFloat)] = [
            (AppTheme.SubwayColors.color(for: "1"), -0.02, 0.30, 0.70, 0.44, -0.18),
            (AppTheme.SubwayColors.color(for: "4"), 0.12, 0.52, 0.86, 0.38, 0.10),
            (AppTheme.SubwayColors.color(for: "A"), 0.28, 0.18, 0.62, 0.42, 0.26),
            (AppTheme.SubwayColors.color(for: "B"), 0.40, 0.72, 1.02, 0.36, -0.06),
            (AppTheme.SubwayColors.color(for: "N"), 0.54, 0.34, 1.12, 0.34, 0.18),
            (AppTheme.SubwayColors.color(for: "7"), 0.78, 0.56, 0.12, 0.26, -0.24),
        ]

        for (index, route) in routes.enumerated() {
            let path = routePath(
                size: size,
                startY: route.1,
                bend: route.2,
                endY: route.3,
                sway: route.5
            )
            let glowWidth = 8.5 + CGFloat(sin(phase * 1.1 + Double(index)) * 1.1)

            canvas.stroke(
                path,
                with: .color(route.0.opacity(route.4 * 0.42)),
                style: StrokeStyle(lineWidth: glowWidth, lineCap: .round, lineJoin: .round)
            )
            canvas.stroke(
                path,
                with: .color(route.0.opacity(route.4)),
                style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round)
            )

            let trainT = (phase * 0.065 + Double(index) * 0.17).truncatingRemainder(dividingBy: 1)
            let trainPoint = pointOnCurve(
                t: trainT,
                p0: CGPoint(x: -42, y: size.height * route.1),
                p1: CGPoint(x: size.width * 0.28, y: size.height * route.2),
                p2: CGPoint(x: size.width * 0.70, y: size.height * (route.2 + route.5)),
                p3: CGPoint(x: size.width + 42, y: size.height * route.3)
            )
            let glint = CGRect(x: trainPoint.x - 3, y: trainPoint.y - 3, width: 6, height: 6)
            canvas.fill(Path(ellipseIn: glint.insetBy(dx: -5, dy: -5)), with: .color(route.0.opacity(0.16)))
            canvas.fill(Path(ellipseIn: glint), with: .color(Color.white.opacity(0.90)))
            canvas.stroke(Path(ellipseIn: glint), with: .color(route.0.opacity(0.82)), lineWidth: 1.1)
        }
    }

    private func drawStationPulses(
        in canvas: inout GraphicsContext,
        size: CGSize,
        date: Date
    ) {
        let phase = date.timeIntervalSinceReferenceDate
        let stations: [(CGFloat, CGFloat, Color)] = [
            (0.18, 0.26, AppTheme.SubwayColors.color(for: "1")),
            (0.34, 0.41, AppTheme.SubwayColors.color(for: "4")),
            (0.52, 0.50, AppTheme.SubwayColors.color(for: "A")),
            (0.70, 0.63, AppTheme.SubwayColors.color(for: "B")),
            (0.82, 0.75, AppTheme.SubwayColors.color(for: "N")),
            (0.28, 0.78, AppTheme.SubwayColors.color(for: "7")),
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
            canvas.fill(Path(ellipseIn: dot), with: .color(palette.stationDot))
            canvas.stroke(
                Path(ellipseIn: dot),
                with: .color(station.2.opacity(0.75)),
                lineWidth: 1
            )
        }
    }

    private func routePath(
        size: CGSize,
        startY: CGFloat,
        bend: CGFloat,
        endY: CGFloat,
        sway: CGFloat
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -42, y: size.height * startY))
        path.addCurve(
            to: CGPoint(x: size.width + 42, y: size.height * endY),
            control1: CGPoint(x: size.width * 0.28, y: size.height * bend),
            control2: CGPoint(x: size.width * 0.70, y: size.height * (bend + sway))
        )
        return path
    }

    private func pointOnCurve(
        t: Double,
        p0: CGPoint,
        p1: CGPoint,
        p2: CGPoint,
        p3: CGPoint
    ) -> CGPoint {
        let u = 1 - t
        let tt = t * t
        let uu = u * u
        let uuu = uu * u
        let ttt = tt * t

        let x = uuu * p0.x
            + 3 * uu * t * p1.x
            + 3 * u * tt * p2.x
            + ttt * p3.x
        let y = uuu * p0.y
            + 3 * uu * t * p1.y
            + 3 * u * tt * p2.y
            + ttt * p3.y
        return CGPoint(x: x, y: y)
    }
}

private struct LoadingProgressRail: View {
    let colors: [Color]
    let palette: SplashPalette

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let midY = size.height / 2
                let rail = Path { path in
                    path.move(to: CGPoint(x: 5, y: midY))
                    path.addLine(to: CGPoint(x: size.width - 5, y: midY))
                }

                canvas.stroke(
                    rail,
                    with: .color(palette.textTertiary.opacity(0.20)),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )

                for (index, color) in colors.enumerated() {
                    let progress = (phase * 0.36 + Double(index) * 0.18)
                        .truncatingRemainder(dividingBy: 1)
                    let x = 8 + (size.width - 16) * progress
                    let pulse = 0.74 + max(0, sin(phase * 4.2 + Double(index))) * 0.26
                    let dot = CGRect(x: x - 4.5, y: midY - 4.5, width: 9, height: 9)

                    canvas.fill(
                        Path(ellipseIn: dot.insetBy(dx: -5, dy: -5)),
                        with: .color(color.opacity(0.10 * pulse))
                    )
                    canvas.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.96)))
                    canvas.stroke(Path(ellipseIn: dot), with: .color(.white.opacity(0.45)), lineWidth: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Splash Dark") {
    SplashLoadingView()
        .preferredColorScheme(.dark)
}

#Preview("Splash Light") {
    SplashLoadingView()
        .preferredColorScheme(.light)
}
