// Shimmer skeleton for arrival rows while data loads.

import SwiftUI

struct ArrivalRowSkeleton: View {
    var count: Int = 3

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 14) {
                    // Route badge
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppTheme.Colors.textSecondary.opacity(0.10))
                        .frame(width: 54, height: 36)

                    // Station + direction
                    VStack(alignment: .leading, spacing: 5) {
                        SkeletonBar(width: 130, height: 15)
                        SkeletonBar(width: 90, height: 12, opacity: 0.08)
                    }

                    Spacer()

                    // Countdown + status
                    VStack(alignment: .trailing, spacing: 6) {
                        SkeletonBar(width: 48, height: 28)
                        SkeletonBar(width: 56, height: 18, opacity: 0.10)
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, AppTheme.Layout.margin)
                .background(AppTheme.Colors.cardBackground)
                .cornerRadius(AppTheme.Layout.cornerRadius)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .shimmer()
    }
}
