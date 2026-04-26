//
//  OfflineBanner.swift
//  Track
//
//  Drops down from the top safe area when the device loses network.
//  Same purple accent as the navbar, rounded "bubble" pill, slash-cloud
//  icon, single line of text.  Auto-hides when connectivity returns.
//
//  Observes `OfflineCacheManager.shared.isOnline` (NWPathMonitor backed)
//  so it reacts within ~1 s of airplane mode toggling on or off.
//

import SwiftUI

struct OfflineBanner: View {
    @ObservedObject private var cacheManager = OfflineCacheManager.shared

    var body: some View {
        Group {
            if !cacheManager.isOnline {
                bubble
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                    )
            }
        }
        .animation(
            .spring(response: 0.45, dampingFraction: 0.82),
            value: cacheManager.isOnline
        )
    }

    private var bubble: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
            Text("Offline — no real-time data")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(AppTheme.Colors.accent)
                .shadow(
                    color: AppTheme.Colors.accent.opacity(0.35),
                    radius: 10, x: 0, y: 4
                )
        )
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Offline. No real-time data.")
    }
}

#Preview {
    ZStack(alignment: .top) {
        Color.gray.ignoresSafeArea()
        OfflineBanner()
    }
}
