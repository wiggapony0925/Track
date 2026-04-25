// VehicleDisplayModel
//
// Side-on vehicle illustrations rendered from SwiftUI primitives,
// used as the "grabber" that perches on top of `FloatingTabBar`
// while the dashboard sheet is collapsed.  The active variant is
// chosen by the user's current `TransportMode` so the bar reflects
// what they were just browsing (subway / bus / LIRR / Metro-North).
//
// All vehicles face RIGHT.  All are tinted with the app accent so
// they read as a single design family.  Each shape is purely
// declarative — no image assets — so they stay crisp at any size
// and pick up theme changes automatically.

import SwiftUI

// MARK: - Display kind

/// Maps a `TransportMode` onto a renderable vehicle.  Falls back to
/// the subway train for `.nearby` since "nearby" isn't a vehicle.
enum VehicleDisplayKind {
    case subway   // 3-cart purple subway train
    case bus      // single articulated city bus
    case lirr     // commuter rail with diesel locomotive
    case mnr      // Metro-North bilevel coach + locomotive

    init(mode: TransportMode) {
        switch mode {
        case .subway, .nearby: self = .subway
        case .bus:             self = .bus
        case .lirr:            self = .lirr
        case .mnr:             self = .mnr
        }
    }

    /// Default render width:height ratio for each vehicle.  Used by
    /// `FloatingTabBar` so the bus (longer body) doesn't get squished
    /// into the same footprint as a multi-cart train.
    var aspectSize: CGSize {
        switch self {
        case .subway: return CGSize(width: 96, height: 28)
        case .bus:    return CGSize(width: 84, height: 30)
        case .lirr:   return CGSize(width: 100, height: 30)
        case .mnr:    return CGSize(width: 102, height: 32)
        }
    }
}

// MARK: - Public entry view

/// One view to rule them all.  Pass the desired `kind` and a `pulse`
/// flag (drives headlight glow / accent telegraph), and this picks
/// the right shape.
struct VehicleDisplayModel: View {
    var kind: VehicleDisplayKind
    var pulse: Bool

    var body: some View {
        switch kind {
        case .subway: SubwayTrainShape(pulse: pulse)
        case .bus:    CityBusShape(pulse: pulse)
        case .lirr:   LIRRTrainShape(pulse: pulse)
        case .mnr:    MNRTrainShape(pulse: pulse)
        }
    }
}

// MARK: - Shared primitives

/// Small black wheel with a highlight — re-used by every vehicle so
/// they all share the same "stance" on the platform.
private struct VehicleWheel: View {
    var size: CGFloat = 6
    var body: some View {
        Circle()
            .fill(Color.black.opacity(0.85))
            .overlay(Circle().fill(Color.white.opacity(0.35)).scaleEffect(0.35))
            .frame(width: size, height: size)
    }
}

/// Faint accent track / shadow line drawn under every vehicle so the
/// silhouette feels grounded on the floating bar.
private struct VehicleTrackShadow: View {
    var width: CGFloat
    var body: some View {
        Capsule()
            .fill(Color.black.opacity(0.18))
            .frame(width: width * 0.92, height: 2)
            .offset(x: width * 0.04, y: -1)
    }
}

// MARK: - Subway train (3 carts, locomotive on the right)

private struct SubwayTrainShape: View {
    var pulse: Bool

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let gap: CGFloat = 2
            let bodyH = h * 0.7
            let wheelH = h * 0.18
            let usable = w - gap * 2
            let cartW = usable * 0.28
            let locoW = usable - cartW * 2

