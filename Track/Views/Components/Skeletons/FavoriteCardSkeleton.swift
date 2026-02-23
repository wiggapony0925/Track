//
//  FavoriteCardSkeleton.swift
//  Track
//
//  Shimmer placeholder shown while favorites are being fetched from Supabase.
//  Matches the exact dimensions of FavoriteCard for a seamless transition.
//

import SwiftUI

/// Shimmer placeholder for a single FavoriteCard.
struct FavoriteCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Badge + countdown row
            HStack(spacing: 8) {
                SkeletonBar(width: AppTheme.Layout.badgeSizeMedium, height: AppTheme.Layout.badgeSizeMedium)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                SkeletonBar(width: 48, height: 16)
            }
            // Stop name
            SkeletonBar(width: 105, height: 12, opacity: 0.08)
            // Direction
            SkeletonBar(width: 82, height: 11, opacity: 0.07)
        }
        .padding(12)
        .frame(minWidth: 140)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
