//
//  CountdownChipSkeleton.swift
//  Track
//
//  Shimmer skeleton for countdown chips while route data loads.
//

import SwiftUI

struct CountdownChipSkeleton: View {
    var count: Int = 3

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(0..<count, id: \.self) { index in
                    VStack(spacing: 8) {
                        SkeletonBar(width: 40, height: index == 0 ? 36 : 28)
                        SkeletonBar(width: 28, height: 10, opacity: 0.08)
                        SkeletonBar(width: 50, height: 18, opacity: 0.10)
                    }
                    .frame(width: index == 0 ? 100 : 80)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(AppTheme.Colors.cardBackground)
                            .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
                    )
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
            .padding(.vertical, 2)
        }
        .shimmer()
    }
}
