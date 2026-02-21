//
//  TransitLoadingSkeleton.swift
//  Track
//
//  Shimmer skeleton shown in the dashboard while transit arrivals
//  are being fetched. Replaces the live route rows until data arrives.
//

import SwiftUI

/// Full-section shimmer shown while transit data is loading.
/// Mirrors the layout of a GroupedRouteRow for a seamless swap.
struct TransitLoadingSkeleton: View {
    // Vary widths per row so it feels organic, not machine-stamped
    private let nameLengths: [CGFloat] = [110, 90, 130]
    private let subLengths:  [CGFloat] = [75, 60, 85]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 12) {
                    // Route badge
                    SkeletonBar(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    // Route name + stop / direction
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBar(width: nameLengths[i], height: 15)
                        SkeletonBar(width: subLengths[i],  height: 12, opacity: 0.07)
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
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius, style: .continuous))
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .shimmer()
    }
}
