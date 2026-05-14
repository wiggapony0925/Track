// Branded launch loading screen shown while restoring the user session.
//
// Motion budget — only the train under "Track" animates.
//
// The background route mesh (curved colored lines) is drawn ONCE into
// a static Canvas using a deterministic seed; nothing else moves.
// The halo, icon, and labels are static. The only animated layer is
// the subway train under the loading label, which slides left→right
// across a rail and fully clears the frame before the next loop —
// same behavior as a train pulling out of a station and the next one
// arriving.

import SwiftUI

struct SplashLoadingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appTheme") private var appTheme = "system"

    private var resolvedColorScheme: ColorScheme {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return colorScheme
        }
    }

    private var palette: SplashPalette { .resolve(resolvedColorScheme) }

    /// Subway-line palette used for the static background polylines.
    /// Each color paints one of the routes drawn behind the splash so
    /// the backdrop reads as a stylized transit map.
    private let routePalette: [Color] = [
        AppTheme.SubwayColors.color(for: "1"),
        AppTheme.SubwayColors.color(for: "4"),
        AppTheme.SubwayColors.color(for: "A"),
        AppTheme.SubwayColors.color(for: "B"),
        AppTheme.SubwayColors.color(for: "7"),
        AppTheme.SubwayColors.color(for: "N"),
        AppTheme.SubwayColors.color(for: "L"),
        AppTheme.SubwayColors.color(for: "G"),
    ]

    var body: some View {
        ZStack {
            // Base background.
            palette.background
                .ignoresSafeArea()

            // STATIC transit-map polylines — drawn once into a Canvas.
            // Authored paths (not random curves) so the mesh reads like
            // a real subway map. Nothing here animates.
            RouteMeshBackground(
                palette: routePalette,
                lineOpacity: palette.routeMeshOpacity,
                casingColor: palette.background
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // STATIC accent halo behind the icon for depth.
            RadialGradient(
                colors: [
                    palette.accent.opacity(palette.pulseHighOpacity),
                    palette.accent.opacity(palette.pulseLowOpacity * 0.4),
                    Color.clear,
                ],
                center: .center,
                startRadius: 0,
                endRadius: 260
            )
            .blur(radius: 30)
            .frame(maxHeight: .infinity)
            .offset(y: -80)
            .allowsHitTesting(false)

            VStack(spacing: 22) {
                Spacer()

                iconLockup

                loadingIndicator

                Spacer()
                Spacer(minLength: 54)
            }
            .padding(.horizontal, 28)
        }
    }

    private var iconLockup: some View {
        VStack(spacing: 14) {
            ZStack {
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
            // The ONLY animated element on the screen — a small subway
            // train sliding along a rail, painted in the app's purple
            // accent so it feels like a Track-branded train.
            TrainLoader(
                bulletColor: AppTheme.Colors.accent,
                bulletLetter: "T",
                palette: palette
            )
            .frame(width: 200, height: 36)

            Text("Loading")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(palette.textTertiary)
                .textCase(.uppercase)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Track")
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
    /// Stroke opacity applied to every line in the static route mesh.
    /// Kept low so the mesh reads as ambient depth, not foreground noise.
    let routeMeshOpacity: Double
    /// Body fill for each subway car (silver/stainless on real R-series cars).
    let carBodyTop: Color
    let carBodyBottom: Color
    /// Color used for the under-frame band and roof equipment line.
    let carTrim: Color
    /// Color used for the dark window strip + door splits.
    let carWindowFill: Color

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
                pulseHighOpacity: 0.22,
                routeMeshOpacity: 0.28,
                carBodyTop: Color(red: 0.92, green: 0.94, blue: 0.96),
                carBodyBottom: Color(red: 0.74, green: 0.78, blue: 0.83),
                carTrim: Color(red: 0.20, green: 0.23, blue: 0.30),
                carWindowFill: Color(red: 0.06, green: 0.08, blue: 0.13)
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
                pulseHighOpacity: 0.30,
                routeMeshOpacity: 0.32,
                carBodyTop: Color(red: 0.86, green: 0.89, blue: 0.93),
                carBodyBottom: Color(red: 0.55, green: 0.60, blue: 0.68),
                carTrim: Color(red: 0.10, green: 0.12, blue: 0.18),
                carWindowFill: Color(red: 0.02, green: 0.03, blue: 0.06)
            )
        }
    }
}

