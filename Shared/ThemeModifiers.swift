// Reusable surface and background helpers powered by AppTheme.
// Clean, minimal surfaces — single fill, single shadow where needed.

import SwiftUI

private struct TrackOverlayGlassModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    let tintOpacity: Double

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground.opacity(0.42))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.10), location: 0.0),
                                    .init(color: tint.opacity(tintOpacity), location: 0.38),
                                    .init(
                                        color: AppTheme.Colors.cardBackground.opacity(0.28),
                                        location: 1.0
                                    ),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.24), location: 0.0),
                                    .init(color: tint.opacity(0.14), location: 0.45),
                                    .init(
                                        color: AppTheme.Colors.borderSubtle.opacity(0.52),
                                        location: 1.0
                                    ),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: tint.opacity(0.09), radius: 16, x: 0, y: 10)
                .shadow(
                    color: AppTheme.Colors.shadowStrong.opacity(0.08),
                    radius: 14,
                    x: 0,
                    y: 8
                )
        }
    }
}

private struct TrackMistBlob: View {
    let color: Color
    let width: CGFloat
    let height: CGFloat
    let xOffset: CGFloat
    let yOffset: CGFloat
    var blurRadius: CGFloat = 56

    var body: some View {
        Ellipse()
            .fill(color)
            .frame(width: width, height: height)
            .blur(radius: blurRadius)
            .offset(x: xOffset, y: yOffset)
    }
}

struct TrackMistBackdrop: View {
    var tint: Color = AppTheme.Colors.mtaBlue

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.78)

                Rectangle()
                    .fill(.regularMaterial)
                    .opacity(0.38)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0.0),
                                .init(color: .white.opacity(0.94), location: 0.16),
                                .init(color: .white.opacity(0.62), location: 0.42),
                                .init(color: .clear, location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }

                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.34), location: 0.0),
                        .init(color: AppTheme.Colors.background.opacity(0.22), location: 0.18),
                        .init(color: tint.opacity(0.12), location: 0.42),
                        .init(color: .clear, location: 0.72),
                        .init(color: AppTheme.Colors.background.opacity(0.06), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                TrackMistBlob(
                    color: .white.opacity(0.54),
                    width: width * 1.08,
                    height: height * 0.28,
                    xOffset: -width * 0.12,
                    yOffset: -height * 0.08,
                    blurRadius: 78
                )

                TrackMistBlob(
                    color: tint.opacity(0.16),
                    width: width * 0.86,
                    height: height * 0.24,
                    xOffset: width * 0.18,
                    yOffset: height * 0.02,
                    blurRadius: 72
                )

                TrackMistBlob(
                    color: .white.opacity(0.28),
                    width: width * 0.92,
                    height: height * 0.22,
                    xOffset: width * 0.08,
                    yOffset: height * 0.18,
                    blurRadius: 70
                )

                TrackMistBlob(
                    color: tint.opacity(0.09),
                    width: width * 0.72,
                    height: height * 0.18,
                    xOffset: -width * 0.10,
                    yOffset: height * 0.34,
                    blurRadius: 62
                )

                TrackMistBlob(
                    color: AppTheme.Colors.background.opacity(0.22),
                    width: width * 0.88,
                    height: height * 0.18,
                    xOffset: width * 0.18,
                    yOffset: height * 0.48,
                    blurRadius: 74
                )
            }
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.18), location: 0.0),
                        .init(color: .clear, location: 0.20),
                        .init(color: tint.opacity(0.04), location: 1.0),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

