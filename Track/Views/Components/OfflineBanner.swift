//
//  OfflineBanner.swift
//  Track
//
// Drops down from the top safe area when the device loses network.
// Same purple accent as the navbar, rounded "bubble" pill, slash-cloud
// icon, single line of text.  Auto-hides when connectivity returns.
//
// Shows context-aware copy depending on whether the offline tile pack
// has been downloaded:
//   • Pack ready   → "Offline — using cached map"     (reassuring)
//   • Pack missing → "Offline — map may be blank"     (informative)
//
//  Observes `OfflineCacheManager.shared.isOnline` (NWPathMonitor backed)
//  so it reacts within ~1 s of airplane mode toggling on or off.
//

import SwiftUI

struct OfflineBanner: View {
    @ObservedObject private var cacheManager = OfflineCacheManager.shared
    @ObservedObject private var tileManager = MapTileOfflineManager.shared

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

    // MARK: - Subviews

    private var bubble: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
            Text(bannerText)
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
        .accessibilityLabel(bannerText)
    }

    // MARK: - Dynamic Copy

    /// Icon reflects whether cached tiles are available.
    private var iconName: String {
        if case .downloaded = tileManager.downloadState {
            return "wifi.slash"
        }
        return "exclamationmark.triangle"
    }

    /// Copy reflects whether the map will still render offline.
    private var bannerText: String {
        if case .downloaded = tileManager.downloadState {
            return "Offline — using cached map"
        }
        return "Offline — map may be blank"
    }
}

#Preview {
    ZStack(alignment: .top) {
        Color.gray.ignoresSafeArea()
        OfflineBanner()
    }
}