            ZStack(alignment: .bottomLeading) {
                cart(width: cartW, height: bodyH).offset(x: 0, y: -wheelH)
                cart(width: cartW, height: bodyH).offset(x: cartW + gap, y: -wheelH)
                locomotive(width: locoW, height: bodyH)
                    .offset(x: cartW * 2 + gap * 2, y: -wheelH)
                VehicleTrackShadow(width: w)
            }
            .frame(width: w, height: h, alignment: .bottomLeading)
        }
    }

    private func cart(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(AppTheme.Colors.accent)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6)
                )
                .overlay(
                    HStack(spacing: 2) {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(Color.white.opacity(0.85))
                        }
                    }
                    .padding(.horizontal, 3)
                    .frame(height: height * 0.45)
                    .offset(y: -height * 0.08)
                )
                .frame(width: width, height: height)

            HStack {
                VehicleWheel(); Spacer(minLength: 0); VehicleWheel()
            }
            .padding(.horizontal, width * 0.12)
            .frame(width: width)
            .offset(y: 5)
        }
        .frame(width: width, height: height, alignment: .bottom)
    }

    private func locomotive(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            SubwayLocoBody()
                .fill(AppTheme.Colors.accent)
                .overlay(
                    SubwayLocoBody().stroke(Color.white.opacity(0.22), lineWidth: 0.6)
                )
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: width * 0.32, height: height * 0.42)
                        .offset(x: width * 0.55, y: height * 0.18)
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color.yellow.opacity(pulse ? 0.95 : 0.7))
                        .frame(width: 4, height: 4)
                        .shadow(color: Color.yellow.opacity(pulse ? 0.8 : 0.4),
                                radius: pulse ? 4 : 2)
                        .offset(x: -2, y: -height * 0.32)
                }
                .frame(width: width, height: height)

            HStack {
                VehicleWheel(); Spacer(minLength: 0); VehicleWheel()
            }
            .padding(.horizontal, width * 0.12)
            .frame(width: width)
            .offset(y: 5)
        }
        .frame(width: width, height: height, alignment: .bottom)
    }
}

private struct SubwayLocoBody: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r: CGFloat = 4
        let noseInset = rect.width * 0.18
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - noseInset, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.45))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - City bus (single articulated body)

private struct CityBusShape: View {
    var pulse: Bool

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let bodyH = h * 0.72
            let wheelH = h * 0.18

            ZStack(alignment: .bottomLeading) {
                // Body
                BusBody()
                    .fill(AppTheme.Colors.accent)
                    .overlay(BusBody().stroke(Color.white.opacity(0.22), lineWidth: 0.6))
                    .overlay(
                        // Window strip — 4 windows + driver windshield
                        HStack(spacing: 1.5) {
                            ForEach(0..<4, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(Color.white.opacity(0.85))
                            }
                            // Driver windshield (slightly taller, separated)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color.white.opacity(0.92))
                                .frame(width: w * 0.13)
                        }
                        .padding(.horizontal, 4)
                        .frame(height: bodyH * 0.45)
                        .offset(y: -bodyH * 0.08)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        // Headlight
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(Color.yellow.opacity(pulse ? 0.95 : 0.7))
                            .frame(width: 4, height: 3)
                            .shadow(color: Color.yellow.opacity(pulse ? 0.8 : 0.4),
                                    radius: pulse ? 4 : 2)
                            .offset(x: -3, y: -bodyH * 0.18)
                    }
                    .overlay(alignment: .bottomLeading) {
                        // Rear taillight
                        Circle()
                            .fill(Color.red.opacity(0.85))
                            .frame(width: 3, height: 3)
                            .offset(x: 3, y: -bodyH * 0.18)
                    }
                    .frame(width: w, height: bodyH)
                    .offset(y: -wheelH)

                // Wheels — front + rear
                HStack {
                    VehicleWheel(size: 7)
                    Spacer(minLength: 0)
                    VehicleWheel(size: 7)
                }
                .padding(.horizontal, w * 0.12)
                .frame(width: w)
                .offset(y: 0)

                VehicleTrackShadow(width: w)
            }
            .frame(width: w, height: h, alignment: .bottomLeading)
        }
    }
}

