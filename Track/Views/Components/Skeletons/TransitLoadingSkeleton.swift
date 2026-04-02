// Shimmer skeleton shown in the dashboard while transit arrivals
// are being fetched. Shows all three distance-tier sections
// (Near You / A Bit Farther / Much Farther) with skeleton
// section headers and route rows for a seamless swap.

import SwiftUI

/// Full-section shimmer shown while transit data is loading.
/// Mirrors the 3-tier layout (Near You → A Bit Farther → Much Farther)
/// of the real NearbyDashboard for a seamless transition.
struct TransitLoadingSkeleton: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── "Near You" tier ──────────────────────────────────────
            TierHeaderSkeleton(
                icon: "location.fill",
                color: AppTheme.Colors.successGreen,
                showTimestamp: true
            )
            SkeletonRouteRows(count: 3)

            // ── "A Bit Farther" tier ─────────────────────────────────
            TierHeaderSkeleton(
                icon: "figure.walk",
                color: AppTheme.Colors.mtaBlue
            )
            SkeletonRouteRows(count: 2)

            // ── "Much Farther" tier ──────────────────────────────────
            TierHeaderSkeleton(
                icon: "car.fill",
                color: .orange
            )
            SkeletonRouteRows(count: 2)
        }
        .shimmer()
    }
}

// MARK: - Tier Header Skeleton

/// Matches the layout of NearYouSectionHeader / FartherAwaySectionHeader /
/// MuchFartherAwaySectionHeader — icon + distance capsule, optional timestamp.
private struct TierHeaderSkeleton: View {
    let icon: String
    let color: Color
    var showTimestamp: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            // Icon + distance capsule placeholder
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)

                SkeletonBar(width: 30, height: 10, opacity: 0.25)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color))

            Spacer()

            if showTimestamp {
                SkeletonBar(width: 52, height: 11, opacity: 0.08)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

// MARK: - Skeleton Route Rows

/// A stack of shimmer rows that mirror GroupedRouteRow layout.
private struct SkeletonRouteRows: View {
    let count: Int

    // Vary widths per row so it feels organic
    private static let nameLengths: [CGFloat]  = [110, 90, 130, 100, 120]
    private static let subLengths:  [CGFloat]  = [75, 60, 85, 70, 80]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 12) {
                    // Route badge
                    SkeletonBar(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    // Route name + stop / direction
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBar(
                            width: Self.nameLengths[i % Self.nameLengths.count],
                            height: 15
                        )
                        SkeletonBar(
                            width: Self.subLengths[i % Self.subLengths.count],
                            height: 12,
                            opacity: 0.07
                        )
                    }

                    Spacer()

                    // Countdown chip + "min" label
                    VStack(alignment: .trailing, spacing: 5) {
                        SkeletonBar(width: 42, height: 26)
                        SkeletonBar(width: 28, height: 11, opacity: 0.07)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.vertical, 12)
                .background(AppTheme.Colors.cardBackground)
                .clipShape(RoundedRectangle(
                    cornerRadius: AppTheme.Layout.cornerRadius,
                    style: .continuous
                ))
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

#Preview {
    ScrollView {
        TransitLoadingSkeleton()
    }
    .background(AppTheme.Colors.background)
}
