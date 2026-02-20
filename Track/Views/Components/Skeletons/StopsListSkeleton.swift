//
//  StopsListSkeleton.swift
//  Track
//
//  Shimmer skeleton for the stops list while route shape loads.
//

import SwiftUI

struct StopsListSkeleton: View {
    var count: Int = 6

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 12) {
                    // Stop dot
                    SkeletonCircle(
                        size: (index == 0 || index == count - 1) ? 14 : 10,
                        opacity: 0.15
                    )
                    .frame(width: 18)

                    // Stop name + details
                    VStack(alignment: .leading, spacing: 4) {
                        SkeletonBar(
                            width: CGFloat.random(in: 100...180),
                            height: 14
                        )
                        if Bool.random() {
                            SkeletonBar(width: 60, height: 10, opacity: 0.08)
                        }
                    }

                    Spacer()

                    // Transfer badges placeholder
                    if index % 3 == 0 {
                        HStack(spacing: 3) {
                            SkeletonBar(width: 22, height: 22, opacity: 0.08)
                            SkeletonBar(width: 22, height: 22, opacity: 0.08)
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Layout.cardPadding)
                .padding(.vertical, 10)

                // Connecting line
                if index < count - 1 {
                    HStack(spacing: 0) {
                        Spacer().frame(width: 27)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(AppTheme.Colors.textSecondary.opacity(0.08))
                            .frame(width: 2, height: 12)
                        Spacer()
                    }
                    .padding(.leading, AppTheme.Layout.cardPadding)
                }
            }
        }
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        .padding(.horizontal, AppTheme.Layout.margin)
        .shimmer()
    }
}