struct TrackFogSheetSurface: View {
    var tint: Color = AppTheme.Colors.mtaBlue
    var cornerRadius: CGFloat = 44

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                        .opacity(0.44)
                }
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.26), location: 0.0),
                            .init(color: tint.opacity(0.11), location: 0.28),
                            .init(color: AppTheme.Colors.cardFloating.opacity(0.30), location: 0.64),
                            .init(color: AppTheme.Colors.cardFloating.opacity(0.14), location: 1.0),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
                .overlay {
                    TrackMistBlob(
                        color: .white.opacity(0.62),
                        width: width * 1.10,
                        height: height * 0.42,
                        xOffset: -width * 0.12,
                        yOffset: -height * 0.14,
                        blurRadius: 76
                    )
                    .mask(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                }
                .overlay {
                    TrackMistBlob(
                        color: tint.opacity(0.15),
                        width: width * 0.78,
                        height: height * 0.34,
                        xOffset: width * 0.18,
                        yOffset: height * 0.02,
                        blurRadius: 70
                    )
                    .mask(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                }
                .overlay {
                    TrackMistBlob(
                        color: .white.opacity(0.20),
                        width: width * 0.92,
                        height: height * 0.30,
                        xOffset: width * 0.02,
                        yOffset: height * 0.30,
                        blurRadius: 72
                    )
                    .mask(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.26), location: 0.0),
                                    .init(color: .white.opacity(0.06), location: 0.10),
                                    .init(color: .clear, location: 0.26),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.28), location: 0.0),
                                    .init(color: tint.opacity(0.14), location: 0.40),
                                    .init(
                                        color: AppTheme.Colors.borderSubtle.opacity(0.28),
                                        location: 1.0
                                    ),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                }
                .shadow(color: tint.opacity(0.08), radius: 28, x: 0, y: 14)
                .shadow(
                    color: AppTheme.Colors.shadowStrong.opacity(0.06),
                    radius: 24,
                    x: 0,
                    y: 10
                )
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func trackScreenBackground() -> some View {
        background {
            AppTheme.Colors.cardBackground
                .ignoresSafeArea()
        }
    }

    func trackCardBackground(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        }
    }

    func trackFloatingChrome(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Colors.cardFloating)
        }
    }

    func trackAccentBackground(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Gradients.accent)
        }
    }

    func trackInsetBackground(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Colors.cardInset)
        }
    }

    func trackTintedChrome(
        tint: Color = AppTheme.Colors.mtaBlue,
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Colors.cardFloating)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(0.04))
                }
        }
    }

    func trackOverlayGlass(
        tint: Color = AppTheme.Colors.mtaBlue,
        cornerRadius: CGFloat = 28,
        tintOpacity: Double = 0.07
    ) -> some View {
        modifier(
            TrackOverlayGlassModifier(
                tint: tint,
                cornerRadius: cornerRadius,
                tintOpacity: tintOpacity
            )
        )
    }

    // MARK: - Stale / Refreshing State

    /// Greyed-out treatment for rows refreshing stale data.
    /// Applies reduced opacity, desaturation, disables hit-testing, and
    /// animates the transition.  Use this instead of duplicating the 4
    /// modifiers inline.
    ///
    /// - Parameters:
    ///   - isStale: Whether the row/card is currently stale.
    ///   - normalOpacity: Opacity when *not* stale (default 1.0).
    ///     FavoriteCard passes a lower value for unmatched cards.
    func staleOverlay(
        _ isStale: Bool,
        normalOpacity: Double = 1.0
    ) -> some View {
        self
            .opacity(isStale ? 0.45 : normalOpacity)
            .saturation(isStale ? 0.3 : 1.0)
            .allowsHitTesting(!isStale)
            .animation(.easeInOut(duration: 0.35), value: isStale)
    }

    /// Elevated hero card — used for primary action cards and key content.
    func trackHeroCard(
        cornerRadius: CGFloat = AppTheme.Layout.cornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Colors.cardElevated)
        }
    }

    // MARK: - Glass Card

    /// Premium glass card background — fill + top-edge highlight + subtle border.
    /// Consolidates the recurring 3-layer pattern used across sheets, detail
    /// views, and cards:
    ///   1. `cardBackground` fill
    ///   2. Optional top-edge white gradient highlight
    ///   3. Subtle `borderSubtle` strokeBorder
    ///
    /// Parameters default to the most common variant. Callers that need only a
    /// plain bordered card can pass `hasHighlight: false`.
    func trackGlassCard(
        cornerRadius: CGFloat = 16,
        borderOpacity: Double = 0.2,
        borderWidth: CGFloat = 0.5,
        hasHighlight: Bool = true,
        shadowRadius: CGFloat = 0,
        shadowY: CGFloat = 0
    ) -> some View {
        background {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)

                if hasHighlight {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.05), location: 0),
                                    .init(color: .clear, location: 0.4),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                }

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        AppTheme.Colors.borderSubtle.opacity(borderOpacity),
                        lineWidth: borderWidth
                    )
            }
            .shadow(
                color: shadowRadius > 0 ? .black.opacity(0.12) : .clear,
                radius: shadowRadius,
                y: shadowY
            )
        }
    }

    /// Tinted glass card — card fill + accent-tinted border (e.g. action cards,
    /// alert rows). Uses a specific tint color instead of `borderSubtle`.
    func trackTintedCard(
        cornerRadius: CGFloat = 16,
        tint: Color = AppTheme.Colors.accent,
        borderOpacity: Double = 0.15,
        borderWidth: CGFloat = 0.8
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(tint.opacity(borderOpacity), lineWidth: borderWidth)
                )
        }
    }
}
