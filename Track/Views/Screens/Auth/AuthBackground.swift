// Shared visual chrome for the authentication flow.
//
// Provides:
//   * `AuthBackground` — the screen-fill background used by `LoginView`,
//     `SignInView` and `CreateAccountView`. Combines the standard theme
//     gradient with a hand-drawn NYC transit pattern (subway lines +
//     station dots in MTA bullet colors) so the auth flow feels
//     branded rather than generic.
//   * `AuthFieldStyle` / `AuthFieldRow` — the unified text-field look.
//   * `AuthPrimaryButton` — the gradient pill CTA.
//   * `AuthErrorBanner` / `AuthInfoBanner` — inline status messaging.
//
// These components are intentionally local to the auth flow so design
// tweaks here don't ripple into the rest of the app.

import SwiftUI

// MARK: - Background

struct AuthBackground: View {
    /// Optional offset for the radial accent halo so each screen can
    /// nudge it for a parallax-style hand-off between pushes.
    var haloOffset: CGSize = .init(width: 0, height: -260)

    @State private var pulse = false

    var body: some View {
        ZStack {
            AppTheme.Gradients.screen
            AppTheme.Gradients.screenGlow

            TransitLinePattern()
                .opacity(0.55)
                .blendMode(.plusLighter)

            // Soft accent wash anchored above the hero so it tints the
            // top of the screen without competing with the form.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            AppTheme.Colors.accent.opacity(0.30),
                            AppTheme.Colors.accentSecondary.opacity(0.10),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 260
                    )
                )
                .frame(width: 460, height: 460)
                .blur(radius: 50)
                .offset(haloOffset)
                .scaleEffect(pulse ? 1.06 : 0.94)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Transit line pattern

/// Hand-drawn NYC-flavoured pattern: a few diagonal "subway lines" in
/// MTA bullet colors with station dots laid over a faint dot grid.
/// Used at low opacity behind the auth screens so the brand feels
/// native rather than templated.
private struct TransitLinePattern: View {
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                drawDotGrid(in: context, size: size)
                drawLines(in: context, size: size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }

    private func drawDotGrid(in context: GraphicsContext, size: CGSize) {
        let spacing: CGFloat = 28
        let dotSize: CGFloat = 1.6
        let color = Color.white.opacity(0.06)

        var x: CGFloat = 0
        while x < size.width {
            var y: CGFloat = 0
            while y < size.height {
                let rect = CGRect(
                    x: x - dotSize / 2,
                    y: y - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )
                context.fill(Path(ellipseIn: rect), with: .color(color))
                y += spacing
            }
            x += spacing
        }
    }

    private func drawLines(in context: GraphicsContext, size: CGSize) {
        // Each line is a gently curved diagonal across the canvas.
        // Colors mirror real MTA route bullet hues so the motif reads
        // as "transit" without naming any one route.
        let lines: [(color: Color, yStart: CGFloat, yEnd: CGFloat, opacity: Double)] = [
            (.init(red: 0.93, green: 0.32, blue: 0.32), 0.05, 0.62, 0.32), // red trunk
            (.init(red: 0.00, green: 0.72, blue: 0.50), 0.18, 0.78, 0.28), // green trunk
            (.init(red: 0.99, green: 0.58, blue: 0.20), 0.32, 0.92, 0.30), // orange trunk
            (.init(red: 0.30, green: 0.55, blue: 0.96), 0.46, 1.05, 0.30), // blue trunk
            (.init(red: 0.99, green: 0.80, blue: 0.20), 0.60, 1.18, 0.24), // yellow trunk
        ]

        for line in lines {
            var path = Path()
            let startY = size.height * line.yStart
            let endY = size.height * line.yEnd
            let cp1 = CGPoint(x: size.width * 0.30, y: startY + size.height * 0.06)
            let cp2 = CGPoint(x: size.width * 0.70, y: endY - size.height * 0.04)

            path.move(to: CGPoint(x: -20, y: startY))
            path.addCurve(
                to: CGPoint(x: size.width + 20, y: endY),
                control1: cp1,
                control2: cp2
            )

            context.stroke(
                path,
                with: .color(line.color.opacity(line.opacity)),
                style: StrokeStyle(lineWidth: 4, lineCap: .round)
            )

            // Station dots along the line at quarter points.
            for t in stride(from: 0.18, through: 0.92, by: 0.18) {
                let p = pointOnCurve(
                    t: t,
                    p0: CGPoint(x: -20, y: startY),
                    p1: cp1,
                    p2: cp2,
                    p3: CGPoint(x: size.width + 20, y: endY)
                )
                let dot = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                context.fill(
                    Path(ellipseIn: dot),
                    with: .color(Color.white.opacity(0.55))
                )
                context.stroke(
                    Path(ellipseIn: dot),
                    with: .color(line.color.opacity(line.opacity + 0.15)),
                    lineWidth: 1.25
                )
            }
        }
    }