/// A bus silhouette: rectangular with a slightly rounded front and
/// a flat back.  Mirrors the locomotive shape but pointed RIGHT and
/// less aggressive on the slope.
private struct BusBody: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r: CGFloat = 3
        let noseR: CGFloat = 6
        // Top-left
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        // Top edge to start of front rounding
        p.addLine(to: CGPoint(x: rect.maxX - noseR, y: rect.minY))
        // Front nose curve down
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + noseR),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        // Right edge
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        // Bottom edge
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        // Left edge
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - LIRR (sleek bullet train, long pointed nose)
//
// Inspired by Shinkansen / Acela noses: a single long body with a
// dramatically tapered front and a narrow continuous window strip.
// LIRR variant uses a single front headlight and a slightly less
// extreme nose taper than MNR.
private struct LIRRTrainShape: View {
    var pulse: Bool

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let bodyH = h * 0.66
            let wheelH = h * 0.18

            ZStack(alignment: .bottomLeading) {
                BulletTrainBody(noseRatio: 0.32, noseDrop: 0.55)
                    .fill(AppTheme.Colors.accent)
                    .overlay(
                        BulletTrainBody(noseRatio: 0.32, noseDrop: 0.55)
                            .stroke(Color.white.opacity(0.22), lineWidth: 0.6)
                    )
                    // Continuous window strip running along the body
                    // (stops short of the nose so it follows the taper).
                    .overlay(
                        Capsule()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: w * 0.52, height: bodyH * 0.28)
                            .offset(x: -w * 0.06, y: -bodyH * 0.05),
                        alignment: .center
                    )
                    // Cab windshield in the nose
                    .overlay(alignment: .topTrailing) {
                        BulletWindshield()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: w * 0.18, height: bodyH * 0.4)
                            .offset(x: -w * 0.04, y: bodyH * 0.18)
                    }
                    // Single bright headlight at the very tip
                    .overlay(alignment: .trailing) {
                        Capsule()
                            .fill(Color.yellow.opacity(pulse ? 0.95 : 0.7))
                            .frame(width: 5, height: 2.5)
                            .shadow(color: Color.yellow.opacity(pulse ? 0.85 : 0.45),
                                    radius: pulse ? 5 : 2.5)
                            .offset(x: -2, y: bodyH * 0.18)
                    }
                    // Faint accent stripe along the lower flank
                    .overlay(
                        Rectangle()
                            .fill(Color.white.opacity(0.35))
                            .frame(height: 1)
                            .padding(.horizontal, 4)
                            .offset(y: bodyH * 0.32),
                        alignment: .center
                    )
                    .frame(width: w, height: bodyH)
                    .offset(y: -wheelH)

                // Two paired-wheel trucks tucked toward the body ends
                HStack {
                    HStack(spacing: 1) { VehicleWheel(); VehicleWheel() }
                    Spacer(minLength: 0)
                    HStack(spacing: 1) { VehicleWheel(); VehicleWheel() }
                }
                .padding(.horizontal, w * 0.14)
                .frame(width: w)
                .offset(y: 0)

                VehicleTrackShadow(width: w)
            }
            .frame(width: w, height: h, alignment: .bottomLeading)
        }
    }
}

// MARK: - Metro-North (extra-sleek bullet train)
//
// MNR variant: even longer nose taper than LIRR + a subtle dual
// window-band (echoes Metro-North's bilevel coaches), giving it a
// “flagship” feel distinct from the LIRR sibling.
private struct MNRTrainShape: View {
    var pulse: Bool

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let bodyH = h * 0.7
            let wheelH = h * 0.18

