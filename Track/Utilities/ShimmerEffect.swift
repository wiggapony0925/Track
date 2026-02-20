//
//  ShimmerEffect.swift
//  Track
//
//  Reusable shimmer / skeleton loading effect used across the app
//  while async data is loading. Matches the existing TransitLoadingSkeleton
//  style from DashboardView but as a composable View + ViewModifier.
//

import SwiftUI

// MARK: - Shimmer Modifier

/// A subtle shimmer animation that sweeps a highlight across any view.
/// Apply with `.shimmer(active: isLoading)`.
struct ShimmerModifier: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1.0

    func body(content: Content) -> some View {
        if active {
            content
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.25),
                                .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width)
                        .blendMode(.softLight)
                    }
                    .clipped()
                )
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        phase = 1.5
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    /// Adds a sweeping shimmer highlight when `active` is true.
    func shimmer(active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

// MARK: - Skeleton Shapes

/// A rounded placeholder bar used in skeleton loading states.
struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var opacity: Double = 0.12

    var body: some View {
        RoundedRectangle(cornerRadius: height / 3)
            .fill(AppTheme.Colors.textSecondary.opacity(opacity))
            .frame(width: width, height: height)
    }
}

/// A circular placeholder used for icons in skeleton loading states.
struct SkeletonCircle: View {
    var size: CGFloat = 28
    var opacity: Double = 0.12

    var body: some View {
        Circle()
            .fill(AppTheme.Colors.textSecondary.opacity(opacity))
            .frame(width: size, height: size)
    }
}