    private func pointOnCurve(
        t: Double,
        p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint
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

// MARK: - Field row

struct AuthFieldRow<Field: Hashable>: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var autocap: TextInputAutocapitalization = .words
    var isSecure: Bool = false
    var revealable: Bool = false
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}

    let field: Field
    var focusBinding: FocusState<Field?>.Binding

    @State private var revealed = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 18)

            Group {
                if isSecure && !revealed {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(.system(size: 14.5, weight: .medium, design: .rounded))
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .keyboardType(keyboard)
            .textContentType(contentType)
            .textInputAutocapitalization(autocap)
            .autocorrectionDisabled(true)
            .focused(focusBinding, equals: field)
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)

            if revealable {
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.Colors.cardElevated.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            focusBinding.wrappedValue == field
                                ? AppTheme.Colors.accent.opacity(0.55)
                                : AppTheme.Colors.borderSubtle.opacity(0.5),
                            lineWidth: focusBinding.wrappedValue == field ? 1.1 : 0.5
                        )
                )
                .shadow(
                    color: focusBinding.wrappedValue == field
                        ? AppTheme.Colors.accent.opacity(0.16)
                        : .clear,
                    radius: 10, y: 3
                )
        )
    }
}

// MARK: - Primary button

struct AuthPrimaryButton: View {
    let label: String
    var icon: String = "arrow.right"
    var isWorking: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView()
                        .tint(AppTheme.Colors.textOnColor)
                        .scaleEffect(0.8)
                }
                Text(isWorking ? "Please wait…" : label)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                if !isWorking {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .heavy))
                }
            }
            .foregroundStyle(AppTheme.Colors.textOnColor)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .trackAccentBackground(cornerRadius: 14)
            .shadow(color: AppTheme.Colors.accent.opacity(0.30), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isWorking)
        .opacity(isEnabled ? 1 : 0.55)
    }
}

// MARK: - Banners

struct AuthErrorBanner: View {
    let message: String
    var body: some View {
        AuthBanner(
            icon: "exclamationmark.triangle.fill",
            color: AppTheme.Colors.alertRed,
            message: message
        )
    }
}

struct AuthInfoBanner: View {
    let message: String
    var body: some View {
        AuthBanner(
            icon: "envelope.badge.fill",
            color: AppTheme.Colors.successGreen,
            message: message
        )
    }
}

private struct AuthBanner: View {
    let icon: String
    let color: Color
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(color)
            Text(message)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(color.opacity(0.25), lineWidth: 0.75)
                )
        )
    }
}

// MARK: - Friendly error mapping (shared)

enum AuthErrorMapper {
    static func friendly(_ error: Error) -> String {
        let raw = (error as? SupabaseError)?.localizedDescription
            ?? error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("invalid login") || lower.contains("invalid_credentials") {
            return "That email and password don't match. Try again."
        }
        if lower.contains("user already registered") || lower.contains("already exists") {
            return "An account with that email already exists. Try signing in instead."
        }
        if lower.contains("password should be") {
            return "Password must be at least 6 characters."
        }
        return raw
    }
}