            ZStack(alignment: .bottomLeading) {
                BulletTrainBody(noseRatio: 0.4, noseDrop: 0.62)
                    .fill(AppTheme.Colors.accent)
                    .overlay(
                        BulletTrainBody(noseRatio: 0.4, noseDrop: 0.62)
                            .stroke(Color.white.opacity(0.22), lineWidth: 0.6)
                    )
                    // Twin window strips evoke Metro-North bilevel coaches.
                    .overlay(
                        VStack(spacing: 1.5) {
                            Capsule()
                                .fill(Color.white.opacity(0.85))
                                .frame(height: bodyH * 0.18)
                            Capsule()
                                .fill(Color.white.opacity(0.78))
                                .frame(height: bodyH * 0.14)
                        }
                        .frame(width: w * 0.5)
                        .offset(x: -w * 0.08, y: -bodyH * 0.04),
                        alignment: .center
                    )
                    .overlay(alignment: .topTrailing) {
                        BulletWindshield()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: w * 0.22, height: bodyH * 0.42)
                            .offset(x: -w * 0.05, y: bodyH * 0.16)
                    }
                    .overlay(alignment: .trailing) {
                        // Long sleek headlight bar at the tip
                        Capsule()
                            .fill(Color.yellow.opacity(pulse ? 0.95 : 0.7))
                            .frame(width: 7, height: 2.5)
                            .shadow(color: Color.yellow.opacity(pulse ? 0.9 : 0.5),
                                    radius: pulse ? 6 : 3)
                            .offset(x: -2, y: bodyH * 0.22)
                    }
                    // Pantograph hint on the roof toward the rear
                    .overlay(alignment: .topLeading) {
                        ZStack {
                            Rectangle()
                                .fill(Color.black.opacity(0.55))
                                .frame(width: 1, height: bodyH * 0.18)
                                .offset(x: w * 0.18, y: -bodyH * 0.1)
                            Rectangle()
                                .fill(Color.black.opacity(0.55))
                                .frame(width: w * 0.16, height: 1)
                                .offset(x: w * 0.1, y: -bodyH * 0.1)
                        }
                    }
                    .frame(width: w, height: bodyH)
                    .offset(y: -wheelH)

                HStack {
                    HStack(spacing: 1) { VehicleWheel(); VehicleWheel() }
                    Spacer(minLength: 0)
                    HStack(spacing: 1) { VehicleWheel(); VehicleWheel() }
                }
                .padding(.horizontal, w * 0.14)
                .frame(width: w)
                .offset(y: 0)

                VehicleTrackShadow(width: w)
            }
            .frame(width: w, height: h, alignment: .bottomLeading)
        }
    }
}

// MARK: - Bullet-train shape primitives

/// A sleek single-body bullet-train silhouette facing right.
///
/// - Parameters:
///   - noseRatio: fraction of the total width devoted to the tapered
///     nose (0.3 = subtle taper, 0.45 = dramatic).
///   - noseDrop: how far down the front face the nose tip ends, as a
///     fraction of body height (0.0 = top, 1.0 = bottom).  Higher
///     values give the classic “diving” Shinkansen profile.
private struct BulletTrainBody: Shape {
    var noseRatio: CGFloat = 0.35
    var noseDrop: CGFloat = 0.6

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r: CGFloat = 4
        let noseStart = rect.maxX - rect.width * noseRatio
        let noseTipY = rect.minY + rect.height * noseDrop

        // Top-left corner
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        // Top edge to where the nose starts curving
        p.addLine(to: CGPoint(x: noseStart, y: rect.minY))
        // Smooth curve from roof to the very tip of the nose
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: noseTipY),
            control1: CGPoint(x: noseStart + (rect.maxX - noseStart) * 0.55, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.18)
        )
        // Curve from the tip back into the underbelly
        p.addCurve(
            to: CGPoint(x: noseStart + (rect.maxX - noseStart) * 0.35, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.04),
            control2: CGPoint(x: noseStart + (rect.maxX - noseStart) * 0.7, y: rect.maxY)
        )
        // Bottom edge back to the rear
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        // Left edge
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Slanted, asymmetric windshield hugging the bullet train's nose.
/// Drawn as a quadrilateral so it follows the nose's curvature
/// instead of looking like a square pasted on a curve.
private struct BulletWindshield: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Trapezoid leaning right — follows the nose down + forward.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.15, y: rect.minY + rect.height * 0.15))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.05, y: rect.maxY * 0.85))
        p.closeSubpath()
        return p
    }
}

#Preview {
    VStack(spacing: 16) {
        VehicleDisplayModel(kind: .subway, pulse: true)
            .frame(width: 96, height: 28)
        VehicleDisplayModel(kind: .bus, pulse: true)
            .frame(width: 84, height: 30)
        VehicleDisplayModel(kind: .lirr, pulse: true)
            .frame(width: 100, height: 30)
        VehicleDisplayModel(kind: .mnr, pulse: true)
            .frame(width: 102, height: 32)
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
