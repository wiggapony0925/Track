//
//  FavoritesSectionSkeleton.swift
//  Track
//
//  Shimmer skeleton for the entire Favorites section while data loads from Supabase.
//  Shown at the same time as TransitLoadingSkeleton on initial app load.
//

import SwiftUI

/// Full-section shimmer placeholder for Favorites.
/// Header bar + a horizontal row of FavoriteCardSkeleton cards, all shimmer together.
struct FavoritesSectionSkeleton: View {
    var cardCount: Int = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // "FAVORITES" header placeholder — same height as DashboardSectionHeader
            SkeletonBar(width: 72, height: 12, opacity: 0.09)
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.top, 8)

            // Horizontal card placeholders
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<cardCount, id: \.self) { _ in
                        FavoriteCardSkeleton()
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
            }
            .disabled(true)
        }
        .shimmer()
    }
}