// MARK: - Static Route Mesh

/// Stylized transit-map polylines rendered ONCE behind the splash.
///
/// Each route is a hand-authored path expressed in normalized 0–1
/// coordinates so it scales to any screen size. Lines run mostly
/// horizontally / vertically with rounded corners (45° turns) so the
/// mesh reads like a real subway diagram — not a chaotic curve field.
/// Each colored route is drawn over a slightly-wider casing of the
/// background color so adjacent lines stay visually separated, exactly
/// the same trick the app's MapLibre style uses for trunk polylines.
private struct RouteMeshBackground: View {
    let palette: [Color]
    let lineOpacity: Double
    let casingColor: Color

    /// One route in the mesh: a list of normalized waypoints and the
    /// color used to paint it. Waypoints are connected with straight
    /// segments and rounded corners (small quadratic arc at every
    /// vertex), exactly how transit-map polylines are drawn.
    private struct Route {
        let colorIndex: Int
        let points: [CGPoint]
    }

    /// Authored "transit lines" laid out as a stylized subway diagram.
    /// Coordinates are normalized to the view's bounds.
    private static let routes: [Route] = [
        // Long express running from bottom-left up to top-right.
        Route(colorIndex: 0, points: [
            CGPoint(x: -0.05, y: 1.05),
            CGPoint(x: 0.20, y: 0.78),
            CGPoint(x: 0.20, y: 0.45),
            CGPoint(x: 0.55, y: 0.18),
            CGPoint(x: 1.05, y: 0.18),
        ]),
        // Crosstown that bends through the middle.
        Route(colorIndex: 1, points: [
            CGPoint(x: -0.05, y: 0.30),
            CGPoint(x: 0.35, y: 0.30),
            CGPoint(x: 0.55, y: 0.50),
            CGPoint(x: 0.55, y: 0.85),
            CGPoint(x: 1.05, y: 1.10),
        ]),
        // Trunk line down the right edge.
        Route(colorIndex: 2, points: [
            CGPoint(x: 0.78, y: -0.05),
            CGPoint(x: 0.78, y: 0.40),
            CGPoint(x: 0.92, y: 0.55),
            CGPoint(x: 0.92, y: 1.05),
        ]),
        // Curved branch sweeping bottom-right to upper-middle.
        Route(colorIndex: 3, points: [
            CGPoint(x: 1.05, y: 0.92),
            CGPoint(x: 0.65, y: 0.92),
            CGPoint(x: 0.40, y: 0.65),
            CGPoint(x: 0.10, y: 0.65),
            CGPoint(x: -0.05, y: 0.55),
        ]),
        // Short shuttle up top.
        Route(colorIndex: 4, points: [
            CGPoint(x: -0.05, y: 0.10),
            CGPoint(x: 0.30, y: 0.10),
            CGPoint(x: 0.45, y: 0.05),
        ]),
        // Diagonal local through the lower half.
        Route(colorIndex: 5, points: [
            CGPoint(x: -0.05, y: 0.85),
            CGPoint(x: 0.30, y: 0.85),
            CGPoint(x: 0.45, y: 0.72),
            CGPoint(x: 0.85, y: 0.72),
            CGPoint(x: 1.05, y: 0.62),
        ]),
    ]

    var body: some View {
        Canvas { canvas, size in
            // Trunk-line widths roughly proportional to screen width
            // so the mesh always looks bold but never overpowering.
            let trunkWidth: CGFloat = max(6, min(10, size.width * 0.018))
            let casingWidth: CGFloat = trunkWidth + 3

            for route in Self.routes {
                let color = palette[route.colorIndex % palette.count]
                let path = Self.makePath(for: route.points, in: size)

                // Casing first — wider stroke in the background color
                // so adjacent routes don't visually bleed into each other.
                canvas.stroke(
                    path,
                    with: .color(casingColor),
                    style: StrokeStyle(
                        lineWidth: casingWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                // Colored route on top.
                canvas.stroke(
                    path,
                    with: .color(color.opacity(lineOpacity)),
                    style: StrokeStyle(
                        lineWidth: trunkWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
    }

    /// Builds a path that visits every waypoint with rounded corners.
    /// Uses `addQuadCurve` at each interior vertex so direction changes
    /// look like the soft 45° bends on a real transit map rather than
    /// hard angles.
    private static func makePath(
        for normalizedPoints: [CGPoint],
        in size: CGSize
    ) -> Path {
        guard normalizedPoints.count >= 2 else { return Path() }

        // Map normalized -> view coordinates.
        let pts = normalizedPoints.map {
            CGPoint(x: $0.x * size.width, y: $0.y * size.height)
        }

        var path = Path()
        path.move(to: pts[0])
        // Corner radius scales with the smaller view dimension so the
        // bends always look proportional.
        let cornerRadius: CGFloat = min(size.width, size.height) * 0.045

        for i in 1..<(pts.count - 1) {
            let prev = pts[i - 1]
            let here = pts[i]
            let next = pts[i + 1]

            // Distance to back off from the vertex along each leg —
            // capped at half the leg length so adjacent corners can't
            // overlap on short segments.
            let backIn = min(cornerRadius, distance(prev, here) / 2)
            let backOut = min(cornerRadius, distance(here, next) / 2)

            let inPoint = pointAlong(from: here, toward: prev, by: backIn)
            let outPoint = pointAlong(from: here, toward: next, by: backOut)

            path.addLine(to: inPoint)
            path.addQuadCurve(to: outPoint, control: here)
        }
        path.addLine(to: pts.last!)
        return path
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func pointAlong(
        from origin: CGPoint,
        toward target: CGPoint,
        by length: CGFloat
    ) -> CGPoint {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let mag = hypot(dx, dy)
        guard mag > 0 else { return origin }
        let t = length / mag
        return CGPoint(x: origin.x + dx * t, y: origin.y + dy * t)
    }
}

private struct TrainLoader: View {
    let bulletColor: Color
    let bulletLetter: String
    let palette: SplashPalette

    var body: some View {
        // `.animation` ticks at the display refresh rate (up to ProMotion
        // 120 Hz). No `minimumInterval` \u2014 we want every available frame
        // so the slide reads as smooth, not stepped.
        //
        // No `.drawingGroup()` here \u2014 it forces an offscreen render every
        // tick which is what was making the train feel laggy. Canvas is
        // already GPU-backed.
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                drawRail(in: &canvas, size: size)
                drawTrain(in: &canvas, size: size, phase: phase)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Rail

    /// A subtle horizontal track with a station dot at each end. No
    /// animation — anchors the train and gives it somewhere to depart
    /// from / arrive at.
    private func drawRail(in canvas: inout GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        let inset: CGFloat = 6

        let rail = Path { path in
            path.move(to: CGPoint(x: inset, y: midY))
            path.addLine(to: CGPoint(x: size.width - inset, y: midY))
        }

        canvas.stroke(
            rail,
            with: .color(palette.textTertiary.opacity(0.22)),
            style: StrokeStyle(lineWidth: 3, lineCap: .round)
        )

        for x in [inset + 1, size.width - inset - 1] {
            let dot = CGRect(x: x - 2.5, y: midY - 2.5, width: 5, height: 5)
            canvas.fill(Path(ellipseIn: dot), with: .color(palette.stationDot))
            canvas.stroke(
                Path(ellipseIn: dot),
                with: .color(palette.textTertiary.opacity(0.55)),
                lineWidth: 0.8
            )
        }
    }

    // MARK: - Train

    /// Renders a 3-car NYC-style stainless-steel subway consist:
    /// silver body with a darker under-frame band, a continuous dark
    /// window strip with individual windows, a center door split, and
    /// a route bullet on the locomotive's flat front. Loops continuously
    /// — the entire train fully clears the right edge before the
    /// locomotive re-emerges from off-screen left, with a brief
    /// dwell to simulate the gap between trains.
    private func drawTrain(
        in canvas: inout GraphicsContext,
        size: CGSize,
        phase: TimeInterval
    ) {
        let midY = size.height / 2

        // Geometry — sized for a 200×36 frame.
        let carCount: Int = 3
        let carWidth: CGFloat = 38
        let carHeight: CGFloat = 17
        let carGap: CGFloat = 1.5
        let trainWidth = CGFloat(carCount) * carWidth
            + CGFloat(carCount - 1) * carGap

        // Off-screen padding so the train fully exits / fully arrives.
        let edgePad: CGFloat = 18
        let travelStart = -trainWidth - edgePad
        let travelEnd = size.width + edgePad
        let travelSpan = travelEnd - travelStart

        // Loop timing — `cycleDuration` is one full pass + dwell. The
        // train moves linearly across `travelSpan` for the first
        // `motionFraction` of the cycle, then sits off-screen for the
        // remainder so the next "train" feels like it's arriving from
        // the next station rather than teleporting.
        let cycleDuration = SplashMotion.cycleDurationSeconds
        let motionFraction = SplashMotion.motionFraction
        let cycle = (phase / cycleDuration)
            .truncatingRemainder(dividingBy: 1)
        let progress = min(1, cycle / motionFraction)
        // Locomotive (right-most car) front edge x-coordinate.
        let frontX = travelStart + trainWidth + travelSpan * CGFloat(progress)

        // Headlight glow — soft halo just ahead of the locomotive.
        let headlightCenter = CGPoint(x: frontX + 7, y: midY)
        let headlight = CGRect(
            x: headlightCenter.x - 14,
            y: headlightCenter.y - 14,
            width: 28,
            height: 28
        )
        canvas.fill(
            Path(ellipseIn: headlight),
            with: .radialGradient(
                Gradient(colors: [
                    Color.white.opacity(0.55),
                    Color.white.opacity(0.12),
                    Color.clear,
                ]),
                center: headlightCenter,
                startRadius: 0,
                endRadius: 20
            )
        )

        // Cars are drawn from the locomotive (right) leftward.
        for index in 0..<carCount {
            let isLocomotive = index == 0
            let bodyMaxX = frontX - CGFloat(index) * (carWidth + carGap)
            let body = CGRect(
                x: bodyMaxX - carWidth,
                y: midY - carHeight / 2,
                width: carWidth,
                height: carHeight
            )
            drawCar(
                in: &canvas,
                rect: body,
                isLocomotive: isLocomotive,
                bulletColor: bulletColor,
                bulletLetter: bulletLetter
            )

            // Coupling between cars.
            if !isLocomotive {
                let coupling = CGRect(
                    x: body.maxX,
                    y: midY - 0.75,
                    width: carGap,
                    height: 1.5
                )
                canvas.fill(
                    Path(coupling),
                    with: .color(palette.carTrim.opacity(0.85))
                )
            }
        }
    }

    /// Renders a single subway car. Layered (back-to-front):
    /// drop shadow → silver body gradient → roof equipment line →
    /// dark window band → individual windows + center door split →
    /// under-frame band → optional route bullet (locomotive only).
    private func drawCar(
        in canvas: inout GraphicsContext,
        rect body: CGRect,
        isLocomotive: Bool,
        bulletColor: Color,
        bulletLetter: String
    ) {
        let cornerRadius: CGFloat = 3
        let bodyPath = Path(
            roundedRect: body,
            cornerRadius: cornerRadius,
            style: .continuous
        )

        // Drop shadow — soft, non-animated, sits below the rail line.
        let shadowRect = body.offsetBy(dx: 0, dy: 2.0)
        canvas.fill(
            Path(
                roundedRect: shadowRect,
                cornerRadius: cornerRadius,
                style: .continuous
            ),
            with: .color(Color.black.opacity(0.22))
        )

        // Stainless-steel body gradient.
        canvas.fill(
            bodyPath,
            with: .linearGradient(
                Gradient(colors: [
                    palette.carBodyTop,
                    palette.carBodyBottom,
                ]),
                startPoint: CGPoint(x: body.minX, y: body.minY),
                endPoint: CGPoint(x: body.minX, y: body.maxY)
            )
        )

        // Roof equipment line — thin trim along the very top of the car.
        let roof = CGRect(
            x: body.minX + 1,
            y: body.minY + 1.4,
            width: body.width - 2,
            height: 1.0
        )
        canvas.fill(
            Path(roundedRect: roof, cornerRadius: 0.5, style: .continuous),
            with: .color(palette.carTrim.opacity(0.55))
        )

        // Dark window band — runs the length of the car at the upper
        // third, with the front-most segment reserved for the cab on
        // the locomotive.
        let windowBand = CGRect(
            x: body.minX + 2,
            y: body.minY + body.height * 0.28,
            width: body.width - 4,
            height: body.height * 0.34
        )
        canvas.fill(
            Path(
                roundedRect: windowBand,
                cornerRadius: 1,
                style: .continuous
            ),
            with: .color(palette.carWindowFill)
        )

        // Individual windows — 4 evenly-spaced bright slits inside the
        // band so the band reads as windows rather than a solid stripe.
        // The locomotive gets one window (the cab) at the front.
        let windowCount = isLocomotive ? 3 : 4
        let windowSpacing: CGFloat = 1.2
        let windowsTotalWidth = windowBand.width
            - windowSpacing * CGFloat(windowCount + 1)
        let windowWidth = windowsTotalWidth / CGFloat(windowCount)
        for w in 0..<windowCount {
            let wx = windowBand.minX
                + windowSpacing
                + (windowWidth + windowSpacing) * CGFloat(w)
            let win = CGRect(
                x: wx,
                y: windowBand.minY + 0.8,
                width: windowWidth,
                height: windowBand.height - 1.6
            )
            canvas.fill(
                Path(roundedRect: win, cornerRadius: 0.6, style: .continuous),
                with: .color(Color.white.opacity(0.78))
            )
        }

        // Door split — vertical thin line dividing the car in half
        // through the under-frame.
        if !isLocomotive {
            let door = CGRect(
                x: body.midX - 0.4,
                y: body.minY + body.height * 0.62,
                width: 0.8,
                height: body.height * 0.34
            )
            canvas.fill(
                Path(door),
                with: .color(palette.carTrim.opacity(0.85))
            )
        }

        // Under-frame band — darker stripe at the very bottom, the
        // visual weight that grounds the car on the rail.
        let underframe = CGRect(
            x: body.minX + 1,
            y: body.maxY - 2.4,
            width: body.width - 2,
            height: 1.6
        )
        canvas.fill(
            Path(
                roundedRect: underframe,
                cornerRadius: 0.6,
                style: .continuous
            ),
            with: .color(palette.carTrim.opacity(0.85))
        )

        // Route bullet on the locomotive's flat front face.
        if isLocomotive {
            let bulletDiameter: CGFloat = body.height * 0.55
            let bullet = CGRect(
                x: body.maxX - bulletDiameter - 3,
                y: body.midY - bulletDiameter / 2,
                width: bulletDiameter,
                height: bulletDiameter
            )
            canvas.fill(Path(ellipseIn: bullet), with: .color(bulletColor))
            // Letter inside the bullet.
            let text = Text(bulletLetter)
                .font(.system(size: bulletDiameter * 0.78, weight: .black, design: .rounded))
                .foregroundColor(.white)
            let resolved = canvas.resolve(text)
            canvas.draw(
                resolved,
                at: CGPoint(x: bullet.midX, y: bullet.midY),
                anchor: .center
            )
        }
    }
}

private enum SplashMotion {
    /// 60 Hz — Canvas re-renders are cheap and the train is the only
    /// moving thing; no point throttling.
    static let frameInterval = 1.0 / 60.0
    /// Total seconds for one full pass-and-dwell cycle.
    static let cycleDurationSeconds: TimeInterval = 4.4
    /// Fraction of the cycle spent moving across the frame. The
    /// remainder is dwell off-screen so the next pass feels like a
    /// new train arriving from the next station rather than teleporting.
    static let motionFraction: Double = 0.82
}

#Preview("Splash Dark") {
    SplashLoadingView()
        .preferredColorScheme(.dark)
}

#Preview("Splash Light") {
    SplashLoadingView()
        .preferredColorScheme(.light)
}
